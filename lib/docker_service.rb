require 'fileutils'
require 'json'
require 'shellwords'
require_relative '../config'
require_relative 'command_runner'
require_relative 'one_password'

module Core
  module DockerService
    QUERY_TIMEOUT = 30
    ACTION_TIMEOUT = 120
    PULL_TIMEOUT = 900
    POST_START_TIMEOUT = 300
    HEALTH_READINESS_TIMEOUT = 90
    HEALTH_POLL_INTERVAL = 2
    PRUNE_TIMEOUT = 900
    PRUNE_MIN_INTERVAL = 86_400
    PRUNE_UNTIL = '168h'
    PRUNE_MARKER = File.join(Config::RUNTIME_DIR, 'docker_prune.last_success')

    def self.ensure_network_exists
      stdout, stderr, status = run(
        'network', 'ls', '--filter', "name=#{Config::NETWORK_NAME}", '--format', '{{.Name}}',
        timeout: QUERY_TIMEOUT,
        label: 'Docker network lookup'
      )
      raise "Error checking for Docker network: #{stderr}" unless status.success?

      return unless stdout.strip.empty?

      puts "Creating Docker network #{Config::NETWORK_NAME}..."
      _stdout, stderr, status = run(
        'network', 'create', Config::NETWORK_NAME,
        timeout: ACTION_TIMEOUT,
        label: 'Docker network creation'
      )
      raise "Error creating Docker network: #{stderr}" unless status.success?
    end

    def self.get_container_id(container_name)
      stdout, stderr, status = run(
        'ps', '-a', '--filter', "name=^#{container_name}$", '--format', '{{.ID}}',
        timeout: QUERY_TIMEOUT,
        label: 'Docker container lookup'
      )
      raise "Error checking for container #{container_name}: #{stderr}" unless status.success?

      stdout.strip
    end

    def self.container_running?(container_name)
      container_id = get_container_id(container_name)
      return false if container_id.empty?

      container_id_running?(container_id, container_name)
    end

    def self.container_id_running?(container_id, container_name = container_id)
      stdout, stderr, status = run(
        'inspect', '--format', '{{.State.Running}}', container_id,
        timeout: QUERY_TIMEOUT,
        label: 'Docker container inspection'
      )
      raise "Error inspecting container #{container_name}: #{stderr}" unless status.success?

      stdout.strip == 'true'
    end

    def self.get_container_image_details(container_id)
      # Get full image name including tag from container
      stdout, stderr, status = run(
        'inspect', '--format', '{{.Config.Image}}', container_id,
        timeout: QUERY_TIMEOUT,
        label: 'Docker image inspection'
      )
      raise "Error getting image name from container: #{stderr}" unless status.success?

      full_image_name = stdout.strip

      # Get image ID
      stdout, stderr, status = run(
        'inspect', '--format', '{{.Image}}', container_id,
        timeout: QUERY_TIMEOUT,
        label: 'Docker image inspection'
      )
      raise "Error getting image ID from container: #{stderr}" unless status.success?

      image_id = stdout.strip

      { full_name: full_image_name, id: image_id }
    end

    def self.pull_image(image)
      puts "Pulling Docker image: #{image}..."
      _stdout, stderr, status = run(
        'pull', image,
        timeout: PULL_TIMEOUT,
        label: 'Docker image pull'
      )

      if status.success?
        puts "Successfully pulled Docker image: #{image}"
        true
      else
        puts "Warning: Failed to pull Docker image #{image}: #{stderr}"
        false
      end
    end

    def self.stop_container(container_name)
      container_id = get_container_id(container_name)
      return if container_id.empty?

      if container_id_running?(container_id, container_name)
        puts "Stopping container: #{container_name}..."
        _stdout, stderr, status = run(
          'stop', container_id,
          timeout: ACTION_TIMEOUT,
          label: 'Docker container stop'
        )
        raise "Error stopping container #{container_name}: #{stderr}" unless status.success?
      else
        puts "Container #{container_name} is already stopped."
      end

      puts "Removing container: #{container_name}..."
      _stdout, stderr, status = run(
        'rm', container_id,
        timeout: ACTION_TIMEOUT,
        label: 'Docker container removal'
      )
      raise "Error removing container #{container_name}: #{stderr}" unless status.success?

      puts "Container #{container_name} stopped and removed successfully."
    end

    def self.start_container(service_config)
      # Ensure directories exist for volumes
      service_config[:volumes]&.each do |volume|
        host_path = volume.split(':').first
        FileUtils.mkdir_p(host_path) if host_path.start_with?('/')
      end

      # Resolve environment variables
      resolved_env = Core::OnePassword.resolve_env_vars(service_config[:environment] || {})

      # Bound Docker's own log files even when callers do not specify logging options.
      cmd = ['run', '-d', '--name', service_config[:name], '--restart', 'unless-stopped']
      cmd.concat(['--network', Config::NETWORK_NAME])
      cmd.concat(['--log-driver', service_config.fetch(:log_driver, 'local')])
      log_options = service_config.fetch(:log_options, { 'max-size' => '10m', 'max-file' => '3' })
      log_options.each { |key, value| cmd.concat(['--log-opt', "#{key}=#{value}"]) }

      # Add env file if specified
      if service_config[:env_file]
        cmd.concat(['--env-file', service_config[:env_file]])
      end

      # Add volumes
      service_config[:volumes]&.each do |volume|
        cmd.concat(['-v', volume])
      end

      # Add ports
      service_config[:ports]&.each do |port|
        cmd.concat(['-p', port])
      end

      # Add healthcheck if specified
      if service_config[:healthcheck]
        hc = service_config[:healthcheck]
        cmd.concat(['--health-cmd', hc[:test]])
        cmd.concat(['--health-interval', hc[:interval]]) if hc[:interval]
        cmd.concat(['--health-timeout', hc[:timeout]]) if hc[:timeout]
        cmd.concat(['--health-retries', hc[:retries].to_s]) if hc[:retries]
        cmd.concat(['--health-start-period', hc[:start_period]]) if hc[:start_period]
      end

      runtime_env_path = write_runtime_environment(service_config[:name], resolved_env)
      begin
        cmd.concat(['--env-file', runtime_env_path]) if runtime_env_path

        # Add image
        cmd << service_config[:image]

        # Add command if specified
        if service_config[:cmd]
          container_command = service_config[:cmd].is_a?(Array) ? service_config[:cmd] : Shellwords.split(service_config[:cmd])
          cmd.concat(container_command)
        end

        # Execute the command
        puts "Starting container: #{service_config[:name]}..."
        _stdout, stderr, status = run(
          *cmd,
          timeout: ACTION_TIMEOUT,
          label: 'Docker container start'
        )
      ensure
        File.delete(runtime_env_path) if runtime_env_path && File.exist?(runtime_env_path)
      end

      raise "Error starting container #{service_config[:name]}: #{stderr}" unless status.success?

      puts "Container #{service_config[:name]} started successfully."

      # Execute post-start command if specified
      if service_config[:post_start_cmd]
        puts "Running post-start command for #{service_config[:name]}..."
        # Wait a moment for the container to be fully ready
        sleep 3
        _stdout, stderr, status = Core::CommandRunner.capture3(
          service_config[:post_start_cmd],
          timeout: POST_START_TIMEOUT,
          label: 'Container post-start command'
        )
        if status.success?
          puts "Post-start command completed successfully."
        else
          puts "Warning: Post-start command failed: #{stderr}"
          puts "You may need to run this manually: #{service_config[:post_start_cmd]}"
        end
      end

      true
    end

    def self.restart_container(container_name)
      container_id = get_container_id(container_name)
      if container_id.empty?
        puts "Container #{container_name} not found, cannot restart."
        return false
      end

      puts "Restarting container: #{container_name}..."
      _stdout, stderr, status = run(
        'restart', container_id,
        timeout: ACTION_TIMEOUT,
        label: 'Docker container restart'
      )
      raise "Error restarting container #{container_name}: #{stderr}" unless status.success?

      puts "Container #{container_name} restarted successfully."
      true
    end

    def self.container_health_status(container_name)
      container_id = get_container_id(container_name)
      return 'not_running' if container_id.empty?

      stdout, stderr, status = run(
        'inspect', '--format', '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}', container_id,
        timeout: QUERY_TIMEOUT,
        label: 'Docker health inspection'
      )
      raise "Error checking container health for #{container_name}: #{stderr}" unless status.success?

      stdout.strip
    end

    def self.container_healthy?(container_name)
      container_health_status(container_name) == 'healthy'
    end

    def self.wait_for_healthy(container_name, timeout: HEALTH_READINESS_TIMEOUT,
                              interval: HEALTH_POLL_INTERVAL,
                              clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) },
                              sleeper: ->(seconds) { sleep(seconds) })
      deadline = clock.call + timeout
      status = nil

      loop do
        status = container_health_status(container_name)
        return status if status == 'healthy'
        return status if clock.call >= deadline

        sleeper.call([interval, deadline - clock.call].min)
      end
    end

    def self.container_logging_compliant?(container_name, service_config = {})
      container_id = get_container_id(container_name)
      return false if container_id.empty?

      stdout, stderr, status = run(
        'inspect', '--format', '{{json .HostConfig.LogConfig}}', container_id,
        timeout: QUERY_TIMEOUT,
        label: 'Docker logging inspection'
      )
      raise "Error checking container logging for #{container_name}: #{stderr}" unless status.success?

      actual = JSON.parse(stdout)
      expected_driver = service_config.fetch(:log_driver, 'local').to_s
      expected_options = service_config.fetch(:log_options, { 'max-size' => '10m', 'max-file' => '3' })
                                       .transform_keys(&:to_s)
                                       .transform_values(&:to_s)
      actual['Type'].to_s == expected_driver && expected_options.all? do |key, value|
        actual.fetch('Config', {})[key].to_s == value
      end
    rescue JSON::ParserError => e
      raise "Error parsing container logging for #{container_name}: #{e.message}"
    end

    def self.image_id(image_name)
      stdout, _stderr, status = run(
        'image', 'inspect', '--format', '{{.Id}}', image_name,
        timeout: QUERY_TIMEOUT,
        label: 'Docker image ID lookup'
      )
      return nil unless status.success?

      stdout.strip
    end

    def self.container_uses_image?(container_name, image_name)
      container_id = get_container_id(container_name)
      return false if container_id.empty?

      configured_image_id = image_id(image_name)
      return false if configured_image_id.to_s.empty?

      get_container_image_details(container_id)[:id] == configured_image_id
    end

    def self.normalize_image_name(image_name)
      # If no tag is specified, Docker assumes 'latest'
      return "#{image_name}:latest" unless image_name.include?(':')

      image_name
    end

    def self.ensure_container_running(service_config)
      name = service_config[:name]
      specified_image = normalize_image_name(service_config[:image])

      if container_running?(name)
        container_id = get_container_id(name)
        container_image = get_container_image_details(container_id)
        running_image = normalize_image_name(container_image[:full_name])
        logging_compliant = container_logging_compliant?(name, service_config)

        # Check if auto-update is enabled and images don't match exactly
        if service_config[:auto_update] && running_image != specified_image
          puts "Container #{name} is running image #{running_image}, but config specifies #{specified_image}"

          # Try to pull the specified image
          if pull_image(specified_image)
            puts "Container #{name} needs to be updated to use the specified image."
            stop_container(name)
            start_container(service_config)
          else
            puts 'Failed to pull specified image, keeping existing container running.'
          end
        elsif !logging_compliant
          puts "Container #{name} has noncompliant logging; recreating it with bounded local logs."
          stop_container(name)
          start_container(service_config)
        else
          puts "Container #{name} is already running with the correct image tag."
        end
      else
        puts "Container #{name} is not running, starting it now..."
        # A stopped container still owns its name and must be removed first.
        stop_container(name)
        # Try to pull the image first if auto_update is enabled
        pull_image(specified_image) if service_config[:auto_update]
        start_container(service_config)
      end
    end

    def self.prune_old_cache(marker_path: PRUNE_MARKER, now: Time.now,
                             min_interval: PRUNE_MIN_INTERVAL, until_age: PRUNE_UNTIL)
      if File.exist?(marker_path)
        last_success = begin
          Time.at(Integer(File.read(marker_path).strip))
        rescue ArgumentError, TypeError
          File.mtime(marker_path)
        end
        if now - last_success < min_interval
          puts "Docker image/cache pruning last succeeded at #{last_success}; skipping."
          return false
        end
      end

      puts "Pruning unused Docker images and build cache older than #{until_age}..."
      [
        ['image', 'prune', '--all', '--force', '--filter', "until=#{until_age}"],
        ['builder', 'prune', '--all', '--force', '--filter', "until=#{until_age}"]
      ].each do |arguments|
        stdout, stderr, status = run(
          *arguments,
          timeout: PRUNE_TIMEOUT,
          label: 'Docker cache pruning'
        )
        puts stdout unless stdout.strip.empty?
        raise "Docker cache pruning failed: #{stderr}" unless status.success?
      end

      write_private_marker(marker_path, "#{now.to_i}\n")
      puts 'Unused Docker image/cache pruning completed successfully.'
      true
    end

    def self.write_private_marker(path, content)
      FileUtils.mkdir_p(File.dirname(path))
      temporary_path = "#{path}.tmp-#{Process.pid}-#{rand(1_000_000)}"
      File.open(temporary_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(content)
        file.flush
        file.fsync
      end
      File.chmod(0o600, temporary_path)
      File.rename(temporary_path, path)
      File.chmod(0o600, path)
    ensure
      File.delete(temporary_path) if temporary_path && File.exist?(temporary_path)
    end
    private_class_method :write_private_marker

    def self.write_runtime_environment(service_name, environment)
      return if environment.empty?

      content = environment.map do |key, value|
        env_key = key.to_s.dup.force_encoding(Encoding::UTF_8)
        unless env_key.valid_encoding? && env_key.match?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
          raise "Invalid environment variable name for #{service_name}"
        end

        env_value = value.to_s.dup.force_encoding(Encoding::UTF_8)
        unless env_value.valid_encoding?
          raise "Environment variable #{env_key} for #{service_name} contains invalid UTF-8"
        end
        if env_value.include?("\0") || env_value.include?("\n") || env_value.include?("\r")
          raise "Environment variable #{env_key} for #{service_name} cannot be represented safely"
        end
        "#{env_key}=#{env_value}"
      end.join("\n")

      safe_name = service_name.to_s.gsub(/[^A-Za-z0-9_.-]/, '_')
      path = File.join(runtime_environment_directory, "#{safe_name}-#{Process.pid}-#{rand(1_000_000)}.env")
      write_private_marker(path, "#{content}\n")
      path
    end
    private_class_method :write_runtime_environment

    def self.runtime_environment_directory
      File.join(Config::RUNTIME_DIR, 'env', 'containers')
    end
    private_class_method :runtime_environment_directory

    def self.run(*arguments, timeout:, label:)
      Core::CommandRunner.capture3(
        'docker', *arguments,
        timeout: timeout,
        label: label
      )
    end
    private_class_method :run
  end
end

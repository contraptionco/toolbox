require 'fileutils'
require 'digest'
require 'net/http'
require 'uri'
require 'json'
require 'yaml'
require_relative '../config'
require_relative 'command_runner'
require_relative 'docker_service'
require_relative 'one_password'

module Core
  module GitService
    GIT_TIMEOUT = 300
    BUILD_TIMEOUT = 3600
    DOCKER_QUERY_TIMEOUT = 30
    DOCKER_BUILD_TIMEOUT = 3600
    COMPOSE_TIMEOUT = 1200
    HTTP_OPEN_TIMEOUT = 5
    HTTP_READ_TIMEOUT = 10
    HTTP_WRITE_TIMEOUT = 5

    def self.clone_repo(repo_url, local_path, branch = nil)
      puts "Cloning repository: #{repo_url} to #{local_path}..."

      # Create parent directories if they don't exist
      FileUtils.mkdir_p(File.dirname(local_path))

      command = ['git', 'clone']
      command.concat(['--branch', branch]) if branch
      command.concat([repo_url, local_path])
      _stdout, stderr, status = run_command(
        *command,
        timeout: GIT_TIMEOUT,
        label: 'Git clone'
      )
      raise "Error cloning repository: #{stderr}" unless status.success?

      puts "Repository cloned successfully."
    end

    def self.pull_latest(local_path, branch = nil)
      Dir.chdir(local_path) do
        puts "Fetching latest changes..."
        fetch_command = ['git', 'fetch', 'origin']
        fetch_command << branch if branch
        _stdout, stderr, status = run_command(
          *fetch_command,
          timeout: GIT_TIMEOUT,
          label: 'Git fetch'
        )
        raise "Error fetching updates: #{stderr}" unless status.success?

        if branch
          puts "Checking out branch: #{branch}..."
          _stdout, stderr, status = run_command(
            'git', 'checkout', branch,
            timeout: GIT_TIMEOUT,
            label: 'Git checkout'
          )
          raise "Error checking out branch #{branch}: #{stderr}" unless status.success?
        end

        puts "Pulling latest changes..."
        pull_command = ['git', 'pull', '--ff-only']
        pull_command.concat(['origin', branch]) if branch
        _stdout, stderr, status = run_command(
          *pull_command,
          timeout: GIT_TIMEOUT,
          label: 'Git pull'
        )
        raise "Error pulling updates: #{stderr}" unless status.success?

        puts "Repository updated successfully."
      end
    end

    def self.has_changes?(local_path, branch = 'main')
      return true unless Dir.exist?(local_path)

      Dir.chdir(local_path) do
        _stdout, stderr, status = run_command(
          'git', 'fetch', 'origin', branch,
          timeout: GIT_TIMEOUT,
          label: 'Git fetch'
        )
        raise "Error fetching updates: #{stderr}" unless status.success?

        stdout, stderr, status = run_command(
          'git', 'branch', '--show-current',
          timeout: GIT_TIMEOUT,
          label: 'Git branch lookup'
        )
        raise "Error checking current branch: #{stderr}" unless status.success?
        return true unless stdout.strip == branch

        # Compare local and remote branches
        stdout, stderr, status = run_command(
          'git', 'rev-list', "HEAD..origin/#{branch}", '--count',
          timeout: GIT_TIMEOUT,
          label: 'Git update check'
        )
        raise "Error checking for updates: #{stderr}" unless status.success?

        stdout.strip.to_i > 0
      end
    end

    def self.run_build_command(local_path, build_cmd)
      puts "Running build command in #{local_path}: #{build_cmd}"
      Dir.chdir(local_path) do
        _stdout, stderr, status = run_command(
          build_cmd,
          timeout: BUILD_TIMEOUT,
          label: 'Project build'
        )
        raise "Error building project: #{stderr}" unless status.success?
        puts "Build completed successfully."
      end
    end

    def self.deploy_files(source_path, dest_path)
      puts "Deploying files from #{source_path} to #{dest_path}..."

      # Ensure the destination directory exists
      FileUtils.mkdir_p(dest_path)

      # Remove destination contents if it exists
      FileUtils.rm_rf(Dir.glob("#{dest_path}/*"))

      # Copy files from source to destination
      FileUtils.cp_r(Dir.glob("#{source_path}/*"), dest_path)

      puts "Files deployed successfully."
    end

    def self.apply_env_file(env_path, env_config)
      puts "Applying environment configuration to #{env_path}..."

      env_content = if env_config.is_a?(Hash) && env_config[:type] == '1password'
        Core::OnePassword.get_item(env_config[:item], env_config[:field])
      else
        env_config.to_s
      end

      env_content.strip!
      if env_content.start_with?('"') && env_content.end_with?('"')
        env_content = env_content[1...-1]
        env_content = env_content.gsub('""', '"')
      end

      changed = !File.exist?(env_path) || File.binread(env_path) != env_content
      atomic_write(env_path, env_content, mode: 0o600) if changed
      File.chmod(0o600, env_path)

      puts(changed ? "Environment configuration saved to #{env_path}." : 'Environment configuration is unchanged.')
      changed
    end

    def self.apply_compose_override(local_path, override_config)
      puts "Applying docker-compose override to #{local_path}..."

      # Helper function to convert keys to strings recursively
      stringify_keys = ->(hash) do
        hash.each_with_object({}) do |(key, value), result|
          new_key = key.is_a?(Symbol) ? key.to_s : key
          new_value = case value
                      when Hash
                        stringify_keys.call(value)
                      when Array
                        value.map { |item| item.is_a?(Hash) ? stringify_keys.call(item) : item }
                      else
                        value
                      end
          result[new_key] = new_value
        end
      end

      override_path = File.join(local_path, "compose.override.yml")
      content = stringify_keys.call(override_config).to_yaml
      changed = !File.exist?(override_path) || File.binread(override_path) != content
      atomic_write(override_path, content, mode: 0o600) if changed
      File.chmod(0o600, override_path)

      puts(changed ? "Docker Compose override saved to #{override_path}." : 'Docker Compose override is unchanged.')
      changed
    end

    def self.docker_compose_up(local_path, force_recreate: false)
      puts "Starting/Updating Docker Compose services in #{local_path}..."
      Dir.chdir(local_path) do
        command = ['docker', 'compose', 'up', '--wait', '--detach']
        command << '--force-recreate' if force_recreate
        stdout, stderr, status = run_command(
          *command,
          timeout: COMPOSE_TIMEOUT,
          label: 'Docker Compose startup'
        )
        puts stdout unless stdout.strip.empty?
        raise "Docker Compose startup failed for #{local_path}: #{stderr}" unless status.success?

        puts "Docker Compose services started/updated successfully for #{local_path}."
      end
    end

    def self.docker_compose_down(local_path)
      puts "Stopping Docker Compose services in #{local_path}..."
      Dir.chdir(local_path) do
        stdout, stderr, status = run_command(
          'docker', 'compose', 'down',
          timeout: COMPOSE_TIMEOUT,
          label: 'Docker Compose shutdown'
        )
        puts stdout unless stdout.strip.empty?
        unless status.success?
           puts "Warning: 'docker compose down' failed for #{local_path}: #{stderr}"
        else
           puts "Docker Compose services stopped successfully for #{local_path}."
        end
      end
    end

    def self.image_exists?(image_name)
      _stdout, _stderr, status = run_command(
        'docker', 'image', 'inspect', image_name,
        timeout: DOCKER_QUERY_TIMEOUT,
        label: 'Docker image lookup'
      )
      status.success?
    end

    def self.build_docker_image(local_path, image_name)
      puts "Building Docker image #{image_name} in #{local_path}..."

      Dir.chdir(local_path) do
        _stdout, stderr, status = run_command(
          'docker', 'build', '-t', image_name, '.',
          timeout: DOCKER_BUILD_TIMEOUT,
          label: 'Docker image build'
        )
        raise "Error building Docker image: #{stderr}" unless status.success?
      end

      puts "Docker image built successfully."
    end

    def self.compose_file_path(local_path)
      %w[compose.yml compose.yaml docker-compose.yml docker-compose.yaml]
        .map { |filename| File.join(local_path, filename) }
        .find { |path| File.exist?(path) }
    end

    def self.runtime_env_path(service_name)
      safe_name = service_name.to_s.gsub(/[^a-zA-Z0-9_.-]/, '_')
      File.join(Config::RUNTIME_DIR, 'env', "#{safe_name}.env")
    end

    def self.deployment_marker_path(service_config)
      return service_config[:deployment_marker_path] if service_config[:deployment_marker_path]

      safe_name = service_config[:name].to_s.gsub(/[^a-zA-Z0-9_.-]/, '_')
      File.join(Config::RUNTIME_DIR, 'deployments', "#{safe_name}.head")
    end

    def self.current_head(local_path)
      stdout, stderr, status = Dir.chdir(local_path) do
        run_command(
          'git', 'rev-parse', 'HEAD',
          timeout: GIT_TIMEOUT,
          label: 'Git HEAD lookup'
        )
      end
      raise "Error reading repository HEAD: #{stderr}" unless status.success?

      stdout.strip
    end

    def self.deployment_state(service_config, head, env_path: nil, compose_override_path: nil)
      config_for_digest = service_config.reject { |key, _value| key == :deployment_marker_path }
      components = [Marshal.dump(config_for_digest)]
      components << File.binread(env_path) if env_path && File.exist?(env_path)
      if compose_override_path && File.exist?(compose_override_path)
        components << File.binread(compose_override_path)
      end
      digest = Digest::SHA256.hexdigest(components.join("\0"))
      "#{head}\n#{digest}\n"
    end

    def self.deployment_required?(service_config, state)
      marker_path = deployment_marker_path(service_config)
      return true unless File.exist?(marker_path)

      File.binread(marker_path) != state
    end

    def self.mark_deployed(service_config, state)
      atomic_write(deployment_marker_path(service_config), state, mode: 0o600)
    end

    def self.atomic_write(path, content, mode:)
      FileUtils.mkdir_p(File.dirname(path))
      temporary_path = "#{path}.tmp-#{Process.pid}-#{rand(1_000_000)}"
      File.open(temporary_path, File::WRONLY | File::CREAT | File::EXCL, mode) do |file|
        file.write(content)
        file.flush
        file.fsync
      end
      File.chmod(mode, temporary_path)
      File.rename(temporary_path, path)
    ensure
      File.delete(temporary_path) if temporary_path && File.exist?(temporary_path)
    end

    def self.deploy_with_temp_folder(source_path, dest_path, build_cmd)
      puts "Deploying with temporary folder from #{source_path} to #{dest_path}..."

      # Create a temporary folder name based on the source path
      temp_folder = "#{source_path}-temp"

      # Remove old temp folder if it exists
      FileUtils.rm_rf(temp_folder) if Dir.exist?(temp_folder)

      # Copy source to temp folder
      FileUtils.cp_r(source_path, temp_folder)

      # Remove .git folder from temp
      git_dir = File.join(temp_folder, '.git')
      puts "Removing .git folder from temporary directory..."
      FileUtils.rm_rf(git_dir)

      # Run build command in temp folder
      puts "Building in temporary folder..."
      run_build_command(temp_folder, build_cmd)

      # Deploy from temp to destination
      deploy_files(temp_folder, dest_path)

      # Clean up temp folder
      FileUtils.rm_rf(temp_folder)

      puts "Deployment with temporary folder completed successfully."
    end

    def self.get_latest_release_tag(repo_url)
      # Extracts owner/repo from URL like https://github.com/getsentry/self-hosted.git
      match = repo_url.match(%r{github\.com/([^/]+)/([^/.]+)(\.git)?})
      return nil unless match

      owner, repo = match[1], match[2]
      releases_url = URI("https://api.github.com/repos/#{owner}/#{repo}/releases/latest")

      begin
        http = Net::HTTP.new(releases_url.host, releases_url.port)
        http.use_ssl = releases_url.scheme == 'https'
        http.open_timeout = HTTP_OPEN_TIMEOUT
        http.read_timeout = HTTP_READ_TIMEOUT
        http.write_timeout = HTTP_WRITE_TIMEOUT if http.respond_to?(:write_timeout=)
        response = http.request(Net::HTTP::Get.new(releases_url.request_uri))
        data = JSON.parse(response.body)
        tag_name = data['tag_name']
        puts "Latest release tag found: #{tag_name}"
        tag_name
      rescue StandardError => e
        puts "Warning: Could not fetch latest release tag for #{repo_url}: #{e.message}"
        nil
      end
    end

    def self.checkout_tag(local_path, tag)
      return unless tag

      Dir.chdir(local_path) do
        puts "Checking out tag: #{tag}..."
        _stdout, stderr, status = run_command(
          'git', 'checkout', tag,
          timeout: GIT_TIMEOUT,
          label: 'Git tag checkout'
        )
        # Ignore error if already on the tag
        unless status.success? || stderr.include?("Already on '#{tag}'") || stderr.include?("is already checked out at")
          raise "Error checking out tag #{tag}: #{stderr}"
        end
        puts "Successfully checked out tag #{tag}."
      end
    end

    def self.run_install_command(local_path, install_cmd)
      puts "Running install command in #{local_path}: #{install_cmd}"
      Dir.chdir(local_path) do
        _stdout, stderr, status = run_command(
          install_cmd,
          timeout: BUILD_TIMEOUT,
          label: 'Service install command'
        )
        raise "Error running install command: #{stderr}" unless status.success?
        puts "Install command completed successfully."
      end
    end

    def self.update_git_service(service_config)
      name = service_config[:name]
      local_path = service_config[:local_path]
      repo_url = service_config[:repo_url]
      branch = service_config[:branch]
      install_cmd = service_config[:install_cmd]
      use_compose = service_config[:use_compose]

      puts "Processing Git service: #{name}..."

      repo_exists = Dir.exist?(local_path)
      repo_updated_or_cloned = false

      if repo_exists
        if service_config[:auto_update]
          changes = has_changes?(local_path, branch || 'main')
          if changes || service_config[:force_update]
            puts "Changes detected in repository, updating..."
            pull_latest(local_path, branch)
            repo_updated_or_cloned = true
          else
            puts "No changes detected in repository."
          end
        else
          puts "Auto-update disabled for #{name}. Checking repository status."
          unless Dir.exist?(File.join(local_path, '.git'))
            raise "#{local_path} exists but is not a valid Git repository"
          end
        end
      else
        puts "Repository not found locally, cloning..."
        clone_repo(repo_url, local_path, branch)
        repo_exists = true
        repo_updated_or_cloned = true
      end

      if branch
        puts "Using specified branch: #{branch}"
      else
        latest_tag = get_latest_release_tag(repo_url)
        checkout_tag(local_path, latest_tag)
      end

      env_path = nil
      env_changed = false
      if service_config[:env_config]
        env_path = if service_config[:container_config]
                     runtime_env_path(name)
                   else
                     File.join(local_path, '.env')
                   end
        env_changed = apply_env_file(env_path, service_config[:env_config])

        if service_config[:container_config]
          expanded_env_path = File.expand_path(env_path)
          expanded_repo_path = "#{File.expand_path(local_path)}/"
          raise 'Runtime environment file must be outside the Docker build context' if expanded_env_path.start_with?(expanded_repo_path)

          legacy_env_path = File.join(local_path, '.env')
          if File.file?(legacy_env_path) || File.symlink?(legacy_env_path)
            File.delete(legacy_env_path)
            puts "Removed legacy environment file from Docker build context: #{legacy_env_path}"
          elsif File.exist?(legacy_env_path)
            raise "Legacy environment path is not a file: #{legacy_env_path}"
          end
        end
      end

      compose_override_path = nil
      compose_override_changed = false
      if service_config[:compose_override]
        compose_override_path = File.join(local_path, 'compose.override.yml')
        compose_override_changed = apply_compose_override(local_path, service_config[:compose_override])
      end

      head = current_head(local_path)
      desired_state = deployment_state(
        service_config,
        head,
        env_path: env_path,
        compose_override_path: compose_override_path
      )
      deployment_needed = repo_updated_or_cloned || service_config[:force_update] ||
                          deployment_required?(service_config, desired_state)

      if deployment_needed
        if name == 'ghost_theme' && service_config[:deploy_path] && service_config[:build_cmd]
          deploy_with_temp_folder(local_path, service_config[:deploy_path], service_config[:build_cmd])
        else
          run_build_command(local_path, service_config[:build_cmd]) if service_config[:build_cmd]
          deploy_files(local_path, service_config[:deploy_path]) if service_config[:deploy_path]
        end

        if service_config[:container_config]&.dig(:image_name)
          build_docker_image(local_path, service_config[:container_config][:image_name])
        end
      end

      if service_config[:container_config]
        container_name = name
        container_config = service_config[:container_config]
        image_name = container_config[:image_name]
        docker_config = {
          name: container_name,
          image: image_name,
          ports: container_config[:ports],
          volumes: container_config[:volumes],
          env_file: env_path,
          environment: container_config[:environment] || {},
          cmd: container_config[:cmd],
          healthcheck: container_config[:healthcheck],
          log_driver: container_config.fetch(:log_driver, 'local'),
          log_options: container_config.fetch(:log_options, { 'max-size' => '10m', 'max-file' => '3' })
        }

        build_docker_image(local_path, image_name) if image_name && !image_exists?(image_name)

        container_running = Core::DockerService.container_running?(container_name)
        health_status = if container_running && docker_config[:healthcheck]
                          Core::DockerService.container_health_status(container_name)
                        end
        healthcheck_missing = health_status == 'none'
        healthcheck_unhealthy = health_status == 'unhealthy'
        logging_noncompliant = container_running &&
                               !Core::DockerService.container_logging_compliant?(container_name, docker_config)
        image_mismatch = container_running && image_name &&
                         !Core::DockerService.container_uses_image?(container_name, image_name)
        recreate = deployment_needed || env_changed || !container_running || healthcheck_missing ||
                   healthcheck_unhealthy || logging_noncompliant || image_mismatch

        if recreate
          puts "Recreating #{container_name} to apply its healthcheck." if healthcheck_missing
          puts "Recreating unhealthy container #{container_name}." if healthcheck_unhealthy
          puts "Recreating #{container_name} to apply bounded logging." if logging_noncompliant
          puts "Recreating #{container_name} to use the successfully built image." if image_mismatch
          Core::DockerService.stop_container(container_name)
          Core::DockerService.start_container(docker_config)
        else
          puts "Container #{container_name} is already running and up-to-date."
        end

        if docker_config[:healthcheck]
          readiness_status = Core::DockerService.wait_for_healthy(
            container_name,
            timeout: docker_config[:healthcheck].fetch(
              :readiness_timeout,
              Core::DockerService::HEALTH_READINESS_TIMEOUT
            ),
            interval: docker_config[:healthcheck].fetch(
              :readiness_interval,
              Core::DockerService::HEALTH_POLL_INTERVAL
            )
          )
          unless readiness_status == 'healthy'
            raise "Container #{container_name} failed readiness (#{readiness_status})"
          end
        end
      elsif use_compose || service_config[:compose_override]
        base_compose_path = compose_file_path(local_path)
        if install_cmd && !base_compose_path
          puts "Docker Compose file missing. Running install command for #{name}..."
          run_install_command(local_path, install_cmd)
          base_compose_path = compose_file_path(local_path)
        end
        raise "Docker Compose file not found in #{local_path}" unless base_compose_path

        stdout, stderr, status = Dir.chdir(local_path) do
          run_command(
            'docker', 'compose', 'ps', '-q',
            timeout: DOCKER_QUERY_TIMEOUT,
            label: 'Docker Compose status'
          )
        end
        raise "Docker Compose status failed for #{name}: #{stderr}" unless status.success?

        compose_running = !stdout.strip.empty?
        compose_changed = compose_override_changed || env_changed
        if deployment_needed || compose_changed || !compose_running
          puts "Ensuring Docker Compose services are up for #{name}..."
          docker_compose_up(local_path, force_recreate: compose_changed)
        else
          puts "Docker Compose services for #{name} are already running."
        end
      end

      if deployment_needed && service_config[:after_deploy]&.dig(:type) == 'restart_service'
        Core::DockerService.restart_container(service_config[:after_deploy][:service])
      end

      mark_deployed(service_config, desired_state) if deployment_needed || env_changed || compose_override_changed
      true
    end

    def self.run_command(*command, timeout:, label:)
      Core::CommandRunner.capture3(
        *command,
        timeout: timeout,
        label: label
      )
    end
    private_class_method :run_command
  end
end

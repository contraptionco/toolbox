require 'fileutils'
require 'digest'
require 'net/http'
require 'uri'
require 'json'
require 'yaml'
require 'tmpdir'
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

    # Backup writers still use this helper. Unlike application deployment,
    # they can legitimately have pending exports or an unpushed backup commit.
    # Git's fast-forward-only merge preserves that work and rejects conflicts;
    # never switch branches, reset, or reuse this path for deploying applications.
    def self.pull_latest(local_path, branch = 'main')
      branch = branch || 'main'
      git_output!(local_path, 'check-ref-format', "refs/heads/#{branch}")
      expected_branch = -> do
        current = git_output!(local_path, 'branch', '--show-current').strip
        unless current == branch
          raise "Backup checkout is not on #{branch}; refusing to switch or update it"
        end
      end
      expected_branch.call
      remote_ref = "refs/remotes/origin/#{branch}"
      git_output!(local_path, 'fetch', '--no-tags', 'origin', "refs/heads/#{branch}:#{remote_ref}")
      expected_branch.call
      git_output!(local_path, 'merge', '--ff-only', remote_ref)
      true
    end

    # Resolve only an explicit origin branch or tag. An omitted ref always means
    # main; the developer's current branch/upstream never selects production.
    def self.resolve_remote_release(local_path, requested_ref)
      ref = requested_ref.to_s
      raise 'A release ref is required' if ref.empty? || ref.start_with?('-')

      candidates = if ref.start_with?('refs/heads/', 'refs/tags/')
                     [ref]
                   else
                     ["refs/heads/#{ref}", "refs/tags/#{ref}"]
                   end
      candidates.each do |candidate|
        git_output!(local_path, 'check-ref-format', candidate)
      end
      listing = git_output!(local_path, 'ls-remote', '--refs', 'origin', *candidates)
      matches = listing.lines.filter_map do |line|
        _sha, remote_ref = line.split
        remote_ref if candidates.include?(remote_ref)
      end.uniq
      raise "Release ref #{ref} is missing or ambiguous on origin" unless matches.length == 1

      remote_ref = matches.first
      temporary_ref = "refs/toolbox/release-#{Process.pid}-#{rand(1_000_000_000)}"
      begin
        git_output!(local_path, 'fetch', '--no-tags', 'origin', "#{remote_ref}:#{temporary_ref}")
        head = git_output!(local_path, 'rev-parse', '--verify', "#{temporary_ref}^{commit}").strip
        { head: head, name: remote_ref.sub(%r{\Arefs/(heads|tags)/}, ''), tag: remote_ref.start_with?('refs/tags/') }
      ensure
        git_output!(local_path, 'update-ref', '-d', temporary_ref)
      end
    end

    def self.ensure_clean_source!(local_path, generated_paths: [])
      status = git_output!(local_path, 'status', '--porcelain=v1', '-z', '--untracked-files=all', '--ignore-submodules=none')
      status.split("\0").each do |entry|
        # Only explicitly configured, untracked generated files are exempt.
        # Tracked modifications to those same names are always rejected.
        next if entry.start_with?('?? ') && generated_paths.include?(entry[3..])

        raise "Application checkout #{local_path} is dirty; refusing deployment"
      end
    end

    def self.prepare_release(service_config)
      local_path = service_config.fetch(:local_path)
      requested_ref = service_config[:branch] || 'main'
      cloned = !Dir.exist?(local_path)
      clone_repo(service_config.fetch(:repo_url), local_path, requested_ref.sub(%r{\Arefs/(heads|tags)/}, '')) if cloned
      generated_paths = []
      generated_paths << '.env' if service_config[:env_config]
      generated_paths << 'compose.override.yml' if service_config[:compose_override]
      ensure_clean_source!(local_path, generated_paths: generated_paths)
      ensure_generated_paths_untracked!(local_path, generated_paths)

      release = resolve_remote_release(local_path, requested_ref)
      branch = git_output!(local_path, 'branch', '--show-current').strip
      head = current_head(local_path)
      if release[:tag]
        unless (branch.empty? || branch == release[:name]) && head == release[:head]
          raise "Application checkout does not match pinned origin tag #{requested_ref}; refusing deployment"
        end
      else
        unless branch == release[:name]
          raise "Application checkout is on #{branch.empty? ? 'a detached HEAD' : branch}, expected #{release[:name]}; refusing deployment"
        end
        # A local commit must already be reachable from the approved remote ref.
        # This rejects both unpushed commits and divergent histories.
        git_output!(local_path, 'merge-base', '--is-ancestor', head, release[:head])
        if service_config[:auto_update] && head != release[:head]
          git_output!(local_path, 'merge', '--ff-only', release[:head])
          head = release[:head]
        end
      end
      ensure_clean_source!(local_path, generated_paths: generated_paths)
      ensure_generated_paths_untracked!(local_path, generated_paths)
      raise 'Application HEAD changed during validation; refusing deployment' unless current_head(local_path) == head

      { head: head, cloned: cloned }
    end

    def self.ensure_generated_paths_untracked!(local_path, generated_paths)
      generated_paths.each do |path|
        tracked = git_output!(local_path, 'ls-files', '--', path)
        raise "Configured generated file #{path} is tracked; refusing deployment" unless tracked.empty?
      end
    end

    def self.git_output!(local_path, *arguments)
      stdout, stderr, status = run_command(
        'git', '-C', local_path, *arguments,
        timeout: GIT_TIMEOUT,
        label: 'Application source validation'
      )
      raise "Application source validation failed (#{arguments.first}): #{stderr.strip}" unless status.success?

      stdout
    end

    # Archive the verified commit instead of copying a mutable working tree.
    # Ignored files, untracked files, and edits made after validation cannot enter
    # the build context. Temp directories are private and removed on failure.
    def self.with_release_snapshot(local_path, head)
      tree = git_output!(local_path, 'ls-tree', '-r', '-z', head)
      if tree.split("\0").any? { |entry| entry.start_with?('160000 ') }
        raise 'Immutable release snapshots do not support Git submodules'
      end
      Dir.mktmpdir('toolbox-release-') do |directory|
        archive = File.join(directory, 'source.tar')
        source = File.join(directory, 'source')
        FileUtils.mkdir_p(source)
        git_output!(local_path, 'archive', '--format=tar', "--output=#{archive}", head)
        _stdout, stderr, status = run_command(
          'tar', '-xf', archive, '-C', source,
          timeout: GIT_TIMEOUT,
          label: 'Application release extraction'
        )
        raise "Could not extract application release: #{stderr}" unless status.success?

        yield source
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

      Dir.mktmpdir('toolbox-image-') do |directory|
        image_id_path = File.join(directory, 'image.id')
        _stdout, stderr, status = Dir.chdir(local_path) do
          run_command(
            'docker', 'build', '--iidfile', image_id_path, '-t', image_name, '.',
            timeout: DOCKER_BUILD_TIMEOUT,
            label: 'Docker image build'
          )
        end
        raise "Error building Docker image: #{stderr}" unless status.success?

        image_id = File.read(image_id_path).strip
        raise 'Docker build did not produce an immutable image ID' unless image_id.match?(/\Asha256:[0-9a-f]{64}\z/)

        puts 'Docker image built successfully.'
        image_id
      end
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
      install_cmd = service_config[:install_cmd]
      use_compose = service_config[:use_compose]

      puts "Processing Git service: #{name}..."
      release = prepare_release(service_config)
      head = release.fetch(:head)

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

      desired_state = deployment_state(
        service_config,
        head,
        env_path: env_path,
        compose_override_path: compose_override_path
      )
      deployment_needed = release[:cloned] || service_config[:force_update] ||
                          deployment_required?(service_config, desired_state)

      built_image_id = nil
      if deployment_needed && (service_config[:build_cmd] || service_config[:deploy_path] || service_config[:container_config])
        with_release_snapshot(local_path, head) do |source|
          run_build_command(source, service_config[:build_cmd]) if service_config[:build_cmd]
          deploy_files(source, service_config[:deploy_path]) if service_config[:deploy_path]
          if service_config[:container_config]&.dig(:image_name)
            built_image_id = build_docker_image(source, service_config[:container_config][:image_name])
          end
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
        if image_mismatch && !deployment_needed
          raise "Local image tag #{image_name} differs from running #{container_name}; refusing unapproved image replacement"
        end
        recreate = deployment_needed || env_changed || !container_running || healthcheck_missing ||
                   healthcheck_unhealthy || logging_noncompliant || image_mismatch

        if recreate
          puts "Recreating #{container_name} to apply its healthcheck." if healthcheck_missing
          puts "Recreating unhealthy container #{container_name}." if healthcheck_unhealthy
          puts "Recreating #{container_name} to apply bounded logging." if logging_noncompliant
          puts "Recreating #{container_name} to use the successfully built image." if image_mismatch
          # Every replacement uses a build from the verified commit. Never adopt
          # an existing mutable tag, including after a development build changed it.
          built_image_id ||= with_release_snapshot(local_path, head) do |source|
            run_build_command(source, service_config[:build_cmd]) if service_config[:build_cmd]
            build_docker_image(source, image_name)
          end
          docker_config[:image] = built_image_id
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

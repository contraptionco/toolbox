require 'open3'
require 'fileutils'
require 'net/http'
require 'uri'
require 'json'
require_relative '../config'
require_relative 'docker_service'
require_relative 'one_password'

module Core
  module GitService
    def self.clone_repo(repo_url, local_path, branch = nil)
      puts "Cloning repository: #{repo_url} to #{local_path}..."

      # Create parent directories if they don't exist
      FileUtils.mkdir_p(File.dirname(local_path))

      # Clone the repository
      # Clone without checking out a specific branch initially if we need to find the latest tag
      cmd = "git clone --no-checkout #{repo_url} #{local_path}"

      stdout, stderr, status = Open3.capture3(cmd)
      raise "Error cloning repository: #{stderr}" unless status.success?

      puts "Repository cloned successfully."
    end

    def self.pull_latest(local_path, branch = nil)
      Dir.chdir(local_path) do
        puts "Fetching latest changes..."
        stdout, stderr, status = Open3.capture3("git fetch")
        raise "Error fetching updates: #{stderr}" unless status.success?

        if branch
          puts "Checking out branch: #{branch}..."
          stdout, stderr, status = Open3.capture3("git checkout #{branch}")
          raise "Error checking out branch #{branch}: #{stderr}" unless status.success?
        end

        puts "Pulling latest changes..."
        stdout, stderr, status = Open3.capture3("git pull")
        raise "Error pulling updates: #{stderr}" unless status.success?

        puts "Repository updated successfully."
      end
    end

    def self.has_changes?(local_path, branch = 'main')
      return true unless Dir.exist?(local_path)

      Dir.chdir(local_path) do
        stdout, stderr, status = Open3.capture3("git fetch")
        raise "Error fetching updates: #{stderr}" unless status.success?

        # Compare local and remote branches
        cmd = "git rev-list HEAD..origin/#{branch} --count"
        stdout, stderr, status = Open3.capture3(cmd)
        raise "Error checking for updates: #{stderr}" unless status.success?

        stdout.strip.to_i > 0
      end
    end

    def self.run_build_command(local_path, build_cmd)
      puts "Running build command in #{local_path}: #{build_cmd}"
      Dir.chdir(local_path) do
        stdout, stderr, status = Open3.capture3(build_cmd)
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

    def self.apply_env_file(local_path, env_config)
      puts "Applying environment configuration to #{local_path}..."

      env_content = if env_config.is_a?(Hash) && env_config[:type] == '1password'
        Core::OnePassword.get_item(env_config[:item], env_config[:field])
      else
        env_config.to_s
      end

      env_content.strip!
      if env_content.start_with?('"') && env_content.end_with?('"')
        env_content = env_content[1...-1]
      end

      env_path = File.join(local_path, ".env")
      File.write(env_path, env_content)

      puts "Environment configuration saved to #{env_path}."
    end

    def self.apply_compose_override(local_path, override_config)
      require 'yaml'

      puts "Applying docker-compose override to #{local_path}..."

      override_path = File.join(local_path, "compose.override.yml")
      File.write(override_path, override_config.to_yaml)

      puts "Docker Compose override saved to #{override_path}."
    end

    def self.docker_compose_up(local_path)
      puts "Starting/Updating Docker Compose services in #{local_path}..."
      Dir.chdir(local_path) do
        # Using --wait might be beneficial for services that depend on others
        # Using --detach ensures it runs in the background
        stdout, stderr, status = Open3.capture3("docker compose up --wait --detach")
        puts stdout unless stdout.strip.empty?
        unless status.success?
          puts "Warning: 'docker compose up' failed for #{local_path}: #{stderr}"
          # Consider raising an error depending on desired behavior
          # raise "Error starting Docker Compose services: #{stderr}"
        else
           puts "Docker Compose services started/updated successfully for #{local_path}."
        end
      end
    end

    def self.docker_compose_down(local_path)
      puts "Stopping Docker Compose services in #{local_path}..."
      Dir.chdir(local_path) do
        stdout, stderr, status = Open3.capture3("docker compose down")
        puts stdout unless stdout.strip.empty?
        unless status.success?
           puts "Warning: 'docker compose down' failed for #{local_path}: #{stderr}"
        else
           puts "Docker Compose services stopped successfully for #{local_path}."
        end
      end
    end

    def self.build_docker_image(local_path, image_name)
      puts "Building Docker image #{image_name} in #{local_path}..."

      Dir.chdir(local_path) do
        stdout, stderr, status = Open3.capture3("docker build -t #{image_name} .")
        raise "Error building Docker image: #{stderr}" unless status.success?
      end

      puts "Docker image built successfully."
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
        response = Net::HTTP.get(releases_url)
        data = JSON.parse(response)
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
        stdout, stderr, status = Open3.capture3("git checkout #{tag}")
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
        stdout, stderr, status = Open3.capture3(install_cmd)
        raise "Error running install command: #{stderr}" unless status.success?
        puts "Install command completed successfully."
      end
    end

    def self.update_git_service(service_config)
      name = service_config[:name]
      local_path = service_config[:local_path]
      repo_url = service_config[:repo_url]
      branch = service_config[:branch] # May not be used if we fetch latest tag
      install_cmd = service_config[:install_cmd]
      use_compose = service_config[:use_compose]

      puts "Processing Git service: #{name}..."

      # Check if repo exists locally
      repo_exists = Dir.exist?(local_path)
      repo_updated_or_cloned = false

      # Clone or update repo
      if repo_exists
        if service_config[:auto_update]
          changes = has_changes?(local_path, branch || 'main')
          if changes || service_config[:force_update]
            puts "Changes detected in repository, updating..."
            pull_latest(local_path, branch) # This might need adjustment if using tags primarily
            repo_updated_or_cloned = true
          else
            puts "No changes detected in repository."
          end
        else
           puts "Auto-update disabled for #{name}. Checking repository status."
           # Ensure repo is usable even if not updating
           unless Dir.exist?(File.join(local_path, '.git'))
             puts "Error: #{local_path} exists but is not a valid git repository. Please remove or fix it."
             return # Stop processing this service
           end
        end
      else
        puts "Repository not found locally, cloning..."
        clone_repo(repo_url, local_path) # Clone without branch initially
        repo_exists = true # It exists now
        repo_updated_or_cloned = true
      end

      # Checkout latest release tag (relevant for Sentry pattern)
      # Do this after clone or potentially on update if auto_update were enabled
      latest_tag = get_latest_release_tag(repo_url)
      checkout_tag(local_path, latest_tag)

      # Process if repo was just cloned/updated OR forced update OR does not exist yet
      # Simplified logic: if repo exists now, ensure it's set up correctly
      if repo_exists
        # Run install command only once after initial clone
        if install_cmd && repo_updated_or_cloned && !Dir.exist?(File.join(local_path, '.git')) # Check if it was *just* cloned
          begin
            run_install_command(local_path, install_cmd)
          rescue StandardError => e
            puts "Install command failed for #{name}: #{e.message}"
            puts "Manual intervention may be required in #{local_path}."
            return # Stop processing this service if install fails
          end
        elsif install_cmd && !repo_exists # Should have been cloned above
            puts "Warning: repo should exist but doesn't, cannot run install_cmd for #{name}"
        end

        # Handle environment file if specified (Plausible example)
        if service_config[:env_config]
          apply_env_file(local_path, service_config[:env_config])
        end

        # Handle Docker Compose override if specified (Plausible example)
        if service_config[:compose_override]
          apply_compose_override(local_path, service_config[:compose_override])
        end

        # Perform build/deploy actions if the repo was updated/cloned or forced
        if repo_updated_or_cloned || service_config[:force_update]
          # Special case for ghost_theme - use temp folder approach
          if name == 'ghost_theme' && service_config[:deploy_path] && service_config[:build_cmd]
            deploy_with_temp_folder(local_path, service_config[:deploy_path], service_config[:build_cmd])
          else
            # Standard approach for other services
            # Run build command if specified
            if service_config[:build_cmd]
              run_build_command(local_path, service_config[:build_cmd])
            end

            # Handle deployment if specified
            if service_config[:deploy_path]
              deploy_files(local_path, service_config[:deploy_path])
            end
          end

          # Build Docker image if specified (e.g., bklt)
          if service_config[:container_config]&.dig(:image_name)
            build_docker_image(local_path, service_config[:container_config][:image_name])
          end
        end # End build/deploy actions

        # Manage container state (either single container or compose)
        if service_config[:container_config]
          # Manage single Docker container
          container_name = name # Assume container name matches service name
          docker_config = {
            name: container_name,
            image: service_config[:container_config][:image_name],
            ports: service_config[:container_config][:ports],
            environment: service_config[:container_config][:environment],
            cmd: service_config[:container_config][:cmd]
            # Add volumes if needed from container_config
          }
          if repo_updated_or_cloned || service_config[:force_update] || !Core::DockerService.container_running?(container_name)
            Core::DockerService.stop_container(container_name) if Core::DockerService.container_running?(container_name)
            Core::DockerService.start_container(docker_config)
          else
            puts "Container #{container_name} is already running and up-to-date."
          end
        elsif use_compose || service_config[:compose_override]
          # Manage Docker Compose services
          # Check if compose services are running
          compose_running = false
          Dir.chdir(local_path) do
              stdout, _stderr, status = Open3.capture3("docker compose ps -q")
              compose_running = status.success? && !stdout.strip.empty?
          end

          if repo_updated_or_cloned || service_config[:force_update] || !compose_running
            # If updated, or forced, or not running, ensure they are (re)started
            puts "Ensuring Docker Compose services are up for #{name}..."
            # We might need down first if updating, but install script handles Sentry specifics
            # docker_compose_down(local_path) # Maybe only if repo_updated_or_cloned?
            docker_compose_up(local_path)
          else
            puts "Docker Compose services for #{name} are already running."
          end
        end

        # Execute after_deploy actions if repo was updated/cloned or forced
        if (repo_updated_or_cloned || service_config[:force_update]) && service_config[:after_deploy]
          if service_config[:after_deploy][:type] == 'restart_service'
            Core::DockerService.restart_container(service_config[:after_deploy][:service])
          end
        end

      end # End if repo_exists
    end
  end
end
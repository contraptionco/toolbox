require 'open3'
require 'fileutils'
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
      cmd = "git clone #{repo_url} #{local_path}"
      cmd += " -b #{branch}" if branch

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
      puts "Starting Docker Compose services in #{local_path}..."

      Dir.chdir(local_path) do
        stdout, stderr, status = Open3.capture3("docker compose up -d")
        raise "Error starting Docker Compose services: #{stderr}" unless status.success?
        puts stdout
      end

      puts "Docker Compose services started successfully."
    end

    def self.docker_compose_down(local_path)
      puts "Stopping Docker Compose services in #{local_path}..."

      Dir.chdir(local_path) do
        stdout, stderr, status = Open3.capture3("docker compose down")
        raise "Error stopping Docker Compose services: #{stderr}" unless status.success?
        puts stdout
      end

      puts "Docker Compose services stopped successfully."
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

    def self.update_git_service(service_config)
      name = service_config[:name]
      local_path = service_config[:local_path]
      repo_url = service_config[:repo_url]
      branch = service_config[:branch]

      puts "Processing Git service: #{name}..."

      # Check if repo exists locally
      repo_exists = Dir.exist?(local_path)

      # Clone or update repo
      if repo_exists
        changes = has_changes?(local_path, branch || 'main')

        if changes || service_config[:force_update]
          puts "Changes detected in repository, updating..."
          pull_latest(local_path, branch)
          repo_updated = true
        else
          puts "No changes detected in repository."
          repo_updated = false
        end
      else
        puts "Repository not found locally, cloning..."
        clone_repo(repo_url, local_path, branch)
        repo_updated = true
      end

      # Process based on service type
      if repo_updated || !repo_exists || service_config[:force_update]
        # Handle environment file if specified
        if service_config[:env_config]
          apply_env_file(local_path, service_config[:env_config])
        end

        # Handle Docker Compose override if specified
        if service_config[:compose_override]
          apply_compose_override(local_path, service_config[:compose_override])
        end

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

        # Build Docker image if specified
        if service_config[:container_config]&.dig(:image_name)
          build_docker_image(local_path, service_config[:container_config][:image_name])
        end

        # Start or restart Docker container if needed
        if service_config[:container_config]
          if Core::DockerService.container_running?(name)
            Core::DockerService.stop_container(name)
          end

          # Create a service config compatible with the Docker service module
          docker_config = {
            name: name,
            image: service_config[:container_config][:image_name],
            ports: service_config[:container_config][:ports],
            environment: service_config[:container_config][:environment],
            cmd: service_config[:container_config][:cmd]
          }

          Core::DockerService.start_container(docker_config)
        end

        # Start Docker Compose if specified
        if service_config[:compose_override]
          docker_compose_down(local_path)
          docker_compose_up(local_path)
        end

        # Execute after_deploy actions
        if service_config[:after_deploy]
          if service_config[:after_deploy][:type] == 'restart_service'
            Core::DockerService.restart_container(service_config[:after_deploy][:service])
          end
        end
      else
        # Check if Docker container needs to be started (not updated, but ensure running)
        if service_config[:container_config] && !Core::DockerService.container_running?(name)
          docker_config = {
            name: name,
            image: service_config[:container_config][:image_name],
            ports: service_config[:container_config][:ports],
            environment: service_config[:container_config][:environment],
            cmd: service_config[:container_config][:cmd]
          }

          Core::DockerService.start_container(docker_config)
        end

        # Check if Docker Compose services need to be started
        if service_config[:compose_override]
          # Check if any containers are running from the compose file
          Dir.chdir(local_path) do
            stdout, stderr, status = Open3.capture3("docker compose ps -q")
            if stdout.strip.empty?
              puts "Docker Compose services not running, starting them..."
              docker_compose_up(local_path)
            else
              puts "Docker Compose services already running."
            end
          end
        end
      end
    end
  end
end
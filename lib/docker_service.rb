require 'open3'
require 'fileutils'
require_relative '../config'
require_relative 'one_password'

module Core
  module DockerService
    def self.ensure_network_exists
      stdout, stderr, status = Open3.capture3("docker network ls --filter name=#{Config::NETWORK_NAME} --format \"{{.Name}}\"")
      raise "Error checking for Docker network: #{stderr}" unless status.success?

      return unless stdout.strip.empty?

      puts "Creating Docker network #{Config::NETWORK_NAME}..."
      stdout, stderr, status = Open3.capture3("docker network create #{Config::NETWORK_NAME}")
      raise "Error creating Docker network: #{stderr}" unless status.success?
    end

    def self.get_container_id(container_name)
      stdout, stderr, status = Open3.capture3("docker ps --filter \"name=#{container_name}\" --format \"{{.ID}}\"")
      raise "Error checking for container #{container_name}: #{stderr}" unless status.success?

      stdout.strip
    end

    def self.container_running?(container_name)
      container_id = get_container_id(container_name)
      return false if container_id.empty?

      stdout, stderr, status = Open3.capture3("docker inspect --format \"{{.State.Running}}\" #{container_id}")
      raise "Error inspecting container #{container_name}: #{stderr}" unless status.success?

      stdout.strip == 'true'
    end

    def self.get_container_image_details(container_id)
      # Get full image name including tag from container
      stdout, stderr, status = Open3.capture3("docker inspect --format \"{{.Config.Image}}\" #{container_id}")
      raise "Error getting image name from container: #{stderr}" unless status.success?

      full_image_name = stdout.strip

      # Get image ID
      stdout, stderr, status = Open3.capture3("docker inspect --format \"{{.Image}}\" #{container_id}")
      raise "Error getting image ID from container: #{stderr}" unless status.success?

      image_id = stdout.strip

      { full_name: full_image_name, id: image_id }
    end

    def self.pull_image(image)
      # Only pull if a specific tag is specified or it's 'latest'
      puts "Pulling Docker image: #{image}..."
      stdout, stderr, status = Open3.capture3("docker pull #{image}")

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

      puts "Stopping container: #{container_name}..."
      stdout, stderr, status = Open3.capture3("docker stop #{container_id}")
      raise "Error stopping container #{container_name}: #{stderr}" unless status.success?

      puts "Removing container: #{container_name}..."
      stdout, stderr, status = Open3.capture3("docker rm #{container_id}")
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

      # Build the docker run command
      cmd = ['docker run -d']
      cmd << "--name #{service_config[:name]}"
      cmd << '--restart unless-stopped'
      cmd << "--network #{Config::NETWORK_NAME}"

      # Add environment variables
      resolved_env.each do |key, value|
        cmd << "-e #{key}=\"#{value}\""
      end

      # Add volumes
      service_config[:volumes]&.each do |volume|
        cmd << "-v \"#{volume}\""
      end

      # Add ports
      service_config[:ports]&.each do |port|
        cmd << "-p #{port}"
      end

      # Add image
      cmd << service_config[:image]

      # Add command if specified
      cmd << service_config[:cmd] if service_config[:cmd]

      # Execute the command
      puts "Starting container: #{service_config[:name]}..."
      puts cmd.join(" \\\n  ")
      stdout, stderr, status = Open3.capture3(cmd.join(" \\\n  "))
      raise "Error starting container #{service_config[:name]}: #{stderr}" unless status.success?

      puts "Container #{service_config[:name]} started successfully."
      true
    end

    def self.restart_container(container_name)
      container_id = get_container_id(container_name)
      if container_id.empty?
        puts "Container #{container_name} not found, cannot restart."
        return false
      end

      puts "Restarting container: #{container_name}..."
      stdout, stderr, status = Open3.capture3("docker restart #{container_id}")
      raise "Error restarting container #{container_name}: #{stderr}" unless status.success?

      puts "Container #{container_name} restarted successfully."
      true
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
        else
          puts "Container #{name} is already running with the correct image tag."
        end
      else
        puts "Container #{name} is not running, starting it now..."
        # Try to pull the image first if auto_update is enabled
        pull_image(specified_image) if service_config[:auto_update]
        start_container(service_config)
      end
    end
  end
end

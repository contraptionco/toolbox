require_relative 'docker_service'
require_relative 'git_service'
require_relative 'system_service'
require_relative 'tunnel_service'
require_relative 'uptime_robot'
require_relative 'one_password'
require_relative 'telemetry'
require_relative '../config'
require 'fileutils'

module Core
  module ServiceManager
    def self.ensure_directories_exist
      # Create main directories if they don't exist
      [
        Config::DATA_DIR,
        Config::CODE_DIR,
        # Common subdirectories for various services
        "#{Config::DATA_DIR}/postgres",
        "#{Config::DATA_DIR}/mysql",
        "#{Config::DATA_DIR}/ghost",
        "#{Config::DATA_DIR}/plausible",
        # Log directory
        File.dirname(Config::TUNNEL_CONFIG[:log_file])
      ].each do |dir|
        unless Dir.exist?(dir)
          puts "Creating directory: #{dir}"
          FileUtils.mkdir_p(dir)
        end
      end
    end

    def self.ensure_prerequisites
      # Ensure all required directories exist
      ensure_directories_exist

      # Report anonymous usage telemetry
      Core::Telemetry.track

      # Ensure 1Password is logged in
      Core::OnePassword.ensure_logged_in

      # Ensure Docker network exists
      Core::DockerService.ensure_network_exists
    end

    def self.start_docker_services
      Config::DOCKER_SERVICES.each do |service_config|
        Core::DockerService.ensure_container_running(service_config)
      end
    end

    def self.start_git_services
      Config::GIT_SERVICES.each do |service_config|
        Core::GitService.update_git_service(service_config)
      end
    end

    def self.start_system_services
      Config::SYSTEM_SERVICES.each do |service_config|
        Core::SystemService.ensure_service_running(service_config)
      end
    end

    def self.handle_tunnel(code_changed)
      Core::TunnelService.ensure_tunnel_running(Config::TUNNEL_CONFIG, code_changed)
    end

    def self.report_uptime
      # Skip Uptime Robot if it's disabled in the config
      return unless Config.const_defined?(:UPTIME_ROBOT) && !Config::UPTIME_ROBOT.nil?

      Core::UptimeRobot.report
    end

    def self.start_all(code_changed = false)
      ensure_prerequisites

      handle_tunnel(code_changed)

      start_system_services

      start_docker_services

      start_git_services

      report_uptime

      puts 'All services started successfully!'
    end
  end
end

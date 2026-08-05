require 'fileutils'
require_relative '../config'
require_relative 'disk_monitor'
require_relative 'docker_service'
require_relative 'git_service'
require_relative 'one_password'
require_relative 'script_runner'
require_relative 'system_service'
require_relative 'telemetry'
require_relative 'tunnel_service'
require_relative 'uptime_robot'

module Core
  module ServiceManager
    class RunFailed < StandardError; end

    def self.ensure_directories_exist
      [
        Config::DATA_DIR,
        Config::CODE_DIR,
        "#{Config::DATA_DIR}/postgres",
        "#{Config::DATA_DIR}/mysql",
        "#{Config::DATA_DIR}/ghost",
        "#{Config::DATA_DIR}/plausible",
        File.dirname(Config::TUNNEL_CONFIG[:log_file])
      ].each do |dir|
        next if Dir.exist?(dir)

        puts "Creating directory: #{dir}"
        FileUtils.mkdir_p(dir)
      end
    end

    def self.ensure_prerequisites
      ensure_directories_exist
      Core::Telemetry.track
      Core::OnePassword.ensure_logged_in
      Core::DockerService.ensure_network_exists
    end

    def self.start_docker_services
      Config::DOCKER_SERVICES.each do |service_config|
        Core::DockerService.ensure_container_running(service_config)
      end
    end

    def self.start_git_services
      failures = []

      Config::GIT_SERVICES.each do |service_config|
        Core::GitService.update_git_service(service_config)
      rescue StandardError => e
        puts "Git service #{service_config[:name]} failed: #{e.message}"
        failures << { component: "git:#{service_config[:name]}", error: e }
      end

      failures
    end

    def self.run_scripts
      Core::ScriptRunner.run_scripts
    end

    def self.prune_docker_cache
      Core::DockerService.prune_old_cache
      []
    rescue StandardError => e
      puts "Docker image/cache pruning failed: #{e.message}"
      [{ component: 'docker:prune', error: e }]
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
      return true unless Config.const_defined?(:UPTIME_ROBOT) && !Config::UPTIME_ROBOT.nil?

      Core::UptimeRobot.report
    end

    def self.preflight_disk!
      status = Core::DiskMonitor.check
      return status unless status.critical?

      raise RunFailed, "Toolbox preflight failed: disk usage is #{status.percent_used}%"
    rescue RunFailed
      raise
    rescue StandardError => e
      raise RunFailed, "Toolbox preflight disk check failed: #{e.message}"
    end

    def self.configured_healthcheck_failures
      configurations = Config::DOCKER_SERVICES.filter_map do |service|
        { name: service[:name], healthcheck: service[:healthcheck] } if service[:healthcheck]
      end
      configurations.concat(Config::GIT_SERVICES.filter_map do |service|
        healthcheck = service.dig(:container_config, :healthcheck)
        { name: service[:name], healthcheck: healthcheck } if healthcheck
      end)

      configurations.filter_map do |configuration|
        healthcheck = configuration[:healthcheck]
        status = Core::DockerService.wait_for_healthy(
          configuration[:name],
          timeout: healthcheck.fetch(:readiness_timeout, Core::DockerService::HEALTH_READINESS_TIMEOUT),
          interval: healthcheck.fetch(:readiness_interval, Core::DockerService::HEALTH_POLL_INTERVAL)
        )
        next if status == 'healthy'

        puts "Container #{configuration[:name]} is not healthy (#{status}); suppressing uptime success."
        {
          component: "health:#{configuration[:name]}",
          error: StandardError.new("container health is #{status}")
        }
      rescue StandardError => e
        puts "Could not verify container health for #{configuration[:name]}: #{e.message}"
        { component: "health:#{configuration[:name]}", error: e }
      end
    end

    def self.start_all(code_changed = false)
      preflight_disk!
      ensure_prerequisites
      failures = prune_docker_cache
      handle_tunnel(code_changed)
      start_system_services
      start_docker_services

      # Backups are configured with Postgres first and run before deployments.
      # Each script and Git service records its own failure so the rest still run.
      failures.concat(run_scripts)
      failures.concat(start_git_services)

      begin
        disk_status = Core::DiskMonitor.check
        if disk_status.critical?
          failures << {
            component: 'disk',
            error: StandardError.new("disk usage is #{disk_status.percent_used}%")
          }
        end
      rescue StandardError => e
        puts "Disk usage check failed: #{e.message}"
        failures << { component: 'disk', error: e }
      end

      failures.concat(configured_healthcheck_failures)

      if failures.empty? && !report_uptime
        failures << { component: 'uptime', error: StandardError.new('uptime report failed') }
      end

      unless failures.empty?
        puts 'Toolbox completed with failures:'
        failures.each do |failure|
          puts "- #{failure[:component]}: #{failure[:error].message}"
        end
        raise RunFailed, "Toolbox failed: #{failures.map { |failure| failure[:component] }.join(', ')}"
      end

      puts 'All services started successfully!'
      true
    end
  end
end

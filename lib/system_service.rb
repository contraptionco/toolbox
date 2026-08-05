require_relative '../config'
require_relative 'command_runner'
require 'shellwords'

module Core
  module SystemService
    DETECTION_TIMEOUT = 15

    def self.service_running?(detection_cmd)
      stdout, _stderr, status = Core::CommandRunner.capture3(
        detection_cmd,
        timeout: DETECTION_TIMEOUT,
        label: 'System service detection'
      )
      return false unless status.success?

      !stdout.strip.empty?
    end

    def self.start_service(start_cmd)
      puts "Starting service with command: #{start_cmd}..."
      command = start_cmd.is_a?(Array) ? start_cmd : Shellwords.split(start_cmd)
      Core::CommandRunner.spawn_detached(
        *command,
        label: 'System service startup'
      )

      # Give it a moment to start
      sleep(2)

      puts "Service started."
    end

    def self.ensure_service_running(service_config)
      name = service_config[:name]
      detection_cmd = service_config[:detection]
      start_cmd = service_config[:start_cmd]

      if service_running?(detection_cmd)
        puts "#{name} is already running."
      else
        puts "#{name} is not running, starting it now..."
        start_service(start_cmd)
      end
    end
  end
end

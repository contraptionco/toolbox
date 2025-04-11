require 'open3'
require_relative '../config'

module Core
  module SystemService
    def self.service_running?(detection_cmd)
      stdout, stderr, status = Open3.capture3(detection_cmd)
      return false unless status.success?

      !stdout.strip.empty?
    end

    def self.start_service(start_cmd)
      puts "Starting service with command: #{start_cmd}..."
      system("nohup #{start_cmd} > /dev/null 2>&1 &")

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
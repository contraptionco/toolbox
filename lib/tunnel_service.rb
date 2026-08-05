require_relative '../config'
require_relative 'command_runner'

module Core
  module TunnelService
    DETECTION_TIMEOUT = 15

    def self.tunnel_running?
      !tunnel_pids.empty?
    end

    def self.start_tunnel(config)
      tunnel_name = config[:tunnel_name]
      config_path = config[:config_path]
      log_file = config[:log_file]

      puts "Starting Cloudflare tunnel: #{tunnel_name}..."
      Core::CommandRunner.spawn_detached(
        'cloudflared', 'tunnel', '--config', config_path, 'run', tunnel_name,
        out: [log_file, 'a'],
        err: [:child, :out],
        label: 'Cloudflare tunnel startup'
      )

      puts "Waiting for the Cloudflare tunnel to establish connections..."
      sleep(10)

      pid = tunnel_pids
      if pid.empty?
        puts "Cloudflare tunnel failed to start. Please check the log at #{log_file} for more information."
        exit(1)
      else
        puts "Cloudflare tunnel started successfully."
        pid.join("\n")
      end
    end

    def self.update_tunnel(config)
      puts "Checking for running Cloudflare tunnel..."

      old_pid = tunnel_pids

      unless old_pid.empty?
        puts "Found running Cloudflare tunnel with PID: #{old_pid.join(', ')}"
      end

      new_pid = start_tunnel(config)

      unless old_pid.empty?
        puts "Killing old Cloudflare tunnel with PID: #{old_pid.join(', ')}"
        old_pid.each { |pid| Process.kill('TERM', pid) }
      end

      puts "Cloudflare tunnel update complete."
      new_pid
    end

    def self.ensure_tunnel_running(config, code_changed = false)
      if tunnel_running?
        if code_changed
          puts "Code changes detected, updating Cloudflare tunnel..."
          update_tunnel(config)
        else
          puts "No code changes detected, Cloudflare tunnel already running. No action needed."
        end
      else
        puts "Cloudflare tunnel not running, starting a new one..."
        start_tunnel(config)
      end
    end

    def self.tunnel_pids
      stdout, _stderr, status = Core::CommandRunner.capture3(
        'pgrep', '-f', 'cloudflared tunnel',
        timeout: DETECTION_TIMEOUT,
        label: 'Cloudflare tunnel detection'
      )
      return [] unless status.success?

      stdout.lines.filter_map { |line| Integer(line.strip, exception: false) }
    end
    private_class_method :tunnel_pids
  end
end

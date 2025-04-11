require 'open3'
require_relative '../config'

module Core
  module TunnelService
    def self.tunnel_running?
      pid = `pgrep -f "cloudflared tunnel"`.strip
      !pid.empty?
    end

    def self.start_tunnel(config)
      tunnel_name = config[:tunnel_name]
      config_path = config[:config_path]
      log_file = config[:log_file]

      puts "Starting Cloudflare tunnel: #{tunnel_name}..."
      system("nohup cloudflared tunnel --config #{config_path} run #{tunnel_name} > #{log_file} 2>&1 &")

      puts "Waiting for the Cloudflare tunnel to establish connections..."
      sleep(10)

      pid = `pgrep -f "cloudflared tunnel"`.strip
      if pid.empty?
        puts "Cloudflare tunnel failed to start. Please check the log at #{log_file} for more information."
        exit(1)
      else
        puts "Cloudflare tunnel started successfully."
        pid
      end
    end

    def self.update_tunnel(config)
      puts "Checking for running Cloudflare tunnel..."

      old_pid = `pgrep -f "cloudflared tunnel"`.strip

      if !old_pid.empty?
        puts "Found running Cloudflare tunnel with PID: #{old_pid}"
      end

      new_pid = start_tunnel(config)

      unless old_pid.empty?
        puts "Killing old Cloudflare tunnel with PID: #{old_pid}"
        Process.kill('TERM', old_pid.to_i)
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
  end
end
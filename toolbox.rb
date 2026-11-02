require_relative 'lib/production_guard'

begin
  repo_dir = Core::ProductionGuard.require_production!(
    __dir__, arguments: ARGV, modes: %w[code_changed no_changes]
  )
  require_relative 'lib/command_runner'
  Core::ProductionGuard.verify_checkout!(repo_dir, command_runner: Core::CommandRunner)
rescue StandardError => e
  warn "Toolbox refused to run: #{e.message}"
  exit 1
end

require 'net/http'
require 'uri'
require 'fileutils'

# Load configuration and core modules
require_relative 'config'
require_relative 'lib/service_manager'

puts "Hello, world! I am running as user: #{Config::USER}"

# Check if code has changed. If so, restart Cloudflare Tunnel
code_changed = ARGV[1] == 'code_changed'

# Start all services
Core::ServiceManager.start_all(code_changed)

puts "That's a job well done!"

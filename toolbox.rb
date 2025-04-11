require 'net/http'
require 'uri'
require 'open3'
require 'fileutils'

# Load configuration and core modules
require_relative 'config'
require_relative 'lib/service_manager'

puts "Hello, world! I am running as user: #{Config::USER}"

# Check if code has changed. If so, restart Cloudflare Tunnel
code_changed = ARGV[0] == 'code_changed'

# Start all services
Core::ServiceManager.start_all(code_changed)

puts "That's a job well done!"

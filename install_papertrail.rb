#!/usr/bin/env ruby
require_relative 'config'

puts "Setting up PaperTrail remote_syslog configuration..."

# Get paths from config
user = Config::USER
home_dir = Config::HOME_DIR
code_dir = Config::CODE_DIR
toolbox_dir = "#{code_dir}/toolbox"
log_files_config = "#{toolbox_dir}/log_files.yml"

# Determine if we need sudo
require_sudo = true
launch_daemons_dir = "/Library/LaunchDaemons"

# Create the plist content
plist_content = <<~XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<!-- Put this file in /Library/LaunchDaemons/ -->
<plist version = "1.0">
  <dict>
    <key>Label</key>
    <string>com.papertrailapp.remote_syslog</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>UserName</key>
    <string>root</string>
    <key>ProgramArguments</key>
    <array>
      <string>/usr/local/bin/remote_syslog</string>
      <string>-c</string>
      <string>#{log_files_config}</string>
      <string>-D</string>
    </array>
  </dict>
</plist>
XML

plist_path = "#{toolbox_dir}/com.papertrailapp.remote_syslog.plist"

# Write the plist file locally first
File.write(plist_path, plist_content)
puts "PaperTrail plist written to: #{plist_path}"

# Check if log_files.yml exists
unless File.exist?(log_files_config)
  puts "\nWarning: #{log_files_config} not found. Creating a sample configuration file."

  # Create a sample log_files.yml
  sample_config = <<~YAML
  files:
    - #{toolbox_dir}/heartbeat.log
  destination:
    host: logs.papertrailapp.com
    port: 12345   # Replace with your actual port
    protocol: tls
  YAML

  File.write(log_files_config, sample_config)
  puts "Sample configuration created at: #{log_files_config}"
  puts "Please update this file with your actual PaperTrail host and port."
end

# Instructions for installation
puts "\nTo install the PaperTrail LaunchDaemon, run the following commands with sudo:"
puts "\nsudo cp #{plist_path} #{launch_daemons_dir}/"
puts "sudo launchctl load #{launch_daemons_dir}/com.papertrailapp.remote_syslog.plist"

puts "\nTo uninstall:"
puts "sudo launchctl unload #{launch_daemons_dir}/com.papertrailapp.remote_syslog.plist"
puts "sudo rm #{launch_daemons_dir}/com.papertrailapp.remote_syslog.plist"
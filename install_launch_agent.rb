#!/usr/bin/env ruby
require_relative 'config'

# Ensure required directories exist
user = Config::USER
home_dir = Config::HOME_DIR
code_dir = Config::CODE_DIR
toolbox_dir = "#{code_dir}/toolbox"
launch_agents_dir = "#{home_dir}/Library/LaunchAgents"

puts "Creating LaunchAgent for Toolbox heartbeat..."

# Create LaunchAgents directory if it doesn't exist
unless Dir.exist?(launch_agents_dir)
  puts "Creating LaunchAgents directory: #{launch_agents_dir}"
  Dir.mkdir(launch_agents_dir)
end

# Create the plist content
plist_content = <<~XML
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>co.contraption.toolbox.heartbeat</string>
    <key>ProgramArguments</key>
    <array>
        <string>#{toolbox_dir}/heartbeat.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>60</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>#{toolbox_dir}/heartbeat.log</string>
    <key>StandardErrorPath</key>
    <string>#{toolbox_dir}/heartbeat.log</string>
    <key>WorkingDirectory</key>
    <string>#{toolbox_dir}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>TOOLBOX_REPO_DIR</key>
        <string>#{toolbox_dir}</string>
        <key>HOME</key>
        <string>#{home_dir}</string>
        <key>OP_SERVICE_ACCOUNT_TOKEN</key>
        <string>FILL_THIS_IN</string>
    </dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
    <key>AbandonProcessGroup</key>
    <true/>
</dict>
</plist>
XML

plist_path = "#{launch_agents_dir}/co.contraption.toolbox.heartbeat.plist"

# Write the plist file
File.write(plist_path, plist_content)
puts "LaunchAgent plist written to: #{plist_path}"

puts "\nImportant: Before loading the LaunchAgent, edit the plist file to add your 1Password service account token:"
puts "Edit: #{plist_path}"
puts "Replace 'FILL_THIS_IN' with your actual OP_SERVICE_ACCOUNT_TOKEN value."

puts "\nTo load the LaunchAgent, run:"
puts "launchctl load #{plist_path}"

puts "\nTo unload the LaunchAgent, run:"
puts "launchctl unload #{plist_path}"
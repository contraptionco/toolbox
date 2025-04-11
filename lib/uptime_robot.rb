require 'net/http'
require 'uri'
require_relative '../config'
require_relative 'one_password'

module Core
  module UptimeRobot
    def self.report
      # Skip if Uptime Robot is disabled in config
      return true unless Config.const_defined?(:UPTIME_ROBOT) && !Config::UPTIME_ROBOT.nil?

      puts 'Reporting to Uptime Robot...'

      begin
        # Get the Uptime Robot URL from 1Password
        url = Core::OnePassword.get_item(
          Config::UPTIME_ROBOT[:url_source][:item],
          Config::UPTIME_ROBOT[:url_source][:field]
        )

        # Ensure we have a valid URL
        if url.nil? || url.empty?
          puts "Error: Could not retrieve Uptime Robot URL from 1Password"
          return false
        end

        # Send the ping
        uri = URI(url)
        response = Net::HTTP.get_response(uri)

        if response.code.to_i >= 200 && response.code.to_i < 300
          puts "Successfully reported to Uptime Robot (#{response.code})"
          true
        else
          puts "Warning: Uptime Robot responded with code #{response.code}"
          false
        end
      rescue => e
        puts "Error reporting to Uptime Robot: #{e.message}"
        false
      end
    end
  end
end

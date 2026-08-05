require 'net/http'
require 'uri'
require_relative '../config'
require_relative 'one_password'

module Core
  module UptimeRobot
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10
    WRITE_TIMEOUT = 5

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
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.open_timeout = OPEN_TIMEOUT
        http.read_timeout = READ_TIMEOUT
        http.write_timeout = WRITE_TIMEOUT if http.respond_to?(:write_timeout=)
        response = http.request(Net::HTTP::Get.new(uri.request_uri))

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

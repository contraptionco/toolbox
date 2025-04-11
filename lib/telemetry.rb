require 'net/http'
require 'uri'
require 'json'
require 'socket'
require_relative '../config'

module Core
  module Telemetry
    PLAUSIBLE_ENDPOINT = 'https://telegraph.contraption.co/api/event'

    # Send a telemetry event to Plausible Analytics (hosted on a Toolbox server)
    def self.track
      return if Config::DISABLE_ANONYMOUS_TELEMETRY

      Thread.new do
        body = {
          name: 'pageview',
          domain: 'toolbox',
          url: "app://toolbox/"
        }

        uri = URI.parse(PLAUSIBLE_ENDPOINT)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = uri.scheme == 'https'
        http.read_timeout = 1 # Very short timeout to avoid blocking
        http.open_timeout = 1

        # Create and send the request
        request = Net::HTTP::Post.new(uri.request_uri)
        request['User-Agent'] = 'Toolbox'
        request['Content-Type'] = 'application/json'
        request.body = body.to_json

        # Send the request and ignore the response
        http.request(request)
      rescue StandardError => e
        # Just silently fail
        # puts "Telemetry error: #{e.message}" if ENV['DEBUG']
      end
    end
  end
end

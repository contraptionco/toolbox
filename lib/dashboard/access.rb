require 'jwt'
require 'json'
require 'net/http'
require 'uri'
require 'thread'

module Dashboard
  # Access is the only login mechanism. Neither an email header nor a cookie is
  # trusted without Cloudflare's signature, this application's audience and issuer.
  class Access
    class Unauthorized < StandardError; end
    class Unavailable < StandardError; end
    MAX_TOKEN_BYTES = 16_384
    MAX_KEYS_BYTES = 131_072
    CACHE_SECONDS = 3600
    REFRESH_SECONDS = 60

    def initialize(issuer:, audience:, fetcher: nil, clock: -> { Time.now.to_i })
      raise ArgumentError, 'Invalid Access issuer' unless issuer.match?(%r{\Ahttps://[a-z0-9-]+\.cloudflareaccess\.com\z})
      raise ArgumentError, 'Access audience is required' if audience.to_s.empty?

      @issuer, @audience, @clock = issuer, audience, clock
      @fetcher = fetcher || method(:fetch_keys)
      @mutex = Mutex.new
      @keys, @fetched_at, @attempted_at = nil, nil, nil
    end

    def verify(token)
      raise Unauthorized, 'Cloudflare Access login required' unless token.is_a?(String) && token.bytesize.between?(1, MAX_TOKEN_BYTES)

      # The unverified header is used only to choose a public key. It cannot
      # supply a URL, algorithm, issuer or other verification configuration.
      _claims, header = JWT.decode(token, nil, false)
      raise Unauthorized, 'Invalid Access token' unless header['alg'] == 'RS256' && header['kid'].is_a?(String)

      key = public_key(header['kid'])
      claims, = JWT.decode(token, key, true,
                          algorithms: ['RS256'], verify_iss: true, iss: @issuer,
                          verify_aud: true, aud: @audience, verify_expiration: true,
                          verify_not_before: true, required_claims: %w[iss aud exp sub],
                          leeway: 15)
      raise Unauthorized, 'Invalid Access token' unless claims['exp'].is_a?(Numeric) && claims['sub'].is_a?(String) && !claims['sub'].empty?

      claims
    rescue JWT::DecodeError, ArgumentError, TypeError
      raise Unauthorized, 'Invalid Access token'
    end

    private

    def public_key(kid)
      @mutex.synchronize do
        now = @clock.call
        expired = @fetched_at.nil? || now - @fetched_at >= CACHE_SECONDS
        missing = @keys && !@keys.key?(kid)
        refresh_allowed = @attempted_at.nil? || now - @attempted_at >= REFRESH_SECONDS
        if (expired || missing) && refresh_allowed
          @attempted_at = now
          begin
            data = @fetcher.call
            list = data.fetch('keys')
            raise ArgumentError unless list.is_a?(Array) && list.length.between?(1, 30)
            keys = list.filter_map do |item|
              next unless item.is_a?(Hash) && item['kty'] == 'RSA' && item['kid'].is_a?(String)
              next if item['alg'] && item['alg'] != 'RS256'
              next if item['use'] && item['use'] != 'sig'
              [item['kid'], JWT::JWK.import(item).public_key]
            end.to_h
            raise ArgumentError if keys.empty?
            @keys, @fetched_at = keys, now
          rescue StandardError
            raise Unavailable, 'Cloudflare Access verification is temporarily unavailable'
          end
        end
        # Never use expired keys after an outage. Unknown key IDs refresh at most
        # once a minute, so forged headers cannot flood the certificate endpoint.
        raise Unavailable, 'Cloudflare Access verification is temporarily unavailable' if @fetched_at.nil? || now - @fetched_at >= CACHE_SECONDS
        @keys.fetch(kid) { raise Unauthorized, 'Invalid Access token' }
      end
    end

    def fetch_keys
      uri = URI("#{@issuer}/cdn-cgi/access/certs")
      body = +''
      Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 3, read_timeout: 3) do |http|
        http.request(Net::HTTP::Get.new(uri.request_uri)) do |response|
          raise Unavailable unless response.is_a?(Net::HTTPSuccess)
          response.read_body do |chunk|
            body << chunk
            raise Unavailable if body.bytesize > MAX_KEYS_BYTES
          end
        end
      end
      JSON.parse(body)
    end
  end
end

require 'json'
require 'time'
require 'thread'
require 'uri'
require_relative 'auth_http'
require_relative 'oauth'
require_relative 'mcp'
require_relative 'http_body'

module Dashboard
  class App
    MIME_TYPES = { '.html' => 'text/html; charset=utf-8', '.css' => 'text/css; charset=utf-8',
                   '.js' => 'application/javascript; charset=utf-8', '.json' => 'application/json',
                   '.webmanifest' => 'application/manifest+json', '.svg' => 'image/svg+xml',
                   '.png' => 'image/png', '.woff2' => 'font/woff2' }.freeze
    CSP = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self' https://fonts.philipithomas.com; img-src 'self' data:; connect-src 'self'; worker-src 'self'; manifest-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'".freeze

    def initialize(collector:, auth_http:, oauth:, origin:, public_dir:, revision:, cache_seconds: 10, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @collector, @auth_http, @oauth, @origin = collector, auth_http, oauth, origin
      @public_dir, @revision = File.realpath(public_dir), revision
      @host = URI.parse(origin).authority
      @mcp = MCP.new(collector: CachedCollector.new(self), oauth: oauth, origin: origin)
      @rate_mutex, @rates = Mutex.new, {}
      @cache_seconds, @clock = cache_seconds, clock
      @snapshot_mutex, @logs_mutex = Mutex.new, Mutex.new
      @snapshot_at, @snapshot, @logs = nil, nil, {}
    end

    # MCP uses the same bounded inventory/log cache as the browser.
    class CachedCollector
      def initialize(app) = @app = app
      def snapshot = @app.send(:snapshot)
      def logs(source, lines:) = @app.send(:logs, source, lines)
    end

    PUBLIC_ASSETS = %w[/style.css /auth.css /auth.js /app.js /offline.html /manifest.webmanifest /sw.js
                       /icons/icon.svg /icons/logo.svg /icons/icon-192.png /icons/icon-512.png
                       /icons/apple-touch-icon.png].freeze
    DISCOVERY = %w[/.well-known/oauth-authorization-server /.well-known/oauth-protected-resource
                   /.well-known/oauth-protected-resource/mcp].freeze

    def call(request, response)
      security_headers(response)
      if request.path == '/healthz' && %w[GET HEAD].include?(request.request_method)
        return json(response, 200, ok: true, revision: @revision)
      end
      return json(response, 421, error: 'Invalid request host') unless request['host'] == @host
      return @mcp.call(request, response) if request.path == '/mcp'
      if DISCOVERY.include?(request.path)
        return method_not_allowed(response, 'GET, HEAD') unless %w[GET HEAD].include?(request.request_method)
        value = request.path == DISCOVERY.first ? @oauth.authorization_metadata : @oauth.resource_metadata
        return json(response, 200, value)
      end
      return if @auth_http.call(request, response)
      return oauth_request(request, response) if request.path.start_with?('/oauth/') && request.path != '/oauth/authorize'
      if request.path == '/oauth/authorize' && request.request_method == 'POST'
        return oauth_request(request, response)
      end
      return method_not_allowed(response, 'GET, HEAD') unless %w[GET HEAD].include?(request.request_method)
      return static('/login.html', response) if ['/login', '/login.html'].include?(request.path)
      return static(request.path, response) if PUBLIC_ASSETS.include?(request.path)
      identity = @auth_http.session(request)
      unless identity
        if request.path.start_with?('/api/')
          return json(response, 401, error: 'Toolbox sign-in required', login_url: '/login')
        end
        next_path = request.path
        next_path += "?#{request.query_string}" if request.respond_to?(:query_string) && request.query_string && request.query_string.bytesize <= 8192
        return redirect(response, '/login?next=' + URI.encode_www_form_component(next_path))
      end
      case request.path
      when '/api/status' then json(response, 200, snapshot)
      when '/api/logs'
        source = request.query['source'].to_s
        count = request.query.fetch('lines', '100').to_s
        return json(response, 400, error: 'Invalid line count') unless count.match?(/\A\d{1,3}\z/) && count.to_i.between?(1, 200)
        json(response, 200, logs(source, count.to_i))
      when '/security' then static('/security.html', response)
      when '/oauth/authorize' then static('/consent.html', response)
      else static(request.path, response)
      end
    rescue OAuth::Error => error
      json(response, error.status, error: error.code, error_description: error.message)
    rescue Auth::Error => error
      json(response, error.status, error: error.message)
    rescue HTTPBody::TooLarge
      HTTPBody.reject(response)
      json(response, 413, error: 'Request too large')
    rescue JSON::ParserError, JSON::NestingError, ArgumentError
      json(response, 400, error: 'Invalid request')
    rescue StandardError
      # Do not return exception messages, subprocess stderr, paths or credentials.
      json(response, 503, error: 'Toolbox is temporarily unavailable')
    ensure
      # WEBrick otherwise drains rejected request bodies before writing the error.
      HTTPBody.reject(response) if response.status.to_i >= 400
    end

    private

    def security_headers(response)
      response['Cache-Control'] = 'no-store, private'
      response['Content-Security-Policy'] = CSP
      response['X-Content-Type-Options'] = 'nosniff'
      response['Referrer-Policy'] = 'no-referrer'
      response['X-Frame-Options'] = 'DENY'
      response['Permissions-Policy'] = 'camera=(), microphone=(), geolocation=()'
      response['Vary'] = 'Cookie, Authorization, Origin'
      response['Strict-Transport-Security'] = 'max-age=31536000' if @origin.start_with?('https:')
    end

    def method_not_allowed(response, methods)
      response['Allow'] = methods
      json(response, 405, error: 'Method not allowed')
    end

    def redirect(response, location)
      raise ArgumentError unless location.start_with?('/') && !location.start_with?('//') && !location.match?(/[\\\x00-\x1f\x7f]/)
      response.status, response.body = 303, ''
      # WEBrick expands relative locations against its plain HTTP listener. Use
      # the configured public origin so tunnel-backed login never downgrades TLS.
      response['Location'] = @origin + location
    end

    def oauth_request(request, response)
      path = request.path
      public_post = %w[/oauth/register /oauth/token /oauth/revoke].include?(path)
      allowed_origin = request['origin'].nil? || [@origin, 'https://claude.ai'].include?(request['origin'])
      return json(response, 403, error: 'Invalid request origin') unless allowed_origin
      if public_post
        if request['origin'] == 'https://claude.ai'
          response['Access-Control-Allow-Origin'] = 'https://claude.ai'
          response['Access-Control-Allow-Headers'] = 'Content-Type, Authorization'
          response['Access-Control-Allow-Methods'] = 'POST, OPTIONS'
        end
        return (response.status = 204; response.body = '') if request.request_method == 'OPTIONS'
        return method_not_allowed(response, 'POST, OPTIONS') unless request.request_method == 'POST'
        return json(response, 429, error: 'temporarily_unavailable') unless rate_allowed?(path)
        data = parse_body(request, form: path != '/oauth/register')
        value = case path
                when '/oauth/register' then @oauth.register_client(data)
                when '/oauth/token' then @oauth.token(data, authorization: request['authorization'])
                else @oauth.revoke(data, authorization: request['authorization']); {}
                end
        return json(response, path == '/oauth/register' ? 201 : 200, value)
      end
      identity = @auth_http.session(request)
      return json(response, 401, error: 'Toolbox sign-in required') unless identity
      case [request.request_method, path]
      when ['GET', '/oauth/consent']
        # Cross-site GETs must not create an authorization transaction.
        return json(response, 403, error: 'Invalid request origin') unless request['sec-fetch-site'].nil? || request['sec-fetch-site'] == 'same-origin'
        json(response, 200, @oauth.begin_authorization(query_params(request), subject: identity.fetch(:email)))
      when ['GET', '/oauth/connections']
        json(response, 200, connections: @oauth.grants(subject: identity.fetch(:email)))
      when ['POST', '/oauth/authorize'], ['POST', '/oauth/connections/revoke']
        expected = identity.fetch(:csrf_token)
        supplied = request['x-csrf-token'].to_s
        valid_csrf = supplied.bytesize == expected.bytesize && OpenSSL.fixed_length_secure_compare(supplied, expected)
        return json(response, 403, error: 'Please reload and try again') unless request['origin'] == @origin && valid_csrf
        data = parse_body(request)
        if path == '/oauth/authorize'
          return json(response, 400, error: 'Choose Allow or Cancel') unless [true, false].include?(data['approve'])
          destination = @oauth.complete_authorization(data['id'], subject: identity.fetch(:email), approve: data['approve'])
          json(response, 200, redirect: destination)
        else
          @oauth.revoke_grant(data['id'], subject: identity.fetch(:email))
          json(response, 200, ok: true)
        end
      else
        json(response, 404, error: 'Not found')
      end
    end

    def query_params(request)
      raw = request.query_string.to_s
      raise ArgumentError if raw.bytesize > 8192
      pairs = URI.decode_www_form(raw)
      raise ArgumentError unless pairs.map(&:first).uniq.length == pairs.length
      pairs.to_h
    end

    def parse_body(request, form: false)
      body = HTTPBody.read(request, limit: 16_384)
      type = request['content-type'].to_s.split(';').first.to_s.downcase.strip
      value = if type == 'application/json'
                JSON.parse(body, max_nesting: 8)
              elsif form && type == 'application/x-www-form-urlencoded'
                pairs = URI.decode_www_form(body)
                raise ArgumentError unless pairs.map(&:first).uniq.length == pairs.length
                pairs.to_h
              else
                raise ArgumentError
              end
      raise ArgumentError unless value.is_a?(Hash)
      value
    end

    def rate_allowed?(path)
      # Fixed keys cap memory. Public registration/token requests never run host commands.
      @rate_mutex.synchronize do
        window = (@clock.call / 60).floor
        state = @rates[path]
        state = @rates[path] = { window: window, count: 0 } unless state && state[:window] == window
        state[:count] += 1
        state[:count] <= (path == '/oauth/register' ? 10 : 120)
      end
    end

    def json(response, status, value)
      response.status = status
      response['Content-Type'] = 'application/json; charset=utf-8'
      response.body = JSON.generate(value)
    end

    def snapshot
      @snapshot_mutex.synchronize do
        if @snapshot_at.nil? || @clock.call - @snapshot_at >= @cache_seconds
          @snapshot = @collector.snapshot
          @snapshot_at = @clock.call
        end
        @snapshot
      end
    end

    def logs(source, lines)
      # Validate against the server's current inventory, never a browser-supplied
      # filename or command. Cache short polls to keep multiple tabs inexpensive.
      allowed = snapshot.fetch(:log_sources).map { |item| item.fetch(:id) }
      raise ArgumentError unless allowed.include?(source)
      @logs_mutex.synchronize do
        key = [source, lines]
        cached = @logs[key]
        if !cached || @clock.call - cached[:at] >= 3
          cached = { at: @clock.call, value: @collector.logs(source, lines: lines) }
          @logs.clear if @logs.length >= 32
          @logs[key] = cached
        end
        cached[:value]
      end
    end

    def static(path, response)
      path = '/index.html' if path == '/'
      return json(response, 404, error: 'Not found') unless path.match?(%r{\A/[a-zA-Z0-9_./-]+\z})
      file = File.realpath(File.join(@public_dir, path.delete_prefix('/')))
      return json(response, 404, error: 'Not found') unless file.start_with?("#{@public_dir}/") && File.file?(file)
      mime = MIME_TYPES[File.extname(file)]
      return json(response, 404, error: 'Not found') unless mime
      response.status = 200
      response['Content-Type'] = mime
      response['Service-Worker-Allowed'] = '/' if path == '/sw.js'
      response.body = File.binread(file)
    rescue Errno::ENOENT, Errno::ENOTDIR
      json(response, 404, error: 'Not found')
    end
  end
end

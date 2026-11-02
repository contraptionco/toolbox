require 'json'
require 'time'
require 'thread'
require_relative 'access'

module Dashboard
  class App
    MIME_TYPES = { '.html' => 'text/html; charset=utf-8', '.css' => 'text/css; charset=utf-8',
                   '.js' => 'application/javascript; charset=utf-8', '.json' => 'application/json',
                   '.webmanifest' => 'application/manifest+json', '.svg' => 'image/svg+xml',
                   '.png' => 'image/png', '.woff2' => 'font/woff2' }.freeze
    CSP = "default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; font-src 'self' https://fonts.philipithomas.com; img-src 'self' data:; connect-src 'self'; worker-src 'self'; manifest-src 'self'; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'".freeze

    def initialize(collector:, access:, public_dir:, revision:, cache_seconds: 10, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
      @collector, @access, @public_dir, @revision = collector, access, File.realpath(public_dir), revision
      @cache_seconds, @clock = cache_seconds, clock
      @snapshot_mutex, @logs_mutex = Mutex.new, Mutex.new
      @snapshot_at, @snapshot, @logs = nil, nil, {}
    end

    def call(request, response)
      security_headers(response)
      unless %w[GET HEAD].include?(request.request_method)
        response['Allow'] = 'GET, HEAD'
        return json(response, 405, error: 'Read-only dashboard')
      end
      if request.path == '/healthz'
        return json(response, 200, ok: true, revision: @revision)
      end
      @access.verify(request['cf-access-jwt-assertion'])
      case request.path
      when '/api/status'
        json(response, 200, snapshot)
      when '/api/logs'
        source = request.query['source'].to_s
        count = request.query.fetch('lines', '100').to_s
        return json(response, 400, error: 'Invalid line count') unless count.match?(/\A\d{1,3}\z/) && count.to_i.between?(1, 200)
        json(response, 200, logs(source, count.to_i))
      else
        static(request.path, response)
      end
    rescue Access::Unauthorized
      json(response, 401, error: 'Cloudflare Access login required', login_url: '/cdn-cgi/access/login')
    rescue Access::Unavailable
      json(response, 503, error: 'Cloudflare Access verification is temporarily unavailable')
    rescue ArgumentError
      json(response, 400, error: 'Invalid request')
    rescue StandardError
      # Do not return exception messages, subprocess stderr, paths or credentials.
      json(response, 503, error: 'Metrics are temporarily unavailable')
    end

    private

    def security_headers(response)
      response['Cache-Control'] = 'no-store, private'
      response['Content-Security-Policy'] = CSP
      response['X-Content-Type-Options'] = 'nosniff'
      response['Referrer-Policy'] = 'no-referrer'
      response['X-Frame-Options'] = 'DENY'
      response['Permissions-Policy'] = 'camera=(), microphone=(), geolocation=()'
      response['Vary'] = 'Cookie, Cf-Access-Jwt-Assertion'
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

require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'net/http'
require 'webrick'
require 'digest'
require 'socket'
require 'timeout'
require 'base64'
require_relative '../lib/dashboard/app'
require_relative '../lib/dashboard/auth'
require_relative '../lib/dashboard/auth_store'
require_relative '../lib/dashboard/http_handler'

# The only network traffic is to this test's ephemeral loopback WEBrick server.
# No host collectors, production files, SMTP, Docker, or external OAuth requests.
class DashboardFlowTest < Minitest::Test
  ORIGIN = 'https://toolbox.example'.freeze

  class Mailer
    attr_reader :deliveries
    def initialize = @deliveries = []
    def send_code(email:, code:)
      @deliveries << { email: email, code: code }
      true
    end
  end

  class Collector
    def snapshot
      { generated_at: '2026-11-27T12:00:00Z', host: { name: 'synthetic-host' },
        containers: [{ name: 'fixture-container', state: 'running' }],
        log_sources: [{ id: 'container:fixture-container', label: 'Fixture' }], errors: [], warnings: [] }
    end
    def logs(source, lines:)
      { source: source, lines: ['synthetic log line'].first(lines), truncated: false }
    end
  end

  def setup
    @directory = Dir.mktmpdir('toolbox-http-flow-')
    public_dir = File.join(@directory, 'public')
    FileUtils.mkdir_p(public_dir)
    %w[index login security consent].each do |name|
      File.write(File.join(public_dir, name + '.html'), "<!doctype html><title>Fixture #{name}</title>")
    end
    @store = Dashboard::AuthStore.new(path: File.join(@directory, 'private', 'auth.sqlite3'))
    @mailer = Mailer.new
    auth = Dashboard::Auth.new(store: @store, origin: ORIGIN, secret: 'fixture-only-secret-' * 3, mailer: @mailer)
    oauth = Dashboard::OAuth.new(store: @store, origin: ORIGIN)
    app = Dashboard::App.new(collector: Collector.new, auth_http: Dashboard::AuthHTTP.new(auth: auth),
      oauth: oauth, origin: ORIGIN, public_dir: public_dir, revision: 'fixture-only')
    @server = WEBrick::HTTPServer.new(BindAddress: '127.0.0.1', Port: 0, MaxClients: 4,
      RequestTimeout: 5, AccessLog: [], Logger: WEBrick::Log.new(File::NULL))
    @server.mount('/', Dashboard::HTTPHandler, app)
    @port = @server.listeners.first.addr[1]
    @thread = Thread.new { @server.start }
    @cookies = {}
  end

  def teardown
    @server&.shutdown
    @thread&.join(2)
    @thread&.kill if @thread&.alive?
    @store&.close
    FileUtils.remove_entry(@directory) if @directory && File.directory?(@directory)
  end

  def test_owner_login_oauth_mcp_refresh_and_revocation_over_real_http
    assert_status 401, request(:get, '/api/status')
    redirect = request(:get, '/')
    assert_status 303, redirect
    assert_equal ORIGIN + '/login?next=%2F', redirect['location']
    assert_status 200, request(:get, '/login')
    assert_status 405, request(:delete, '/api/status')
    preflight_headers = { 'Origin' => 'https://claude.ai', 'Access-Control-Request-Method' => 'POST', 'Access-Control-Request-Headers' => 'Authorization, Content-Type' }
    ['/mcp', '/oauth/token'].each do |path|
      preflight = request(:options, path, browser: false, headers: preflight_headers)
      assert_status 204, preflight
      assert_equal 'https://claude.ai', preflight['access-control-allow-origin']
      assert_includes preflight['access-control-allow-methods'], 'POST'
      assert_includes preflight['access-control-allow-headers'], 'Authorization'
      assert_nil preflight['access-control-allow-credentials']
    end
    assert_status 403, request(:options, '/mcp', browser: false, headers: { 'Origin' => 'https://evil.example' })

    bootstrap = request(:get, '/auth/session')
    assert_status 200, bootstrap
    initial = json(bootstrap)
    assert_equal false, initial.fetch('authenticated')
    @csrf = initial.fetch('csrf_token')
    cookie = bootstrap.get_fields('set-cookie').first
    assert_match(/\A__Host-toolbox_browser=/, cookie)
    assert_includes cookie, 'HttpOnly'
    assert_includes cookie, 'Secure'
    assert_includes cookie, 'SameSite=Strict'

    # Neither a different address nor a cross-site login request can send mail.
    assert_status 403, request(:post, '/auth/email', json: { email: Dashboard::Auth::EMAIL }, headers: { 'Origin' => 'https://evil.example', 'X-CSRF-Token' => @csrf })
    assert_status 200, auth_post('/auth/email', { email: 'another@example.com' })
    assert_empty @mailer.deliveries
    assert_status 200, auth_post('/auth/email', { email: Dashboard::Auth::EMAIL })
    assert_equal 1, @mailer.deliveries.length
    assert_equal Dashboard::Auth::EMAIL, @mailer.deliveries.first.fetch(:email)
    code = @mailer.deliveries.first.fetch(:code)
    verified = auth_post('/auth/verify', { email: Dashboard::Auth::EMAIL, code: code })
    assert_status 200, verified
    assert verified.get_fields('set-cookie').any? { |value| value.start_with?('__Host-toolbox_session=') && value.include?('Secure') && value.include?('HttpOnly') }
    signed_in = json(request(:get, '/auth/session'))
    assert_equal true, signed_in.fetch('authenticated')
    assert_equal Dashboard::Auth::EMAIL, signed_in.fetch('email')
    assert signed_in.fetch('csrf_token') != @csrf, 'Successful login rotates the CSRF token.'
    @csrf = signed_in.fetch('csrf_token')
    assert_status 200, request(:get, '/api/status')

    resource = ORIGIN + '/mcp'
    assert_equal resource, json(request(:get, '/.well-known/oauth-protected-resource/mcp', browser: false)).fetch('resource')
    metadata = json(request(:get, '/.well-known/oauth-authorization-server', browser: false))
    assert_equal ['S256'], metadata.fetch('code_challenge_methods_supported')
    registered = request(:post, '/oauth/register', browser: false,
      json: { redirect_uris: [Dashboard::OAuth::REDIRECT_URI], token_endpoint_auth_method: 'none', scope: 'toolbox:read toolbox:logs' })
    assert_status 201, registered
    assert_nil registered['set-cookie']
    client_id = json(registered).fetch('client_id')
    verifier = 'fixture-pkce-verifier-' * 3
    authorize = { client_id: client_id, redirect_uri: Dashboard::OAuth::REDIRECT_URI,
      resource: resource, response_type: 'code', scope: 'toolbox:read toolbox:logs', state: 'fixture-state',
      code_challenge: Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false), code_challenge_method: 'S256' }
    query = URI.encode_www_form(authorize)
    assert_status 200, request(:get, '/oauth/authorize?' + query)
    consent = request(:get, '/oauth/consent?' + query, headers: { 'Sec-Fetch-Site' => 'same-origin' })
    assert_status 200, consent
    consent_id = json(consent).fetch('id')
    assert_status 403, request(:post, '/oauth/authorize', json: { id: consent_id, approve: true }, headers: { 'Origin' => ORIGIN, 'X-CSRF-Token' => 'incorrect' })
    approved = auth_post('/oauth/authorize', { id: consent_id, approve: true })
    assert_status 200, approved
    callback = URI(json(approved).fetch('redirect'))
    assert_equal Dashboard::OAuth::REDIRECT_URI, callback.to_s.split('?').first
    callback_params = URI.decode_www_form(callback.query).to_h
    assert_equal 'fixture-state', callback_params.fetch('state')
    assert_equal ORIGIN, callback_params.fetch('iss')
    assert_status 400, auth_post('/oauth/authorize', { id: consent_id, approve: true })

    exchange = request(:post, '/oauth/token', browser: false, form: {
      grant_type: 'authorization_code', client_id: client_id, code: callback_params.fetch('code'),
      code_verifier: verifier, redirect_uri: Dashboard::OAuth::REDIRECT_URI, resource: resource })
    assert_status 200, exchange
    tokens = json(exchange)
    assert_equal 'Bearer', tokens.fetch('token_type')
    assert_equal 'toolbox:read toolbox:logs', tokens.fetch('scope')
    token = tokens.fetch('access_token')

    assert_status 401, request(:post, '/mcp', json: { jsonrpc: '2.0', id: 1, method: 'tools/list' })
    initialized = mcp(token, 'initialize', { protocolVersion: '2025-11-25', capabilities: {}, clientInfo: { name: 'fixture', version: '1' } })
    assert_status 200, initialized
    assert_equal 'Toolbox', json(initialized).dig('result', 'serverInfo', 'name')
    listed = mcp(token, 'tools/list')
    assert_equal %w[toolbox_status toolbox_containers toolbox_logs], json(listed).dig('result', 'tools').map { |tool| tool.fetch('name') }
    status = mcp(token, 'tools/call', { name: 'toolbox_status' })
    assert_equal 'synthetic-host', json(status).dig('result', 'structuredContent', 'host', 'name')
    containers = mcp(token, 'tools/call', { name: 'toolbox_containers' })
    assert_equal 'fixture-container', json(containers).dig('result', 'structuredContent', 'containers', 0, 'name')
    logs = mcp(token, 'tools/call', { name: 'toolbox_logs', arguments: { source: 'container:fixture-container', lines: 10 } })
    assert_equal ['synthetic log line'], json(logs).dig('result', 'structuredContent', 'lines')
    denied_logs = mcp(token, 'tools/call', { name: 'toolbox_logs', arguments: { source: '/private/unknown' } })
    assert_equal(-32602, json(denied_logs).dig('error', 'code'))

    refreshed = request(:post, '/oauth/token', browser: false, form: {
      grant_type: 'refresh_token', client_id: client_id, refresh_token: tokens.fetch('refresh_token'), resource: resource })
    assert_status 200, refreshed
    rotated = json(refreshed)
    assert rotated.fetch('refresh_token') != tokens.fetch('refresh_token'), 'Refresh tokens rotate.'
    assert_status 200, mcp(rotated.fetch('access_token'), 'ping')
    connections = json(request(:get, '/oauth/connections')).fetch('connections')
    assert_equal 1, connections.length
    assert_status 200, auth_post('/oauth/connections/revoke', { id: connections.first.fetch('id') })
    assert_empty json(request(:get, '/oauth/connections')).fetch('connections')
    assert_status 401, mcp(token, 'tools/list')
    assert_status 401, mcp(rotated.fetch('access_token'), 'tools/list')
    assert_status 400, request(:post, '/oauth/token', browser: false, form: {
      grant_type: 'refresh_token', client_id: client_id, refresh_token: rotated.fetch('refresh_token'), resource: resource })
    assert_status 200, request(:get, '/api/status')

    stale_cookie = @cookies.map { |name, value| "#{name}=#{value}" }.join('; ')
    assert_status 200, auth_post('/auth/logout', {})
    assert_status 401, request(:get, '/api/status')
    assert_status 401, request(:get, '/api/status', browser: false, headers: { 'Cookie' => stale_cookie })
    assert_equal false, json(request(:get, '/auth/session')).fetch('authenticated')
  end

  def test_non_post_bodies_are_rejected_before_webrick_drains_them
    socket = nil
    [['GET', '/healthz'], ['GET', '/'], ['OPTIONS', '/mcp']].each do |method, path|
      ['Content-Length: 1000000', 'Transfer-Encoding: chunked'].each do |body_header|
        socket = TCPSocket.new('127.0.0.1', @port)
        socket.write("#{method} #{path} HTTP/1.1\r\nHost: #{URI(ORIGIN).host}\r\n#{body_header}\r\nConnection: keep-alive\r\n\r\n")
        # No body bytes or terminal chunk follow. The guard must close promptly,
        # before WEBrick's five-second timeout or any successful route response.
        response = Timeout.timeout(2) { socket.read }
        assert_match(/\AHTTP\/1\.1 400 /, response)
        assert_match(/\r\nConnection: close\r\n/i, response)
        assert_includes response, 'Request bodies are only accepted for POST requests'
        socket.close
      end
    end
    assert_status 200, request(:get, '/healthz', headers: { 'Content-Length' => '0' })
  ensure
    socket&.close unless socket&.closed?
  end

  private

  def request(method, path, json: nil, form: nil, headers: {}, browser: true)
    klass = { get: Net::HTTP::Get, post: Net::HTTP::Post, options: Net::HTTP::Options, delete: Net::HTTP::Delete }.fetch(method)
    message = klass.new(path)
    message['Host'] = URI(ORIGIN).host
    message['Accept'] = 'application/json'
    message['Cookie'] = @cookies.map { |name, value| "#{name}=#{value}" }.join('; ') if browser && !@cookies.empty?
    if json
      message['Content-Type'] = 'application/json'
      message.body = JSON.generate(json)
    elsif form
      message['Content-Type'] = 'application/x-www-form-urlencoded'
      message.body = URI.encode_www_form(form)
    end
    headers.each { |name, value| message[name] = value }
    http = Net::HTTP.new('127.0.0.1', @port, nil)
    http.open_timeout, http.read_timeout = 2, 3
    response = http.start { |connection| connection.request(message) }
    if browser
      Array(response.get_fields('set-cookie')).each do |cookie|
        name, value = cookie.split(';', 2).first.split('=', 2)
        if cookie.match?(/;\s*Max-Age=0(?:;|$)/i)
          @cookies.delete(name)
        else
          @cookies[name] = value
        end
      end
    end
    response
  end

  def auth_post(path, data)
    request(:post, path, json: data, headers: { 'Origin' => ORIGIN, 'X-CSRF-Token' => @csrf })
  end

  def mcp(token, method, params = {})
    request(:post, '/mcp', browser: false, json: { jsonrpc: '2.0', id: 1, method: method, params: params },
      headers: { 'Authorization' => "Bearer #{token}", 'MCP-Protocol-Version' => '2025-11-25', 'Accept' => 'application/json, text/event-stream' })
  end

  def json(response) = JSON.parse(response.body)
  def assert_status(expected, response) = assert_equal(expected.to_s, response.code)
end

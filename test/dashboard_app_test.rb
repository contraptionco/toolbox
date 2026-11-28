require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/dashboard/app'

class DashboardAppTest < Minitest::Test
  Request = Struct.new(:path, :request_method, :query, :headers, :body_value, :query_string) do
    def [](key) = headers[key]
    def body = body_value
  end

  class Response
    attr_accessor :status, :body, :keep_alive
    attr_reader :headers
    def initialize
      @headers = {}
      @keep_alive = true
    end
    def []=(key, value)
      @headers[key] = value
    end
    def [](key) = @headers[key]
  end

  class Collector
    attr_reader :snapshot_calls, :log_calls
    attr_accessor :failure
    def initialize
      @snapshot_calls = 0
      @log_calls = []
    end
    def snapshot
      @snapshot_calls += 1
      raise failure if failure
      { host: { hostname: 'fixture-host' }, log_sources: [{ id: 'toolbox', label: 'Toolbox' }] }
    end
    def logs(source, lines:)
      @log_calls << [source, lines]
      { lines: ['fixture heartbeat complete'] }
    end
  end

  class AuthHTTP
    attr_reader :calls
    attr_accessor :failure
    def initialize = @calls = []
    def call(_request, _response) = false
    def session(request)
      @calls << request['cookie']
      raise failure if failure
      return nil unless request['cookie'] == 'toolbox_session=fixture-token'
      { email: 'philip@ilic.nyc', csrf_token: 'fixture-csrf', session_id: 'fixture-session' }
    end
  end

  class OAuth
    attr_reader :registrations, :consents, :decisions, :revocations
    def initialize
      @registrations, @consents, @decisions, @revocations = [], [], [], []
    end
    def authorization_metadata = { issuer: 'https://toolbox.example', authorization_endpoint: 'https://toolbox.example/oauth/authorize' }
    def resource_metadata = { resource: 'https://toolbox.example/mcp', authorization_servers: ['https://toolbox.example'] }
    def register_client(params)
      @registrations << params
      { client_id: 'fixture-client' }
    end
    def begin_authorization(params, subject:)
      @consents << [params, subject]
      { id: 'fixture-consent', client_name: 'Claude', client_origin: 'https://claude.ai', scopes: ['toolbox:read'] }
    end
    def complete_authorization(id, subject:, approve:)
      @decisions << [id, subject, approve]
      'https://claude.ai/api/mcp/auth_callback?code=fixture'
    end
    def grants(subject:) = [{ id: 'fixture-grant', client_name: 'Claude', scopes: ['toolbox:read'] }]
    def revoke_grant(id, subject:)
      @revocations << [id, subject]
      true
    end
    def authenticate(_value)
      raise Dashboard::OAuth::Error.new('invalid_token', 'Authentication required.', 401)
    end
  end

  def setup
    @directory = Dir.mktmpdir('toolbox-dashboard-test-')
    @public = File.join(@directory, 'public')
    FileUtils.mkdir_p(@public)
    File.write(File.join(@public, 'index.html'), '<h1>Fixture</h1>')
    %w[login security consent].each { |name| File.write(File.join(@public, name + '.html'), '<h1>' + name + '</h1>') }
    File.write(File.join(@public, 'sw.js'), 'self.addEventListener("fetch", () => {});')
    File.write(File.join(@directory, 'secret.html'), 'private fixture secret')
    File.symlink(File.join(@directory, 'secret.html'), File.join(@public, 'escape.html'))
    @collector = Collector.new
    @auth_http, @oauth = AuthHTTP.new, OAuth.new
    @now = 0
    @app = Dashboard::App.new(collector: @collector, auth_http: @auth_http, oauth: @oauth, origin: 'https://toolbox.example',
                             public_dir: @public, revision: 'fixture-sha', clock: -> { @now })
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_unauthenticated_requests_never_collect_host_data
    ['/api/status', '/api/logs'].each do |path|
      response = request(path, token: nil)
      assert_equal 401, response.status
      assert_equal 'Toolbox sign-in required', JSON.parse(response.body)['error']
      assert_no_store(response)
    end
    ['/', '/security', '/security.html', '/index.html', '/consent.html'].each do |path|
      response = request(path, token: nil)
      assert_equal 303, response.status
      assert_equal 'https://toolbox.example/login?next=' + URI.encode_www_form_component(path), response['Location']
      refute_includes response.body, 'Fixture'
    end
    assert_equal 0, @collector.snapshot_calls
    assert_empty @collector.log_calls
  end

  def test_login_and_generic_assets_are_public_without_collecting_host_data
    assert_equal 200, request('/login', token: nil).status
    assert_equal 200, request('/sw.js', token: nil).status
    assert_empty @auth_http.calls
    assert_equal 0, @collector.snapshot_calls
    assert_empty @collector.log_calls
  end

  def test_dashboard_html_uses_loaded_revision_even_when_checkout_advances
    template = File.read(File.expand_path('../web/public/index.html', __dir__))
    File.write(File.join(@public, 'index.html'), template)
    loaded = 'a' * 40
    checkout = 'b' * 40
    @collector.define_singleton_method(:snapshot) { { deployment: { checkout_commit: checkout } } }
    @app = Dashboard::App.new(collector: @collector, auth_http: @auth_http, oauth: @oauth,
      origin: 'https://toolbox.example', public_dir: @public, revision: loaded)

    ['/', '/index.html'].each do |path|
      response = request(path)
      assert_equal 200, response.status
      assert_includes response.body, '<meta name="toolbox-revision" content="' + loaded + '">'
      refute_includes response.body, checkout
      %w[/app.js /style.css /auth.css].each { |asset| assert_includes response.body, '"' + asset + '?revision=' + loaded + '"' }
      assert_no_store(response)
    end
    assert_equal loaded, JSON.parse(request('/api/status').body).dig('deployment', 'dashboard_commit')
    assert_includes File.read(File.join(@public, 'index.html')), '<meta name="toolbox-revision" content="">'
    assert_equal 303, request('/', token: nil).status
  end

  def test_dashboard_revision_stamp_escapes_html_and_demo_remains_identifiable
    File.write(File.join(@public, 'index.html'), '<meta name="toolbox-revision" content="">')
    ['demo', '"<unsafe>'].each do |revision|
      @app = Dashboard::App.new(collector: @collector, auth_http: @auth_http, oauth: @oauth,
        origin: 'https://toolbox.example', public_dir: @public, revision: revision)
      assert_equal '<meta name="toolbox-revision" content="' + CGI.escapeHTML(revision) + '">', request('/').body
    end
  end

  def test_authentication_outage_fails_closed_without_collecting
    @auth_http.failure = IOError.new('secret diagnostics')
    response = request('/api/status')
    assert_equal 503, response.status
    refute_includes response.body, 'secret diagnostics'
    assert_equal 0, @collector.snapshot_calls
    assert_no_store(response)
  end

  def test_cached_data_still_requires_authentication_for_every_request
    assert_equal 200, request('/api/status').status
    assert_equal 200, request('/api/status').status
    assert_equal 1, @collector.snapshot_calls
    assert_equal 401, request('/api/status', token: nil).status
    assert_equal 1, @collector.snapshot_calls
    assert_equal 3, @auth_http.calls.length
    @now = 10
    assert_equal 200, request('/api/status').status
    assert_equal 2, @collector.snapshot_calls
  end

  def test_running_dashboard_revision_does_not_follow_checkout_or_mutate_collector_evidence
    checkout = 'b' * 40
    running = 'a' * 40
    evidence = { status: 'stale', commit: checkout, checkout_commit: checkout, dashboard_commit: 'untrusted-collector-value' }.freeze
    sample = { deployment: evidence, log_sources: [] }.freeze
    @collector.define_singleton_method(:snapshot) { sample }
    @app = Dashboard::App.new(collector: @collector, auth_http: @auth_http, oauth: @oauth,
      origin: 'https://toolbox.example', public_dir: @public, revision: running, clock: -> { @now })
    [0, 11].each do |at|
      @now = at
      deployment = JSON.parse(request('/api/status').body).fetch('deployment')
      assert_equal running, deployment['dashboard_commit']
      assert_equal checkout, deployment['checkout_commit']
      assert_equal checkout, deployment['commit']
      assert_equal 'stale', deployment['status']
    end
    assert_equal 'untrusted-collector-value', evidence[:dashboard_commit]
  end

  def test_runtime_revision_does_not_make_missing_heartbeat_evidence_healthy
    deployment = JSON.parse(request('/api/status').body).fetch('deployment')
    assert_equal 'fixture-sha', deployment['dashboard_commit']
    refute deployment.key?('status')
    refute deployment.key?('commit')
  end

  def test_log_sources_are_allowlisted_before_the_collector_receives_them
    ['../../secret', 'toolbox; touch /tmp/owned', 'docker:unlisted', ''].each do |source|
      assert_equal 400, request('/api/logs', query: { 'source' => source }).status
    end
    assert_empty @collector.log_calls
    response = request('/api/logs', query: { 'source' => 'toolbox', 'lines' => '25' })
    assert_equal 200, response.status
    assert_equal [['toolbox', 25]], @collector.log_calls
  end

  def test_log_count_bounds_reject_untrusted_input_without_collecting
    ['0', '201', '1000', '-1', '1;id', '1.5'].each do |count|
      assert_equal 400, request('/api/logs', query: { 'source' => 'toolbox', 'lines' => count }).status
    end
    assert_equal 0, @collector.snapshot_calls
    assert_empty @collector.log_calls
  end

  def test_log_polls_use_short_cache_but_still_authenticate
    query = { 'source' => 'toolbox', 'lines' => '20' }
    2.times { assert_equal 200, request('/api/logs', query: query).status }
    assert_equal [['toolbox', 20]], @collector.log_calls
    @now = 3
    assert_equal 200, request('/api/logs', query: query).status
    assert_equal 2, @collector.log_calls.length
    assert_equal 3, @auth_http.calls.length
  end

  def test_static_paths_cannot_escape_public_directory
    ['/../secret.html', '/escape.html', '/%2e%2e/secret.html', '/..\\secret.html'].each do |path|
      response = request(path)
      assert_equal 404, response.status
      refute_includes response.body, 'private fixture secret'
    end
    assert_equal 0, @collector.snapshot_calls
  end

  def test_read_only_methods_and_no_host_work_on_health_check
    %w[POST PUT PATCH DELETE OPTIONS].each do |method|
      response = request('/api/status', method: method)
      assert_equal 405, response.status
      assert_equal 'GET, HEAD', response['Allow']
      assert_no_store(response)
    end
    response = request('/healthz', token: nil)
    assert_equal 200, response.status
    assert_equal({ 'ok' => true, 'revision' => 'fixture-sha' }, JSON.parse(response.body))
    assert_equal 0, @collector.snapshot_calls
    assert_empty @auth_http.calls
  end

  def test_response_security_headers_and_authenticated_static_assets
    response = request('/')
    assert_equal 200, response.status
    assert_equal '<h1>Fixture</h1>', response.body
    assert_equal 'text/html; charset=utf-8', response['Content-Type']
    assert_no_store(response)
    assert_equal 'nosniff', response['X-Content-Type-Options']
    assert_equal 'DENY', response['X-Frame-Options']
    assert_includes response['Content-Security-Policy'], "frame-ancestors 'none'"
    assert_includes response['Content-Security-Policy'], "object-src 'none'"
    assert_equal '/', request('/sw.js')['Service-Worker-Allowed']
  end

  def test_metrics_failure_does_not_return_paths_or_command_diagnostics
    @collector.failure = IOError.new('failure /private/secret TOKEN=private-value')
    response = request('/api/status')
    assert_equal 503, response.status
    assert_equal 'Toolbox is temporarily unavailable', JSON.parse(response.body)['error']
    refute_includes response.body, 'private-value'
    assert_no_store(response)
  end

  def test_untrusted_host_and_old_cloudflare_headers_cannot_authenticate
    assert_equal 421, request('/api/status', headers: { 'host' => 'attacker.example' }).status
    assert_empty @auth_http.calls
    response = request('/api/status', token: nil, headers: { 'cf-access-jwt-assertion' => 'fixture-token', 'x-forwarded-host' => 'toolbox.example' })
    assert_equal 401, response.status
    assert_equal 401, request('/api/status', token: nil, headers: { 'authorization' => 'Bearer fixture' }).status
    assert_equal 0, @collector.snapshot_calls
  end

  def test_discovery_is_public_but_a_browser_cookie_cannot_open_mcp
    metadata = request('/.well-known/oauth-protected-resource/mcp', token: nil)
    assert_equal 200, metadata.status
    assert_equal 'https://toolbox.example/mcp', JSON.parse(metadata.body)['resource']
    assert_equal 200, request('/.well-known/oauth-authorization-server', token: nil).status
    assert_equal 405, request('/.well-known/oauth-authorization-server', method: 'POST').status
    response = request('/mcp', method: 'POST', data: { jsonrpc: '2.0', method: 'tools/list', id: 1 })
    assert_equal 401, response.status
    assert_includes response['WWW-Authenticate'], 'oauth-protected-resource/mcp'
    assert_empty @auth_http.calls
    assert_equal 0, @collector.snapshot_calls
  end

  def test_oauth_login_redirect_preserves_original_authorization_query
    query = { 'client_id' => 'fixture-client', 'state' => 'opaque state' }
    response = request('/oauth/authorize', token: nil, query: query)
    assert_equal 303, response.status
    next_path = URI.decode_www_form(URI(response['Location']).query).to_h.fetch('next')
    assert_equal '/oauth/authorize?' + URI.encode_www_form(query), next_path
    assert_empty @oauth.consents
  end

  def test_consent_creation_requires_owner_session_and_same_origin_fetch
    assert_equal 401, request('/oauth/consent', token: nil).status
    assert_equal 403, request('/oauth/consent', headers: { 'sec-fetch-site' => 'cross-site' }).status
    assert_equal 403, request('/oauth/consent', headers: { 'origin' => 'https://evil.example' }).status
    assert_empty @oauth.consents
    query = { 'client_id' => 'fixture-client' }
    assert_equal 200, request('/oauth/consent', query: query, headers: { 'sec-fetch-site' => 'same-origin' }).status
    assert_equal [[query, 'philip@ilic.nyc']], @oauth.consents
    assert_equal 0, @collector.snapshot_calls
  end

  def test_consent_decisions_and_revocation_require_session_origin_and_csrf
    data = { id: 'fixture-consent', approve: true }
    assert_equal 401, request('/oauth/authorize', token: nil, method: 'POST', data: data).status
    assert_equal 403, request('/oauth/authorize', method: 'POST', data: data).status
    assert_equal 403, request('/oauth/authorize', method: 'POST', data: data, headers: { 'origin' => 'https://toolbox.example', 'x-csrf-token' => 'wrong' }).status
    assert_equal 403, request('/oauth/authorize', method: 'POST', data: data, headers: { 'origin' => 'https://evil.example', 'x-csrf-token' => 'fixture-csrf' }).status
    assert_empty @oauth.decisions
    headers = { 'origin' => 'https://toolbox.example', 'x-csrf-token' => 'fixture-csrf' }
    response = request('/oauth/authorize', method: 'POST', data: data, headers: headers)
    assert_equal 200, response.status
    assert_equal [[data[:id], 'philip@ilic.nyc', true]], @oauth.decisions
    assert_equal 'https://claude.ai/api/mcp/auth_callback?code=fixture', JSON.parse(response.body)['redirect']
    assert_equal 400, request('/oauth/authorize', method: 'POST', data: { id: data[:id], approve: 'true' }, headers: headers).status
    assert_equal 403, request('/oauth/connections/revoke', method: 'POST', data: { id: 'fixture-grant' }).status
    assert_empty @oauth.revocations
    assert_equal 200, request('/oauth/connections/revoke', method: 'POST', data: { id: 'fixture-grant' }, headers: headers).status
    assert_equal [['fixture-grant', 'philip@ilic.nyc']], @oauth.revocations
    assert_equal 0, @collector.snapshot_calls
  end

  def test_public_oauth_requests_are_bounded_and_registration_is_rate_limited
    response = request('/oauth/register', token: nil, method: 'POST', raw: 'x' * 16_385)
    assert_equal 413, response.status
    assert_equal 'close', response['Connection']
    assert_equal false, response.keep_alive
    assert_equal 400, request('/oauth/token', token: nil, method: 'POST', raw: 'client_id=a&client_id=b', headers: { 'content-type' => 'application/x-www-form-urlencoded' }).status
    assert_empty @oauth.registrations
    @now = 60
    10.times { assert_equal 201, request('/oauth/register', token: nil, method: 'POST', data: {}).status }
    assert_equal 429, request('/oauth/register', token: nil, method: 'POST', data: {}).status
    assert_equal 10, @oauth.registrations.length
    @now = 120
    assert_equal 201, request('/oauth/register', token: nil, method: 'POST', data: {}).status
    assert_equal 0, @collector.snapshot_calls
  end

  private

  def request(path, token: 'fixture-token', query: {}, method: 'GET', headers: {}, data: nil, raw: nil)
    response = Response.new
    defaults = { 'host' => 'toolbox.example', 'cookie' => token && "toolbox_session=#{token}", 'content-type' => 'application/json' }
    body = raw || (data.nil? ? '' : JSON.generate(data))
    query_string = query.empty? ? nil : URI.encode_www_form(query)
    @app.call(Request.new(path, method, query, defaults.merge(headers), body, query_string), response)
    response
  end

  def assert_no_store(response)
    assert_equal 'no-store, private', response['Cache-Control']
    assert_equal 'Cookie, Authorization, Origin', response['Vary']
  end
end

require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/dashboard/app'

class DashboardAppTest < Minitest::Test
  Request = Struct.new(:path, :request_method, :query, :headers) do
    def [](key) = headers[key]
  end

  class Response
    attr_accessor :status, :body
    attr_reader :headers
    def initialize = @headers = {}
    def []=(key, value) = @headers[key] = value
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

  class Access
    attr_reader :calls
    attr_accessor :failure
    def initialize = @calls = []
    def verify(token)
      @calls << token
      raise failure if failure
      raise Dashboard::Access::Unauthorized unless token == 'fixture-token'
      { 'sub' => 'fixture-user' }
    end
  end

  def setup
    @directory = Dir.mktmpdir('toolbox-dashboard-test-')
    @public = File.join(@directory, 'public')
    FileUtils.mkdir_p(@public)
    File.write(File.join(@public, 'index.html'), '<h1>Fixture</h1>')
    File.write(File.join(@public, 'sw.js'), 'self.addEventListener("fetch", () => {});')
    File.write(File.join(@directory, 'secret.html'), 'private fixture secret')
    File.symlink(File.join(@directory, 'secret.html'), File.join(@public, 'escape.html'))
    @collector = Collector.new
    @access = Access.new
    @now = 0
    @app = Dashboard::App.new(collector: @collector, access: @access,
                             public_dir: @public, revision: 'fixture-sha', clock: -> { @now })
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_unauthenticated_requests_never_collect_host_data_or_serve_assets
    ['/', '/api/status', '/api/logs', '/sw.js'].each do |path|
      response = request(path, token: nil)
      assert_equal 401, response.status
      assert_equal 'Cloudflare Access login required', JSON.parse(response.body)['error']
      assert_no_store(response)
    end
    assert_equal 0, @collector.snapshot_calls
    assert_empty @collector.log_calls
  end

  def test_authentication_outage_fails_closed_without_collecting
    @access.failure = Dashboard::Access::Unavailable.new('secret diagnostics')
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
    assert_equal 3, @access.calls.length
    @now = 10
    assert_equal 200, request('/api/status').status
    assert_equal 2, @collector.snapshot_calls
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
    assert_equal 3, @access.calls.length
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
    assert_empty @access.calls
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
    assert_equal 'Metrics are temporarily unavailable', JSON.parse(response.body)['error']
    refute_includes response.body, 'private-value'
    assert_no_store(response)
  end

  private

  def request(path, token: 'fixture-token', query: {}, method: 'GET')
    response = Response.new
    @app.call(Request.new(path, method, query, { 'cf-access-jwt-assertion' => token }), response)
    response
  end

  def assert_no_store(response)
    assert_equal 'no-store, private', response['Cache-Control']
    assert_equal 'Cookie, Cf-Access-Jwt-Assertion', response['Vary']
  end
end

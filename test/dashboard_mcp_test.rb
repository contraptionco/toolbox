require_relative 'test_helper'
require_relative '../lib/dashboard/mcp'

class DashboardMCPTest < Minitest::Test
  Request = Struct.new(:request_method, :headers, :body) do
    def [](name) = headers[name]
  end
  class Response
    attr_accessor :status, :body
    def initialize = @headers = {}
    def []=(name, value)
      @headers[name] = value
    end
    def [](name) = @headers[name]
  end
  class OAuth
    attr_accessor :scopes
    def initialize = @scopes = %w[toolbox:read toolbox:logs]
    def authenticate(value)
      raise Dashboard::OAuth::Error.new('invalid_token', 'Authentication required.', 401) unless value == 'Bearer fixture'
      { subject: Dashboard::OAuth::OWNER, scopes: scopes }
    end
  end
  class Collector
    attr_reader :calls
    def initialize = @calls = []
    def snapshot
      @calls << :snapshot
      { generated_at: 'fixture', host: { name: 'fixture-host' }, containers: [{ name: 'postcard' }],
        deployment: { dashboard_commit: 'a' * 40, checkout_commit: 'b' * 40, status: 'stale' },
        applications: [{ name: 'postcard', running_commit: nil, last_successful_commit: 'c' * 40,
                         running_image_id: 'sha256:' + 'd' * 64, revision_evidence: 'last_successful_only' },
                       { name: 'bully-pulpit', running_commit: 'e' * 40, revision_evidence: 'image_match' },
                       { name: 'external', running_commit: nil, last_successful_commit: nil, revision_evidence: 'unknown' }],
        log_sources: [{ id: 'container:postcard' }], errors: [], warnings: ['Fixture stale evidence warning'] }
    end
    def logs(source, lines:)
      @calls << [source, lines]
      { source: source, lines: ['[sensitive log line omitted]', 'fixture log'], truncated: false }
    end
  end

  def setup
    @oauth, @collector = OAuth.new, Collector.new
    @mcp = Dashboard::MCP.new(collector: @collector, oauth: @oauth, origin: 'https://toolbox.example')
  end

  def call(method = 'tools/list', params = {}, headers: {}, http_method: 'POST', raw: nil, id: 1)
    defaults = { 'authorization' => 'Bearer fixture', 'content-type' => 'application/json', 'accept' => 'application/json, text/event-stream', 'mcp-protocol-version' => '2025-11-25' }
    message = { jsonrpc: '2.0', method: method, params: params }
    message[:id] = id unless id == :absent
    response = Response.new
    @mcp.call(Request.new(http_method, defaults.merge(headers), raw || JSON.generate(message)), response)
    response
  end

  def parsed(response) = JSON.parse(response.body)

  def test_bearer_authentication_required_even_for_get_and_initialization
    %w[GET POST DELETE].each do |method|
      response = call(headers: { 'authorization' => nil, 'cookie' => 'valid-browser-session' }, http_method: method)
      assert_equal 401, response.status
      assert_includes response['WWW-Authenticate'], 'oauth-protected-resource/mcp'
      assert_equal 'no-store, private', response['Cache-Control']
    end
    assert_empty @collector.calls
  end

  def test_invalid_origin_and_transport_rejected_before_collection
    assert_equal 403, call(headers: { 'origin' => 'https://evil.example' }).status
    assert_equal 405, call(http_method: 'GET').status
    assert_equal 405, call(http_method: 'DELETE').status
    assert_equal 415, call(headers: { 'content-type' => 'text/plain' }).status
    assert_equal 406, call(headers: { 'accept' => 'text/event-stream' }).status
    assert_equal 400, call(headers: { 'mcp-protocol-version' => 'unsupported' }).status
    assert_empty @collector.calls
  end

  def test_cors_preflight_returns_no_data_and_exposes_bearer_challenge_only_to_allowed_origins
    response = call(headers: { 'authorization' => nil, 'origin' => 'https://claude.ai' }, http_method: 'OPTIONS')
    assert_equal 204, response.status
    assert_equal '', response.body
    assert_equal 'https://claude.ai', response['Access-Control-Allow-Origin']
    assert_includes response['Access-Control-Allow-Headers'], 'Authorization'
    assert_nil response['Access-Control-Allow-Credentials']
    assert_equal 403, call(headers: { 'origin' => 'https://evil.example' }, http_method: 'OPTIONS').status
    assert_empty @collector.calls
  end

  def test_initialization_negotiates_supported_version_and_no_write_tools
    response = call('initialize', { protocolVersion: 'future', capabilities: {}, clientInfo: { name: 'fixture', version: '1' } })
    assert_equal '2025-11-25', parsed(response).dig('result', 'protocolVersion')
    tools = parsed(call).dig('result', 'tools')
    assert_equal %w[toolbox_status toolbox_deployments toolbox_containers toolbox_logs], tools.map { |tool| tool['name'] }
    assert tools.all? { |tool| tool.dig('annotations', 'readOnlyHint') && !tool.dig('annotations', 'destructiveHint') }
    assert_empty @collector.calls
  end

  def test_version_negotiation_only_accepts_implemented_protocol_revisions
    %w[2025-06-18 2025-11-25].each do |version|
      response = call('initialize', { protocolVersion: version, capabilities: {}, clientInfo: { name: 'fixture', version: '1' } },
        headers: { 'mcp-protocol-version' => nil })
      assert_equal 200, response.status
      assert_equal version, parsed(response).dig('result', 'protocolVersion')
      assert_equal version, response['MCP-Protocol-Version']
      assert_equal 200, call('ping', headers: { 'mcp-protocol-version' => version }).status
    end
    # A legacy offer can negotiate a supported revision, but subsequent requests
    # cannot claim the older batching-capable revision that we do not implement.
    response = call('initialize', { protocolVersion: '2025-03-26', capabilities: {}, clientInfo: { name: 'fixture', version: '1' } },
      headers: { 'mcp-protocol-version' => nil })
    assert_equal '2025-11-25', parsed(response).dig('result', 'protocolVersion')
    %w[2025-03-26 2026-07-28].each do |version|
      assert_equal 400, call('tools/call', { name: 'toolbox_status' }, headers: { 'mcp-protocol-version' => version }).status
    end
    assert_empty @collector.calls
  end

  def test_notifications_do_not_trigger_collection
    response = call('notifications/initialized', {}, id: :absent)
    assert_equal 202, response.status
    assert_equal '', response.body
    assert_equal 400, call('tools/call', { name: 'toolbox_status' }, id: :absent).status
    assert_empty @collector.calls
  end

  def test_status_and_container_tools_only_return_collector_data
    status = parsed(call('tools/call', { name: 'toolbox_status' })).dig('result', 'structuredContent')
    assert_equal 'fixture-host', status.dig('host', 'name')
    containers = parsed(call('tools/call', { name: 'toolbox_containers' })).dig('result', 'structuredContent')
    assert_equal ['postcard'], containers.fetch('containers').map { |row| row['name'] }
    refute containers.key?('host')
  end

  def test_deployments_tool_keeps_runtime_checkout_and_historical_evidence_distinct
    @oauth.scopes = ['toolbox:read']
    tools = parsed(call).dig('result', 'tools')
    assert_includes tools.map { |tool| tool['name'] }, 'toolbox_deployments'
    response = call('tools/call', { name: 'toolbox_deployments' })
    assert_equal 200, response.status
    value = parsed(response).dig('result', 'structuredContent')
    assert_equal %w[applications deployment errors generated_at warnings], value.keys.sort
    assert_equal 'a' * 40, value.dig('deployment', 'dashboard_commit')
    assert_equal 'b' * 40, value.dig('deployment', 'checkout_commit')
    assert_equal 'stale', value.dig('deployment', 'status')
    assert_nil value.dig('applications', 0, 'running_commit')
    assert_equal 'c' * 40, value.dig('applications', 0, 'last_successful_commit')
    assert_equal 'last_successful_only', value.dig('applications', 0, 'revision_evidence')
    assert_equal 'e' * 40, value.dig('applications', 1, 'running_commit')
    assert_equal 'image_match', value.dig('applications', 1, 'revision_evidence')
    assert_equal 'unknown', value.dig('applications', 2, 'revision_evidence')
    assert_equal ['Fixture stale evidence warning'], value['warnings']
    refute value.key?('host')
    refute value.key?('containers')
    refute value.key?('log_sources')
    assert_equal [:snapshot], @collector.calls
  end

  def test_deployments_tool_rejects_arguments_and_missing_read_scope_before_collection
    assert_equal(-32602, parsed(call('tools/call', { name: 'toolbox_deployments', arguments: { path: '/private/other-repo' } })).dig('error', 'code'))
    @oauth.scopes = ['toolbox:logs']
    assert_equal 403, call('tools/call', { name: 'toolbox_deployments' }).status
    assert_empty @collector.calls
  end

  def test_log_calls_are_allowlisted_and_bounded
    response = call('tools/call', { name: 'toolbox_logs', arguments: { source: 'container:postcard', lines: 25 } })
    assert_equal false, parsed(response).dig('result', 'isError')
    assert_includes @collector.calls, ['container:postcard', 25]
    @collector.calls.clear
    [0, 201, '25', 2.5].each do |count|
      assert_equal(-32602, parsed(call('tools/call', { name: 'toolbox_logs', arguments: { source: 'container:postcard', lines: count } })).dig('error', 'code'))
    end
    assert_equal(-32602, parsed(call('tools/call', { name: 'toolbox_logs', arguments: { source: '../../secret' } })).dig('error', 'code'))
    assert_equal(-32602, parsed(call('tools/call', { name: 'toolbox_logs', arguments: { source: 'container:postcard', command: 'rm' } })).dig('error', 'code'))
    refute @collector.calls.any? { |entry| entry.is_a?(Array) }
  end

  def test_read_only_grant_cannot_discover_or_invoke_log_tool
    @oauth.scopes = ['toolbox:read']
    tools = parsed(call).dig('result', 'tools')
    refute_includes tools.map { |tool| tool['name'] }, 'toolbox_logs'
    response = call('tools/call', { name: 'toolbox_logs', arguments: { source: 'container:postcard' } })
    assert_equal 403, response.status
    assert_includes response['WWW-Authenticate'], 'insufficient_scope'
    assert_empty @collector.calls
  end

  def test_invalid_rpc_messages_and_oversize_inputs_do_not_collect
    assert_equal 413, call(raw: 'x' * 65_537).status
    assert_equal(-32700, parsed(call(raw: '{')).dig('error', 'code'))
    assert_equal(-32600, parsed(call(raw: '[]')).dig('error', 'code'))
    assert_equal(-32600, parsed(call(id: nil)).dig('error', 'code'))
    assert_equal(-32600, parsed(call(id: 'x' * 129)).dig('error', 'code'))
    assert_equal(-32600, parsed(call(raw: JSON.generate(jsonrpc: '2.0', id: 1, method: 'tools/call', params: []))).dig('error', 'code'))
    assert_equal(-32601, parsed(call('execute', { command: 'docker stop postcard' })).dig('error', 'code'))
    assert_empty @collector.calls
  end
end

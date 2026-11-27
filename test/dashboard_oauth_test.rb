require_relative 'test_helper'
require 'sqlite3'
require 'tmpdir'
require_relative '../lib/dashboard/oauth'

class DashboardOAuthTest < Minitest::Test
  class Store
    def initialize(path)
      @db = SQLite3::Database.new(path)
      @db.results_as_hash = true
      @mutex = Mutex.new
    end
    def with_db(&block) = @mutex.synchronize { block.call(@db) }
    def close = @db.close
  end

  def setup
    @directory = Dir.mktmpdir('toolbox-oauth-test-')
    @store = Store.new(File.join(@directory, 'auth.sqlite3'))
    @time = Time.utc(2026, 11, 27)
    @oauth = Dashboard::OAuth.new(store: @store, origin: 'https://toolbox.example', clock: -> { @time })
    @owner = Dashboard::OAuth::OWNER
    @client = @oauth.register_client('redirect_uris' => [Dashboard::OAuth::REDIRECT_URI])
    @verifier = 'v' * 43
  end

  def teardown
    @store.close
    FileUtils.remove_entry(@directory)
  end

  def authorization(scope: nil, **changes)
    params = { 'client_id' => @client[:client_id], 'redirect_uri' => Dashboard::OAuth::REDIRECT_URI,
               'resource' => @oauth.resource, 'response_type' => 'code', 'state' => 'opaque-client-state',
               'code_challenge' => Base64.urlsafe_encode64(Digest::SHA256.digest(@verifier), padding: false), 'code_challenge_method' => 'S256' }
    params['scope'] = scope if scope
    @oauth.begin_authorization(params.merge(changes.transform_keys(&:to_s)), subject: @owner)
  end

  def code(scope: nil)
    request = authorization(scope: scope)
    callback = @oauth.complete_authorization(request[:id], subject: @owner, approve: true)
    URI.decode_www_form(URI(callback).query).to_h.fetch('code')
  end

  def exchange(value, **changes)
    @oauth.token({ 'grant_type' => 'authorization_code', 'client_id' => @client[:client_id], 'code' => value,
                   'code_verifier' => @verifier, 'redirect_uri' => Dashboard::OAuth::REDIRECT_URI, 'resource' => @oauth.resource }.merge(changes.transform_keys(&:to_s)))
  end

  def refresh(value, **changes)
    @oauth.token({ 'grant_type' => 'refresh_token', 'client_id' => @client[:client_id], 'refresh_token' => value, 'resource' => @oauth.resource }.merge(changes.transform_keys(&:to_s)))
  end

  def assert_oauth_error(code, &block)
    assert_equal code, assert_raises(Dashboard::OAuth::Error, &block).code
  end

  def test_metadata_advertises_discovery_pkce_and_read_only_scopes
    assert_equal ['S256'], @oauth.authorization_metadata[:code_challenge_methods_supported]
    assert_equal ['none'], @oauth.authorization_metadata[:token_endpoint_auth_methods_supported]
    assert_equal 'https://toolbox.example/mcp', @oauth.resource_metadata[:resource]
    assert_equal %w[toolbox:read toolbox:logs], @oauth.resource_metadata[:scopes_supported]
  end

  def test_registration_rejects_untrusted_redirects_and_confidential_client_methods
    [[], ['https://attacker.example/callback'], ["#{Dashboard::OAuth::REDIRECT_URI}?next=evil"], ["#{Dashboard::OAuth::REDIRECT_URI}#fragment"]].each do |redirects|
      assert_oauth_error('invalid_redirect_uri') { @oauth.register_client('redirect_uris' => redirects) }
    end
    assert_oauth_error('invalid_client_metadata') { @oauth.register_client('redirect_uris' => [Dashboard::OAuth::REDIRECT_URI], 'token_endpoint_auth_method' => 'client_secret_post') }
    assert_equal 'Claude', @oauth.register_client('redirect_uris' => [Dashboard::OAuth::REDIRECT_URI], 'client_name' => '<script>evil</script>')[:client_name]
  end

  def test_equivalent_public_registrations_reuse_application_identity
    duplicate = @oauth.register_client('redirect_uris' => [Dashboard::OAuth::REDIRECT_URI], 'client_name' => 'Changed name')
    assert_equal @client[:client_id], duplicate[:client_id]
    assert_equal @client[:client_id_issued_at], duplicate[:client_id_issued_at]
    @store.with_db { |db| assert_equal 1, db.get_first_value('SELECT COUNT(*) FROM oauth_clients') }
  end

  def test_only_owner_can_consent_and_requests_are_bound_to_client_resource_and_pkce
    assert_oauth_error('access_denied') { @oauth.begin_authorization({}, subject: 'someone@example.com') }
    assert_oauth_error('invalid_target') { authorization(resource: 'https://other.example/mcp') }
    assert_oauth_error('invalid_request') { authorization(redirect_uri: 'https://attacker.example/callback') }
    assert_oauth_error('invalid_request') { authorization(code_challenge_method: 'plain') }
    assert_oauth_error('invalid_scope') { authorization(scope: 'toolbox:write') }
    assert_oauth_error('invalid_scope') { authorization(scope: 'toolbox:logs') }
    assert_oauth_error('invalid_client') { authorization(client_id: 'missing') }
  end

  def test_consent_is_explicit_single_use_and_denial_issues_no_tokens
    pending = authorization
    assert_empty @oauth.grants(subject: @owner)
    assert_equal pending, @oauth.consent(pending[:id], subject: @owner)
    callback = @oauth.complete_authorization(pending[:id], subject: @owner, approve: false)
    values = URI.decode_www_form(URI(callback).query).to_h
    assert_equal 'access_denied', values['error']
    assert_equal 'opaque-client-state', values['state']
    assert_equal @oauth.origin, values['iss']
    refute values.key?('code')
    assert_oauth_error('invalid_request') { @oauth.complete_authorization(pending[:id], subject: @owner, approve: true) }
    assert_empty @oauth.grants(subject: @owner)
  end

  def test_pkce_failure_does_not_consume_code_and_codes_cannot_cross_clients_or_resources
    value = code
    assert_oauth_error('invalid_grant') { exchange(value, code_verifier: 'w' * 43) }
    assert_oauth_error('invalid_target') { exchange(value, resource: 'https://other.example/mcp') }
    assert_oauth_error('invalid_grant') { exchange(value, redirect_uri: 'https://attacker.example/') }
    other = @oauth.register_client('redirect_uris' => [Dashboard::OAuth::REDIRECT_URI], 'scope' => 'toolbox:read')
    assert_oauth_error('invalid_grant') { exchange(value, client_id: other[:client_id]) }
    tokens = exchange(value)
    identity = @oauth.authenticate("Bearer #{tokens[:access_token]}")
    assert_equal @owner, identity[:subject]
    assert_equal %w[toolbox:read toolbox:logs], identity[:scopes]
  end

  def test_tokens_are_hashed_and_access_expires_while_refresh_rotates
    tokens = exchange(code)
    stored = @store.with_db { |db| db.execute('SELECT * FROM oauth_access_tokens') + db.execute('SELECT * FROM oauth_refresh_tokens') }
    refute_includes JSON.generate(stored), tokens[:access_token]
    refute_includes JSON.generate(stored), tokens[:refresh_token]
    @time += 3601
    assert_oauth_error('invalid_token') { @oauth.authenticate("Bearer #{tokens[:access_token]}") }
    rotated = refresh(tokens[:refresh_token])
    refute_equal tokens[:refresh_token], rotated[:refresh_token]
    assert_equal @owner, @oauth.authenticate("Bearer #{rotated[:access_token]}")[:subject]
    @store.with_db { |db| assert_equal 1, db.get_first_value('SELECT COUNT(*) FROM oauth_refresh_tokens WHERE consumed_at IS NOT NULL') }
  end

  def test_refresh_reuse_revokes_entire_token_family_and_commit_survives_error
    tokens = exchange(code)
    rotated = refresh(tokens[:refresh_token])
    assert_oauth_error('invalid_grant') { refresh(tokens[:refresh_token]) }
    assert_oauth_error('invalid_token') { @oauth.authenticate("Bearer #{rotated[:access_token]}") }
    assert_oauth_error('invalid_token') { @oauth.authenticate("Bearer #{tokens[:access_token]}") }
    assert_oauth_error('invalid_grant') { refresh(rotated[:refresh_token]) }
    assert_empty @oauth.grants(subject: @owner)
  end

  def test_code_replay_revokes_issued_tokens
    value = code
    tokens = exchange(value)
    assert_oauth_error('invalid_grant') { exchange(value) }
    assert_oauth_error('invalid_token') { @oauth.authenticate("Bearer #{tokens[:access_token]}") }
  end

  def test_refresh_cannot_escalate_scopes_and_narrowing_persists
    tokens = exchange(code(scope: 'toolbox:read'))
    assert_oauth_error('invalid_scope') { refresh(tokens[:refresh_token], scope: 'toolbox:read toolbox:logs') }
    rotated = refresh(tokens[:refresh_token])
    assert_equal ['toolbox:read'], @oauth.authenticate("Bearer #{rotated[:access_token]}")[:scopes]
    full = exchange(code)
    narrowed = refresh(full[:refresh_token], scope: 'toolbox:read')
    assert_oauth_error('invalid_scope') { refresh(narrowed[:refresh_token], scope: 'toolbox:read toolbox:logs') }
  end

  def test_owner_revocation_immediately_disables_access_and_refresh
    tokens = exchange(code)
    grant = @oauth.grants(subject: @owner).first
    assert_oauth_error('access_denied') { @oauth.revoke_grant(grant[:id], subject: 'other@example.com') }
    @oauth.revoke_grant(grant[:id], subject: @owner)
    assert_oauth_error('invalid_token') { @oauth.authenticate("Bearer #{tokens[:access_token]}") }
    assert_oauth_error('invalid_grant') { refresh(tokens[:refresh_token]) }
  end

  def test_revocation_endpoint_requires_matching_client_and_does_not_disclose_unknown_tokens
    tokens = exchange(code)
    other = @oauth.register_client('redirect_uris' => [Dashboard::OAuth::REDIRECT_URI], 'scope' => 'toolbox:read')
    assert @oauth.revoke({ 'client_id' => other[:client_id], 'token' => tokens[:refresh_token] })
    assert @oauth.authenticate("Bearer #{tokens[:access_token]}")
    assert @oauth.revoke({ 'client_id' => @client[:client_id], 'token' => 'unknown' })
    assert @oauth.revoke({ 'client_id' => @client[:client_id], 'token' => tokens[:refresh_token] })
    assert_oauth_error('invalid_token') { @oauth.authenticate("Bearer #{tokens[:access_token]}") }
  end

  def test_consent_codes_and_absolute_grants_expire
    pending = authorization
    @time += 601
    assert_oauth_error('invalid_request') { @oauth.consent(pending[:id], subject: @owner) }
    value = code
    @time += 121
    assert_oauth_error('invalid_grant') { exchange(value) }
    tokens = exchange(code)
    @time += Dashboard::OAuth::REFRESH_SECONDS + 1
    assert_oauth_error('invalid_grant') { refresh(tokens[:refresh_token]) }
  end

  def test_cookie_or_other_token_material_is_not_accepted_as_bearer
    [nil, '', 'Cookie session=value', 'Bearer abc', 'Bearer ' + 'a' * 44, 'Bearer ' + 'a' * 43 + "\n"].each do |value|
      assert_oauth_error('invalid_token') { @oauth.authenticate(value) }
    end
  end

  def test_bearer_tokens_survive_restart_but_are_bound_to_this_resource
    tokens = exchange(code)
    @store.close
    @store = Store.new(File.join(@directory, 'auth.sqlite3'))
    restarted = Dashboard::OAuth.new(store: @store, origin: @oauth.origin, clock: -> { @time })
    assert_equal @owner, restarted.authenticate("Bearer #{tokens[:access_token]}")[:subject]
    wrong_resource = Dashboard::OAuth.new(store: @store, origin: 'https://other.example', clock: -> { @time })
    assert_oauth_error('invalid_token') { wrong_resource.authenticate("Bearer #{tokens[:access_token]}") }
  end

  def test_refreshes_cannot_extend_the_absolute_grant_lifetime
    tokens = exchange(code)
    3.times do
      @time += 29 * 86_400
      tokens = refresh(tokens[:refresh_token])
    end
    @time += 3 * 86_400 + 1
    assert_oauth_error('invalid_grant') { refresh(tokens[:refresh_token]) }
    assert_oauth_error('invalid_token') { @oauth.authenticate("Bearer #{tokens[:access_token]}") }
  end

  def use_cimd(cache_control: 'public, max-age=300')
    @metadata_calls = 0
    @metadata_document = {
      'client_id' => Dashboard::OAuth::CLAUDE_CLIENT_ID, 'client_name' => 'Claude',
      'redirect_uris' => [Dashboard::OAuth::REDIRECT_URI], 'token_endpoint_auth_method' => 'none',
      'grant_types' => %w[authorization_code refresh_token urn:ietf:params:oauth:grant-type:jwt-bearer], 'response_types' => ['code']
    }
    @metadata_response = { status: 200, headers: { 'content-type' => 'application/json', 'cache-control' => cache_control }, body: nil }
    @metadata_error = nil
    fetcher = lambda do
      @metadata_calls += 1
      raise @metadata_error if @metadata_error
      @metadata_response.merge(body: @metadata_response[:body] || JSON.generate(@metadata_document))
    end
    @oauth = Dashboard::OAuth.new(store: @store, origin: 'https://toolbox.example', clock: -> { @time }, metadata_fetcher: fetcher)
    @client = { client_id: Dashboard::OAuth::CLAUDE_CLIENT_ID }
  end

  def test_cimd_published_identity_supports_consent_code_refresh_and_revocation
    use_cimd
    assert_equal true, @oauth.authorization_metadata[:client_id_metadata_document_supported]
    tokens = exchange(code)
    assert_equal 1, @metadata_calls
    assert_equal @owner, @oauth.authenticate("Bearer #{tokens[:access_token]}")[:subject]
    @time += 301
    @metadata_error = IOError.new('metadata unavailable')
    rotated = refresh(tokens[:refresh_token])
    assert_equal 1, @metadata_calls, 'Existing token grants do not depend on metadata fetches'
    assert @oauth.revoke({ 'client_id' => Dashboard::OAuth::CLAUDE_CLIENT_ID, 'token' => rotated[:refresh_token] })
    assert_oauth_error('invalid_token') { @oauth.authenticate("Bearer #{rotated[:access_token]}") }
    assert_equal 1, @metadata_calls
  end

  def test_cimd_cache_respects_max_age_and_revalidates_before_approval
    use_cimd(cache_control: 'public, max-age=10')
    pending = authorization
    @time += 9
    authorization
    assert_equal 1, @metadata_calls
    @time += 2
    @oauth.complete_authorization(pending[:id], subject: @owner, approve: true)
    assert_equal 2, @metadata_calls
    @metadata_response[:headers]['cache-control'] = 'public, max-age=86400'
    @time += 11
    authorization
    @time += 301
    authorization
    assert_equal 4, @metadata_calls, 'Server caps a successful cache lifetime at five minutes'
  end

  def test_cimd_no_store_and_age_headers_cannot_extend_cache_lifetime
    use_cimd(cache_control: 'no-store, max-age=300')
    2.times { authorization }
    assert_equal 2, @metadata_calls
    @metadata_response[:headers] = { 'content-type' => 'application/json', 'cache-control' => 'max-age=300', 'age' => '299' }
    authorization
    @time += 2
    authorization
    assert_equal 4, @metadata_calls
  end

  def test_cimd_failed_metadata_is_not_cached_or_allowed_to_create_consent
    use_cimd
    @metadata_document['client_id'] = 'https://attacker.example/metadata'
    2.times { assert_oauth_error('invalid_client') { authorization } }
    assert_equal 2, @metadata_calls
    @store.with_db { |db| assert_equal 0, db.get_first_value('SELECT COUNT(*) FROM oauth_consents') }
    @metadata_document['client_id'] = Dashboard::OAuth::CLAUDE_CLIENT_ID
    pending = authorization
    @time += 301
    @metadata_document['redirect_uris'] = ['https://attacker.example/callback']
    assert_oauth_error('invalid_client') { @oauth.complete_authorization(pending[:id], subject: @owner, approve: true) }
    assert_empty @oauth.grants(subject: @owner)
    assert_includes @oauth.complete_authorization(pending[:id], subject: @owner, approve: false), 'access_denied'
  end

  def test_cimd_only_exact_allowlisted_identity_and_owner_can_trigger_fetch
    use_cimd
    ['https://127.0.0.1/private', 'https://claude.ai.evil.example/oauth/mcp-oauth-client-metadata',
     Dashboard::OAuth::CLAUDE_CLIENT_ID + '?query=1', Dashboard::OAuth::CLAUDE_CLIENT_ID + '#fragment',
     'http://claude.ai/oauth/mcp-oauth-client-metadata', 'https://claude.ai/oauth/claude-code-client-metadata'].each do |id|
      assert_oauth_error('invalid_client') { authorization(client_id: id) }
    end
    assert_oauth_error('access_denied') { @oauth.begin_authorization({ 'client_id' => Dashboard::OAuth::CLAUDE_CLIENT_ID }, subject: 'other@example.com') }
    assert_equal 0, @metadata_calls
  end

  def test_cimd_validates_response_size_type_status_and_client_authentication
    use_cimd
    [{ status: 302 }, { body: 'x' * 5121 }, { body: '[]' }, { body: '{' },
     { headers: { 'content-type' => 'text/html' } }].each do |changes|
      original = @metadata_response
      @metadata_response = original.merge(changes)
      assert_raises(Dashboard::OAuth::Error) { authorization }
      @metadata_response = original
    end
    @metadata_document['token_endpoint_auth_method'] = 'private_key_jwt'
    assert_oauth_error('invalid_client') { authorization }
    @metadata_document['token_endpoint_auth_method'] = 'none'
    @metadata_document['client_secret'] = 'fixture'
    assert_oauth_error('invalid_client') { authorization }
    @metadata_document.delete('client_secret')
    @metadata_document.delete('client_name')
    assert_oauth_error('invalid_client') { authorization }
    @metadata_error = Timeout::Error.new('network secret must not escape')
    error = assert_raises(Dashboard::OAuth::Error) { authorization }
    assert_equal 503, error.status
    refute_includes error.message, 'network secret'
  end

  class MetadataHTTP
    attr_accessor :use_ssl, :verify_mode, :verify_hostname, :open_timeout, :read_timeout, :write_timeout, :max_retries
    attr_reader :requests
    def initialize(response)
      @response, @requests = response, []
    end
    def start = yield self
    def request(request)
      @requests << request
      yield @response
    end
  end

  class MetadataResponse
    attr_reader :code, :body_reads
    def initialize(code:, headers:, chunks:)
      @code, @headers, @chunks, @body_reads = code, headers, chunks, 0
    end
    def [](name) = @headers[name]
    def read_body
      @chunks.each do |chunk|
        @body_reads += 1
        yield chunk
      end
    end
  end

  def test_cimd_network_fetch_pins_host_path_tls_and_never_follows_redirects
    use_cimd
    response = MetadataResponse.new(code: '200', headers: { 'content-type' => 'application/json', 'cache-control' => 'max-age=300' }, chunks: [JSON.generate(@metadata_document)])
    connection = MetadataHTTP.new(response)
    constructor = lambda do |host, port, proxy|
      assert_equal 'claude.ai', host
      assert_equal 443, port
      assert_nil proxy
      connection
    end
    Net::HTTP.stub(:new, constructor) do
      assert Dashboard::OAuth::ClaudeMetadata.new(clock: -> { @time }).verify!
    end
    assert_equal true, connection.use_ssl
    assert_equal OpenSSL::SSL::VERIFY_PEER, connection.verify_mode
    assert_equal true, connection.verify_hostname
    assert_equal 0, connection.max_retries
    assert_equal '/oauth/mcp-oauth-client-metadata', connection.requests.first.path
    assert_equal 'identity', connection.requests.first['Accept-Encoding']
    assert_nil connection.requests.first['Authorization']
    assert_nil connection.requests.first['Cookie']
    redirect = MetadataResponse.new(code: '302', headers: { 'location' => 'https://127.0.0.1/private' }, chunks: ['redirect'])
    connection = MetadataHTTP.new(redirect)
    Net::HTTP.stub(:new, constructor) { assert_oauth_error('invalid_client') { Dashboard::OAuth::ClaudeMetadata.new(clock: -> { @time }).verify! } }
    assert_equal 1, connection.requests.length
    assert_equal 0, redirect.body_reads
  end

  def test_cimd_network_reader_stops_oversized_chunked_bodies
    response = MetadataResponse.new(code: '200', headers: { 'content-type' => 'application/json' }, chunks: ['x' * 5120, 'y', 'never read'])
    connection = MetadataHTTP.new(response)
    Net::HTTP.stub(:new, connection) do
      assert_oauth_error('invalid_client') { Dashboard::OAuth::ClaudeMetadata.new(clock: -> { @time }).verify! }
    end
    assert_equal 2, response.body_reads
  end

  def test_concurrent_code_exchange_allows_at_most_one_success
    value = code
    results = 2.times.map { Thread.new { exchange(value) rescue $! } }.map(&:value)
    assert_equal 1, results.count { |result| result.is_a?(Hash) }
    assert_equal 1, results.count { |result| result.is_a?(Dashboard::OAuth::Error) }
    # Second use revokes the first result rather than minting another token family.
    assert_empty @oauth.grants(subject: @owner)
  end
end

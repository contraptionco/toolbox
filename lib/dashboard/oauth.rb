require 'base64'
require 'digest'
require 'json'
require 'net/http'
require 'timeout'
require 'thread'
require 'openssl'
require 'securerandom'
require 'uri'

module Dashboard
  # A deliberately small OAuth authorization server for the owner's Claude connector.
  # Browser authentication and CSRF checks belong to App, not the bearer-token API.
  class OAuth
    OWNER = 'philip@ilic.nyc'.freeze
    REDIRECT_URI = 'https://claude.ai/api/mcp/auth_callback'.freeze
    CLAUDE_CLIENT_ID = 'https://claude.ai/oauth/mcp-oauth-client-metadata'.freeze
    SCOPES = %w[toolbox:read toolbox:logs].freeze
    TOKEN = /\A[A-Za-z0-9_-]{43}\z/
    ACCESS_SECONDS = 3600
    REFRESH_SECONDS = 30 * 86_400
    GRANT_SECONDS = 90 * 86_400

    class Error < StandardError
      attr_reader :code, :status
      def initialize(code, message, status = 400)
        @code, @status = code, status
        super(message)
      end
    end

    # Only Claude's published public client is trusted. No request supplies a
    # fetch URL, no redirects/proxy are followed, and no logo/JWKS URL is read.
    class ClaudeMetadata
      MAX_BYTES = 5 * 1024
      MAX_CACHE_SECONDS = 300

      def initialize(clock:, fetcher: nil)
        @clock, @fetcher = clock, fetcher || method(:fetch)
        @mutex = Mutex.new
        @valid_until = nil
      end

      def verify!
        @mutex.synchronize do
          return true if @valid_until && @valid_until > @clock.call.to_i
          result = @fetcher.call
          body = result.fetch(:body)
          headers = result.fetch(:headers)
          invalid! unless result[:status] == 200 && body.is_a?(String) && body.bytesize <= MAX_BYTES && headers.is_a?(Hash)
          invalid! unless headers['content-type'].to_s.split(';').first.to_s.strip.downcase == 'application/json'
          document = JSON.parse(body, max_nesting: 8)
          invalid! unless document.is_a?(Hash) && document['client_id'] == CLAUDE_CLIENT_ID &&
                          document['client_name'].is_a?(String) && document['client_name'].bytesize.between?(1, 100) &&
                          document['redirect_uris'].is_a?(Array) && document['redirect_uris'].all? { |uri| uri.is_a?(String) && uri.bytesize <= 2048 } &&
                          document['redirect_uris'].include?(REDIRECT_URI) && document['token_endpoint_auth_method'] == 'none' &&
                          !document.key?('client_secret') && !document.key?('client_secret_expires_at')
          { 'grant_types' => 'authorization_code', 'response_types' => 'code' }.each do |key, required|
            next unless document.key?(key)
            values = document[key]
            invalid! unless values.is_a?(Array) && values.all? { |value| value.is_a?(String) } && values.include?(required)
          end
          policy = headers['cache-control'].to_s.downcase
          age = headers['age'].to_s.match?(/\A\d+\z/) ? headers['age'].to_i : 0
          ttl = policy[/\bmax-age\s*=\s*"?(\d+)/, 1]&.to_i || MAX_CACHE_SECONDS
          ttl = 0 if policy.match?(/\b(?:no-store|no-cache)\b/)
          @valid_until = @clock.call.to_i + [[ttl - age, 0].max, MAX_CACHE_SECONDS].min
          true
        end
      rescue Error
        raise
      rescue StandardError
        raise Error.new('temporarily_unavailable', 'Claude client verification is temporarily unavailable. Try again or choose Register automatically.', 503)
      end

      private

      def invalid!
        raise Error.new('invalid_client', 'Claude published client metadata could not be verified.')
      end

      def fetch
        uri = URI(CLAUDE_CLIENT_ID)
        http = Net::HTTP.new(uri.host, uri.port, nil)
        http.use_ssl = true
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.verify_hostname = true
        http.open_timeout = 2
        http.read_timeout = 3
        http.write_timeout = 2
        http.max_retries = 0
        result = nil
        Timeout.timeout(5) do
          request = Net::HTTP::Get.new(uri.request_uri)
          request['Accept'] = 'application/json'
          request['Accept-Encoding'] = 'identity'
          http.start do |connection|
            connection.request(request) do |response|
              # Reject redirects and encoded bodies rather than following or
              # decompressing attacker-controlled data. This URL is fixed.
              invalid! unless response.code == '200' && [nil, 'identity'].include?(response['content-encoding'])
              length = response['content-length']
              invalid! if length && (!length.match?(/\A\d+\z/) || length.to_i > MAX_BYTES)
              body = +''
              response.read_body do |chunk|
                invalid! if body.bytesize + chunk.bytesize > MAX_BYTES
                body << chunk
              end
              result = { status: response.code.to_i, body: body, headers: {
                'content-type' => response['content-type'], 'cache-control' => response['cache-control'], 'age' => response['age']
              } }
            end
          end
        end
        result
      end
    end

    attr_reader :origin, :resource

    def initialize(store:, origin:, clock: -> { Time.now }, metadata_fetcher: nil)
      uri = URI.parse(origin)
      raise ArgumentError, 'HTTPS origin required' unless uri.is_a?(URI::HTTPS) && uri.host && uri.userinfo.nil? && uri.query.nil? && uri.fragment.nil? && uri.path.empty? && uri.port == 443
      @store, @origin, @clock = store, origin, clock
      @resource = "#{origin}/mcp"
      @claude_metadata = ClaudeMetadata.new(clock: clock, fetcher: metadata_fetcher)
      @store.with_db do |db|
        db.execute_batch(<<~SQL)
          CREATE TABLE IF NOT EXISTS oauth_clients (id TEXT PRIMARY KEY, scopes TEXT NOT NULL, created_at INTEGER NOT NULL);
          CREATE TABLE IF NOT EXISTS oauth_consents (id TEXT PRIMARY KEY, subject TEXT NOT NULL, client_id TEXT NOT NULL, state TEXT, scopes TEXT NOT NULL, challenge TEXT NOT NULL, expires_at INTEGER NOT NULL, consumed_at INTEGER);
          CREATE TABLE IF NOT EXISTS oauth_grants (id TEXT PRIMARY KEY, subject TEXT NOT NULL, client_id TEXT NOT NULL, scopes TEXT NOT NULL, resource TEXT NOT NULL, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, last_used_at INTEGER, revoked_at INTEGER);
          CREATE TABLE IF NOT EXISTS oauth_codes (token_hash TEXT PRIMARY KEY, grant_id TEXT NOT NULL, challenge TEXT NOT NULL, expires_at INTEGER NOT NULL, consumed_at INTEGER);
          CREATE TABLE IF NOT EXISTS oauth_access_tokens (token_hash TEXT PRIMARY KEY, grant_id TEXT NOT NULL, scopes TEXT NOT NULL, expires_at INTEGER NOT NULL);
          CREATE TABLE IF NOT EXISTS oauth_refresh_tokens (token_hash TEXT PRIMARY KEY, grant_id TEXT NOT NULL, scopes TEXT NOT NULL, expires_at INTEGER NOT NULL, consumed_at INTEGER);
          CREATE INDEX IF NOT EXISTS oauth_access_grant ON oauth_access_tokens(grant_id);
          CREATE INDEX IF NOT EXISTS oauth_refresh_grant ON oauth_refresh_tokens(grant_id);
        SQL
      end
    end

    def authorization_metadata
      { issuer: origin, authorization_endpoint: "#{origin}/oauth/authorize", token_endpoint: "#{origin}/oauth/token",
        registration_endpoint: "#{origin}/oauth/register", revocation_endpoint: "#{origin}/oauth/revoke",
        response_types_supported: ['code'], grant_types_supported: %w[authorization_code refresh_token],
        token_endpoint_auth_methods_supported: ['none'], revocation_endpoint_auth_methods_supported: ['none'],
        code_challenge_methods_supported: ['S256'], scopes_supported: SCOPES,
        authorization_response_iss_parameter_supported: true, client_id_metadata_document_supported: true }
    end

    def resource_metadata
      { resource: resource, authorization_servers: [origin], scopes_supported: SCOPES,
        bearer_methods_supported: ['header'], resource_name: 'Toolbox' }
    end

    def register_client(params)
      object!(params)
      unless params['redirect_uris'].is_a?(Array) && params['redirect_uris'] == [REDIRECT_URI]
        fail_with('invalid_redirect_uri', 'Register the exact Claude callback URL.')
      end
      unless [nil, 'none'].include?(params['token_endpoint_auth_method'])
        fail_with('invalid_client_metadata', 'Use a public client with PKCE.')
      end
      { 'grant_types' => %w[authorization_code refresh_token], 'response_types' => ['code'] }.each do |key, allowed|
        next unless params.key?(key)
        values = params[key]
        fail_with('invalid_client_metadata', 'Unsupported grant or response type.') unless values.is_a?(Array) && !values.empty? && (values - allowed).empty?
      end
      scopes = parse_scopes(params['scope'])
      client = transaction do |db|
        prune(db)
        # A public client identifies the Claude application, not its end user.
        # With one fixed callback and two possible scope sets, equivalent DCR
        # requests can reuse an ID instead of allowing anonymous database growth.
        existing = db.get_first_row('SELECT * FROM oauth_clients WHERE scopes = ? ORDER BY created_at LIMIT 1', [scopes.join(' ')])
        next existing if existing
        fail_with('temporarily_unavailable', 'Client registration is temporarily unavailable.', 503) if db.get_first_value('SELECT COUNT(*) FROM oauth_clients').to_i >= 1000
        id = random_token
        db.execute('INSERT INTO oauth_clients VALUES (?, ?, ?)', [id, scopes.join(' '), now])
        { 'id' => id, 'created_at' => now }
      end
      # Names in public DCR metadata are untrusted. The validated callback determines the name.
      { client_id: client['id'], client_id_issued_at: client['created_at'], client_name: 'Claude', redirect_uris: [REDIRECT_URI],
        token_endpoint_auth_method: 'none', grant_types: %w[authorization_code refresh_token],
        response_types: ['code'], scope: scopes.join(' ') }
    end

    def begin_authorization(params, subject:)
      owner!(subject)
      object!(params)
      fail_with('invalid_request', 'Use the authorization code flow.') unless params['response_type'] == 'code'
      fail_with('invalid_target', 'This authorization is only for Toolbox.') unless params['resource'] == resource
      fail_with('invalid_request', 'A PKCE S256 challenge is required.') unless params['code_challenge_method'] == 'S256' && valid_token?(params['code_challenge'])
      state = params['state']
      fail_with('invalid_request', 'Invalid OAuth state.') unless state.nil? || (state.is_a?(String) && state.bytesize <= 2048 && !state.match?(/[\x00-\x1f\x7f]/))
      @claude_metadata.verify! if params['client_id'] == CLAUDE_CLIENT_ID
      transaction do |db|
        prune(db)
        client = client!(db, params['client_id'])
        fail_with('invalid_request', 'Unregistered callback URL.') unless params['redirect_uri'] == REDIRECT_URI
        scopes = parse_scopes(params['scope'], default: client['scopes'].split)
        fail_with('invalid_scope', 'The client is not registered for this permission.') unless (scopes - client['scopes'].split).empty?
        fail_with('temporarily_unavailable', 'Too many pending connection requests.', 429) if db.get_first_value('SELECT COUNT(*) FROM oauth_consents WHERE consumed_at IS NULL').to_i >= 32
        id = random_token
        db.execute('INSERT INTO oauth_consents VALUES (?, ?, ?, ?, ?, ?, ?, NULL)', [id, subject, params['client_id'], state, scopes.join(' '), params['code_challenge'], now + 600])
        consent_value(db.get_first_row('SELECT * FROM oauth_consents WHERE id = ?', [id]))
      end
    end

    def consent(id, subject:)
      owner!(subject)
      @store.with_db { |db| consent_value(consent!(db, id, subject)) }
    end

    def complete_authorization(id, subject:, approve:)
      owner!(subject)
      pending = @store.with_db { |db| consent!(db, id, subject) }
      @claude_metadata.verify! if approve == true && pending['client_id'] == CLAUDE_CLIENT_ID
      transaction do |db|
        row = consent!(db, id, subject)
        db.execute('UPDATE oauth_consents SET consumed_at = ? WHERE id = ?', [now, id])
        if approve == true
          fail_with('temporarily_unavailable', 'Revoke an old connection before adding another.', 429) if db.get_first_value('SELECT COUNT(*) FROM oauth_grants WHERE revoked_at IS NULL AND expires_at > ?', [now]).to_i >= 64
          grant = random_token
          db.execute('INSERT INTO oauth_grants VALUES (?, ?, ?, ?, ?, ?, ?, NULL, NULL)', [grant, subject, row['client_id'], row['scopes'], resource, now, now + GRANT_SECONDS])
          code = random_token
          db.execute('INSERT INTO oauth_codes VALUES (?, ?, ?, ?, NULL)', [hash_token(code), grant, row['challenge'], now + 120])
          callback(row['state'], code: code)
        else
          callback(row['state'], error: 'access_denied')
        end
      end
    end

    def token(params, authorization: nil)
      object!(params)
      fail_with('invalid_client', 'Use the registered public client identifier.', 401) unless authorization.nil? || authorization.empty?
      result = transaction do |db|
        client!(db, params['client_id'])
        case params['grant_type']
        when 'authorization_code' then exchange_code(db, params)
        when 'refresh_token' then exchange_refresh(db, params)
        else fail_with('unsupported_grant_type', 'Unsupported grant type.')
        end
      end
      # Replay revocation must be committed before returning the error.
      raise result if result.is_a?(Error)
      result
    end

    def authenticate(authorization)
      fail_with('invalid_token', 'A bearer token is required.', 401) unless authorization.is_a?(String) && authorization.match?(/\ABearer [A-Za-z0-9_-]{43}\z/i)
      token = authorization.split(' ', 2).last
      transaction do |db|
        row = db.get_first_row('SELECT a.scopes AS token_scopes, g.* FROM oauth_access_tokens a JOIN oauth_grants g ON g.id = a.grant_id WHERE a.token_hash = ? AND a.expires_at > ?', [hash_token(token), now])
        fail_with('invalid_token', 'The access token is invalid or expired.', 401) unless active_grant?(row)
        db.execute('UPDATE oauth_grants SET last_used_at = ? WHERE id = ?', [now, row['id']])
        { subject: row['subject'], scopes: row['token_scopes'].split, grant_id: row['id'] }
      end
    end

    def grants(subject:)
      owner!(subject)
      @store.with_db do |db|
        db.execute('SELECT id, scopes, created_at, last_used_at, expires_at FROM oauth_grants WHERE subject = ? AND revoked_at IS NULL AND expires_at > ? ORDER BY created_at DESC', [subject, now]).map do |row|
          { id: row['id'], client_name: 'Claude', client_origin: 'https://claude.ai', scopes: row['scopes'].split,
            created_at: row['created_at'], last_used_at: row['last_used_at'], expires_at: row['expires_at'] }
        end
      end
    end

    def revoke_grant(id, subject:)
      owner!(subject)
      fail_with('invalid_request', 'Invalid connection.') unless valid_token?(id)
      transaction { |db| db.execute('UPDATE oauth_grants SET revoked_at = ? WHERE id = ? AND subject = ?', [now, id, subject]) }
      true
    end

    def revoke(params, authorization: nil)
      object!(params)
      fail_with('invalid_client', 'Use the registered public client identifier.', 401) unless authorization.nil? || authorization.empty?
      transaction do |db|
        client!(db, params['client_id'])
        next unless valid_token?(params['token'])
        token_hash = hash_token(params['token'])
        %w[oauth_access_tokens oauth_refresh_tokens].each do |table|
          db.execute("UPDATE oauth_grants SET revoked_at = ? WHERE client_id = ? AND id IN (SELECT grant_id FROM #{table} WHERE token_hash = ?)", [now, params['client_id'], token_hash])
        end
      end
      true
    end

    private

    def transaction
      result = nil
      @store.with_db { |db| db.transaction(:immediate) { result = yield db } }
      result
    end

    def now = @clock.call.to_i
    def random_token = SecureRandom.urlsafe_base64(32, false)
    def hash_token(value) = Digest::SHA256.hexdigest(value)
    def valid_token?(value) = value.is_a?(String) && value.match?(TOKEN)
    def fail_with(code, message, status = 400) = raise(Error.new(code, message, status))
    def owner!(subject)
      fail_with('access_denied', 'Owner authentication is required.', 403) unless subject == OWNER
    end

    def object!(value)
      fail_with('invalid_request', 'Expected an object.') unless value.is_a?(Hash) && value.keys.all? { |key| key.is_a?(String) }
    end

    def parse_scopes(value, default: SCOPES)
      return default if value.nil?
      fail_with('invalid_scope', 'Invalid permissions.') unless value.is_a?(String) && value.bytesize <= 256
      scopes = value.split(' ').uniq
      fail_with('invalid_scope', 'Choose Toolbox read access with optional log access.') unless scopes.include?('toolbox:read') && (scopes - SCOPES).empty?
      SCOPES.select { |scope| scopes.include?(scope) }
    end

    def client!(db, id)
      # Token exchanges only use a grant already approved after metadata
      # validation. Avoid network dependencies on the token/refresh/revoke path.
      return { 'id' => CLAUDE_CLIENT_ID, 'scopes' => SCOPES.join(' ') } if id == CLAUDE_CLIENT_ID
      fail_with('invalid_client', 'Unknown OAuth client.', 401) unless valid_token?(id)
      db.get_first_row('SELECT * FROM oauth_clients WHERE id = ?', [id]) || fail_with('invalid_client', 'Unknown OAuth client.', 401)
    end

    def consent!(db, id, subject)
      fail_with('invalid_request', 'This connection request is unavailable.') unless valid_token?(id)
      db.get_first_row('SELECT * FROM oauth_consents WHERE id = ? AND subject = ? AND consumed_at IS NULL AND expires_at > ?', [id, subject, now]) || fail_with('invalid_request', 'This connection request expired or was already used.')
    end

    def consent_value(row)
      { id: row['id'], client_name: 'Claude', client_origin: 'https://claude.ai', scopes: row['scopes'].split, expires_at: row['expires_at'] }
    end

    def callback(state, **params)
      values = params.merge(iss: origin)
      values[:state] = state unless state.nil?
      "#{REDIRECT_URI}?#{URI.encode_www_form(values)}"
    end

    def active_grant?(row)
      row && row['revoked_at'].nil? && row['expires_at'].to_i > now && row['subject'] == OWNER && row['resource'] == resource
    end

    def bound_grant(db, grant_id, client_id)
      row = db.get_first_row('SELECT * FROM oauth_grants WHERE id = ? AND client_id = ?', [grant_id, client_id])
      fail_with('invalid_grant', 'The authorization is invalid or expired.') unless active_grant?(row)
      row
    end

    def exchange_code(db, params)
      fail_with('invalid_target', 'This token is only for Toolbox.') unless params['resource'] == resource
      fail_with('invalid_grant', 'Invalid code exchange.') unless params['redirect_uri'] == REDIRECT_URI && valid_token?(params['code'])
      verifier = params['code_verifier']
      fail_with('invalid_grant', 'PKCE verification failed.') unless verifier.is_a?(String) && verifier.match?(/\A[A-Za-z0-9._~-]{43,128}\z/)
      row = db.get_first_row('SELECT * FROM oauth_codes WHERE token_hash = ?', [hash_token(params['code'])])
      fail_with('invalid_grant', 'The code is invalid or expired.') unless row && row['expires_at'].to_i > now
      challenge = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
      fail_with('invalid_grant', 'PKCE verification failed.') unless OpenSSL.fixed_length_secure_compare(challenge, row['challenge'])
      grant = bound_grant(db, row['grant_id'], params['client_id'])
      return revoke_replay(db, grant['id']) unless row['consumed_at'].nil?
      db.execute('UPDATE oauth_codes SET consumed_at = ? WHERE token_hash = ?', [now, hash_token(params['code'])])
      issue_tokens(db, grant, grant['scopes'])
    end

    def exchange_refresh(db, params)
      fail_with('invalid_target', 'This token is only for Toolbox.') unless params['resource'].nil? || params['resource'] == resource
      fail_with('invalid_grant', 'Invalid refresh token.') unless valid_token?(params['refresh_token'])
      row = db.get_first_row('SELECT * FROM oauth_refresh_tokens WHERE token_hash = ?', [hash_token(params['refresh_token'])])
      fail_with('invalid_grant', 'The refresh token is invalid or expired.') unless row && row['expires_at'].to_i > now
      grant = bound_grant(db, row['grant_id'], params['client_id'])
      return revoke_replay(db, grant['id']) unless row['consumed_at'].nil?
      scopes = parse_scopes(params['scope'], default: row['scopes'].split)
      fail_with('invalid_scope', 'Refreshing cannot add permissions.') unless (scopes - row['scopes'].split).empty?
      db.execute('UPDATE oauth_refresh_tokens SET consumed_at = ? WHERE token_hash = ?', [now, hash_token(params['refresh_token'])])
      issue_tokens(db, grant, scopes.join(' '))
    end

    def revoke_replay(db, grant_id)
      db.execute('UPDATE oauth_grants SET revoked_at = ? WHERE id = ?', [now, grant_id])
      Error.new('invalid_grant', 'This token was already used. Reconnect to Toolbox.')
    end

    def issue_tokens(db, grant, scopes)
      access, refresh = random_token, random_token
      access_expiry = [now + ACCESS_SECONDS, grant['expires_at']].min
      refresh_expiry = [now + REFRESH_SECONDS, grant['expires_at']].min
      db.execute('INSERT INTO oauth_access_tokens VALUES (?, ?, ?, ?)', [hash_token(access), grant['id'], scopes, access_expiry])
      db.execute('INSERT INTO oauth_refresh_tokens VALUES (?, ?, ?, ?, NULL)', [hash_token(refresh), grant['id'], scopes, refresh_expiry])
      { access_token: access, token_type: 'Bearer', expires_in: access_expiry - now, refresh_token: refresh, scope: scopes }
    end

    def prune(db)
      db.execute('DELETE FROM oauth_consents WHERE expires_at <= ?', [now])
      db.execute('DELETE FROM oauth_codes WHERE expires_at <= ?', [now])
      db.execute('DELETE FROM oauth_access_tokens WHERE expires_at <= ?', [now])
      db.execute('DELETE FROM oauth_refresh_tokens WHERE expires_at <= ?', [now])
      db.execute('DELETE FROM oauth_grants WHERE expires_at <= ?', [now])
      db.execute('DELETE FROM oauth_clients WHERE created_at < ? AND id NOT IN (SELECT client_id FROM oauth_grants) AND id NOT IN (SELECT client_id FROM oauth_consents)', [now - 86_400])
    end
  end
end

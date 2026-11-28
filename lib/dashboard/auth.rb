require 'json'
require 'openssl'
require 'securerandom'
require 'uri'
require 'time'
require 'webauthn'
require_relative 'auth_store'
require_relative 'mailer'

module Dashboard
  class Auth
    EMAIL = 'philip@ilic.nyc'.freeze
    SESSION_SECONDS = 30 * 24 * 60 * 60
    RECENT_SECONDS = 15 * 60
    MAX_RATE_ROWS = 4096
    MAX_PENDING_CODES = 20
    MAX_CHALLENGES = 2048
    TOKEN = /\A[a-f0-9]{64}\z/
    class Error < StandardError
      attr_reader :status
      def initialize(message, status = 400)
        super(message)
        @status = status
      end
    end
    attr_reader :store, :origin, :email_sign_in_enabled

    def initialize(store:, origin:, secret:, mailer:, email_sign_in_enabled: false, clock: -> { Time.now }, relying_party: nil)
      @store, @origin, @secret, @mailer, @clock = store, origin.to_s, secret.to_s, mailer, clock
      @email_sign_in_enabled = email_sign_in_enabled == true
      uri = URI(@origin)
      local = %w[localhost 127.0.0.1 [::1]].include?(uri.host)
      raise ArgumentError, 'Configure an exact HTTPS origin' unless uri.host && !uri.userinfo && ['', '/'].include?(uri.path) && !uri.query && !uri.fragment && (uri.scheme == 'https' || (local && uri.scheme == 'http'))
      @origin = @origin.delete_suffix('/')
      raise ArgumentError, 'Auth secret must be at least 32 bytes' if @secret.bytesize < 32
      @rp = relying_party || WebAuthn::RelyingParty.new(allowed_origins: [@origin], id: uri.host, name: 'Toolbox', verify_cross_origin: true)
      @store.with_db do |db|
        db.execute('INSERT OR IGNORE INTO auth_settings(key,value) VALUES(?,?)', ['user_handle', WebAuthn.generate_user_handle])
        @user_handle = db.get_first_value('SELECT value FROM auth_settings WHERE key=?', ['user_handle'])
      end
    end

    def now = @clock.call.to_i
    def secure? = @origin.start_with?('https:')
    def digest(value) = OpenSSL::Digest::SHA256.hexdigest(value.to_s)
    def csrf_token(token) = OpenSSL::HMAC.hexdigest('SHA256', @secret, "csrf:#{token}")
    def valid_token?(value) = value.is_a?(String) && TOKEN.match?(value)
    def equal?(left, right)
      left.is_a?(String) && right.is_a?(String) && left.bytesize == right.bytesize && OpenSSL.fixed_length_secure_compare(left, right)
    end

    def session(token)
      return nil unless valid_token?(token)
      row = @store.with_db { |db| db.get_first_row('SELECT * FROM auth_sessions WHERE token_hash=? AND expires_at>?', [digest(token), now]) }
      row && { email: EMAIL, session_id: row['token_hash'], csrf_token: csrf_token(token), authenticated_at: row['created_at'] }
    end

    def require_recent!(identity)
      raise Error.new('Sign in again to manage security settings.', 401) unless identity && identity[:authenticated_at] > now - RECENT_SECONDS
      active = @store.with_db { |db| active_session?(db, identity[:session_id]) }
      raise Error.new('Please sign in again.', 401) unless active
    end

    def revoke_session(token)
      @store.with_db { |db| db.execute('DELETE FROM auth_sessions WHERE token_hash=?', [digest(token)]) } if valid_token?(token)
    end

    def revoke_all_sessions(identity)
      require_recent!(identity)
      @store.with_db { |db| db.execute('DELETE FROM auth_sessions') }
    end

    def passkeys
      @store.with_db do |db|
        db.execute('SELECT id,name,created_at,last_used_at FROM auth_passkeys ORDER BY created_at').map do |row|
          { id: row['id'], name: row['name'], created_at: Time.at(row['created_at']).utc.iso8601,
            last_used_at: row['last_used_at'] && Time.at(row['last_used_at']).utc.iso8601 }
        end
      end
    end

    def rate_limit!(key, limit:, seconds:)
      rate_limits!([[key, limit]], seconds: seconds)
    end

    def request_email(email:, browser_token:, client_key: 'direct')
      require_email_sign_in!
      raise Error.new('Invalid request') unless valid_token?(browser_token) && email.is_a?(String) && email.bytesize <= 254
      public_limit!('email-request', client_key, browser_token, client_limit: 30, browser_limit: 30)
      email = email.strip.downcase
      return true unless email == EMAIL
      # Invalid addresses never consume the actual delivery quota. One client
      # cannot exhaust the installation's mail budget by rotating browser cookies.
      rate_limits!([["email-send-client:#{client_key}", 3], ["email-send-browser:#{browser_token}", 5], ['email-send-global', 10]])
      code = SecureRandom.random_number(1_000_000).to_s.rjust(6, '0')
      browser_hash = digest(browser_token)
      hash = code_hash(code, browser_token)
      @store.with_db do |db|
        db.transaction do
          db.execute('DELETE FROM auth_login WHERE expires_at<=?', [now])
          existing = db.get_first_value('SELECT 1 FROM auth_login WHERE browser_hash=?', [browser_hash])
          raise Error.new('Too many pending codes. Please try again later.', 429) if !existing && db.get_first_value('SELECT count(*) FROM auth_login') >= MAX_PENDING_CODES
          db.execute('INSERT OR REPLACE INTO auth_login(owner,code_hash,browser_hash,expires_at,attempts) VALUES(?,?,?,?,0)', [EMAIL, hash, browser_hash, now + 600])
        end
      end
      begin
        @mailer.send_code(email: EMAIL, code: code)
      rescue StandardError
        @store.with_db { |db| db.execute('DELETE FROM auth_login WHERE browser_hash=? AND code_hash=?', [browser_hash, hash]) }
        raise Error.new('Email delivery is temporarily unavailable. Please try again.', 503)
      end
      true
    end

    def verify_email(email:, code:, browser_token:, client_key: 'direct')
      require_email_sign_in!
      public_limit!('email-verify', client_key, browser_token, client_limit: 60, browser_limit: 20)
      raise Error, 'That code is invalid or expired. Request a new one.' unless email.is_a?(String) && email.strip.downcase == EMAIL && code.is_a?(String) && code.match?(/\A\d{6}\z/) && valid_token?(browser_token)
      token = @store.with_db do |db|
        db.transaction do
          browser_hash = digest(browser_token)
          row = db.get_first_row('SELECT * FROM auth_login WHERE owner=? AND browser_hash=? AND expires_at>? AND attempts<5', [EMAIL, browser_hash, now])
          if !row
            nil
          elsif !equal?(row['code_hash'], code_hash(code, browser_token))
            db.execute('UPDATE auth_login SET attempts=attempts+1 WHERE browser_hash=?', [browser_hash])
            nil
          else
            db.execute('DELETE FROM auth_login WHERE browser_hash=?', [browser_hash])
            issue_session(db)
          end
        end
      end
      raise Error, 'That code is invalid or expired. Request a new one.' unless token
      token
    end

    def registration_options(browser_token:, identity:)
      require_recent!(identity)
      rate_limit!('passkey-register', limit: 10, seconds: 600)
      options = @rp.options_for_registration(user: { id: @user_handle, name: EMAIL, display_name: 'Philip' },
        exclude: passkeys.map { |key| key[:id] }, attestation: 'none',
        authenticator_selection: { resident_key: 'required', user_verification: 'required' })
      store_challenge(browser_token, 'registration', options.challenge, identity[:session_id])
      options.as_json
    end

    def register_passkey(browser_token:, identity:, response:, name: 'My passkey')
      require_recent!(identity)
      validate_credential!(response)
      name = name.to_s.strip
      raise Error, 'Use a passkey name of 1 to 80 characters.' if name.empty? || name.length > 80 || name.match?(/[\x00-\x1f\x7f]/)
      challenge = consume_challenge(browser_token, 'registration', identity[:session_id])
      begin
        credential = @rp.verify_registration(response, challenge, user_verification: true, user_presence: true)
      rescue StandardError
        raise Error, 'Unable to verify this passkey. Please try again.'
      end
      raise Error, 'Unable to verify this passkey.' unless credential
      @store.with_db do |db|
        db.transaction do
          raise Error.new('Please sign in again.', 401) unless active_session?(db, identity[:session_id])
          raise Error, 'Remove an existing passkey before adding another.' if db.get_first_value('SELECT count(*) FROM auth_passkeys') >= 20
          transports = response.dig('response', 'transports')
          transports = [] unless transports.is_a?(Array) && transports.all? { |item| %w[usb nfc ble internal hybrid smart-card].include?(item) }
          db.execute('INSERT INTO auth_passkeys(id,public_key,sign_count,name,transports,created_at) VALUES(?,?,?,?,?,?)', [credential.id, credential.public_key, credential.sign_count.to_i, name, JSON.generate(transports), now])
        end
      end
      true
    rescue SQLite3::ConstraintException
      raise Error, 'That passkey is already registered.'
    end

    def authentication_options(browser_token:, client_key: 'direct')
      public_limit!('passkey-login', client_key, browser_token, client_limit: 60, browser_limit: 30)
      options = @rp.options_for_authentication(user_verification: 'required')
      store_challenge(browser_token, 'authentication', options.challenge, nil)
      options.as_json
    end

    def authenticate_passkey(browser_token:, response:, client_key: 'direct')
      public_limit!('passkey-verify', client_key, browser_token, client_limit: 60, browser_limit: 30)
      validate_credential!(response)
      challenge = consume_challenge(browser_token, 'authentication', nil)
      handle = response.dig('response', 'userHandle')
      raise Error, 'Unable to verify this passkey.' unless handle.is_a?(String) && equal?(handle, @user_handle)
      @store.with_db do |db|
        db.transaction do
          row = db.get_first_row('SELECT * FROM auth_passkeys WHERE id=?', [response['id']])
          raise Error, 'Unable to verify this passkey.' unless row
          begin
            credential = @rp.verify_authentication(response, challenge, public_key: row['public_key'], sign_count: row['sign_count'], user_verification: true, user_presence: true)
          rescue StandardError
            raise Error, 'Unable to verify this passkey. Please try again.'
          end
          raise Error, 'Unable to verify this passkey.' unless credential
          db.execute('UPDATE auth_passkeys SET sign_count=?,last_used_at=? WHERE id=?', [credential.sign_count.to_i, now, row['id']])
          issue_session(db)
        end
      end
    end

    def delete_passkey(identity:, id:)
      require_recent!(identity)
      raise Error, 'Invalid passkey' unless id.is_a?(String) && id.bytesize.between?(1, 2048)
      @store.with_db do |db|
        db.transaction do
          raise Error.new('Please sign in again.', 401) unless active_session?(db, identity[:session_id])
          db.execute('DELETE FROM auth_passkeys WHERE id=?', [id])
          raise Error.new('Passkey not found.', 404) if db.changes.zero?
          if !@email_sign_in_enabled && db.get_first_value('SELECT count(*) FROM auth_passkeys').zero?
            raise Error.new('Add another passkey before removing your last one while email sign-in is disabled.', 409)
          end
        end
      end
      true
    end

    private

    def require_email_sign_in!
      raise Error.new('Email sign-in is disabled. Use a saved passkey.', 403) unless @email_sign_in_enabled
    end

    # Admit all counters atomically. Rejected per-client/browser attempts do not
    # spend the global allowance or create more rows. Persisted limits survive
    # restarts; capacity never evicts an active limit and enables a bypass.
    def rate_limits!(limits, seconds: 600)
      @store.with_db do |db|
        db.transaction do
          db.execute('DELETE FROM auth_limits WHERE expires_at<=?', [now])
          keys = limits.map do |key, limit|
            hashed = digest(key)
            count = db.get_first_value('SELECT count FROM auth_limits WHERE key=?', [hashed])
            raise Error.new('Too many attempts. Please try again in a few minutes.', 429) if count && count >= limit
            [hashed, count]
          end
          fresh = keys.count { |_key, count| count.nil? }
          if fresh.positive? && db.get_first_value('SELECT count(*) FROM auth_limits') + fresh > MAX_RATE_ROWS
            raise Error.new('Sign-in is busy. Please try again in a few minutes.', 429)
          end
          keys.each do |key, _count|
            db.execute('INSERT INTO auth_limits(key,count,expires_at) VALUES(?,1,?) ON CONFLICT(key) DO UPDATE SET count=count+1', [key, now + seconds])
          end
        end
      end
    end

    def public_limit!(endpoint, client_key, browser_token, client_limit:, browser_limit:)
      raise Error, 'Please reload the sign-in page.' unless valid_token?(browser_token)
      raise Error, 'Invalid request client.' unless client_key.is_a?(String) && client_key.bytesize.between?(1, 100)
      rate_limits!([["#{endpoint}-client:#{client_key}", client_limit],
                    ["#{endpoint}-browser:#{browser_token}", browser_limit],
                    ["#{endpoint}-global", 600]])
    end

    def code_hash(code, browser_token) = OpenSSL::HMAC.hexdigest('SHA256', @secret, "otp:#{EMAIL}:#{browser_token}:#{code}")
    def active_session?(db, id) = !!db.get_first_value('SELECT 1 FROM auth_sessions WHERE token_hash=? AND expires_at>?', [id, now])
    def issue_session(db)
      db.execute('DELETE FROM auth_sessions WHERE expires_at<=?', [now])
      db.execute('DELETE FROM auth_sessions WHERE token_hash IN (SELECT token_hash FROM auth_sessions ORDER BY created_at DESC LIMIT -1 OFFSET 19)')
      token = SecureRandom.hex(32)
      db.execute('INSERT INTO auth_sessions(token_hash,created_at,expires_at) VALUES(?,?,?)', [digest(token), now, now + SESSION_SECONDS])
      token
    end

    def validate_credential!(response)
      raise Error, 'Invalid passkey response.' unless response.is_a?(Hash) && response['type'] == 'public-key' && response['id'].is_a?(String) && response['id'].bytesize.between?(1, 2048) && response['rawId'].is_a?(String) && response['response'].is_a?(Hash)
    end

    def store_challenge(browser_token, purpose, challenge, session_id)
      raise Error, 'Please reload the sign-in page.' unless valid_token?(browser_token)
      @store.with_db do |db|
        db.execute('DELETE FROM auth_challenges WHERE expires_at<=?', [now])
        existing = db.get_first_value('SELECT 1 FROM auth_challenges WHERE browser_hash=? AND purpose=?', [digest(browser_token), purpose])
        raise Error.new('Too many pending passkey requests. Please try again later.', 429) if !existing && db.get_first_value('SELECT count(*) FROM auth_challenges') >= MAX_CHALLENGES
        db.execute('INSERT OR REPLACE INTO auth_challenges(browser_hash,purpose,challenge,session_id,expires_at) VALUES(?,?,?,?,?)', [digest(browser_token), purpose, challenge, session_id, now + 300])
      end
    end

    def consume_challenge(browser_token, purpose, session_id)
      raise Error, 'This passkey request expired. Please try again.' unless valid_token?(browser_token)
      row = @store.with_db do |db|
        db.transaction do
          row = db.get_first_row('SELECT challenge FROM auth_challenges WHERE browser_hash=? AND purpose=? AND session_id IS ? AND expires_at>?', [digest(browser_token), purpose, session_id, now])
          db.execute('DELETE FROM auth_challenges WHERE browser_hash=? AND purpose=?', [digest(browser_token), purpose])
          row
        end
      end
      raise Error, 'This passkey request expired. Please try again.' unless row
      row['challenge']
    end
  end
end

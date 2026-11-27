require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/dashboard/auth_http'
require 'webauthn/fake_client'

class DashboardAuthTest < Minitest::Test
  class Mail
    attr_accessor :fail
    attr_reader :messages
    def initialize = @messages = []
    def send_code(**message)
      raise 'provider password should never escape' if fail
      @messages << message
    end
  end
  Request = Struct.new(:path, :request_method, :headers, :body, :peeraddr) do
    def [](name) = headers[name]
  end
  class Response
    attr_accessor :body, :status
    attr_reader :headers, :cookies
    def initialize
      @headers, @cookies = {}, []
    end
    def [](key) = @headers[key]
    def []=(key, value)
      @headers[key] = value
    end
  end

  def setup
    @directory = Dir.mktmpdir('toolbox-auth-test-')
    @path = File.join(@directory, 'auth', 'auth.sqlite3')
    @store = Dashboard::AuthStore.new(path: @path)
    @clock = Time.utc(2026, 11, 27)
    @mail = Mail.new
    @browser = 'a' * 64
    @auth = make_auth
    @http = Dashboard::AuthHTTP.new(auth: @auth)
  end

  def teardown
    @store.close
    FileUtils.remove_entry(@directory)
  end

  def make_auth
    Dashboard::Auth.new(store: @store, origin: 'https://toolbox.example', secret: 'fixture-secret-' * 4, mailer: @mail, clock: -> { @clock })
  end

  def login
    @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: @browser)
    @auth.verify_email(email: Dashboard::Auth::EMAIL, code: @mail.messages.last[:code], browser_token: @browser)
  end

  def enroll(client = WebAuthn::FakeClient.new('https://toolbox.example'))
    token = login
    identity = @auth.session(token)
    options = @auth.registration_options(browser_token: @browser, identity: identity)
    response = client.create(challenge: options[:challenge], user_verified: true)
    @auth.register_passkey(browser_token: @browser, identity: identity, response: response, name: 'Fixture key')
    [client, identity, options[:user][:id], response]
  end

  def assertion(client, handle, **options)
    request = @auth.authentication_options(browser_token: @browser)
    client.get(challenge: request[:challenge], user_handle: WebAuthn.standard_encoder.decode(handle), user_verified: true, **options)
  end

  def test_only_fixed_email_can_receive_or_verify_codes
    @auth.request_email(email: 'attacker@example.test', browser_token: @browser)
    assert_empty @mail.messages
    assert_raises(Dashboard::Auth::Error) { @auth.verify_email(email: 'attacker@example.test', code: '123456', browser_token: @browser) }
    @auth.request_email(email: ' PHILIP@ILIC.NYC ', browser_token: @browser)
    assert_equal Dashboard::Auth::EMAIL, @mail.messages.last[:email]
  end

  def test_code_is_hashed_single_use_and_browser_bound
    @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: @browser)
    code = @mail.messages.last[:code]
    @store.with_db { |db| refute_equal code, db.get_first_value('SELECT code_hash FROM auth_login') }
    assert_raises(Dashboard::Auth::Error) { @auth.verify_email(email: Dashboard::Auth::EMAIL, code: code, browser_token: 'b' * 64) }
    token = @auth.verify_email(email: Dashboard::Auth::EMAIL, code: code, browser_token: @browser)
    assert_equal Dashboard::Auth::EMAIL, @auth.session(token)[:email]
    @store.with_db { |db| refute_equal token, db.get_first_value('SELECT token_hash FROM auth_sessions') }
    assert_raises(Dashboard::Auth::Error) { @auth.verify_email(email: Dashboard::Auth::EMAIL, code: code, browser_token: @browser) }
  end

  def test_code_attempts_and_expiry_fail_closed
    @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: @browser)
    code = @mail.messages.last[:code]
    wrong = code == '000000' ? '111111' : '000000'
    5.times { assert_raises(Dashboard::Auth::Error) { @auth.verify_email(email: Dashboard::Auth::EMAIL, code: wrong, browser_token: @browser) } }
    assert_raises(Dashboard::Auth::Error) { @auth.verify_email(email: Dashboard::Auth::EMAIL, code: code, browser_token: @browser) }
    @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: @browser)
    @clock += 601
    assert_raises(Dashboard::Auth::Error) { @auth.verify_email(email: Dashboard::Auth::EMAIL, code: @mail.messages.last[:code], browser_token: @browser) }
  end

  def test_limits_and_sessions_survive_auth_restart
    token = login
    2.times { @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: @browser) }
    @auth = make_auth
    assert @auth.session(token)
    error = assert_raises(Dashboard::Auth::Error) { @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: @browser) }
    assert_equal 429, error.status
    @clock += 601
    assert @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: @browser)
  end

  def test_global_email_limit_cannot_be_bypassed_by_rotating_browser_cookies
    10.times { |index| @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: SecureRandom.hex(32), client_key: "fixture-client-#{index}") }
    error = assert_raises(Dashboard::Auth::Error) { @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: SecureRandom.hex(32)) }
    assert_equal 429, error.status
    assert_equal 10, @mail.messages.length
    assert_equal 10, rate_count('email-send-global')
    @store.with_db { |db| assert_operator db.get_first_value('SELECT count(*) FROM auth_limits'), :<=, 44 }
  end

  def test_sessions_and_limits_survive_database_close_and_reopen
    token = login
    2.times { @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: @browser) }
    @store.close
    @store = Dashboard::AuthStore.new(path: @path)
    @auth = make_auth
    assert @auth.session(token)
    error = assert_raises(Dashboard::Auth::Error) { @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: @browser) }
    assert_equal 429, error.status
  end

  def test_email_failure_removes_code_and_redacts_error
    @mail.fail = true
    error = assert_raises(Dashboard::Auth::Error) { @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: @browser) }
    assert_equal 503, error.status
    refute_includes error.message, 'provider'
    @store.with_db { |db| assert_equal 0, db.get_first_value('SELECT count(*) FROM auth_login') }
  end

  def test_sessions_expire_and_revoke_and_security_requires_recent_auth
    token = login
    identity = @auth.session(token)
    @clock += Dashboard::Auth::RECENT_SECONDS + 1
    assert_raises(Dashboard::Auth::Error) { @auth.registration_options(browser_token: @browser, identity: identity) }
    assert @auth.session(token)
    @auth.revoke_session(token)
    assert_nil @auth.session(token)
    @clock += 601
    token = login
    @clock += Dashboard::Auth::SESSION_SECONDS + 1
    assert_nil @auth.session(token)
  end

  def test_auth_storage_has_private_permissions
    assert_equal 0o600, File.stat(@path).mode & 0o777
    assert_equal 0o700, File.stat(File.dirname(@path)).mode & 0o777
  end

  def test_valid_passkey_round_trip_and_deletion
    client, identity, handle = enroll
    assert_equal 'Fixture key', @auth.passkeys.first[:name]
    response = assertion(client, handle)
    token = @auth.authenticate_passkey(browser_token: @browser, response: response)
    assert @auth.session(token)
    assert_raises(Dashboard::Auth::Error) { @auth.authenticate_passkey(browser_token: @browser, response: response) }
    @auth.delete_passkey(identity: identity, id: @auth.passkeys.first[:id])
    assert_empty @auth.passkeys
    assert @auth.session(login), 'Email recovery remains available after final passkey removal'
  end

  def test_passkey_origin_rp_user_verification_and_cross_origin_are_checked
    token = login
    identity = @auth.session(token)
    [{ origin: 'https://evil.example', rp_id: 'toolbox.example', user_verified: true },
     { origin: 'https://toolbox.example', rp_id: 'evil.example', user_verified: true },
     { origin: 'https://toolbox.example', rp_id: 'toolbox.example', user_verified: false },
     { origin: 'https://toolbox.example', rp_id: 'toolbox.example', user_verified: true, cross_origin: true }].each do |input|
      options = @auth.registration_options(browser_token: @browser, identity: identity)
      client = WebAuthn::FakeClient.new(input[:origin], cross_origin: input[:cross_origin])
      response = client.create(challenge: options[:challenge], rp_id: input[:rp_id], user_verified: input[:user_verified])
      assert_raises(Dashboard::Auth::Error) { @auth.register_passkey(browser_token: @browser, identity: identity, response: response) }
    end
    assert_empty @auth.passkeys
  end

  def test_passkey_user_handle_and_counter_are_checked
    client, _identity, handle = enroll
    response = assertion(client, handle)
    response['response']['userHandle'] = 'wrong-handle'
    assert_raises(Dashboard::Auth::Error) { @auth.authenticate_passkey(browser_token: @browser, response: response) }
    response = assertion(client, handle)
    @auth.authenticate_passkey(browser_token: @browser, response: response)
    response = assertion(client, handle, sign_count: 1)
    assert_raises(Dashboard::Auth::Error) { @auth.authenticate_passkey(browser_token: @browser, response: response) }
  end

  def test_bootstrap_csrf_cookie_and_origin_guard
    response = http('/auth/session', method: 'GET')
    assert_equal 200, response.status
    assert_equal false, JSON.parse(response.body)['authenticated']
    cookie = response.cookies.first.to_s
    assert_includes cookie, '__Host-toolbox_browser='
    assert_includes cookie, 'HttpOnly'
    assert_includes cookie, 'Secure'
    refute_includes cookie, 'Domain='
    browser = cookie.split(';').first
    csrf = JSON.parse(response.body)['csrf_token']
    response = http('/auth/email', data: {email: Dashboard::Auth::EMAIL}, headers: {'cookie' => browser, 'x-csrf-token' => csrf, 'origin' => 'https://evil.example'})
    assert_equal 403, response.status
    assert_empty @mail.messages
    response = http('/auth/email', data: {email: Dashboard::Auth::EMAIL}, headers: {'cookie' => browser, 'x-csrf-token' => 'bad'})
    assert_equal 403, response.status
  end

  def test_http_login_sets_secure_cookie_and_rotates_csrf
    bootstrap = http('/auth/session', method: 'GET')
    cookie = bootstrap.cookies.first.to_s.split(';').first
    headers = {'cookie' => cookie, 'x-csrf-token' => JSON.parse(bootstrap.body)['csrf_token']}
    assert_equal 200, http('/auth/email', data: {email: Dashboard::Auth::EMAIL}, headers: headers).status
    response = http('/auth/verify', data: {email: Dashboard::Auth::EMAIL, code: @mail.messages.last[:code]}, headers: headers)
    assert_equal 200, response.status
    session_cookie = response.cookies.first.to_s
    assert_includes session_cookie, '__Host-toolbox_session='
    assert_includes session_cookie, 'SameSite=Lax'
    token = session_cookie.split(';').first.split('=', 2).last
    refute_equal headers['x-csrf-token'], @auth.session(token)[:csrf_token]
  end

  def test_http_rejects_oversized_and_non_json_bodies
    headers = {'cookie' => "__Host-toolbox_browser=#{@browser}", 'x-csrf-token' => @auth.csrf_token(@browser)}
    assert_equal 413, http('/auth/email', data: {}, headers: headers.merge('content-length' => '65537')).status
    assert_equal 415, http('/auth/email', data: {}, headers: headers.merge('content-type' => 'text/plain')).status
    assert_equal 413, http('/auth/email', raw: ' ' * 65537, headers: headers).status
  end

  def test_concurrent_code_redemption_yields_one_session
    @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: @browser)
    code = @mail.messages.last[:code]
    results = 2.times.map do
      Thread.new do
        @auth.verify_email(email: Dashboard::Auth::EMAIL, code: code, browser_token: @browser)
      rescue Dashboard::Auth::Error
        nil
      end
    end.map(&:value).compact
    assert_equal 1, results.length
    @store.with_db { |db| assert_equal 1, db.get_first_value('SELECT count(*) FROM auth_sessions') }
  end

  def test_passkey_challenges_are_expiring_single_use_and_session_bound
    token = login
    identity = @auth.session(token)
    options = @auth.registration_options(browser_token: @browser, identity: identity)
    client = WebAuthn::FakeClient.new('https://toolbox.example')
    response = client.create(challenge: options[:challenge], user_verified: true)
    assert_raises(Dashboard::Auth::Error) { @auth.register_passkey(browser_token: 'b' * 64, identity: identity, response: response) }
    @clock += 301
    assert_raises(Dashboard::Auth::Error) { @auth.register_passkey(browser_token: @browser, identity: identity, response: response) }
    options = @auth.registration_options(browser_token: @browser, identity: identity)
    response = client.create(challenge: options[:challenge], user_verified: true)
    @auth.register_passkey(browser_token: @browser, identity: identity, response: response)
    assert_raises(Dashboard::Auth::Error) { @auth.register_passkey(browser_token: @browser, identity: identity, response: response) }
    @auth.revoke_session(token)
    assert_raises(Dashboard::Auth::Error) { @auth.delete_passkey(identity: identity, id: @auth.passkeys.first[:id]) }
  end

  def test_http_never_accepts_duplicate_cookie_or_csrf_in_body
    headers = {'cookie' => "__Host-toolbox_browser=#{@browser}; __Host-toolbox_browser=#{@browser}", 'x-csrf-token' => @auth.csrf_token(@browser)}
    assert_equal 403, http('/auth/email', data: {email: Dashboard::Auth::EMAIL}, headers: headers).status
    headers = {'cookie' => "__Host-toolbox_browser=#{@browser}"}
    assert_equal 403, http('/auth/email', data: {email: Dashboard::Auth::EMAIL, csrf_token: @auth.csrf_token(@browser)}, headers: headers).status
    assert_empty @mail.messages
  end

  def test_invalid_emails_do_not_spend_owner_delivery_quota
    30.times { @auth.request_email(email: 'other@example.test', browser_token: SecureRandom.hex(32), client_key: 'attacker') }
    error = assert_raises(Dashboard::Auth::Error) { @auth.request_email(email: 'other@example.test', browser_token: SecureRandom.hex(32), client_key: 'attacker') }
    assert_equal 429, error.status
    assert_nil rate_count('email-send-global')
    @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: @browser, client_key: 'owner')
    assert_equal 1, @mail.messages.length
    assert_equal 1, rate_count('email-send-global')
  end

  def test_owner_code_survives_another_browser_request_and_exhausted_mail_budget
    @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: @browser, client_key: 'owner')
    owner_code = @mail.messages.last[:code]
    other = 'b' * 64
    @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: other, client_key: 'other')
    other_code = @mail.messages.last[:code]
    8.times { |index| @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: SecureRandom.hex(32), client_key: "extra-#{index}") }
    assert_equal 429, assert_raises(Dashboard::Auth::Error) { @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: SecureRandom.hex(32), client_key: 'extra-blocked') }.status
    owner_token = @auth.verify_email(email: Dashboard::Auth::EMAIL, code: owner_code, browser_token: @browser, client_key: 'owner')
    other_token = @auth.verify_email(email: Dashboard::Auth::EMAIL, code: other_code, browser_token: other, client_key: 'other')
    assert @auth.session(owner_token)
    assert @auth.session(other_token)
  end

  def test_rotating_browser_cookies_cannot_spend_one_clients_entire_mail_budget
    3.times { @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: SecureRandom.hex(32), client_key: 'attacker') }
    10.times do
      error = assert_raises(Dashboard::Auth::Error) { @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: SecureRandom.hex(32), client_key: 'attacker') }
      assert_equal 429, error.status
    end
    assert_equal 3, rate_count('email-send-global')
    @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: @browser, client_key: 'owner')
    assert_equal 4, @mail.messages.length
  end

  def test_rejected_passkey_client_does_not_exhaust_global_quota
    60.times { @auth.authentication_options(browser_token: SecureRandom.hex(32), client_key: 'attacker') }
    650.times do
      assert_equal 429, assert_raises(Dashboard::Auth::Error) { @auth.authentication_options(browser_token: SecureRandom.hex(32), client_key: 'attacker') }.status
    end
    assert_equal 60, rate_count('passkey-login-global')
    assert @auth.authentication_options(browser_token: @browser, client_key: 'owner')[:challenge]
    assert_equal 61, rate_count('passkey-login-global')
    @store.with_db { |db| assert_equal 61, db.get_first_value('SELECT count(*) FROM auth_challenges') }
  end

  def test_passkey_browser_limit_is_independent_of_client_and_mail_limits
    30.times { |index| @auth.authentication_options(browser_token: @browser, client_key: "client-#{index}") }
    assert_equal 429, assert_raises(Dashboard::Auth::Error) { @auth.authentication_options(browser_token: @browser, client_key: 'another') }.status
    assert_equal 30, rate_count('passkey-login-global')
    assert @auth.authentication_options(browser_token: 'b' * 64, client_key: 'another')[:challenge]
  end

  def test_bad_passkey_and_otp_verifications_do_not_block_other_clients
    60.times do
      assert_raises(Dashboard::Auth::Error) { @auth.verify_email(email: Dashboard::Auth::EMAIL, code: '000000', browser_token: SecureRandom.hex(32), client_key: 'attacker') }
      assert_raises(Dashboard::Auth::Error) { @auth.authenticate_passkey(browser_token: SecureRandom.hex(32), response: {}, client_key: 'attacker') }
    end
    assert_equal 429, assert_raises(Dashboard::Auth::Error) { @auth.authenticate_passkey(browser_token: SecureRandom.hex(32), response: {}, client_key: 'attacker') }.status
    assert_equal 429, assert_raises(Dashboard::Auth::Error) { @auth.verify_email(email: Dashboard::Auth::EMAIL, code: '000000', browser_token: SecureRandom.hex(32), client_key: 'attacker') }.status
    assert_equal 60, rate_count('email-verify-global')
    assert_equal 60, rate_count('passkey-verify-global')
    client, _identity, handle = enroll
    assert @auth.session(@auth.authenticate_passkey(browser_token: @browser, response: assertion(client, handle), client_key: 'owner'))
  end

  def test_rate_state_capacity_preserves_existing_limits_and_expires
    @auth.rate_limit!('existing', limit: 5, seconds: 600)
    @store.with_db do |db|
      db.transaction do
        (Dashboard::Auth::MAX_RATE_ROWS - 1).times do |index|
          db.execute('INSERT INTO auth_limits(key,count,expires_at) VALUES(?,1,?)', [@auth.digest("seed-#{index}"), @clock.to_i + 600])
        end
      end
    end
    assert_equal 429, assert_raises(Dashboard::Auth::Error) { @auth.rate_limit!('new', limit: 5, seconds: 600) }.status
    @auth.rate_limit!('existing', limit: 5, seconds: 600)
    assert_equal 2, rate_count('existing')
    @store.with_db { |db| assert_equal Dashboard::Auth::MAX_RATE_ROWS, db.get_first_value('SELECT count(*) FROM auth_limits') }
    @clock += 601
    @auth.rate_limit!('new', limit: 5, seconds: 600)
    @store.with_db { |db| assert_equal 1, db.get_first_value('SELECT count(*) FROM auth_limits') }
  end

  def test_pending_codes_are_bounded_and_expired_rows_are_pruned
    @store.with_db do |db|
      Dashboard::Auth::MAX_PENDING_CODES.times do |index|
        db.execute('INSERT INTO auth_login(browser_hash,owner,code_hash,expires_at,attempts) VALUES(?,?,?,?,0)', [@auth.digest("seed-#{index}"), Dashboard::Auth::EMAIL, 'fixture-hash', @clock.to_i + 600])
      end
    end
    assert_equal 429, assert_raises(Dashboard::Auth::Error) { @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: @browser) }.status
    assert_empty @mail.messages
    @store.with_db { |db| assert_equal Dashboard::Auth::MAX_PENDING_CODES, db.get_first_value('SELECT count(*) FROM auth_login') }
    @clock += 601
    @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: @browser)
    @store.with_db { |db| assert_equal 1, db.get_first_value('SELECT count(*) FROM auth_login') }
  end

  def test_passkey_challenge_capacity_allows_replacing_existing_browser_and_expires
    @store.with_db do |db|
      db.transaction do
        Dashboard::Auth::MAX_CHALLENGES.times do |index|
          browser = index.zero? ? @browser : "seed-#{index}"
          db.execute('INSERT INTO auth_challenges(browser_hash,purpose,challenge,expires_at) VALUES(?,?,?,?)', [@auth.digest(browser), 'authentication', 'fixture-challenge', @clock.to_i + 300])
        end
      end
    end
    assert_equal 429, assert_raises(Dashboard::Auth::Error) { @auth.authentication_options(browser_token: 'b' * 64) }.status
    assert @auth.authentication_options(browser_token: @browser)[:challenge]
    @store.with_db { |db| assert_equal Dashboard::Auth::MAX_CHALLENGES, db.get_first_value('SELECT count(*) FROM auth_challenges') }
    @clock += 301
    assert @auth.authentication_options(browser_token: 'b' * 64)[:challenge]
    @store.with_db { |db| assert_equal 1, db.get_first_value('SELECT count(*) FROM auth_challenges') }
  end

  def test_legacy_pending_code_schema_migration_preserves_sessions_and_passkeys
    _client, identity, _handle, credential = enroll
    @store.with_db do |db|
      db.execute('DROP TABLE auth_login')
      db.execute('CREATE TABLE auth_login (owner TEXT PRIMARY KEY, code_hash TEXT NOT NULL, browser_hash TEXT NOT NULL, expires_at INTEGER NOT NULL, attempts INTEGER NOT NULL DEFAULT 0)')
      db.execute('INSERT INTO auth_login VALUES(?,?,?,?,0)', [Dashboard::Auth::EMAIL, 'legacy-hash', @auth.digest(@browser), @clock.to_i + 600])
    end
    @store.close
    @store = Dashboard::AuthStore.new(path: @path)
    @auth = make_auth
    assert_equal credential['id'], @auth.passkeys.first[:id]
    @store.with_db do |db|
      assert_equal 1, db.get_first_value('SELECT count(*) FROM auth_sessions WHERE token_hash=?', [identity[:session_id]])
      assert_equal 0, db.get_first_value('SELECT count(*) FROM auth_login')
      assert_equal 'browser_hash', db.execute('PRAGMA table_info(auth_login)').find { |column| column['pk'] == 1 }['name']
    end
    assert @auth.session(login)
  end

  def test_cf_client_address_is_validated_and_only_trusted_from_loopback_in_production
    request = Request.new('/auth/email', 'POST', {'cf-connecting-ip' => '2001:0db8:0000:0000:0000:0000:0000:0001'}, '{}', ['AF_INET', 12345, nil, '127.0.0.1'])
    assert_equal '2001:db8::1', @http.send(:client_key, request)
    request.headers['cf-connecting-ip'] = '2001:DB8::1'
    assert_equal '2001:db8::1', @http.send(:client_key, request)
    ['192.0.2.1, 192.0.2.2', '192.0.2.1/24', 'not-an-address', ' 192.0.2.1', ''].each do |invalid|
      request.headers['cf-connecting-ip'] = invalid
      assert_equal '127.0.0.1', @http.send(:client_key, request)
    end
    request.headers['cf-connecting-ip'] = '192.0.2.1'
    request.peeraddr[3] = '198.51.100.20'
    assert_equal '198.51.100.20', @http.send(:client_key, request)
    demo = Dashboard::Auth.new(store: @store, origin: 'http://127.0.0.1:4179', secret: 'fixture-secret-' * 4, mailer: @mail)
    request.peeraddr[3] = '127.0.0.1'
    assert_equal '127.0.0.1', Dashboard::AuthHTTP.new(auth: demo).send(:client_key, request)
  end

  def test_http_client_limit_cannot_be_bypassed_with_new_browser_cookies
    3.times do
      browser = SecureRandom.hex(32)
      headers = {'cookie' => "__Host-toolbox_browser=#{browser}", 'x-csrf-token' => @auth.csrf_token(browser), 'cf-connecting-ip' => '198.51.100.10'}
      assert_equal 200, http('/auth/email', data: {email: Dashboard::Auth::EMAIL}, headers: headers).status
    end
    browser = SecureRandom.hex(32)
    headers = {'cookie' => "__Host-toolbox_browser=#{browser}", 'x-csrf-token' => @auth.csrf_token(browser), 'cf-connecting-ip' => '198.51.100.10'}
    assert_equal 429, http('/auth/email', data: {email: Dashboard::Auth::EMAIL}, headers: headers).status
    headers['cf-connecting-ip'] = '198.51.100.11'
    assert_equal 200, http('/auth/email', data: {email: Dashboard::Auth::EMAIL}, headers: headers).status
  end

  def rate_count(key)
    @store.with_db { |db| db.get_first_value('SELECT count FROM auth_limits WHERE key=?', [@auth.digest(key)]) }
  end

  def test_mailer_requires_tls_and_renders_multipart_without_header_injection
    assert_raises(ArgumentError) { Dashboard::Mailer.new(host: 'smtp.example', user: 'u', password: 'p', origin: 'https://toolbox.example', require_tls: false) }
    assert_raises(ArgumentError) { Dashboard::Mailer.new(host: 'smtp.example', user: 'u', password: 'p', origin: 'https://toolbox.example', from: "evil\r\nBcc: thief@example.test") }
    mail = Dashboard::Mailer.new(host: 'smtp.example', user: 'u', password: 'p', origin: 'https://toolbox.example')
    message = mail.message(email: Dashboard::Auth::EMAIL, code: '123456')
    assert_includes message, 'multipart/alternative'
    assert_includes message, 'text/plain; charset=UTF-8'
    assert_includes message, 'text/html; charset=UTF-8'
    refute_includes message, 'password'
  end

  def http(path, method: 'POST', data: {}, raw: nil, headers: {}, peer: '127.0.0.1')
    request = Request.new(path, method, {'origin' => 'https://toolbox.example', 'content-type' => 'application/json'}.merge(headers), raw || JSON.generate(data), ['AF_INET', 12345, nil, peer])
    response = Response.new
    assert @http.call(request, response)
    assert_equal 'private, no-store', response['Cache-Control']
    response
  end
end

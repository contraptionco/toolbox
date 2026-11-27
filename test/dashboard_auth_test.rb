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
  Request = Struct.new(:path, :request_method, :headers, :body) do
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
    4.times { @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: @browser) }
    @auth = make_auth
    assert @auth.session(token)
    error = assert_raises(Dashboard::Auth::Error) { @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: @browser) }
    assert_equal 429, error.status
    @clock += 601
    assert @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: @browser)
  end

  def test_global_email_limit_cannot_be_bypassed_by_rotating_browser_cookies
    10.times { @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: SecureRandom.hex(32)) }
    error = assert_raises(Dashboard::Auth::Error) { @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: SecureRandom.hex(32)) }
    assert_equal 429, error.status
    assert_equal 10, @mail.messages.length
    @store.with_db { |db| assert_equal 11, db.get_first_value('SELECT count(*) FROM auth_limits') }
  end

  def test_sessions_and_limits_survive_database_close_and_reopen
    token = login
    4.times { @auth.request_email(email: Dashboard::Auth::EMAIL, browser_token: @browser) }
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

  def http(path, method: 'POST', data: {}, raw: nil, headers: {})
    request = Request.new(path, method, {'origin' => 'https://toolbox.example', 'content-type' => 'application/json'}.merge(headers), raw || JSON.generate(data))
    response = Response.new
    assert @http.call(request, response)
    assert_equal 'private, no-store', response['Cache-Control']
    response
  end
end

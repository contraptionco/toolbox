require 'json'
require 'securerandom'
require 'webrick/cookie'
require_relative 'auth'
require_relative 'http_body'

module Dashboard
  class AuthHTTP
    MAX_BODY_BYTES = 64 * 1024
    attr_reader :auth

    def initialize(auth:)
      @auth = auth
      prefix = @auth.secure? ? '__Host-' : ''
      @session_cookie = "#{prefix}toolbox_session"
      @browser_cookie = "#{prefix}toolbox_browser"
    end

    def session(request)
      @auth.session(cookie(request, @session_cookie))
    end

    # Shared with the browser OAuth consent handler; OAuth token endpoints use
    # their own bearer/PKCE validation and do not call this cookie guard.
    def verify_csrf!(request)
      raise Auth::Error.new('This request must come from Toolbox.', 403) unless request['origin'] == @auth.origin
      identity = session(request)
      browser = cookie(request, @browser_cookie)
      expected = identity ? identity[:csrf_token] : @auth.valid_token?(browser) && @auth.csrf_token(browser)
      raise Auth::Error.new('Please reload this page and try again.', 403) unless expected && @auth.equal?(expected, request['x-csrf-token'])
      true
    end

    def call(request, response)
      return false unless request.path.start_with?('/auth/')
      response['Cache-Control'] = 'private, no-store'
      response['Pragma'] = 'no-cache'
      response['Vary'] = 'Cookie'
      response['X-Content-Type-Options'] = 'nosniff'
      if request.path == '/auth/session' && %w[GET HEAD].include?(request.request_method)
        identity = session(request)
        browser = cookie(request, @browser_cookie)
        unless @auth.valid_token?(browser)
          browser = SecureRandom.hex(32)
          set_cookie(response, @browser_cookie, browser, 86400)
        end
        json(response, 200, authenticated: !!identity, csrf_token: identity ? identity[:csrf_token] : @auth.csrf_token(browser),
             email: identity && identity[:email], passkeys: identity ? @auth.passkeys : [])
        return true
      end
      unless request.request_method == 'POST'
        response['Allow'] = request.path == '/auth/session' ? 'GET, HEAD' : 'POST'
        json(response, 405, error: 'Method not allowed')
        return true
      end
      verify_csrf!(request)
      input = read_json(request)
      browser = cookie(request, @browser_cookie)
      identity = session(request)
      case request.path
      when '/auth/email'
        @auth.request_email(email: input['email'], browser_token: browser)
        json(response, 200, ok: true, message: 'If this email is allowed, a sign-in code is on its way.')
      when '/auth/verify'
        token = @auth.verify_email(email: input['email'], code: input['code'], browser_token: browser)
        @auth.revoke_session(cookie(request, @session_cookie))
        set_cookie(response, @session_cookie, token, Auth::SESSION_SECONDS)
        json(response, 200, ok: true)
      when '/auth/logout'
        @auth.revoke_session(cookie(request, @session_cookie))
        set_cookie(response, @session_cookie, '', 0)
        json(response, 200, ok: true)
      when '/auth/sessions/revoke'
        @auth.revoke_all_sessions(identity)
        set_cookie(response, @session_cookie, '', 0)
        json(response, 200, ok: true)
      when '/auth/passkey/register/options'
        json(response, 200, @auth.registration_options(browser_token: browser, identity: identity))
      when '/auth/passkey/register/verify'
        @auth.register_passkey(browser_token: browser, identity: identity, response: input['response'], name: input.fetch('name', 'My passkey'))
        json(response, 200, ok: true)
      when '/auth/passkey/login/options'
        json(response, 200, @auth.authentication_options(browser_token: browser))
      when '/auth/passkey/login/verify'
        token = @auth.authenticate_passkey(browser_token: browser, response: input['response'])
        @auth.revoke_session(cookie(request, @session_cookie))
        set_cookie(response, @session_cookie, token, Auth::SESSION_SECONDS)
        json(response, 200, ok: true)
      when '/auth/passkey/delete'
        @auth.delete_passkey(identity: identity, id: input['id'])
        json(response, 200, ok: true)
      else
        json(response, 404, error: 'Not found')
      end
      true
    rescue HTTPBody::TooLarge
      HTTPBody.reject(response)
      json(response, 413, error: 'Request is too large.')
      true
    rescue Auth::Error => error
      json(response, error.status, error: error.message)
      true
    rescue StandardError
      # Avoid provider exceptions or malformed credential bytes entering logs.
      json(response, 503, error: 'Authentication is temporarily unavailable. Please try again.')
      true
    end

    private

    def cookie(request, name)
      matches = request['cookie'].to_s.split(';').filter_map do |part|
        key, value = part.strip.split('=', 2)
        value if key == name
      end
      matches.length == 1 ? matches.first : nil
    end

    def read_json(request)
      type = request['content-type'].to_s.split(';').first.to_s.strip.downcase
      raise Auth::Error.new('Send application/json.', 415) unless type == 'application/json'
      body = HTTPBody.read(request, limit: MAX_BODY_BYTES)
      value = JSON.parse(body, max_nesting: 12)
      raise Auth::Error, 'Send a JSON object.' unless value.is_a?(Hash)
      value
    rescue JSON::ParserError
      raise Auth::Error, 'Send valid JSON.'
    end

    def set_cookie(response, name, value, max_age)
      # WEBrick::Cookie has no HttpOnly/SameSite setters, but preserves extensions
      # in the wire string. A tiny wrapper avoids writing joined Set-Cookie values.
      same_site = name == @session_cookie ? 'Lax' : 'Strict'
      cookie = "#{name}=#{value}; Path=/; Max-Age=#{max_age}; HttpOnly; SameSite=#{same_site}"
      cookie += '; Secure' if @auth.secure?
      if response.respond_to?(:cookies)
        response.cookies << CookieHeader.new(cookie)
      else
        existing = response['Set-Cookie']
        response['Set-Cookie'] = Array(existing) + [cookie]
      end
    end

    CookieHeader = Struct.new(:value) do
      def to_s = value
    end

    def json(response, status, value)
      response.status = status
      response['Content-Type'] = 'application/json; charset=utf-8'
      response.body = JSON.generate(value)
    end
  end
end

require_relative 'test_helper'
require_relative '../lib/dashboard/access'

class DashboardAccessTest < Minitest::Test
  ISSUER = 'https://example.cloudflareaccess.com'
  AUDIENCE = 'toolbox-application'
  SIGNING_KEY = OpenSSL::PKey::RSA.new(2048)
  ROTATED_KEY = OpenSSL::PKey::RSA.new(2048)

  def setup
    @now = Time.now.to_i
    @fetches = 0
    @keys = { 'keys' => [jwk(SIGNING_KEY, 'current')] }
    @fetch_error = nil
    @access = Dashboard::Access.new(issuer: ISSUER, audience: AUDIENCE,
      clock: -> { @now }, fetcher: lambda {
        @fetches += 1
        raise @fetch_error if @fetch_error
        @keys
      })
  end

  def test_valid_signed_application_token_is_verified_and_keys_are_cached
    2.times { assert_equal 'philip', @access.verify(token)['sub'] }
    assert_equal 1, @fetches
  end

  def test_missing_malformed_and_oversized_tokens_do_not_fetch_keys
    [nil, '', 'not.a.jwt', 'a' * (Dashboard::Access::MAX_TOKEN_BYTES + 1)].each do |value|
      assert_raises(Dashboard::Access::Unauthorized) { @access.verify(value) }
    end
    assert_equal 0, @fetches
  end

  def test_wrong_issuer_and_wrong_application_audience_are_rejected
    [{ 'iss' => 'https://other.cloudflareaccess.com' }, { 'aud' => ['another-app'] }].each do |claims|
      assert_raises(Dashboard::Access::Unauthorized) { @access.verify(token(claims)) }
    end
  end

  def test_expired_and_not_yet_valid_tokens_are_rejected
    [{ 'exp' => Time.now.to_i - 60 }, { 'nbf' => Time.now.to_i + 300 }].each do |claims|
      assert_raises(Dashboard::Access::Unauthorized) { @access.verify(token(claims)) }
    end
  end

  def test_required_claims_and_nonempty_subject_are_enforced
    %w[iss aud exp sub].each do |claim|
      assert_raises(Dashboard::Access::Unauthorized) { @access.verify(token({}, omit: claim)) }
    end
    ['', 123].each do |subject|
      assert_raises(Dashboard::Access::Unauthorized) { @access.verify(token({ 'sub' => subject })) }
    end
  end

  def test_wrong_signature_and_unapproved_algorithms_are_rejected
    assert_raises(Dashboard::Access::Unauthorized) { @access.verify(token({}, key: ROTATED_KEY)) }
    %w[none HS256].each do |algorithm|
      signed = JWT.encode(claims, algorithm == 'none' ? nil : 'forged-secret', algorithm, kid: 'current')
      assert_raises(Dashboard::Access::Unauthorized) { @access.verify(signed) }
    end
  end

  def test_header_cannot_override_the_trusted_key_source
    signed = JWT.encode(claims, SIGNING_KEY, 'RS256', kid: 'current',
                        jku: 'http://attacker.invalid/keys', x5u: 'file:///secret')
    assert_equal 'philip', @access.verify(signed)['sub']
    assert_equal 1, @fetches
  end

  def test_initial_jwks_outage_fails_closed_and_refresh_is_rate_limited
    @fetch_error = IOError.new('private upstream diagnostics')
    2.times { assert_raises(Dashboard::Access::Unavailable) { @access.verify(token) } }
    assert_equal 1, @fetches
    @now += Dashboard::Access::REFRESH_SECONDS
    @fetch_error = nil
    assert_equal 'philip', @access.verify(token)['sub']
    assert_equal 2, @fetches
  end

  def test_expired_cached_keys_are_not_used_during_an_outage
    @access.verify(token)
    @now += Dashboard::Access::CACHE_SECONDS
    @fetch_error = IOError.new('offline')
    2.times { assert_raises(Dashboard::Access::Unavailable) { @access.verify(token) } }
    assert_equal 2, @fetches
  end

  def test_unknown_key_refresh_is_limited_and_rotation_is_accepted
    @access.verify(token)
    rotated = token({}, key: ROTATED_KEY, kid: 'rotated')
    2.times { assert_raises(Dashboard::Access::Unauthorized) { @access.verify(rotated) } }
    assert_equal 1, @fetches
    @now += Dashboard::Access::REFRESH_SECONDS
    @keys = { 'keys' => [jwk(SIGNING_KEY, 'current'), jwk(ROTATED_KEY, 'rotated')] }
    assert_equal 'philip', @access.verify(rotated)['sub']
    assert_equal 2, @fetches
    assert_equal 'philip', @access.verify(token)['sub']
  end

  def test_unusable_jwks_fails_closed
    [{}, { 'keys' => [] }, { 'keys' => [{ 'kty' => 'oct', 'kid' => 'current', 'k' => 'secret' }] }].each do |keys|
      access = Dashboard::Access.new(issuer: ISSUER, audience: AUDIENCE, fetcher: -> { keys })
      assert_raises(Dashboard::Access::Unavailable) { access.verify(token) }
    end
  end

  def test_issuer_configuration_cannot_select_arbitrary_or_insecure_hosts
    ['http://example.cloudflareaccess.com', 'https://attacker.invalid',
     'https://example.cloudflareaccess.com.evil.test', 'https://example.cloudflareaccess.com/path'].each do |issuer|
      assert_raises(ArgumentError) { Dashboard::Access.new(issuer: issuer, audience: AUDIENCE) }
    end
    assert_raises(ArgumentError) { Dashboard::Access.new(issuer: ISSUER, audience: '') }
  end

  private

  def claims
    { 'iss' => ISSUER, 'aud' => [AUDIENCE], 'exp' => Time.now.to_i + 600, 'sub' => 'philip' }
  end

  def token(overrides = {}, key: SIGNING_KEY, kid: 'current', omit: nil)
    payload = claims.merge(overrides)
    payload.delete(omit) if omit
    JWT.encode(payload, key, 'RS256', kid: kid)
  end

  def jwk(key, kid)
    JWT::JWK.new(key, kid: kid).export.transform_keys(&:to_s)
  end
end

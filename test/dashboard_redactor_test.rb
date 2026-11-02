require_relative 'test_helper'
require_relative '../lib/dashboard/redactor'

class DashboardRedactorTest < Minitest::Test
  def test_sensitive_log_lines_are_removed_completely
    [
      'Authorization: Bearer short-secret', 'Cookie: session=private',
      'DATABASE_URL=postgres://user:pass@host/database', 'AWS_SECRET_ACCESS_KEY=small-secret',
      'OPENAI_API_KEY="shortsecret"', 'Parameters: {"body":"private customer content"}',
      '{"access_token":"private"}', 'environment = { PRIVATE_VALUE: abc }',
      '-----BEGIN RSA PRIVATE KEY-----', 'OP_SERVICE_ACCOUNT_TOKEN=opaque'
    ].each do |line|
      assert_equal '[sensitive log line omitted]', Dashboard::Redactor.line(line)
    end
  end

  def test_credentials_email_url_queries_and_long_opaque_tokens_are_redacted
    text = Dashboard::Redactor.line('Connected postgres://user:pass@host/db https://example.com/callback?code=short#fragment hello+test@example.com ' + 'a' * 48)
    refute_includes text, 'user:pass'
    refute_includes text, 'code=short'
    refute_includes text, 'fragment'
    refute_includes text, 'hello+test@example.com'
    refute_includes text, 'a' * 48
    assert_includes text, 'postgres://[redacted]@host/db'
    assert_includes text, 'https://example.com/callback?[redacted]'
  end

  def test_readable_operational_messages_remain_and_control_sequences_are_removed
    assert_equal 'Postcard is healthy. CPU 12.5%', Dashboard::Redactor.line("\e[32mPostcard is healthy.\e[0m CPU 12.5%\0")
    assert_equal 'Up-to-date: no deployment needed.', Dashboard::Redactor.line('Up-to-date: no deployment needed.')
    assert_operator Dashboard::Redactor.line('hello ' * 1000).length, :<=, 2070
    assert Dashboard::Redactor.line("bad\xFF".b).valid_encoding?
  end
end

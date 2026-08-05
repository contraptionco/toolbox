require_relative 'test_helper'
require_relative '../lib/one_password'

class OnePasswordTest < Minitest::Test
  FakeStatus = Struct.new(:success?)

  def test_docker_backend_checks_auth_with_token_in_environment_only
    secret = 'service-account-secret'
    calls, runner = recording_docker_runner(['', '', FakeStatus.new(true)])

    with_environment('TOOLBOX_OP_BACKEND' => 'docker', 'OP_SERVICE_ACCOUNT_TOKEN' => secret) do
      Core::CommandRunner.stub(:capture3, runner) do
        assert Core::OnePassword.logged_in?
      end
    end

    run_command, run_options = calls.fetch(0)
    container_name = run_command.fetch(4)
    assert_equal docker_command(container_name, 'whoami'), run_command
    assert_equal({ 'OP_SERVICE_ACCOUNT_TOKEN' => secret }, run_options[:env])
    assert_equal Core::OnePassword::DOCKER_COMMAND_TIMEOUT, run_options[:timeout]
    assert_equal '1Password authentication check', run_options[:label]
    refute_includes run_command.join(' '), secret
    assert_cleanup_call calls.fetch(1), container_name, secret
  end

  def test_docker_backend_gets_item_without_daemon_logs
    secret = 'service-account-secret'
    calls, runner = recording_docker_runner(["resolved-value\n", '', FakeStatus.new(true)])

    value = with_environment(
      'TOOLBOX_OP_BACKEND' => 'docker',
      'OP_SERVICE_ACCOUNT_TOKEN' => secret
    ) do
      Core::CommandRunner.stub(:capture3, runner) do
        Core::OnePassword.get_item('Fixture Item', 'password')
      end
    end

    run_command, run_options = calls.fetch(0)
    container_name = run_command.fetch(4)
    assert_equal docker_command(
      container_name,
      'item', 'get', 'Fixture Item',
      '--vault', Config::OP_VAULT,
      '--fields', 'password',
      '--reveal'
    ), run_command
    assert_includes run_command, '--log-driver=none'
    assert_equal({ 'OP_SERVICE_ACCOUNT_TOKEN' => secret }, run_options[:env])
    assert_equal 'resolved-value', value
    assert_cleanup_call calls.fetch(1), container_name, secret
  end

  def test_docker_timeout_still_force_removes_the_exact_container
    secret = 'service-account-secret'
    calls = []
    runner = lambda do |*arguments, **options|
      calls << [arguments, options]
      if arguments[1] == 'run'
        raise Core::CommandRunner::TimeoutError, 'lookup timed out'
      end

      ['', '', FakeStatus.new(true)]
    end

    error = with_environment(
      'TOOLBOX_OP_BACKEND' => 'docker',
      'OP_SERVICE_ACCOUNT_TOKEN' => secret
    ) do
      assert_raises(Core::CommandRunner::TimeoutError) do
        Core::CommandRunner.stub(:capture3, runner) do
          Core::OnePassword.logged_in?
        end
      end
    end

    assert_equal 'lookup timed out', error.message
    container_name = calls.fetch(0).fetch(0).fetch(4)
    assert_cleanup_call calls.fetch(1), container_name, secret
  end

  def test_cleanup_failure_does_not_replace_the_primary_timeout
    calls = []
    runner = lambda do |*arguments, **options|
      calls << [arguments, options]
      raise Core::CommandRunner::TimeoutError, 'lookup timed out' if arguments[1] == 'run'

      ['', 'Docker unavailable', FakeStatus.new(false)]
    end

    _stdout, stderr = capture_io do
      error = with_environment(
        'TOOLBOX_OP_BACKEND' => 'docker',
        'OP_SERVICE_ACCOUNT_TOKEN' => 'service-account-secret'
      ) do
        assert_raises(Core::CommandRunner::TimeoutError) do
          Core::CommandRunner.stub(:capture3, runner) do
            Core::OnePassword.logged_in?
          end
        end
      end
      assert_equal 'lookup timed out', error.message
    end

    assert_includes stderr, 'cleanup failed'
    assert_equal 2, calls.length
  end

  def test_host_backend_remains_the_default
    captured = nil
    runner = lambda do |*arguments, **options|
      captured = [arguments, options]
      ['', '', FakeStatus.new(true)]
    end

    with_environment('TOOLBOX_OP_BACKEND' => nil, 'OP_SERVICE_ACCOUNT_TOKEN' => 'unused-secret') do
      Core::CommandRunner.stub(:capture3, runner) do
        assert Core::OnePassword.logged_in?
      end
    end

    command, options = captured
    assert_equal ['op', 'whoami'], command
    assert_equal({ 'OP_SERVICE_ACCOUNT_TOKEN' => 'unused-secret' }, options[:env])
    assert_equal Core::OnePassword::HOST_COMMAND_TIMEOUT, options[:timeout]
    refute_includes command.join(' '), 'unused-secret'
  end

  def test_docker_backend_requires_a_service_account_token_before_running
    called = false
    runner = lambda do |*_arguments, **_options|
      called = true
      ['', '', FakeStatus.new(true)]
    end

    error = with_environment(
      'TOOLBOX_OP_BACKEND' => 'docker',
      'OP_SERVICE_ACCOUNT_TOKEN' => nil
    ) do
      assert_raises(RuntimeError) do
        Core::CommandRunner.stub(:capture3, runner) do
          Core::OnePassword.logged_in?
        end
      end
    end

    refute called
    assert_includes error.message, 'OP_SERVICE_ACCOUNT_TOKEN is required'
  end

  def test_failed_lookup_redacts_token_from_error
    secret = 'service-account-secret'
    calls, runner = recording_docker_runner(['', "authentication failed for #{secret}", FakeStatus.new(false)])

    error = with_environment(
      'TOOLBOX_OP_BACKEND' => 'docker',
      'OP_SERVICE_ACCOUNT_TOKEN' => secret
    ) do
      assert_raises(RuntimeError) do
        Core::CommandRunner.stub(:capture3, runner) do
          Core::OnePassword.get_item('Fixture Item', 'password')
        end
      end
    end

    assert_includes error.message, '[REDACTED]'
    refute_includes error.message, secret
    assert_equal 2, calls.length
  end

  private

  def recording_docker_runner(run_result)
    calls = []
    runner = lambda do |*arguments, **options|
      calls << [arguments, options]
      arguments[1] == 'rm' ? ['', 'No such container', FakeStatus.new(false)] : run_result
    end
    [calls, runner]
  end

  def docker_command(container_name, *arguments)
    [
      'docker', 'run', '--rm',
      '--name', container_name,
      '--log-driver=none',
      '--env', 'OP_SERVICE_ACCOUNT_TOKEN',
      Core::OnePassword::DOCKER_IMAGE, 'op', '--cache=false', *arguments
    ]
  end

  def assert_cleanup_call(call, container_name, secret)
    command, options = call
    assert_equal ['docker', 'rm', '--force', container_name], command
    assert_equal({ 'OP_SERVICE_ACCOUNT_TOKEN' => nil }, options[:env])
    assert_equal Core::OnePassword::DOCKER_CLEANUP_TIMEOUT, options[:timeout]
    refute_includes command.join(' '), secret
  end

  def with_environment(changes)
    previous = changes.to_h { |key, _value| [key, ENV[key]] }
    changes.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
    yield
  ensure
    previous&.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end

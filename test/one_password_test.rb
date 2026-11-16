require_relative 'test_helper'
require_relative '../lib/one_password'
require 'tmpdir'

class OnePasswordTest < Minitest::Test
  FakeStatus = Struct.new(:success?)

  def setup
    @directory = Dir.mktmpdir('toolbox-op-test-')
    @cache_root = File.join(@directory, 'cache')
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

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

  def test_service_account_cache_survives_separate_calls_and_preserves_multiline_values
    value = "DATABASE_URL='postgres://fixture:literal$pass@postgres/manual'\nSMTP_FROM=\"Manual <manual@example.test>\""
    calls, runner = recording_docker_runner(["#{value}\n", '', FakeStatus.new(true)])

    with_service_account do
      Core::CommandRunner.stub(:capture3, runner) do
        assert_equal value, Core::OnePassword.get_item('manual', 'ENV')
      end
      Core::CommandRunner.stub(:capture3, ->(*) { flunk 'Fresh cache must not invoke an external command' }) do
        assert_equal value, Core::OnePassword.get_item('manual', 'ENV')
      end
    end

    assert_equal 2, calls.length
    assert_equal 0o700, File.stat(@cache_root).mode & 0o777
    entry = Dir[File.join(@cache_root, '*.json')].fetch(0)
    assert_equal 0o600, File.stat(entry).mode & 0o777
    refute_includes File.read(entry), 'service-account-secret'
    refute_includes File.basename(entry), 'manual'
  end

  def test_only_successful_authentication_is_cached_without_identity_output
    calls, runner = recording_docker_runner(['private account identity', '', FakeStatus.new(true)])
    with_service_account do
      Core::CommandRunner.stub(:capture3, runner) do
        assert Core::OnePassword.logged_in?
        assert Core::OnePassword.logged_in?
      end
    end
    assert_equal 2, calls.length
    entry = JSON.parse(File.read(Dir[File.join(@cache_root, '*.json')].fetch(0)))
    assert_equal true, entry['value']
    refute_includes entry.to_s, 'private account identity'
  end

  def test_failed_authentication_is_not_cached
    calls, runner = recording_docker_runner(['', 'unavailable', FakeStatus.new(false)])
    with_service_account do
      Core::CommandRunner.stub(:capture3, runner) do
        refute Core::OnePassword.logged_in?
        refute Core::OnePassword.logged_in?
      end
    end
    assert_equal 4, calls.length
    assert_empty Dir[File.join(@cache_root, '*.json')]
  end

  def test_interactive_host_authentication_remains_uncached
    calls = []
    runner = ->(*arguments, **options) { calls << [arguments, options]; ['', '', FakeStatus.new(true)] }
    with_environment('TOOLBOX_OP_BACKEND' => 'host', 'OP_SERVICE_ACCOUNT_TOKEN' => nil) do
      Core::CommandRunner.stub(:capture3, runner) do
        assert Core::OnePassword.logged_in?
        assert Core::OnePassword.logged_in?
      end
    end
    assert_equal 2, calls.length
    refute File.exist?(@cache_root)
  end

  def test_cache_keys_isolate_token_backend_vault_item_and_field
    calls, runner = recording_docker_runner(['fixture-value', '', FakeStatus.new(true)])
    with_service_account do
      Core::CommandRunner.stub(:capture3, runner) do
        Core::OnePassword.get_item('first-item', 'first-field')
        Core::OnePassword.get_item('first-item', 'second-field')
        Core::OnePassword.get_item('second-item', 'first-field')
        with_environment('OP_SERVICE_ACCOUNT_TOKEN' => 'another-service-account') do
          Core::OnePassword.get_item('first-item', 'first-field')
        end
        with_environment('TOOLBOX_OP_BACKEND' => 'host') do
          Core::OnePassword.get_item('first-item', 'first-field')
        end
        original_vault = Config::OP_VAULT
        Config.send(:remove_const, :OP_VAULT)
        Config.const_set(:OP_VAULT, 'another-vault')
        begin
          Core::OnePassword.get_item('first-item', 'first-field')
        ensure
          Config.send(:remove_const, :OP_VAULT)
          Config.const_set(:OP_VAULT, original_vault)
        end
      end
    end
    assert_equal 6, Dir[File.join(@cache_root, '*.json')].length
    assert_equal 11, calls.length # Five Docker calls/cleanups and one host call.
  end

  def test_expired_value_is_refreshed_and_failed_refresh_does_not_use_stale_data
    with_service_account do
      _calls, success = recording_docker_runner(['initial', '', FakeStatus.new(true)])
      Core::CommandRunner.stub(:capture3, success) { Core::OnePassword.get_item('manual', 'ENV') }
      entry_path = Dir[File.join(@cache_root, '*.json')].fetch(0)
      entry = JSON.parse(File.read(entry_path))
      entry['fetched_at'] = Time.now.to_f - Core::OnePassword::CACHE_TTL
      File.write(entry_path, JSON.generate(entry))
      calls, failure = recording_docker_runner(['', 'rate limited', FakeStatus.new(false)])
      Core::CommandRunner.stub(:capture3, failure) do
        error = assert_raises(RuntimeError) { Core::OnePassword.get_item('manual', 'ENV') }
        assert_includes error.message, 'rate limited'
      end
      assert_equal 2, calls.length
      refute File.exist?(entry_path)
      _new_calls, refreshed = recording_docker_runner(['rotated', '', FakeStatus.new(true)])
      Core::CommandRunner.stub(:capture3, refreshed) do
        assert_equal 'rotated', Core::OnePassword.get_item('manual', 'ENV')
      end
    end
  end

  def test_force_refresh_replaces_fresh_value_and_invalidates_it_on_failure
    with_service_account do
      _calls, initial = recording_docker_runner(['initial', '', FakeStatus.new(true)])
      Core::CommandRunner.stub(:capture3, initial) { Core::OnePassword.get_item('manual', 'ENV') }
      with_environment('TOOLBOX_OP_REFRESH' => '1') do
        _calls, fresh = recording_docker_runner(['rotated', '', FakeStatus.new(true)])
        Core::CommandRunner.stub(:capture3, fresh) do
          assert_equal 'rotated', Core::OnePassword.get_item('manual', 'ENV')
        end
        _calls, failure = recording_docker_runner(['', 'permission denied', FakeStatus.new(false)])
        Core::CommandRunner.stub(:capture3, failure) do
          assert_raises(RuntimeError) { Core::OnePassword.get_item('manual', 'ENV') }
        end
      end
      assert_empty Dir[File.join(@cache_root, '*.json')]
    end
  end

  def test_opt_out_bypasses_cache_reads_and_writes
    calls, runner = recording_docker_runner(['live-value', '', FakeStatus.new(true)])
    with_service_account do
      with_environment('TOOLBOX_OP_CACHE' => '0') do
        Core::CommandRunner.stub(:capture3, runner) do
          2.times { assert_equal 'live-value', Core::OnePassword.get_item('manual', 'ENV') }
        end
      end
    end
    assert_equal 4, calls.length
    refute File.exist?(@cache_root)
  end

  def test_malformed_or_future_dated_entries_are_refreshed
    with_service_account do
      _calls, initial = recording_docker_runner(['initial', '', FakeStatus.new(true)])
      Core::CommandRunner.stub(:capture3, initial) { Core::OnePassword.get_item('manual', 'ENV') }
      entry_path = Dir[File.join(@cache_root, '*.json')].fetch(0)
      ['invalid json', JSON.generate(key: File.basename(entry_path, '.json'), fetched_at: Time.now.to_f + 300, value: 'future')].each do |bad_entry|
        File.write(entry_path, bad_entry)
        calls, refreshed = recording_docker_runner(['fresh', '', FakeStatus.new(true)])
        Core::CommandRunner.stub(:capture3, refreshed) do
          assert_equal 'fresh', Core::OnePassword.get_item('manual', 'ENV')
        end
        assert_equal 2, calls.length
      end
    end
  end

  def test_unsafe_cache_directory_is_rejected_before_external_commands
    Dir.mkdir(@cache_root, 0o755)
    with_service_account do
      Core::CommandRunner.stub(:capture3, ->(*) { flunk 'Unsafe cache must fail before a lookup' }) do
        assert_raises(RuntimeError) { Core::OnePassword.logged_in? }
      end
    end
  end

  def test_symlinked_cache_directory_is_rejected
    File.symlink(@directory, @cache_root)
    with_service_account do
      Core::CommandRunner.stub(:capture3, ->(*) { flunk 'Unsafe cache must fail before a lookup' }) do
        assert_raises(RuntimeError) { Core::OnePassword.logged_in? }
      end
    end
  end

  def test_cache_directory_owned_by_another_user_is_rejected
    Dir.mkdir(@cache_root, 0o700)
    real_lstat = File.method(:lstat)
    stat = File.lstat(@cache_root)
    stat.define_singleton_method(:uid) { Process.euid + 1 }
    with_service_account do
      File.stub(:lstat, ->(path) { path == @cache_root ? stat : real_lstat.call(path) }) do
        Core::CommandRunner.stub(:capture3, ->(*) { flunk 'Unowned cache must fail before a lookup' }) do
          assert_raises(RuntimeError) { Core::OnePassword.logged_in? }
        end
      end
    end
  end

  def test_unsafe_entry_permissions_and_symlinks_are_rejected
    with_service_account do
      _calls, success = recording_docker_runner(['value', '', FakeStatus.new(true)])
      Core::CommandRunner.stub(:capture3, success) { Core::OnePassword.get_item('manual', 'ENV') }
      entry_path = Dir[File.join(@cache_root, '*.json')].fetch(0)
      File.chmod(0o644, entry_path)
      target = File.join(@directory, 'target')
      Core::CommandRunner.stub(:capture3, ->(*) { flunk 'Unsafe entry must fail before a lookup' }) do
        assert_raises(RuntimeError) { Core::OnePassword.get_item('manual', 'ENV') }
        File.delete(entry_path)
        File.write(target, 'not a credential')
        File.symlink(target, entry_path)
        assert_raises(RuntimeError) { Core::OnePassword.get_item('manual', 'ENV') }
      end
      assert_equal 'not a credential', File.read(target)
    end
  end

  def test_successful_lookup_with_failed_helper_cleanup_is_not_cached
    runner = lambda do |*arguments, **_options|
      arguments[1] == 'run' ? ['value', '', FakeStatus.new(true)] : ['', 'cleanup failed', FakeStatus.new(false)]
    end
    with_service_account do
      Core::CommandRunner.stub(:capture3, runner) do
        assert_raises(RuntimeError) { Core::OnePassword.get_item('manual', 'ENV') }
      end
      assert_empty Dir[File.join(@cache_root, '*.json')]
    end
  end

  private

  def with_service_account(&block)
    with_environment('TOOLBOX_OP_BACKEND' => 'docker', 'OP_SERVICE_ACCOUNT_TOKEN' => 'service-account-secret', &block)
  end

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
    @environment_depth = (@environment_depth || 0) + 1
    if @environment_depth == 1
      Core::OnePassword.stub(:cache_root, @cache_root) { yield }
    else
      yield
    end
  ensure
    @environment_depth -= 1 if @environment_depth
    previous&.each do |key, value|
      value.nil? ? ENV.delete(key) : ENV[key] = value
    end
  end
end

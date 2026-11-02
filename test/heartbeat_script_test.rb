require_relative 'test_helper'
require 'fileutils'
require 'open3'
require 'tmpdir'

class HeartbeatScriptTest < Minitest::Test
  SCRIPT = File.expand_path('../heartbeat.sh', __dir__)
  WRITER = File.expand_path('../lib/bounded_log_writer.rb', __dir__)

  def test_atomic_lock_allows_only_one_concurrent_run
    Dir.mktmpdir do |repo|
      prepare_fixture(repo)
      env = heartbeat_env(repo)
      hold = File.join(repo, 'hold')
      File.write(hold, '')

      first = Open3.popen3(env, 'zsh', File.join(repo, 'heartbeat.sh'))
      assert wait_until(5) { File.exist?(File.join(repo, 'invocations')) }, 'first heartbeat did not start'

      contenders = 3.times.map do
        stdin, stdout, stderr, wait_thread = Open3.popen3(env, 'zsh', File.join(repo, 'heartbeat.sh'))
        stdin.close
        [stdout, stderr, wait_thread]
      end
      contenders.each do |stdout, stderr, wait_thread|
        assert wait_thread.value.success?, stderr.read
        stdout.close
        stderr.close
      end
      File.delete(hold)

      first_stdin, first_stdout, first_stderr, first_wait = first
      first_stdin.close
      assert first_wait.value.success?, first_stderr.read
      first_stdout.close
      first_stderr.close

      invocations = File.readlines(File.join(repo, 'invocations'), chomp: true)
      assert_equal 1, invocations.length
      refute File.exist?(File.join(repo, '.heartbeat.lock'))
    ensure
      File.delete(hold) if hold && File.exist?(hold)
    end
  end

  def test_reclaims_a_stale_lock_when_pid_has_been_reused
    Dir.mktmpdir do |repo|
      prepare_fixture(repo)
      lock_path = File.join(repo, '.heartbeat.lock')
      FileUtils.mkdir_p(lock_path)
      File.write(File.join(lock_path, 'pid'), "#{Process.pid} old-token Mon Jan 1 00:00:00 2001\n")

      _stdout, stderr, status = Open3.capture3(heartbeat_env(repo), 'zsh', File.join(repo, 'heartbeat.sh'))

      assert status.success?, stderr
      assert_equal 1, File.readlines(File.join(repo, 'invocations')).length
      refute File.exist?(lock_path)
    end
  end

  def test_development_copy_cannot_redirect_to_production
    Dir.mktmpdir do |home|
      repo = File.join(home, 'code', 'toolbox')
      development = File.join(home, 'development')
      prepare_fixture(repo)
      prepare_fixture(development)
      env = heartbeat_env(repo).merge('HOME' => home, 'TOOLBOX_PRODUCTION_REPO_DIR' => nil)

      _stdout, stderr, status = Open3.capture3(env, 'zsh', File.join(development, 'heartbeat.sh'))

      refute status.success?
      assert_includes stderr, 'outside the intended production checkout'
      assert_no_heartbeat_effects(repo)
      assert_no_heartbeat_effects(development)
    end
  end

  def test_existing_default_production_location_needs_no_new_environment_variable
    Dir.mktmpdir do |home|
      repo = File.join(home, 'code', 'toolbox')
      prepare_fixture(repo)
      env = heartbeat_env(repo).merge('HOME' => home, 'TOOLBOX_PRODUCTION_REPO_DIR' => nil)

      _stdout, stderr, status = Open3.capture3(env, 'zsh', File.join(repo, 'heartbeat.sh'))

      assert status.success?, stderr
      assert_equal 1, File.readlines(File.join(repo, 'invocations')).length
    end
  end

  def test_repo_override_cannot_select_a_different_checkout
    Dir.mktmpdir do |repo|
      Dir.mktmpdir do |other|
        prepare_fixture(repo)
        env = heartbeat_env(repo).merge('TOOLBOX_REPO_DIR' => other)

        _stdout, stderr, status = Open3.capture3(env, 'zsh', File.join(repo, 'heartbeat.sh'))

        refute status.success?
        assert_includes stderr, 'differs from the production checkout'
        assert_no_heartbeat_effects(repo)
        assert_no_heartbeat_effects(other)
      end
    end
  end

  private

  def prepare_fixture(repo)
    lib = File.join(repo, 'lib')
    FileUtils.mkdir_p(lib)
    FileUtils.cp(SCRIPT, File.join(repo, 'heartbeat.sh'))
    FileUtils.ln_s(WRITER, File.join(lib, 'bounded_log_writer.rb'))
    File.write(
      File.join(lib, 'heartbeat_update.rb'),
      <<~RUBY
        File.open(File.join(ARGV.fetch(0), 'invocations'), 'a') { |file| file.puts(Process.pid) }
        hold = File.join(ARGV.fetch(0), 'hold')
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        while File.exist?(hold) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          sleep 0.01
        end
      RUBY
    )
  end

  def heartbeat_env(repo)
    # The fixture's temporary HOME intentionally selects macOS's system Ruby.
    # Do not inject the dashboard test bundle from another Ruby installation.
    clean_bundle = ENV.keys.grep(/\ABUNDLE_/).to_h { |key| [key, nil] }
    clean_bundle.merge(
      'RUBYOPT' => nil, 'RUBYLIB' => nil,
      'TOOLBOX_REPO_DIR' => repo,
      'TOOLBOX_PRODUCTION_REPO_DIR' => repo,
      'TOOLBOX_HEARTBEAT_LOG' => File.join(repo, 'heartbeat.log')
    )
  end

  def assert_no_heartbeat_effects(repo)
    %w[invocations heartbeat.log .heartbeat.lock .heartbeat.lock.reclaim].each do |name|
      refute File.exist?(File.join(repo, name)), "unexpected heartbeat effect: #{name}"
    end
  end

  def wait_until(timeout)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      return true if yield
      sleep 0.01
    end
    yield
  end
end

require_relative 'test_helper'
require_relative '../lib/heartbeat_status'
require 'tmpdir'

class HeartbeatStatusTest < Minitest::Test
  Result = Struct.new(:success?)
  class Runner
    def capture3(*args, **options)
      raise 'Unexpected command' unless args == %w[git rev-parse HEAD] && options[:timeout] == 5
      ['a' * 40, '', Result.new(true)]
    end
  end

  def test_atomic_status_preserves_last_success_on_later_failure
    Dir.mktmpdir do |repo|
      now = Time.utc(2026, 11, 2, 18)
      writer = Core::HeartbeatStatus.new(repo, clock: -> { now }, command_runner: Runner.new)
      path = File.join(repo, '.runtime', 'heartbeat-status.json')
      writer.start
      assert_equal 'running', JSON.parse(File.read(path))['status']
      writer.finish(success: true, exit_code: 0)
      success = JSON.parse(File.read(path))
      assert_equal now.iso8601, success['last_success_at']
      assert_equal 'a' * 40, success['commit']
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal 0o700, File.stat(File.dirname(path)).mode & 0o777
      now += 60
      writer.start
      writer.finish(success: false, exit_code: 1)
      failure = JSON.parse(File.read(path))
      assert_equal 'failed', failure['status']
      assert_equal success['last_success_at'], failure['last_success_at']
      assert_equal 1, failure['exit_code']
      assert_equal ['heartbeat-status.json'], Dir.children(File.dirname(path))
      refute_match(/token|password|environment/, File.read(path))
    end
  end

  def test_corrupt_previous_status_does_not_block_next_run
    Dir.mktmpdir do |repo|
      FileUtils.mkdir_p(File.join(repo, '.runtime'))
      path = File.join(repo, '.runtime', 'heartbeat-status.json')
      File.write(path, 'not-json')
      writer = Core::HeartbeatStatus.new(repo, command_runner: Runner.new)
      writer.start
      assert_equal 'running', JSON.parse(File.read(path))['status']
      writer.finish(success: true, exit_code: 0)
      assert_equal 'healthy', JSON.parse(File.read(path))['status']
    end
  end

  def test_disk_full_status_writes_do_not_raise_or_replace_previous_success
    Dir.mktmpdir do |repo|
      warnings = StringIO.new
      writer = Core::HeartbeatStatus.new(repo, command_runner: Runner.new, stderr: warnings)
      writer.start
      writer.finish(success: true, exit_code: 0)
      path = File.join(repo, '.runtime', 'heartbeat-status.json')
      previous = File.binread(path)
      File.stub(:rename, ->(*) { raise Errno::ENOSPC, 'private diagnostic' }) do
        assert_equal false, writer.start
        assert_equal false, writer.finish(success: true, exit_code: 0)
      end
      assert_equal previous, File.binread(path)
      assert_equal ['heartbeat-status.json'], Dir.children(File.dirname(path))
      assert_equal 2, warnings.string.lines.length
      refute_includes warnings.string, 'private diagnostic'
      assert writer.start
      assert writer.finish(success: true, exit_code: 0)
    end
  end

  def test_permission_failure_on_runtime_directory_does_not_block_services
    Dir.mktmpdir do |repo|
      warnings = StringIO.new
      writer = Core::HeartbeatStatus.new(repo, command_runner: Runner.new, stderr: warnings)
      FileUtils.stub(:mkdir_p, ->(*) { raise Errno::EACCES, 'private path' }) do
        assert_equal false, writer.start
        assert_equal false, writer.finish(success: false, exit_code: 1)
      end
      assert_equal 2, warnings.string.lines.length
      refute_includes warnings.string, 'private path'
    end
  end

  def test_unreadable_previous_record_does_not_prevent_new_status
    Dir.mktmpdir do |repo|
      FileUtils.mkdir_p(File.join(repo, '.runtime'))
      path = File.join(repo, '.runtime', 'heartbeat-status.json')
      File.write(path, '{}')
      writer = Core::HeartbeatStatus.new(repo, command_runner: Runner.new)
      File.stub(:read, ->(*) { raise Errno::EACCES }) do
        assert writer.start
      end
      assert_equal 'running', JSON.parse(File.read(path))['status']
    end
  end

  def test_valid_non_object_previous_json_is_treated_as_missing
    Dir.mktmpdir do |repo|
      FileUtils.mkdir_p(File.join(repo, '.runtime'))
      path = File.join(repo, '.runtime', 'heartbeat-status.json')
      File.write(path, '[]')
      writer = Core::HeartbeatStatus.new(repo, command_runner: Runner.new)
      assert writer.start
      assert_equal 'running', JSON.parse(File.read(path))['status']
    end
  end
end

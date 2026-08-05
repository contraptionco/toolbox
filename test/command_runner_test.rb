require_relative 'test_helper'
require_relative '../lib/command_runner'
require 'tmpdir'

class CommandRunnerTest < Minitest::Test
  def test_captures_output_and_status
    stdout, stderr, status = Core::CommandRunner.capture3(
      RbConfig.ruby, '-e', '$stdout.write("out"); $stderr.write("err")',
      timeout: 2,
      label: 'Ruby fixture'
    )

    assert_equal 'out', stdout
    assert_equal 'err', stderr
    assert status.success?
  end

  def test_timeout_error_does_not_include_command_arguments
    secret = 'do-not-leak-this-value'
    error = assert_raises(Core::CommandRunner::TimeoutError) do
      Core::CommandRunner.capture3(
        RbConfig.ruby, '-e', 'sleep 30', secret,
        timeout: 0.1,
        label: 'Slow fixture'
      )
    end

    assert_includes error.message, 'Slow fixture timed out'
    refute_includes error.message, secret
  end

  def test_capture_is_bounded_while_output_is_drained
    stdout, = Core::CommandRunner.capture3(
      RbConfig.ruby, '-e', '$stdout.write("x" * 10_000)',
      timeout: 2,
      capture_limit: 64,
      label: 'Noisy fixture'
    )

    assert_equal 64, stdout.bytesize
    assert_includes stdout, 'output truncated'
  end

  def test_service_account_token_is_scrubbed_unless_explicitly_passed
    key = 'OP_SERVICE_ACCOUNT_TOKEN'
    previous = ENV[key]
    ENV[key] = 'parent-secret'

    stdout, = Core::CommandRunner.capture3(
      RbConfig.ruby, '-e', 'print ENV.fetch("OP_SERVICE_ACCOUNT_TOKEN", "missing")',
      timeout: 2,
      label: 'Environment scrub fixture'
    )
    assert_equal 'missing', stdout

    stdout, = Core::CommandRunner.capture3(
      RbConfig.ruby, '-e', 'print ENV.fetch("OP_SERVICE_ACCOUNT_TOKEN", "missing")',
      env: { key => 'explicit-secret' },
      timeout: 2,
      label: 'Explicit environment fixture'
    )
    assert_equal 'explicit-secret', stdout
  ensure
    previous.nil? ? ENV.delete(key) : ENV[key] = previous
  end

  def test_timeout_kills_a_descendant_that_ignores_term
    Dir.mktmpdir do |directory|
      parent_info = File.join(directory, 'parent')
      child_info = File.join(directory, 'child')
      term_marker = File.join(directory, 'term')
      child_pid = nil
      parent_code = <<~'RUBY'
        require 'rbconfig'
        parent_info, child_info, term_marker = ARGV
        File.write(parent_info, "#{Process.pid} #{Process.getpgrp}")
        child_code = <<~'CHILD'
          child_info, term_marker = ARGV
          trap('TERM') { File.write(term_marker, 'term'); loop { sleep 1 } }
          File.write(child_info, "#{Process.pid} #{Process.getpgrp}")
          loop { sleep 1 }
        CHILD
        child = spawn(RbConfig.ruby, '-e', child_code, child_info, term_marker,
                      out: File::NULL, err: File::NULL)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 2
        sleep 0.01 until File.exist?(child_info) || Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        Process.wait(child)
      RUBY

      assert_raises(Core::CommandRunner::TimeoutError) do
        Core::CommandRunner.capture3(
          RbConfig.ruby, '-e', parent_code, parent_info, child_info, term_marker,
          timeout: 0.5,
          label: 'Process group fixture'
        )
      end

      parent_pid, parent_pgid = File.read(parent_info).split.map(&:to_i)
      child_pid, child_pgid = File.read(child_info).split.map(&:to_i)
      assert_equal parent_pid, parent_pgid
      assert_equal parent_pgid, child_pgid
      assert File.exist?(term_marker), 'descendant never received TERM'
      assert wait_until(3) { process_gone?(child_pid) }, 'descendant survived process-group timeout cleanup'
    ensure
      Process.kill('KILL', child_pid) if child_pid && !process_gone?(child_pid)
    end
  end

  private

  def process_gone?(pid)
    Process.kill(0, pid)
    false
  rescue Errno::ESRCH
    true
  end

  def wait_until(timeout)
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
    until Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
      return true if yield
      sleep 0.02
    end
    yield
  end
end

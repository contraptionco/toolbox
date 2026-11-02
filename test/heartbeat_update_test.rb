require 'stringio'
require_relative 'test_helper'
require_relative '../lib/heartbeat_update'

class HeartbeatUpdateTest < Minitest::Test
  FakeStatus = Struct.new(:success?, :exitstatus)
  DiskStatus = Struct.new(:percent_used, :critical?)

  class FakeDiskMonitor
    def check
      DiskStatus.new(50, false)
    end
  end

  class FakeRunner
    attr_reader :commands, :run_options

    def initialize(dirty: false, branch: 'main')
      @commands = []
      @branch = branch
      @head = 'old-head'
      @remote = 'new-head'
      @dirty = dirty
    end

    def capture3(*command, **options)
      @commands << [command, options]
      arguments = command.drop(1)
      output = case arguments.first
               when 'status'
                 @dirty ? " M changed.rb\n" : ''
               when 'symbolic-ref'
                 "#{@branch}\n"
               when 'switch'
                 @branch = arguments.last
                 ''
               when 'rev-parse'
                 arguments.last.include?('refs/remotes') ? "#{@remote}\n" : "#{@head}\n"
               when 'merge'
                 @head = @remote
                 ''
               else
                 ''
               end
      [output, '', FakeStatus.new(true, 0)]
    end

    def run(*command, **options)
      @run_options = [command, options]
      FakeStatus.new(true, 0)
    end
  end

  def test_updates_verified_main_and_bounds_explicit_production_run
    runner = FakeRunner.new
    updater = Core::HeartbeatUpdate.new(
      '/toolbox',
      command_runner: runner,
      disk_monitor: FakeDiskMonitor.new,
      stdout: StringIO.new,
      stderr: StringIO.new
    )

    previous_token = ENV['OP_SERVICE_ACCOUNT_TOKEN']
    ENV['OP_SERVICE_ACCOUNT_TOKEN'] = 'fixture-service-token'
    begin
      updater.stub(:find_executable, nil) do
        assert updater.update_and_run
      end
    ensure
      previous_token.nil? ? ENV.delete('OP_SERVICE_ACCOUNT_TOKEN') : ENV['OP_SERVICE_ACCOUNT_TOKEN'] = previous_token
    end

    commands = runner.commands.map(&:first)
    assert_includes commands, ['git', 'fetch', '--no-tags', 'origin',
                               'refs/heads/main:refs/remotes/origin/main']
    refute commands.any? { |command| command.first(2) == %w[git switch] }
    assert_includes commands, ['git', 'merge', '--ff-only', 'refs/remotes/origin/main']
    assert_equal Core::HeartbeatUpdate::TOOLBOX_TIMEOUT, runner.run_options.last[:timeout]
    assert_operator Core::HeartbeatUpdate::TOOLBOX_TIMEOUT, :>=, 24 * 60 * 60
    assert_equal ['--production', 'code_changed'], runner.run_options.first.last(2)
    assert_equal({ 'OP_SERVICE_ACCOUNT_TOKEN' => 'fixture-service-token' }, runner.run_options.last[:env])
  end

  def test_refuses_an_unexpected_branch_before_fetch_or_service_run
    runner = FakeRunner.new(branch: 'feature')
    updater = Core::HeartbeatUpdate.new(
      '/toolbox', command_runner: runner, disk_monitor: FakeDiskMonitor.new, stderr: StringIO.new
    )

    error = assert_raises(RuntimeError) { updater.update_and_run }

    assert_includes error.message, 'not main'
    assert_equal [['git', 'symbolic-ref', '--quiet', '--short', 'HEAD']], runner.commands.map(&:first)
    assert_nil runner.run_options
  end

  def test_refuses_dirty_checkout_before_switch_or_pull
    runner = FakeRunner.new(dirty: true)
    updater = Core::HeartbeatUpdate.new(
      '/toolbox',
      command_runner: runner,
      disk_monitor: FakeDiskMonitor.new,
      stderr: StringIO.new
    )

    error = assert_raises(RuntimeError) { updater.update }

    assert_includes error.message, 'dirty'
    refute runner.commands.any? { |command, _options| %w[switch fetch merge].include?(command[1]) }
    assert_nil runner.run_options
  end
end

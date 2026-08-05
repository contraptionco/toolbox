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

    def initialize(dirty: false)
      @commands = []
      @branch = 'feature'
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

  def test_switches_to_verified_main_and_bounds_toolbox_run
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
    switch_index = commands.index(['git', 'switch', 'main'])
    merge_index = commands.index(['git', 'merge', '--ff-only', 'refs/remotes/origin/main'])
    assert_operator switch_index, :<, merge_index
    assert_equal Core::HeartbeatUpdate::TOOLBOX_TIMEOUT, runner.run_options.last[:timeout]
    assert_operator Core::HeartbeatUpdate::TOOLBOX_TIMEOUT, :>=, 24 * 60 * 60
    assert_equal ['code_changed'], runner.run_options.first.last(1)
    assert_equal({ 'OP_SERVICE_ACCOUNT_TOKEN' => 'fixture-service-token' }, runner.run_options.last[:env])
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
    refute runner.commands.any? { |command, _options| command.first(2) == %w[git switch] }
    assert_nil runner.run_options
  end
end

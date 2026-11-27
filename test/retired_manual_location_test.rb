require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/retired_manual_location'

class RetiredManualLocationTest < Minitest::Test
  Status = Struct.new(:exitstatus) do
    def success? = exitstatus.zero?
  end

  class Runner
    attr_reader :calls
    attr_accessor :bootout_status, :dirty

    def initialize
      @calls = []
      @bootout_status = 0
      @dirty = false
    end

    def capture3(*arguments, **options)
      @calls << [arguments, options]
      output = case arguments
               when ['git', 'symbolic-ref', '--quiet', '--short', 'HEAD'] then "main\n"
               when ['git', 'status', '--porcelain', '--untracked-files=all', '--ignore-submodules=none'] then @dirty ? ' M config.rb' : ''
               when ['git', 'rev-parse', 'HEAD'], ['git', 'rev-parse', 'refs/remotes/origin/main'] then "#{'b' * 40}\n"
               else ''
               end
      [output, '', Status.new(arguments.first == 'launchctl' ? @bootout_status : 0)]
    end
  end

  def setup
    @directory = Dir.mktmpdir('toolbox-retired-location-')
    @repo = File.join(@directory, 'production')
    @home = File.join(@directory, 'home')
    @runtime_root = File.join(@repo, '.runtime')
    @runtime = File.join(@runtime_root, 'manual-location')
    @launch_root = File.join(@home, 'Library', 'LaunchAgents')
    @plist = File.join(@launch_root, "#{Core::RetiredManualLocation::LABEL}.plist")
    FileUtils.mkdir_p([@runtime, @launch_root])
    File.write(@plist, 'retired helper')
    File.write(File.join(@runtime, 'config.json'), 'private-key-fixture')
    File.write(File.join(@runtime, 'find-my-reader'), 'native reader fixture')
    File.write(File.join(@launch_root, 'co.contraption.toolbox.dashboard.plist'), 'keep')
    File.write(File.join(@runtime_root, 'heartbeat-status.json'), 'keep')
    @saved_env = %w[TOOLBOX_PRODUCTION_REPO_DIR TOOLBOX_REPO_DIR].to_h { |key| [key, ENV[key]] }
    ENV['TOOLBOX_PRODUCTION_REPO_DIR'] = @repo
    ENV.delete('TOOLBOX_REPO_DIR')
    @runner = Runner.new
  end

  def teardown
    @saved_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    FileUtils.remove_entry(@directory)
  end

  def retirement(**options)
    Core::RetiredManualLocation.new(repo_dir: @repo, home_dir: @home, runner: @runner, uid: 501, **options)
  end

  def test_unloads_only_the_retired_helper_then_removes_its_private_runtime
    assert retirement.remove
    refute File.exist?(@plist)
    refute File.exist?(@runtime)
    assert_equal 'keep', File.read(File.join(@launch_root, 'co.contraption.toolbox.dashboard.plist'))
    assert_equal 'keep', File.read(File.join(@runtime_root, 'heartbeat-status.json'))
    launch = @runner.calls.select { |arguments, _options| arguments.first == 'launchctl' }
    assert_equal 1, launch.length
    assert_equal ['launchctl', 'bootout', 'gui/501/co.contraption.toolbox.manual-location'], launch.first.first
    assert_equal 15, launch.first.last[:timeout]
    refute @runner.calls.any? { |arguments, _| %w[op docker tccutil kill pkill].include?(arguments.first) }
  end

  def test_missing_or_previously_unloaded_service_is_idempotent
    @runner.bootout_status = 3
    assert retirement.remove
    assert retirement.remove
    refute File.exist?(@runtime)
    refute File.exist?(@plist)
  end

  def test_a_running_service_is_unloaded_even_if_its_plist_and_runtime_are_already_missing
    File.unlink(@plist)
    FileUtils.remove_entry(@runtime)
    assert retirement.remove
    assert @runner.calls.any? { |arguments, _| arguments.first == 'launchctl' }
  end

  def test_unload_failure_preserves_configuration_and_executable_for_retry
    @runner.bootout_status = 1
    error = assert_raises(RuntimeError) { retirement.remove }
    assert_includes error.message, 'preserved'
    assert File.exist?(@plist)
    assert File.exist?(File.join(@runtime, 'config.json'))
    assert File.exist?(File.join(@runtime, 'find-my-reader'))
  end

  def test_an_unintended_or_dirty_checkout_refuses_before_any_host_change
    development = File.join(@directory, 'development')
    FileUtils.mkdir_p(development)
    assert_raises(Core::ProductionGuard::Error) { retirement(repo_dir: development).remove }
    assert_empty @runner.calls
    @runner.dirty = true
    assert_raises(Core::ProductionGuard::Error) { retirement.remove }
    refute @runner.calls.any? { |arguments, _| arguments.first == 'launchctl' }
    assert File.exist?(@plist)
    assert File.exist?(@runtime)
  end

  def test_symlinked_parents_refuse_without_touching_the_target
    real_runtime = File.join(@directory, 'outside-runtime')
    File.rename(@runtime_root, real_runtime)
    File.symlink(real_runtime, @runtime_root)
    assert_raises(RuntimeError) { retirement.remove }
    assert File.exist?(File.join(real_runtime, 'manual-location', 'config.json'))
    refute @runner.calls.any? { |arguments, _| arguments.first == 'launchctl' }
  end

  def test_a_symlinked_runtime_is_unlinked_without_removing_its_target
    FileUtils.remove_entry(@runtime)
    outside = File.join(@directory, 'other-service')
    FileUtils.mkdir_p(outside)
    File.write(File.join(outside, 'keep'), 'private unrelated data')
    File.symlink(outside, @runtime)
    assert retirement.remove
    refute File.symlink?(@runtime)
    assert_equal 'private unrelated data', File.read(File.join(outside, 'keep'))
  end

  def test_a_symlinked_plist_is_unlinked_without_removing_its_target
    File.unlink(@plist)
    outside = File.join(@directory, 'other.plist')
    File.write(outside, 'keep')
    File.symlink(outside, @plist)
    assert retirement.remove
    refute File.symlink?(@plist)
    assert_equal 'keep', File.read(outside)
  end
end

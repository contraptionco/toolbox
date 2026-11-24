require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/manual_location_service'

class ManualLocationServiceTest < Minitest::Test
  REVISION = 'b' * 40
  Status = Struct.new(:successful) do
    def success? = successful
  end
  class Runner
    attr_reader :calls
    attr_accessor :revision
    def initialize
      @calls = []
      @revision = REVISION
    end
    def capture3(*arguments, **options)
      @calls << [arguments, options]
      output = case arguments
               when ['git', 'symbolic-ref', '--quiet', '--short', 'HEAD'] then "main\n"
               when ['git', 'status', '--porcelain', '--untracked-files=all', '--ignore-submodules=none'] then ''
               when ['git', 'rev-parse', 'HEAD'], ['git', 'rev-parse', 'refs/remotes/origin/main'] then "#{@revision}\n"
               else ''
               end
      if arguments[0, 2] == ['/usr/bin/xcrun', 'swiftc']
        File.write(arguments.last, 'fixture executable', perm: 0o700)
      end
      [output, '', Status.new(true)]
    end
  end

  def setup
    @directory = Dir.mktmpdir('toolbox-location-service-')
    @repo = File.join(@directory, 'production')
    @home = File.join(@directory, 'home')
    @runtime = File.join(@repo, '.runtime', 'manual-location')
    @ruby = File.join(@directory, 'ruby', 'bin', 'ruby')
    FileUtils.mkdir_p(File.dirname(@ruby))
    File.write(@ruby, 'fixture interpreter', perm: 0o700)
    FileUtils.mkdir_p([@runtime, @home, File.join(@repo, 'native')])
    ManualLocation::Revision::FILES.each do |relative|
      path = File.join(@repo, relative)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, "fixture #{relative}")
    end
    @saved_env = %w[TOOLBOX_PRODUCTION_REPO_DIR TOOLBOX_REPO_DIR OP_SERVICE_ACCOUNT_TOKEN].to_h { |key| [key, ENV[key]] }
    ENV['TOOLBOX_PRODUCTION_REPO_DIR'] = @repo
    ENV.delete('TOOLBOX_REPO_DIR')
    ENV['OP_SERVICE_ACCOUNT_TOKEN'] = 'never-inherit-deployment-secret'
    File.write(File.join(@repo, 'native', 'find_my_reader.swift'), 'fixture source')
    @key = 'test-key-' + 'y' * 43
    @config = File.join(@runtime, 'config.json')
    File.write(@config, JSON.generate(key: @key), perm: 0o600)
    @expected = ManualLocation::Revision.current(repo: @repo, config_path: @config, ruby: @ruby, home: @home)
    @runner = Runner.new
    @health = [nil, @expected]
  end

  def teardown
    @saved_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    FileUtils.remove_entry(@directory)
  end

  def service(**options)
    Core::ManualLocationService.new(repo_dir: @repo, home_dir: @home, runner: @runner,
                                   health_reader: -> { @health.shift }, sleeper: ->(_) {}, uid: 501,
                                   ruby: @ruby, **options)
  end

  def plist_path
    File.join(@home, 'Library', 'LaunchAgents', "#{Core::ManualLocationService::LABEL}.plist")
  end

  def test_unconfigured_bridge_does_nothing_and_never_reads_secrets
    File.delete(@config)
    assert service.ensure_running
    assert_empty @runner.calls
    refute File.exist?(plist_path)
  end

  def test_install_compiles_reader_and_bootstraps_only_its_agent_with_private_environment
    assert service.ensure_running
    assert_equal 0o600, File.stat(plist_path).mode & 0o777
    assert_equal 0o700, File.stat(File.join(@runtime, 'find-my-reader')).mode & 0o777
    commands = @runner.calls.map(&:first)
    assert_includes commands, ['launchctl', 'bootout', 'gui/501/co.contraption.toolbox.manual-location']
    assert_includes commands, ['launchctl', 'bootstrap', 'gui/501', plist_path]
    refute commands.any? { |arguments| %w[op docker].include?(arguments.first) }
    plist = File.read(plist_path)
    refute_includes plist, 'OP_SERVICE_ACCOUNT_TOKEN'
    refute_includes plist, @key
    refute_includes plist, 'never-inherit-deployment-secret'
    assert_includes plist, 'manual_location_server.rb'
    assert_includes plist, '<string>--production</string>'
  end

  def test_healthy_revision_is_idempotent_and_unchanged_native_binary_is_not_rebuilt
    assert service.ensure_running
    @runner.calls.clear
    @health = [@expected]
    assert service.ensure_running
    assert @runner.calls.all? { |arguments, _| arguments.first == 'git' }
    @runner.calls.clear
    @health = [nil, @expected]
    assert service.ensure_running
    refute @runner.calls.any? { |arguments, _| arguments.first == '/usr/bin/xcrun' }
  end

  def test_unrelated_toolbox_commits_keep_the_healthy_helper_and_its_memory_cache
    assert service.ensure_running
    @runner.calls.clear
    @runner.revision = 'c' * 40
    File.write(File.join(@repo, 'config.rb'), 'unrelated application configuration')
    @health = [@expected]
    assert service.ensure_running
    assert @runner.calls.all? { |arguments, _| arguments.first == 'git' }
    assert_equal @expected, ManualLocation::Revision.current(repo: @repo, config_path: @config, ruby: @ruby, home: @home)
  end

  def test_helper_code_dependencies_and_private_key_changes_invalidate_the_revision
    original = @expected
    ManualLocation::Revision::FILES.each do |relative|
      path = File.join(@repo, relative)
      previous = File.read(path)
      File.write(path, previous + '\nchange')
      refute_equal original, ManualLocation::Revision.current(repo: @repo, config_path: @config, ruby: @ruby, home: @home), relative
      File.write(path, previous)
    end
    alternative_ruby = @ruby + '-other'
    FileUtils.cp(@ruby, alternative_ruby)
    refute_equal original, ManualLocation::Revision.current(repo: @repo, config_path: @config, ruby: alternative_ruby, home: @home)
    refute_equal original, ManualLocation::Revision.current(repo: @repo, config_path: @config, ruby: @ruby, home: @home + '-other')
    File.write(@config, JSON.generate(key: 'replacement-' + 'z' * 43), perm: 0o600)
    refute_equal original, ManualLocation::Revision.current(repo: @repo, config_path: @config, ruby: @ruby, home: @home)
  end

  def test_changed_helper_restarts_but_does_not_recompile_unchanged_native_source
    assert service.ensure_running
    @runner.calls.clear
    File.write(File.join(@repo, 'lib/manual_location/app.rb'), 'changed helper implementation')
    expected = ManualLocation::Revision.current(repo: @repo, config_path: @config, ruby: @ruby, home: @home)
    @health = [@expected, expected]
    assert service.ensure_running
    assert_includes @runner.calls.map(&:first), ['launchctl', 'kickstart', '-k', 'gui/501/co.contraption.toolbox.manual-location']
    refute @runner.calls.any? { |arguments, _| arguments.first == '/usr/bin/xcrun' }
  end

  def test_replacing_the_interpreter_at_the_same_path_restarts_the_helper
    assert service.ensure_running
    @runner.calls.clear
    File.write(@ruby, 'replacement interpreter', perm: 0o700)
    expected = ManualLocation::Revision.current(repo: @repo, config_path: @config, ruby: @ruby, home: @home)
    refute_equal @expected, expected
    @health = [@expected, expected]
    assert service.ensure_running
    assert_includes @runner.calls.map(&:first), ['launchctl', 'kickstart', '-k', 'gui/501/co.contraption.toolbox.manual-location']
  end

  def test_removing_private_config_unloads_only_this_bridge
    assert service.ensure_running
    @runner.calls.clear
    File.delete(@config)
    assert service.ensure_running
    refute File.exist?(plist_path)
    launch = @runner.calls.map(&:first).select { |arguments| arguments.first == 'launchctl' }
    assert_equal [['launchctl', 'bootout', 'gui/501/co.contraption.toolbox.manual-location']], launch
  end

  def test_unintended_checkout_refuses_before_installing_or_compiling
    development = File.join(@directory, 'development')
    FileUtils.mkdir_p(File.join(development, '.runtime', 'manual-location'))
    FileUtils.cp(@config, File.join(development, '.runtime', 'manual-location', 'config.json'))
    assert_raises(Core::ProductionGuard::Error) { service(repo_dir: development).ensure_running }
    assert_empty @runner.calls
  end
end

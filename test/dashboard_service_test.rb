require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/dashboard_service'

class DashboardServiceTest < Minitest::Test
  REVISION = 'a' * 40
  Status = Struct.new(:successful) do
    def success? = successful
  end

  class Runner
    attr_reader :calls
    attr_accessor :bundle_installed, :kickstart_success, :bootstrap_success
    def initialize
      @calls = []
      @bundle_installed = true
      @kickstart_success = true
      @bootstrap_success = true
    end

    def capture3(*arguments, **options)
      @calls << [arguments, options]
      output = case arguments
               when ['git', 'symbolic-ref', '--quiet', '--short', 'HEAD'] then "main\n"
               when ['git', 'status', '--porcelain', '--untracked-files=all', '--ignore-submodules=none'] then ''
               when ['git', 'rev-parse', 'HEAD'], ['git', 'rev-parse', 'refs/remotes/origin/main'] then "#{REVISION}\n"
               else ''
               end
      success = if arguments.include?('check')
                  bundle_installed
                elsif arguments[0, 2] == ['launchctl', 'kickstart']
                  kickstart_success
                elsif arguments[0, 2] == ['launchctl', 'bootstrap']
                  bootstrap_success
                else
                  true
                end
      [output, '', Status.new(success)]
    end
  end

  def setup
    @directory = Dir.mktmpdir('toolbox-dashboard-service-')
    @repo = File.join(@directory, 'production')
    @home = File.join(@directory, 'home')
    FileUtils.mkdir_p([@repo, @home])
    @saved_env = %w[TOOLBOX_PRODUCTION_REPO_DIR TOOLBOX_REPO_DIR OP_SERVICE_ACCOUNT_TOKEN].to_h { |key| [key, ENV[key]] }
    ENV['TOOLBOX_PRODUCTION_REPO_DIR'] = @repo
    ENV.delete('TOOLBOX_REPO_DIR')
    ENV['OP_SERVICE_ACCOUNT_TOKEN'] = 'fixture-secret-that-must-not-enter-plist'
    @runner = Runner.new
    @health = [nil, REVISION]
    @sleeps = []
    @service = service
  end

  def teardown
    @saved_env.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    FileUtils.remove_entry(@directory)
  end

  def test_development_checkout_refuses_before_commands_or_installation
    development = File.join(@directory, 'development')
    FileUtils.mkdir_p(development)
    assert_raises(Core::ProductionGuard::Error) { service(repo_dir: development).ensure_running }
    assert_empty @runner.calls
    refute File.exist?(File.join(development, '.runtime'))
    refute File.exist?(plist_path)
  end

  def test_matching_revision_is_idempotent_without_process_or_dependency_changes
    @health = [REVISION]
    assert @service.ensure_running
    assert @runner.calls.all? { |arguments, _options| arguments.first == 'git' }
    refute File.exist?(plist_path)
    assert_empty @sleeps
  end

  def test_first_install_bootstraps_only_the_dashboard_with_private_files
    assert @service.ensure_running
    commands = launch_commands
    assert_equal [
      ['launchctl', 'bootout', "gui/501/#{Core::DashboardService::LABEL}"],
      ['launchctl', 'bootstrap', 'gui/501', plist_path]
    ], commands
    assert_equal 0o600, File.stat(plist_path).mode & 0o777
    assert_equal 0o700, File.stat(File.join(@repo, '.runtime', 'dashboard')).mode & 0o777
    refute @runner.calls.any? { |arguments, _options| arguments.first == 'docker' }
  end

  def test_plist_has_only_required_environment_and_no_orchestration_credentials
    plist = @service.plist
    environment = plist.match(%r{<key>EnvironmentVariables</key><dict>(.*?)</dict>}m)[1]
    names = environment.scan(%r{<key>(.*?)</key>}).flatten
    assert_equal %w[BUNDLE_GEMFILE BUNDLE_PATH BUNDLE_APP_CONFIG BUNDLE_WITHOUT BUNDLE_FROZEN HOME PATH LANG TOOLBOX_PRODUCTION_REPO_DIR].sort,
                 names.sort
    refute_includes plist, 'OP_SERVICE_ACCOUNT_TOKEN'
    refute_includes plist, ENV.fetch('OP_SERVICE_ACCOUNT_TOKEN')
    assert_includes plist, '<string>--production</string>'
    assert_includes plist, '<key>StandardOutPath</key><string>/dev/null</string>'
    assert_includes plist, '<key>StandardErrorPath</key><string>/dev/null</string>'
    assert_includes plist, File.join(@repo, 'web', 'server.rb')
    refute_includes plist, '/bin/sh'
  end

  def test_dependency_install_uses_separate_frozen_bundle_configuration
    @runner.bundle_installed = false
    assert @service.ensure_running
    arguments, options = @runner.calls.find { |argv, _| argv.include?('install') }
    assert_equal ['/fixture/ruby/bin/ruby', '/fixture/ruby/bin/bundle', 'install', '--quiet'], arguments
    assert_equal Core::DashboardService::DEPENDENCY_TIMEOUT, options[:timeout]
    assert_equal File.join(@repo, '.runtime', 'dashboard', 'gems'), options[:env]['BUNDLE_PATH']
    assert_equal File.join(@repo, '.runtime', 'dashboard', 'bundle-config'), options[:env]['BUNDLE_APP_CONFIG']
    assert_equal File.join(@repo, 'Gemfile'), options[:env]['BUNDLE_GEMFILE']
    assert_equal 'test', options[:env]['BUNDLE_WITHOUT']
    assert_equal 'true', options[:env]['BUNDLE_FROZEN']
    assert_equal @repo, options[:chdir]
  end

  def test_existing_matching_plist_only_kickstarts_the_dashboard
    write_matching_plist
    assert @service.ensure_running
    assert_equal [['launchctl', 'kickstart', '-k', "gui/501/#{Core::DashboardService::LABEL}"]], launch_commands
  end

  def test_unloaded_existing_plist_falls_back_to_dashboard_bootstrap
    write_matching_plist
    @runner.kickstart_success = false
    assert @service.ensure_running
    assert_equal [
      ['launchctl', 'kickstart', '-k', "gui/501/#{Core::DashboardService::LABEL}"],
      ['launchctl', 'bootstrap', 'gui/501', plist_path]
    ], launch_commands
  end

  def test_readiness_failure_has_bounded_wait_and_never_stops_other_services
    @health = [nil]
    error = assert_raises(RuntimeError) { @service.ensure_running }
    assert_equal 'Dashboard did not become ready on loopback', error.message
    assert_equal Array.new(20, 0.5), @sleeps
    assert_equal [
      ['launchctl', 'bootout', "gui/501/#{Core::DashboardService::LABEL}"],
      ['launchctl', 'bootstrap', 'gui/501', plist_path]
    ], launch_commands
    refute @runner.calls.any? { |arguments, _options| %w[docker kill pkill].include?(arguments.first) }
  end

  def test_launch_failure_returns_safe_diagnostic_without_further_process_actions
    @runner.bootstrap_success = false
    error = assert_raises(RuntimeError) { @service.ensure_running }
    assert_equal 'Dashboard service command failed; application services are unaffected', error.message
    assert_empty @sleeps
    assert_equal 2, launch_commands.length
  end

  private

  def service(repo_dir: @repo)
    Core::DashboardService.new(repo_dir: repo_dir, home_dir: @home, runner: @runner,
      uid: 501, ruby: '/fixture/ruby/bin/ruby', sleeper: ->(seconds) { @sleeps << seconds },
      health_reader: -> { @health.length > 1 ? @health.shift : @health.first })
  end

  def plist_path
    File.join(@home, 'Library', 'LaunchAgents', "#{Core::DashboardService::LABEL}.plist")
  end

  def write_matching_plist
    FileUtils.mkdir_p(File.dirname(plist_path))
    File.write(plist_path, @service.plist)
  end

  def launch_commands
    @runner.calls.map(&:first).select { |arguments| arguments.first == 'launchctl' }
  end
end

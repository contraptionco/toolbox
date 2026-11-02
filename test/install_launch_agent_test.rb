require_relative 'test_helper'
require 'open3'
require 'tmpdir'
require 'fileutils'

class InstallLaunchAgentTest < Minitest::Test
  SCRIPT = File.expand_path('../install_launch_agent.rb', __dir__)

  def test_writes_token_bearing_plist_with_private_permissions
    Dir.mktmpdir do |home|
      repo = File.join(home, 'code', 'toolbox')
      prepare_fixture(repo)
      _stdout, stderr, status = Open3.capture3(
        fixture_env(home),
        RbConfig.ruby,
        File.join(repo, 'install_launch_agent.rb'), '--production'
      )
      assert status.success?, stderr

      path = File.join(home, 'Library', 'LaunchAgents', 'co.contraption.toolbox.heartbeat.plist')
      assert_equal 0o600, File.stat(path).mode & 0o777
      plist = File.binread(path)
      assert_includes plist, 'OP_SERVICE_ACCOUNT_TOKEN'
      assert_match(/<key>TOOLBOX_OP_BACKEND<\/key>\s*<string>docker<\/string>/, plist)
      assert_includes plist, '<key>TOOLBOX_PRODUCTION_REPO_DIR</key>'
    end
  end

  def test_development_invocation_cannot_replace_an_existing_plist
    Dir.mktmpdir do |home|
      repo = File.join(home, 'code', 'toolbox')
      development = File.join(home, 'development')
      prepare_fixture(repo)
      prepare_fixture(development)
      path = File.join(home, 'Library', 'LaunchAgents', 'co.contraption.toolbox.heartbeat.plist')
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, 'existing production settings')

      _stdout, stderr, status = Open3.capture3(
        fixture_env(home), RbConfig.ruby, File.join(development, 'install_launch_agent.rb'), '--production'
      )

      refute status.success?
      assert_includes stderr, 'outside the intended checkout'
      assert_equal 'existing production settings', File.read(path)
    end
  end

  def test_installation_requires_explicit_intent
    Dir.mktmpdir do |home|
      repo = File.join(home, 'code', 'toolbox')
      prepare_fixture(repo)
      _stdout, stderr, status = Open3.capture3(
        fixture_env(home), RbConfig.ruby, File.join(repo, 'install_launch_agent.rb')
      )

      refute status.success?
      assert_includes stderr, 'require --production'
      refute Dir.exist?(File.join(home, 'Library'))
    end
  end

  def test_custom_production_directory_is_preserved_in_plist
    Dir.mktmpdir do |home|
      repo = File.join(home, 'production & services', 'toolbox')
      prepare_fixture(repo)
      env = fixture_env(home).merge('TOOLBOX_PRODUCTION_REPO_DIR' => repo)
      _stdout, stderr, status = Open3.capture3(
        env, RbConfig.ruby, File.join(repo, 'install_launch_agent.rb'), '--production'
      )

      assert status.success?, stderr
      plist = File.read(File.join(home, 'Library', 'LaunchAgents', 'co.contraption.toolbox.heartbeat.plist'))
      escaped = File.realpath(repo).gsub('&', '&amp;')
      assert_includes plist, "<string>#{escaped}/heartbeat.sh</string>"
      %w[TOOLBOX_REPO_DIR TOOLBOX_PRODUCTION_REPO_DIR].each do |key|
        assert_match(/<key>#{key}<\/key>\s*<string>#{Regexp.escape(escaped)}<\/string>/, plist)
      end
    end
  end

  private

  def fixture_env(home)
    { 'HOME' => home, 'USER' => 'fixture', 'TOOLBOX_REPO_DIR' => nil, 'TOOLBOX_PRODUCTION_REPO_DIR' => nil }
  end

  def prepare_fixture(repo)
    FileUtils.mkdir_p(File.join(repo, 'lib'))
    FileUtils.cp(SCRIPT, File.join(repo, 'install_launch_agent.rb'))
    FileUtils.cp(File.expand_path('../lib/production_guard.rb', __dir__), File.join(repo, 'lib', 'production_guard.rb'))
    File.write(File.join(repo, 'config.rb'), <<~RUBY)
      module Config
        USER = ENV.fetch('USER')
        HOME_DIR = ENV.fetch('HOME')
      end
    RUBY
  end
end

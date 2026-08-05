require_relative 'test_helper'
require 'open3'
require 'tmpdir'

class InstallLaunchAgentTest < Minitest::Test
  SCRIPT = File.expand_path('../install_launch_agent.rb', __dir__)

  def test_writes_token_bearing_plist_with_private_permissions
    Dir.mktmpdir do |home|
      _stdout, stderr, status = Open3.capture3(
        { 'HOME' => home, 'USER' => 'fixture' },
        RbConfig.ruby,
        SCRIPT
      )
      assert status.success?, stderr

      path = File.join(home, 'Library', 'LaunchAgents', 'co.contraption.toolbox.heartbeat.plist')
      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_includes File.binread(path), 'OP_SERVICE_ACCOUNT_TOKEN'
    end
  end
end

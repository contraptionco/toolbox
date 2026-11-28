require_relative 'test_helper'
require 'tmpdir'
require_relative '../lib/dashboard/settings'

class DashboardSettingsTest < Minitest::Test
  def settings
    { secret: 'a' * 64, smtp_host: 'email-smtp.us-east-2.amazonaws.com', smtp_port: 587,
      smtp_user: 'fixture-user', smtp_password: 'fixture-password', smtp_from: 'Toolbox <toolbox@contraption.co>' }
  end

  def test_private_owned_file_is_required_and_symlinks_fail_closed
    Dir.mktmpdir do |dir|
      path = File.join(dir, 'auth.json')
      File.write(path, JSON.generate(settings), mode: 'w', perm: 0o600)
      assert_equal 'fixture-user', Dashboard::Settings.load(path)['smtp_user']
      File.chmod(0o644, path)
      assert_raises(ArgumentError) { Dashboard::Settings.load(path) }
      File.chmod(0o600, path)
      File.symlink(path, File.join(dir, 'link'))
      assert_raises(Errno::ELOOP) { Dashboard::Settings.load(File.join(dir, 'link')) }
    end
  end

  def test_sender_migration_accepts_only_the_two_exact_configured_identities
    ['Toolbox <toolbox@contraption.co>', 'Toolbox <toolbox@ilic.nyc>'].each do |sender|
      assert_equal sender, Dashboard::Settings.parse(JSON.generate(settings.merge(smtp_from: sender)))['smtp_from']
    end
    ['toolbox@contraption.co', 'Other <toolbox@contraption.co>', 'Toolbox <other@contraption.co>',
     "Toolbox <toolbox@contraption.co>\r\nBcc: other@example.test"].each do |sender|
      assert_raises(ArgumentError) { Dashboard::Settings.parse(JSON.generate(settings.merge(smtp_from: sender))) }
    end
  end

  def test_only_expected_mail_settings_and_strong_secret_are_accepted
    [{secret: 'short'}, {smtp_port: 25}, {smtp_from: 'Other <other@example.com>'},
     {smtp_host: 'localhost'}, {smtp_password: "bad\nheader"}, {extra: 'unrelated-secret'}].each do |change|
      error = assert_raises(ArgumentError) { Dashboard::Settings.parse(JSON.generate(settings.merge(change))) }
      assert_equal 'Invalid dashboard credential configuration', error.message
    end
  end
end

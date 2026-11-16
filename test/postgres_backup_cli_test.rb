require_relative 'test_helper'
require 'fileutils'
require 'open3'
require 'tmpdir'

class PostgresBackupCliTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def test_requires_production_intent_before_loading_secrets_or_configuration
    with_fixture do |repo, environment|
      _out, error, status = run_backup(repo, environment, '--force')

      refute status.success?
      assert_includes error, 'require --production'
      refute File.exist?(environment.fetch('FIXTURE_CONFIG_MARKER'))
    end
  end

  def test_force_does_not_allow_a_development_checkout
    with_fixture do |repo, environment|
      Dir.mktmpdir do |production|
        environment['TOOLBOX_PRODUCTION_REPO_DIR'] = production
        _out, error, status = run_backup(repo, environment, '--production', '--force')

        refute status.success?
        assert_includes error, 'outside the intended checkout'
        refute File.exist?(environment.fetch('FIXTURE_CONFIG_MARKER'))
      end
    end
  end

  def test_force_does_not_allow_uncommitted_production_code
    with_fixture do |repo, environment|
      File.write(File.join(repo, 'uncommitted'), 'fixture')
      _out, error, status = run_backup(repo, environment, '--production', '--force')

      refute status.success?
      assert_includes error, 'dirty'
      refute File.exist?(environment.fetch('FIXTURE_CONFIG_MARKER'))
    end
  end

  def test_force_does_not_allow_a_feature_branch
    with_fixture do |repo, environment|
      git!(repo, 'switch', '-c', 'feature')
      _out, error, status = run_backup(repo, environment, '--production', '--force')

      refute status.success?
      assert_includes error, 'not main'
      refute File.exist?(environment.fetch('FIXTURE_CONFIG_MARKER'))
    end
  end

  def test_refuses_unknown_options
    with_fixture do |repo, environment|
      _out, error, status = run_backup(repo, environment, '--production', '--force', '--no-lock')

      refute status.success?
      assert_includes error, 'Unexpected production arguments'
      refute File.exist?(environment.fetch('FIXTURE_CONFIG_MARKER'))
    end
  end

  def test_verified_checkout_accepts_normal_and_forced_entrypoints
    [[], ['--force']].each do |arguments|
      with_fixture do |repo, environment|
        _out, error, = run_backup(repo, environment, '--production', *arguments)

        assert File.exist?(environment.fetch('FIXTURE_CONFIG_MARKER')), error
        assert_includes error, 'Fixture stops before any service command'
      end
    end
  end

  private

  def with_fixture
    Dir.mktmpdir('backup-cli-test-') do |directory|
      repo = File.join(directory, 'production')
      FileUtils.mkdir_p([File.join(repo, 'scripts'), File.join(repo, 'lib')])
      %w[scripts/postgres_backup.rb lib/production_guard.rb lib/command_runner.rb].each do |file|
        FileUtils.cp(File.join(ROOT, file), File.join(repo, file))
      end
      File.write(File.join(repo, 'config.rb'), <<~RUBY)
        File.write(ENV.fetch('FIXTURE_CONFIG_MARKER'), 'loaded')
        raise 'Fixture stops before any service command'
      RUBY
      git!(repo, 'init', '-b', 'main', '--template=')
      git!(repo, 'add', '.')
      git!(repo, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-m', 'Fixture')
      git!(repo, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
      environment = {
        'TOOLBOX_PRODUCTION_REPO_DIR' => repo,
        'TOOLBOX_REPO_DIR' => nil,
        'OP_SERVICE_ACCOUNT_TOKEN' => nil,
        'FIXTURE_CONFIG_MARKER' => File.join(directory, 'configuration-loaded')
      }
      yield repo, environment
    end
  end

  def run_backup(repo, environment, *arguments)
    Open3.capture3(environment, RbConfig.ruby, File.join(repo, 'scripts', 'postgres_backup.rb'), *arguments)
  end

  def git!(repo, *arguments)
    _out, error, status = Open3.capture3('git', '-C', repo, *arguments)
    raise error unless status.success?
  end
end

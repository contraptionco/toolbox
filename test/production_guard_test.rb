require_relative 'test_helper'
require 'fileutils'
require 'open3'
require 'tmpdir'
require_relative '../lib/production_guard'

class ProductionGuardTest < Minitest::Test
  ROOT = File.expand_path('..', __dir__)

  def test_manual_run_requires_explicit_intent_before_loading_configuration
    with_fixture do |repo, env|
      _stdout, stderr, status = run_toolbox(repo, env)

      refute status.success?
      assert_includes stderr, 'require --production'
      assert_no_service_effects(env)
    end
  end

  def test_explicit_flag_does_not_authorize_a_development_checkout
    with_fixture do |repo, env|
      Dir.mktmpdir do |production|
        env['TOOLBOX_PRODUCTION_REPO_DIR'] = production
        _stdout, stderr, status = run_toolbox(repo, env, '--production')

        refute status.success?
        assert_includes stderr, 'outside the intended checkout'
        assert_no_service_effects(env)
      end
    end
  end

  def test_clean_verified_production_run_preserves_code_changed_mode
    with_fixture do |repo, env|
      _stdout, stderr, status = run_toolbox(repo, env, '--production', 'code_changed')

      assert status.success?, stderr
      assert_equal 'true', File.read(env.fetch('FIXTURE_SERVICE_MARKER'))
    end
  end

  def test_first_legacy_heartbeat_invocation_is_skipped_and_next_new_invocation_succeeds
    with_fixture do |repo, env|
      _stdout, stderr, status = run_toolbox(repo, env, 'code_changed')

      refute status.success?
      assert_includes stderr, 'require --production'
      assert_no_service_effects(env)

      _stdout, stderr, status = run_toolbox(repo, env, '--production', 'no_changes')

      assert status.success?, stderr
      assert_equal 'false', File.read(env.fetch('FIXTURE_SERVICE_MARKER'))
    end
  end

  def test_manual_production_run_refuses_feature_branch_before_loading_configuration
    with_fixture do |repo, env|
      git!(repo, 'switch', '-c', 'feature')
      _stdout, stderr, status = run_toolbox(repo, env, '--production')

      refute status.success?
      assert_includes stderr, 'not main'
      assert_no_service_effects(env)
    end
  end

  def test_manual_production_run_refuses_uncommitted_files
    with_fixture do |repo, env|
      git!(repo, 'config', 'status.showUntrackedFiles', 'no')
      File.write(File.join(repo, 'uncommitted.rb'), 'development work')
      _stdout, stderr, status = run_toolbox(repo, env, '--production')

      refute status.success?
      assert_includes stderr, 'dirty'
      assert_no_service_effects(env)
    end
  end

  def test_updater_cli_refuses_development_copy_before_loading_dependencies
    Dir.mktmpdir do |root|
      production = File.join(root, 'production')
      development = File.join(root, 'development')
      FileUtils.mkdir_p([production, File.join(development, 'lib')])
      %w[production_guard.rb heartbeat_update.rb].each do |name|
        FileUtils.cp(File.join(ROOT, 'lib', name), File.join(development, 'lib', name))
      end
      env = { 'TOOLBOX_PRODUCTION_REPO_DIR' => production, 'TOOLBOX_REPO_DIR' => nil }

      _stdout, stderr, status = Open3.capture3(
        env, RbConfig.ruby, File.join(development, 'lib', 'heartbeat_update.rb'), production
      )

      refute status.success?
      assert_includes stderr, 'outside the intended checkout'
      assert_empty Dir.children(production)
    end
  end

  def test_manual_production_run_refuses_unpublished_commits
    with_fixture do |repo, env|
      git!(repo, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
           'commit', '--allow-empty', '-m', 'Unpublished change')
      _stdout, stderr, status = run_toolbox(repo, env, '--production')

      refute status.success?
      assert_includes stderr, 'does not match origin/main'
      assert_no_service_effects(env)
    end
  end

  def test_symlink_does_not_disguise_a_different_checkout
    Dir.mktmpdir do |root|
      production = File.join(root, 'production')
      development = File.join(root, 'development')
      FileUtils.mkdir_p([production, development])
      link = File.join(root, 'linked-development')
      FileUtils.ln_s(development, link)

      assert_raises(Core::ProductionGuard::Error) do
        Core::ProductionGuard.validate_directory!(link, environment: { 'TOOLBOX_PRODUCTION_REPO_DIR' => production })
      end
    end
  end

  private

  def with_fixture
    Dir.mktmpdir do |root|
      repo = File.join(root, 'production')
      FileUtils.mkdir_p(File.join(repo, 'lib'))
      %w[toolbox.rb lib/production_guard.rb lib/command_runner.rb].each do |name|
        FileUtils.cp(File.join(ROOT, name), File.join(repo, name))
      end
      File.write(File.join(repo, 'config.rb'), <<~RUBY)
        File.write(ENV.fetch('FIXTURE_CONFIG_MARKER'), 'loaded')
        module Config
          USER = 'fixture'
        end
      RUBY
      File.write(File.join(repo, 'lib', 'service_manager.rb'), <<~RUBY)
        module Core
          module ServiceManager
            def self.start_all(changed)
              File.write(ENV.fetch('FIXTURE_SERVICE_MARKER'), changed.to_s)
            end
          end
        end
      RUBY
      git!(repo, 'init', '-b', 'main', '--template=')
      git!(repo, 'add', '.')
      git!(repo, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
           'commit', '-m', 'Fixture')
      git!(repo, 'update-ref', 'refs/remotes/origin/main', 'HEAD')
      env = {
        'HOME' => root,
        'TOOLBOX_PRODUCTION_REPO_DIR' => repo,
        'TOOLBOX_REPO_DIR' => nil,
        'GIT_CONFIG_GLOBAL' => File::NULL,
        'GIT_CONFIG_NOSYSTEM' => '1',
        'GIT_ALLOW_PROTOCOL' => 'file',
        'FIXTURE_CONFIG_MARKER' => File.join(root, 'config-loaded'),
        'FIXTURE_SERVICE_MARKER' => File.join(root, 'services-started')
      }
      yield repo, env
    end
  end

  def run_toolbox(repo, env, *arguments)
    Open3.capture3(env, RbConfig.ruby, File.join(repo, 'toolbox.rb'), *arguments)
  end

  def assert_no_service_effects(env)
    refute File.exist?(env.fetch('FIXTURE_CONFIG_MARKER')), 'configuration was loaded'
    refute File.exist?(env.fetch('FIXTURE_SERVICE_MARKER')), 'services were started'
  end

  def git!(repo, *arguments)
    environment = {
      'GIT_CONFIG_GLOBAL' => File::NULL,
      'GIT_CONFIG_NOSYSTEM' => '1',
      'GIT_ALLOW_PROTOCOL' => 'file'
    }
    _stdout, stderr, status = Open3.capture3(
      environment, 'git', '-c', 'commit.gpgsign=false', *arguments, chdir: repo
    )
    assert status.success?, stderr
  end
end

require 'tmpdir'
require 'open3'
require_relative 'test_helper'
require_relative '../lib/git_service'
require_relative '../scripts/ghost_backup'

class GitReleaseSafetyTest < Minitest::Test
  IMAGE_ID = "sha256:#{'a' * 64}"

  def with_repository
    # These tests use only temporary local Git repositories. The protocol guard
    # prevents any accidental network fallback; no actual Docker command is run.
    environment = {
      'GIT_ALLOW_PROTOCOL' => 'file',
      'GIT_CONFIG_GLOBAL' => File::NULL,
      'GIT_CONFIG_NOSYSTEM' => '1',
      'GIT_AUTHOR_NAME' => 'Toolbox test',
      'GIT_AUTHOR_EMAIL' => 'test@example.invalid',
      'GIT_COMMITTER_NAME' => 'Toolbox test',
      'GIT_COMMITTER_EMAIL' => 'test@example.invalid'
    }
    previous = environment.to_h { |key, _value| [key, ENV[key]] }
    environment.each { |key, value| ENV[key] = value }
    Dir.mktmpdir('toolbox-git-test-') do |directory|
      upstream = File.join(directory, 'upstream')
      local = File.join(directory, 'checkout')
      FileUtils.mkdir_p(upstream)
      git(upstream, 'init', '--initial-branch=main', '--template=')
      File.write(File.join(upstream, 'app.txt'), "approved\n")
      File.write(File.join(upstream, '.gitignore'), "ignored.txt\n")
      commit(upstream, 'initial')
      git(directory, 'clone', upstream, local)
      git(local, 'config', 'status.showUntrackedFiles', 'no')
      service = {
        name: 'fixture', repo_url: upstream, local_path: local,
        auto_update: true, deployment_marker_path: File.join(directory, 'fixture.head')
      }
      yield service, upstream, directory
    end
  ensure
    previous&.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def git(directory, *arguments)
    stdout, stderr, status = Open3.capture3('git', '-c', 'commit.gpgsign=false', '-C', directory, *arguments)
    raise "Fixture Git failed: #{stderr}" unless status.success?

    stdout.strip
  end

  def commit(directory, message)
    git(directory, 'add', '--all')
    git(directory, 'commit', '-m', message)
    git(directory, 'rev-parse', 'HEAD')
  end

  def with_backup_repository(service)
    original_path = Scripts::GhostBackup::REPO_PATH
    original_url = Scripts::GhostBackup::REPO_URL
    Scripts::GhostBackup.send(:remove_const, :REPO_PATH)
    Scripts::GhostBackup.const_set(:REPO_PATH, service[:local_path])
    Scripts::GhostBackup.send(:remove_const, :REPO_URL)
    Scripts::GhostBackup.const_set(:REPO_URL, service[:repo_url])
    yield Scripts::GhostBackup.new
  ensure
    Scripts::GhostBackup.send(:remove_const, :REPO_PATH)
    Scripts::GhostBackup.const_set(:REPO_PATH, original_path)
    Scripts::GhostBackup.send(:remove_const, :REPO_URL)
    Scripts::GhostBackup.const_set(:REPO_URL, original_url)
  end

  def test_ghost_backup_updates_existing_repository_through_compatibility_helper
    with_repository do |service, upstream|
      File.write(File.join(upstream, 'remote.txt'), 'published backup')
      remote_head = commit(upstream, 'published')
      with_backup_repository(service) do |backup|
        assert backup.send(:ensure_backup_repo)
      end
      assert_equal remote_head, git(service[:local_path], 'rev-parse', 'HEAD')
    end
  end

  def test_ghost_backup_clones_missing_repository_before_updating
    with_repository do |service, upstream|
      FileUtils.rm_rf(service[:local_path])
      with_backup_repository(service) do |backup|
        assert backup.send(:ensure_backup_repo)
      end
      assert_equal git(upstream, 'rev-parse', 'HEAD'), git(service[:local_path], 'rev-parse', 'HEAD')
      assert_equal 'main', git(service[:local_path], 'branch', '--show-current')
    end
  end

  def test_backup_pull_preserves_pending_exports_while_fast_forwarding
    with_repository do |service, upstream|
      File.write(File.join(service[:local_path], 'app.txt'), 'pending export')
      File.write(File.join(service[:local_path], 'pending.csv'), 'pending members')
      File.write(File.join(upstream, 'remote.txt'), 'published backup')
      remote_head = commit(upstream, 'published')
      assert Core::GitService.pull_latest(service[:local_path])
      assert_equal remote_head, git(service[:local_path], 'rev-parse', 'HEAD')
      assert_equal 'pending export', File.read(File.join(service[:local_path], 'app.txt'))
      assert_equal 'pending members', File.read(File.join(service[:local_path], 'pending.csv'))
      # Application deployments must still reject the same dirty checkout.
      assert_raises(RuntimeError) { Core::GitService.prepare_release(service) }
    end
  end

  def test_backup_pull_preserves_unpushed_commit_without_weakening_deployment_guard
    with_repository do |service, _upstream|
      File.write(File.join(service[:local_path], 'app.txt'), 'unpushed backup')
      local_head = commit(service[:local_path], 'backup awaiting retry')
      assert Core::GitService.pull_latest(service[:local_path], nil)
      assert_equal local_head, git(service[:local_path], 'rev-parse', 'HEAD')
      assert_raises(RuntimeError) { Core::GitService.prepare_release(service) }
    end
  end

  def test_backup_pull_rejects_divergence_without_losing_local_commit
    with_repository do |service, upstream|
      File.write(File.join(service[:local_path], 'local.txt'), 'unpushed backup')
      local_head = commit(service[:local_path], 'local backup')
      File.write(File.join(upstream, 'remote.txt'), 'remote backup')
      commit(upstream, 'remote backup')
      assert_raises(RuntimeError) { Core::GitService.pull_latest(service[:local_path], 'main') }
      assert_equal local_head, git(service[:local_path], 'rev-parse', 'HEAD')
      assert_equal 'unpushed backup', File.read(File.join(service[:local_path], 'local.txt'))
      refute File.exist?(File.join(service[:local_path], '.git', 'MERGE_HEAD'))
    end
  end

  def test_backup_pull_rejects_conflicting_remote_change_without_discarding_export
    with_repository do |service, upstream|
      File.write(File.join(service[:local_path], 'app.txt'), 'pending local export')
      old_head = git(service[:local_path], 'rev-parse', 'HEAD')
      File.write(File.join(upstream, 'app.txt'), 'conflicting remote export')
      commit(upstream, 'remote backup')
      assert_raises(RuntimeError) { Core::GitService.pull_latest(service[:local_path], 'main') }
      assert_equal old_head, git(service[:local_path], 'rev-parse', 'HEAD')
      assert_equal 'pending local export', File.read(File.join(service[:local_path], 'app.txt'))
    end
  end

  def test_backup_pull_never_switches_an_unexpected_branch
    with_repository do |service, _upstream|
      git(service[:local_path], 'switch', '-c', 'development')
      error = assert_raises(RuntimeError) { Core::GitService.pull_latest(service[:local_path], 'main') }
      assert_includes error.message, 'refusing to switch'
      assert_equal 'development', git(service[:local_path], 'branch', '--show-current')
      git(service[:local_path], 'switch', '--detach')
      assert_raises(RuntimeError) { Core::GitService.pull_latest(service[:local_path], 'main') }
      assert_equal '', git(service[:local_path], 'branch', '--show-current')
    end
  end

  def test_backup_pull_propagates_fetch_failure_and_preserves_pending_export
    with_repository do |service, _upstream, directory|
      File.write(File.join(service[:local_path], 'app.txt'), 'pending export')
      old_head = git(service[:local_path], 'rev-parse', 'HEAD')
      git(service[:local_path], 'remote', 'set-url', 'origin', File.join(directory, 'missing-origin'))
      assert_raises(RuntimeError) { Core::GitService.pull_latest(service[:local_path], 'main') }
      assert_equal old_head, git(service[:local_path], 'rev-parse', 'HEAD')
      assert_equal 'pending export', File.read(File.join(service[:local_path], 'app.txt'))
    end
  end

  def test_missing_checkout_clones_the_explicit_default_main
    with_repository do |service, _upstream|
      FileUtils.rm_rf(service[:local_path])
      release = Core::GitService.prepare_release(service)
      assert release[:cloned]
      assert_equal 'main', git(service[:local_path], 'branch', '--show-current')
    end
  end

  def test_missing_default_main_does_not_fall_back_to_another_remote_branch
    with_repository do |service, upstream|
      git(upstream, 'branch', '-m', 'development')
      error = assert_raises(RuntimeError) { Core::GitService.prepare_release(service) }
      assert_includes error.message, 'missing or ambiguous'
      assert_equal 'main', git(service[:local_path], 'branch', '--show-current')
    end
  end

  def test_default_main_rejects_feature_branch_without_switching
    with_repository do |service, _upstream|
      git(service[:local_path], 'switch', '-c', 'development')
      error = assert_raises(RuntimeError) { Core::GitService.prepare_release(service) }
      assert_includes error.message, 'expected main'
      assert_equal 'development', git(service[:local_path], 'branch', '--show-current')
    end
  end

  def test_unpushed_main_commit_is_rejected
    with_repository do |service, _upstream|
      File.write(File.join(service[:local_path], 'app.txt'), "local development\n")
      local_head = commit(service[:local_path], 'unpublished')
      assert_raises(RuntimeError) { Core::GitService.prepare_release(service) }
      assert_equal local_head, git(service[:local_path], 'rev-parse', 'HEAD')
    end
  end

  def test_divergent_main_is_rejected
    with_repository do |service, upstream|
      File.write(File.join(service[:local_path], 'local.txt'), 'unpublished')
      commit(service[:local_path], 'local')
      File.write(File.join(upstream, 'remote.txt'), 'published')
      commit(upstream, 'remote')
      assert_raises(RuntimeError) { Core::GitService.prepare_release(service) }
      refute File.exist?(File.join(service[:local_path], 'remote.txt'))
    end
  end

  def test_remote_main_fast_forwards_to_verified_commit
    with_repository do |service, upstream|
      File.write(File.join(upstream, 'app.txt'), "new approved version\n")
      approved = commit(upstream, 'published')
      release = Core::GitService.prepare_release(service)
      assert_equal approved, release[:head]
      assert_equal approved, git(service[:local_path], 'rev-parse', 'HEAD')
      assert_empty git(service[:local_path], 'for-each-ref', 'refs/toolbox')
    end
  end

  def test_auto_update_false_keeps_an_approved_ancestor
    with_repository do |service, upstream|
      original = git(service[:local_path], 'rev-parse', 'HEAD')
      File.write(File.join(upstream, 'app.txt'), "new approved version\n")
      commit(upstream, 'published')
      release = Core::GitService.prepare_release(service.merge(auto_update: false))
      assert_equal original, release[:head]
      assert_equal original, git(service[:local_path], 'rev-parse', 'HEAD')
    end
  end

  def test_tracked_edits_and_untracked_files_are_rejected_before_deployment
    with_repository do |service, _upstream|
      stopped = false
      Core::DockerService.stub(:stop_container, ->(*) { stopped = true }) do
        File.write(File.join(service[:local_path], 'app.txt'), 'dirty')
        assert_raises(RuntimeError) { Core::GitService.update_git_service(service) }
        git(service[:local_path], 'restore', 'app.txt')
        File.write(File.join(service[:local_path], 'AGENTS.md'), 'development instructions')
        assert_raises(RuntimeError) { Core::GitService.update_git_service(service) }
      end
      refute stopped
      refute File.exist?(service[:deployment_marker_path])
    end
  end

  def test_configured_untracked_generated_files_are_allowed_but_other_files_are_not
    with_repository do |service, _upstream|
      service = service.merge(env_config: 'TOKEN=fixture', compose_override: { services: {} })
      File.write(File.join(service[:local_path], '.env'), 'generated')
      File.write(File.join(service[:local_path], 'compose.override.yml'), 'generated')
      assert Core::GitService.prepare_release(service)
      assert_raises(RuntimeError) { Core::GitService.prepare_release(service.reject { |key, _| key == :env_config }) }
      File.write(File.join(service[:local_path], 'other.env'), 'development')
      assert_raises(RuntimeError) { Core::GitService.prepare_release(service) }
    end
  end

  def test_tracked_generated_files_are_not_exempt_even_when_clean
    with_repository do |service, upstream|
      File.write(File.join(upstream, 'compose.override.yml'), "services: {}\n")
      commit(upstream, 'tracked configuration')
      git(service[:local_path], 'pull', '--ff-only')
      configured = service.merge(compose_override: { services: {} })
      assert_raises(RuntimeError) { Core::GitService.prepare_release(configured) }
      File.write(File.join(service[:local_path], 'compose.override.yml'), 'development')
      assert_raises(RuntimeError) { Core::GitService.prepare_release(configured) }
    end
  end

  def test_generated_path_newly_tracked_by_remote_is_rejected_after_fast_forward
    with_repository do |service, upstream|
      File.write(File.join(upstream, '.env'), 'TRACKED=do-not-overwrite')
      commit(upstream, 'tracked environment')
      error = assert_raises(RuntimeError) do
        Core::GitService.prepare_release(service.merge(env_config: 'GENERATED=fixture'))
      end
      assert_includes error.message, 'generated file .env is tracked'
      assert_equal 'TRACKED=do-not-overwrite', File.read(File.join(service[:local_path], '.env'))
    end
  end

  def test_annotated_pinned_tag_supports_detached_head_and_generated_configuration
    with_repository do |service, upstream|
      git(upstream, 'tag', '-a', 'v3.1.0', '-m', 'release')
      git(service[:local_path], 'fetch', 'origin', 'tag', 'v3.1.0')
      git(service[:local_path], 'switch', '--detach', 'v3.1.0')
      File.write(File.join(service[:local_path], '.env'), 'generated')
      File.write(File.join(service[:local_path], 'compose.override.yml'), 'generated')
      service = service.merge(branch: 'v3.1.0', auto_update: false, env_config: 'TOKEN=fixture', compose_override: {})
      assert_equal git(upstream, 'rev-parse', 'v3.1.0^{commit}'), Core::GitService.prepare_release(service)[:head]
      git(service[:local_path], 'switch', '-c', 'development')
      assert_raises(RuntimeError) { Core::GitService.prepare_release(service) }
    end
  end

  def test_wrong_pinned_tag_commit_is_rejected
    with_repository do |service, upstream|
      git(upstream, 'tag', 'v3.1.0')
      File.write(File.join(upstream, 'app.txt'), 'newer')
      commit(upstream, 'newer')
      git(service[:local_path], 'pull', '--ff-only')
      git(service[:local_path], 'switch', '--detach')
      assert_raises(RuntimeError) { Core::GitService.prepare_release(service.merge(branch: 'v3.1.0', auto_update: false)) }
    end
  end

  def test_ambiguous_branch_and_tag_fail_closed
    with_repository do |service, upstream|
      git(upstream, 'tag', 'main')
      assert_raises(RuntimeError) { Core::GitService.prepare_release(service) }
      assert Core::GitService.prepare_release(service.merge(branch: 'refs/heads/main'))
    end
  end

  def test_snapshot_excludes_ignored_files_and_edits_after_source_validation
    with_repository do |service, _upstream|
      File.write(File.join(service[:local_path], 'ignored.txt'), 'private development data')
      release = Core::GitService.prepare_release(service)
      File.write(File.join(service[:local_path], 'app.txt'), 'late development edit')
      File.write(File.join(service[:local_path], 'untracked.txt'), 'late new file')
      snapshot_path = nil
      Core::GitService.with_release_snapshot(service[:local_path], release[:head]) do |source|
        snapshot_path = source
        assert_equal "approved\n", File.read(File.join(source, 'app.txt'))
        refute File.exist?(File.join(source, 'ignored.txt'))
        refute File.exist?(File.join(source, 'untracked.txt'))
        refute File.exist?(File.join(source, '.git'))
      end
      refute Dir.exist?(snapshot_path)
    end
  end

  def test_snapshot_fails_explicitly_instead_of_silently_omitting_submodules
    with_repository do |service, upstream|
      head = git(upstream, 'rev-parse', 'HEAD')
      git(upstream, 'update-index', '--add', '--cacheinfo', "160000,#{head},dependency")
      git(upstream, 'commit', '-m', 'submodule entry')
      release = Core::GitService.prepare_release(service)
      error = assert_raises(RuntimeError) do
        Core::GitService.with_release_snapshot(service[:local_path], release[:head]) { flunk 'Must reject incomplete snapshot' }
      end
      assert_includes error.message, 'do not support Git submodules'
    end
  end

  def test_snapshot_is_removed_when_build_fails
    with_repository do |service, _upstream|
      release = Core::GitService.prepare_release(service)
      snapshot_path = nil
      assert_raises(RuntimeError) do
        Core::GitService.with_release_snapshot(service[:local_path], release[:head]) do |source|
          snapshot_path = source
          raise 'fixture build failure'
        end
      end
      refute Dir.exist?(snapshot_path)
    end
  end

  def with_container_stubs(service, running:, matching:, build:, start:, stop:)
    Core::DockerService.stub(:container_running?, running) do
      Core::DockerService.stub(:container_logging_compliant?, true) do
        Core::DockerService.stub(:container_uses_image?, matching) do
          Core::DockerService.stub(:stop_container, stop) do
            Core::DockerService.stub(:start_container, start) do
              Core::GitService.stub(:build_docker_image, build) do
                yield
              end
            end
          end
        end
      end
    end
  end

  def test_changed_local_image_tag_does_not_replace_or_rebuild_healthy_production
    with_repository do |service, _upstream|
      service = service.merge(container_config: { image_name: 'fixture' })
      head = git(service[:local_path], 'rev-parse', 'HEAD')
      Core::GitService.mark_deployed(service, Core::GitService.deployment_state(service, head))
      forbidden = ->(*) { flunk 'Unapproved local tag must not cause a build or replacement' }
      with_container_stubs(service, running: true, matching: false, build: forbidden, start: forbidden, stop: forbidden) do
        error = assert_raises(RuntimeError) { Core::GitService.update_git_service(service) }
        assert_includes error.message, 'refusing unapproved image replacement'
      end
    end
  end

  def test_stopped_container_rebuilds_verified_source_and_starts_immutable_id
    with_repository do |service, _upstream|
      service = service.merge(container_config: { image_name: 'fixture' })
      head = git(service[:local_path], 'rev-parse', 'HEAD')
      Core::GitService.mark_deployed(service, Core::GitService.deployment_state(service, head))
      File.write(File.join(service[:local_path], 'ignored.txt'), 'private development data')
      events = []
      builder = lambda do |source, image_name|
        refute_equal service[:local_path], source
        assert_equal 'fixture', image_name
        assert_equal "approved\n", File.read(File.join(source, 'app.txt'))
        refute File.exist?(File.join(source, 'ignored.txt'))
        events << :build
        IMAGE_ID
      end
      starter = ->(configuration) { events << [:start, configuration[:image]] }
      stopper = ->(*) { events << :stop }
      with_container_stubs(service, running: false, matching: false, build: builder, start: starter, stop: stopper) do
        assert Core::GitService.update_git_service(service)
      end
      assert_equal [:build, :stop, [:start, IMAGE_ID]], events
    end
  end

  def test_failed_approved_build_keeps_existing_container
    with_repository do |service, _upstream|
      service = service.merge(container_config: { image_name: 'fixture' })
      failed_build = ->(*) { raise 'fixture build failure' }
      forbidden = ->(*) { flunk 'A failed build must not stop or replace production' }
      with_container_stubs(service, running: true, matching: true, build: failed_build, start: forbidden, stop: forbidden) do
        assert_raises(RuntimeError) { Core::GitService.update_git_service(service) }
      end
      refute File.exist?(service[:deployment_marker_path])
    end
  end
end

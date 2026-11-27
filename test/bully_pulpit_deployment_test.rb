require 'tmpdir'
require_relative 'test_helper'
require_relative '../lib/git_service'

class BullyPulpitDeploymentTest < Minitest::Test
  FakeStatus = Struct.new(:success?)

  def test_production_uses_dedicated_checkout_and_is_disabled_until_explicit_enable
    service = Config::GIT_SERVICES.find { |entry| entry[:name] == 'bully-pulpit-production' }
    assert_equal 'main', service[:branch]
    assert_equal File.join(Config::CODE_DIR, 'bully-pulpit-production'), service[:local_path]
    assert_equal 'Bully Pulpit Production', service.dig(:env_config, :item)
    assert service[:env_file_path].start_with?(Config::DATA_DIR)
    assert service[:enabled_if].end_with?('/enabled.json')
    assert_equal %w[app proxy scheduler], service[:compose_readiness_services]
    Dir.mktmpdir do |directory|
      service = service.merge(enabled_if: File.join(directory, 'missing'))
      Core::GitService.stub(:prepare_release, ->(*) { flunk 'disabled deployment fetched code' }) do
        assert Core::GitService.update_git_service(service)
      end
    end
  end

  def test_infrastructure_content_changes_trigger_release_even_at_same_app_commit
    Dir.mktmpdir do |directory|
      file = File.join(directory, 'scheduler.py')
      File.write(file, 'first')
      config = { release_inputs: [file] }
      first = Core::GitService.deployment_state(config, 'same-sha')
      File.write(file, 'second')
      refute_equal first, Core::GitService.deployment_state(config, 'same-sha')
    end
  end

  def test_custom_compose_uses_exact_file_and_waits_for_readiness
    calls = []
    runner = ->(*args, **_options) { calls << args; ['', '', FakeStatus.new(true)] }
    Dir.mktmpdir do |directory|
      file = File.join(directory, 'compose.json')
      Core::CommandRunner.stub(:capture3, runner) do
        Core::GitService.docker_compose_up(directory, force_recreate: true, compose_file: file)
      end
      assert_equal ['docker', 'compose', '-f', file, 'up', '--wait', '--detach', '--force-recreate'], calls.last
    end
  end

  def test_verified_release_metadata_reaches_build_but_secret_values_do_not
    Dir.mktmpdir do |directory|
      repo = File.join(directory, 'checkout'); FileUtils.mkdir_p(repo)
      secret_path = File.join(directory, 'private', 'app.env')
      compose_path = File.join(directory, 'compose.json')
      File.write(compose_path, '{}')
      service = { name: 'fixture', local_path: repo, env_config: 'SECRET=runtime-only',
                  env_file_path: secret_path, build_cmd: 'prepare', release_environment: true,
                  use_compose: true, compose_file: compose_path, after_deploy_command: 'record',
                  deployment_marker_path: File.join(directory, 'marker') }
      events = []
      build = ->(path, command, **options) { events << [command, path, options] }
      runner = ->(*_args, **_options) { ["running\n", '', FakeStatus.new(true)] }
      Core::GitService.stub(:prepare_release, { head: 'a' * 40, cloned: false }) do
        Core::GitService.stub(:with_release_snapshot, ->(_path, _sha, &block) { block.call('/fixture-immutable-archive') }) do
          Core::GitService.stub(:run_build_command, build) do
            Core::GitService.stub(:run_command, runner) do
              Core::GitService.stub(:docker_compose_up, ->(*_args, **_options) { events << ['ready'] }) do
                Core::GitService.update_git_service(service)
              end
            end
          end
        end
      end
      assert_equal %w[prepare ready record], events.map(&:first)
      assert_equal '/fixture-immutable-archive', events.first[1]
      assert_equal({ 'TOOLBOX_RELEASE_SHA' => 'a' * 40, 'TOOLBOX_RUNTIME_ENV' => secret_path }, events.first[2][:environment])
      refute_includes events.inspect, 'runtime-only'
      assert_equal 'SECRET=runtime-only', File.read(secret_path)
      refute File.exist?(File.join(repo, '.env'))
      assert File.exist?(service[:deployment_marker_path])
    end
  end
  def test_supervised_compose_readiness_requires_every_service_and_accepts_compose_json_formats
    Dir.mktmpdir do |directory|
      file = File.join(directory, 'compose.json'); File.write(file, '{}')
      ready = %w[app proxy scheduler].map { |service| { 'Service' => service, 'State' => 'running', 'Health' => 'healthy' } }
      rows = ready + [{ 'Service' => 'migrate', 'State' => 'exited', 'ExitCode' => 0 }]
      [JSON.generate(rows), rows.map { |row| JSON.generate(row) }.join("\n")].each do |text|
        Core::GitService.stub(:run_command, ->(*_args, **_options) { [text, '', FakeStatus.new(true)] }) do
          assert Core::GitService.compose_services_ready?(directory, file, %w[app proxy scheduler])
          refute Core::GitService.compose_recovery_required?(directory, file, %w[app proxy scheduler])
        end
      end
      [ready.drop(1), ready.reject { |row| row['Service'] == 'scheduler' },
       ready.map { |row| row['Service'] == 'app' ? row.merge('Health' => 'unhealthy') : row },
       ready.map { |row| row['Service'] == 'scheduler' ? row.merge('State' => 'exited') : row }].each do |unready|
        Core::GitService.stub(:run_command, ->(*_args, **_options) { [JSON.generate(unready), '', FakeStatus.new(true)] }) do
          refute Core::GitService.compose_services_ready?(directory, file, %w[app proxy scheduler])
        end
      end
      [ready.drop(1), ready.reject { |row| row['Service'] == 'scheduler' },
       ready.map { |row| row['Service'] == 'scheduler' ? row.merge('State' => 'exited') : row }].each do |recoverable|
        Core::GitService.stub(:run_command, ->(*_args, **_options) { [JSON.generate(recoverable), '', FakeStatus.new(true)] }) do
          assert Core::GitService.compose_recovery_required?(directory, file, %w[app proxy scheduler])
        end
      end
      Core::GitService.stub(:run_command, ->(*_args, **_options) { ['invalid', '', FakeStatus.new(true)] }) do
        assert_raises(RuntimeError) { Core::GitService.compose_services_ready?(directory, file, %w[app]) }
      end
    end
  end

  def test_unchanged_supervised_release_is_prepared_again_before_recovery_and_only_recorded_after_health
    [true, false].each do |recovers|
      Dir.mktmpdir do |directory|
        file = File.join(directory, 'compose.json'); File.write(file, '{}')
        marker = File.join(directory, 'deployment.head')
        File.write(marker, 'previous healthy release')
        service = { name: 'fixture', local_path: directory, use_compose: true, compose_file: file,
                    compose_readiness_services: %w[app proxy scheduler], build_cmd: 'prepare',
                    release_environment: true, after_deploy_command: 'record', deployment_marker_path: marker }
        events = []
        prepare = ->(location, command, **_options) { events << [command, location] }
        up = ->(_location, **options) { events << ['recover', options] }
        Core::GitService.stub(:prepare_release, { head: 'a' * 40, cloned: false }) do
          Core::GitService.stub(:deployment_required?, false) do
            Core::GitService.stub(:compose_recovery_required?, true) do
              Core::GitService.stub(:compose_services_ready?, recovers) do
                Core::GitService.stub(:with_release_snapshot, ->(_path, _sha, &block) { block.call('/verified-archive') }) do
                  Core::GitService.stub(:run_build_command, prepare) do
                    Core::GitService.stub(:run_command, ->(*_args, **_options) { ["surviving-proxy\n", '', FakeStatus.new(true)] }) do
                      Core::GitService.stub(:docker_compose_up, up) do
                        if recovers
                          assert Core::GitService.update_git_service(service)
                        else
                          assert_raises(RuntimeError) { Core::GitService.update_git_service(service) }
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
        assert_equal ['prepare', '/verified-archive'], events.first
        assert_equal({ force_recreate: false, compose_file: file }, events[1][1])
        assert_equal(recovers ? %w[prepare recover record] : %w[prepare recover], events.map(&:first))
        if recovers
          refute_equal 'previous healthy release', File.read(marker)
        else
          assert_equal 'previous healthy release', File.read(marker)
        end
      end
    end
  end

  def test_unhealthy_running_scheduler_never_restarts_healthy_companions_on_repeated_heartbeats
    Dir.mktmpdir do |directory|
      file = File.join(directory, 'compose.json'); File.write(file, '{}')
      marker = File.join(directory, 'deployment.head'); File.write(marker, 'healthy release')
      service = { name: 'fixture', local_path: directory, use_compose: true, compose_file: file,
                  compose_readiness_services: %w[app proxy scheduler], build_cmd: 'prepare',
                  release_environment: true, after_deploy_command: 'record', deployment_marker_path: marker }
      rows = %w[app proxy scheduler].map do |name|
        { 'Service' => name, 'State' => 'running', 'Health' => name == 'scheduler' ? 'unhealthy' : 'healthy' }
      end
      Core::GitService.stub(:prepare_release, { head: 'a' * 40, cloned: false }) do
        Core::GitService.stub(:deployment_required?, false) do
          Core::GitService.stub(:run_command, ->(*_args, **_options) { [JSON.generate(rows), '', FakeStatus.new(true)] }) do
            Core::GitService.stub(:with_release_snapshot, ->(*) { flunk 'unhealthy scheduler triggered release/restart' }) do
              2.times do
                error = assert_raises(RuntimeError) { Core::GitService.update_git_service(service) }
                assert_includes error.message, 'scheduler is not healthy'
              end
            end
          end
        end
      end
      assert_equal 'healthy release', File.read(marker)
    end
  end
end

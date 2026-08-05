require 'tmpdir'
require_relative 'test_helper'
require_relative '../lib/git_service'

class GitServiceTest < Minitest::Test
  FakeStatus = Struct.new(:success?)
  ReleaseResponse = Struct.new(:body)

  class FakeHttp
    attr_accessor :use_ssl, :open_timeout, :read_timeout, :write_timeout

    def request(_request)
      ReleaseResponse.new('{"tag_name":"v1.2.3"}')
    end
  end

  def test_branch_pull_is_explicitly_fast_forward_only
    commands = []
    runner = lambda do |*arguments, **_options|
      commands << arguments
      ['', '', FakeStatus.new(true)]
    end

    Dir.mktmpdir do |directory|
      capture_output do
        Core::CommandRunner.stub(:capture3, runner) do
          Core::GitService.pull_latest(directory, 'main')
        end
      end
    end

    assert_includes commands, ['git', 'fetch', 'origin', 'main']
    assert_includes commands, ['git', 'checkout', 'main']
    assert_includes commands, ['git', 'pull', '--ff-only', 'origin', 'main']
  end

  def test_postcard_is_pinned_and_has_a_healthcheck
    postcard = Config::GIT_SERVICES.find { |service| service[:name] == 'postcard' }

    assert_equal 'main', postcard[:branch]
    assert_includes postcard.dig(:container_config, :healthcheck, :test), '/.postcard'
  end

  def test_plausible_compose_services_have_bounded_logs
    plausible = Config::GIT_SERVICES.find { |service| service[:name] == 'plausible' }

    %i[plausible_db plausible_events_db plausible].each do |name|
      logging = plausible.dig(:compose_override, :services, name, :logging)
      assert_equal 'local', logging[:driver]
      assert_equal({ 'max-size' => '10m', 'max-file' => '3' }, logging[:options])
    end
  end

  def test_stopped_git_service_container_is_removed_before_start
    events = []
    service = {
      name: 'fixture',
      repo_url: 'https://example.com/fixture.git',
      local_path: nil,
      branch: 'main',
      auto_update: true,
      container_config: { image_name: 'fixture' }
    }

    Dir.mktmpdir do |directory|
      service[:local_path] = directory
      service[:deployment_marker_path] = File.join(directory, 'marker')
      capture_output do
        Core::GitService.stub(:has_changes?, false) do
          Core::GitService.stub(:current_head, 'head') do
            Core::GitService.stub(:build_docker_image, true) do
              Core::GitService.stub(:image_exists?, true) do
                Core::DockerService.stub(:container_running?, false) do
                  Core::DockerService.stub(:stop_container, ->(name) { events << [:stop, name] }) do
                    Core::DockerService.stub(:start_container, ->(config) { events << [:start, config[:name]] }) do
                      Core::GitService.update_git_service(service)
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    assert_equal [[:stop, 'fixture'], [:start, 'fixture']], events
  end

  def test_docker_build_never_receives_runtime_secrets_as_build_args
    command = nil
    runner = lambda do |*arguments, **_options|
      command = arguments
      ['', '', FakeStatus.new(true)]
    end

    Dir.mktmpdir do |directory|
      Core::CommandRunner.stub(:capture3, runner) do
        Core::GitService.build_docker_image(directory, 'postcard')
      end
    end

    assert_equal ['docker', 'build', '-t', 'postcard', '.'], command
    refute_includes command.join(' '), 'SECRET'
    refute_includes command, '--build-arg'
  end

  def test_single_container_env_is_external_private_and_legacy_copy_is_removed
    Dir.mktmpdir do |directory|
      repo = File.join(directory, 'repo')
      runtime_env = File.join(directory, 'runtime', 'postcard.env')
      FileUtils.mkdir_p(repo)
      File.binwrite(File.join(repo, '.env'), 'LEGACY=secret')
      service = {
        name: 'postcard',
        repo_url: 'https://example.com/postcard.git',
        local_path: repo,
        branch: 'main',
        auto_update: true,
        env_config: 'SECRET=runtime-only',
        deployment_marker_path: File.join(directory, 'postcard.head'),
        container_config: { image_name: 'postcard' }
      }
      started_config = nil

      capture_output do
        Core::GitService.stub(:has_changes?, false) do
          Core::GitService.stub(:current_head, 'head') do
            Core::GitService.stub(:runtime_env_path, runtime_env) do
              Core::GitService.stub(:build_docker_image, true) do
                Core::GitService.stub(:image_exists?, true) do
                  Core::DockerService.stub(:container_running?, false) do
                    Core::DockerService.stub(:stop_container, true) do
                      Core::DockerService.stub(:start_container, ->(config) { started_config = config }) do
                        Core::GitService.update_git_service(service)
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end

      assert_equal runtime_env, started_config[:env_file]
      refute runtime_env.start_with?("#{repo}/")
      assert_equal 0o600, File.stat(runtime_env).mode & 0o777
      refute File.exist?(File.join(repo, '.env'))
      assert_equal 'SECRET=runtime-only', File.binread(runtime_env)
    end
  end

  def test_failed_deployment_retries_same_head_until_marker_is_written
    Dir.mktmpdir do |directory|
      repo = File.join(directory, 'repo')
      FileUtils.mkdir_p(repo)
      service = {
        name: 'fixture',
        repo_url: 'https://example.com/fixture.git',
        local_path: repo,
        branch: 'main',
        auto_update: true,
        build_cmd: 'build',
        deployment_marker_path: File.join(directory, 'fixture.head')
      }
      attempts = 0
      builder = lambda do |_path, _command|
        attempts += 1
        raise 'build failed' if attempts == 1
      end

      Core::GitService.stub(:has_changes?, false) do
        Core::GitService.stub(:current_head, 'same-head') do
          Core::GitService.stub(:run_build_command, builder) do
            assert_raises(RuntimeError) { Core::GitService.update_git_service(service) }
            refute File.exist?(service[:deployment_marker_path])
            Core::GitService.update_git_service(service)
            assert File.exist?(service[:deployment_marker_path])
            Core::GitService.update_git_service(service)
          end
        end
      end

      assert_equal 2, attempts
    end
  end

  def test_unhealthy_container_does_not_mark_deployment_successful
    Dir.mktmpdir do |directory|
      repo = File.join(directory, 'repo')
      FileUtils.mkdir_p(repo)
      marker = File.join(directory, 'postcard.head')
      service = {
        name: 'postcard',
        repo_url: 'https://example.com/postcard.git',
        local_path: repo,
        branch: 'main',
        auto_update: true,
        deployment_marker_path: marker,
        container_config: {
          image_name: 'postcard',
          healthcheck: { test: 'curl http://127.0.0.1:3000/.postcard' }
        }
      }

      capture_output do
        Core::GitService.stub(:has_changes?, false) do
          Core::GitService.stub(:current_head, 'same-head') do
            Core::GitService.stub(:build_docker_image, true) do
              Core::GitService.stub(:image_exists?, true) do
                Core::DockerService.stub(:container_running?, false) do
                  Core::DockerService.stub(:stop_container, true) do
                    Core::DockerService.stub(:start_container, true) do
                      Core::DockerService.stub(:wait_for_healthy, 'unhealthy') do
                        error = assert_raises(RuntimeError) do
                          Core::GitService.update_git_service(service)
                        end
                        assert_includes error.message, 'failed readiness'
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end

      refute File.exist?(marker)
    end
  end

  def test_compose_yml_override_change_forces_recreation
    Dir.mktmpdir do |directory|
      repo = File.join(directory, 'repo')
      FileUtils.mkdir_p(File.join(repo, '.git'))
      File.binwrite(File.join(repo, 'compose.yml'), "services: {}\n")
      service = {
        name: 'plausible',
        repo_url: 'https://example.com/plausible.git',
        local_path: repo,
        branch: 'main',
        auto_update: false,
        deployment_marker_path: File.join(directory, 'plausible.head'),
        compose_override: { services: { plausible: { logging: { driver: 'local' } } } }
      }
      compose_calls = []
      status_runner = ->(*_arguments, **_options) { ["container-id\n", '', FakeStatus.new(true)] }

      capture_output do
        Core::GitService.stub(:current_head, 'head') do
          Core::GitService.stub(:run_command, status_runner) do
            Core::GitService.stub(:docker_compose_up, ->(path, force_recreate:) { compose_calls << [path, force_recreate] }) do
              Core::GitService.update_git_service(service)
              Core::GitService.update_git_service(service)
            end
          end
        end
      end

      assert_equal File.join(repo, 'compose.yml'), Core::GitService.compose_file_path(repo)
      assert_equal [[repo, true]], compose_calls
      override = YAML.safe_load_file(File.join(repo, 'compose.override.yml'))
      assert_equal 'local', override.dig('services', 'plausible', 'logging', 'driver')
      assert_equal 0o600, File.stat(File.join(repo, 'compose.override.yml')).mode & 0o777
    end
  end

  def test_compose_up_failure_is_propagated
    runner = ->(*_arguments, **_options) { ['', 'compose failed', FakeStatus.new(false)] }

    Dir.mktmpdir do |directory|
      error = Core::CommandRunner.stub(:capture3, runner) do
        assert_raises(RuntimeError) { Core::GitService.docker_compose_up(directory) }
      end
      assert_includes error.message, 'compose failed'
    end
  end

  def test_release_lookup_has_http_timeouts
    http = FakeHttp.new

    capture_output do
      Net::HTTP.stub(:new, http) do
        assert_equal 'v1.2.3', Core::GitService.get_latest_release_tag('https://github.com/example/repo.git')
      end
    end

    assert_equal Core::GitService::HTTP_OPEN_TIMEOUT, http.open_timeout
    assert_equal Core::GitService::HTTP_READ_TIMEOUT, http.read_timeout
    assert_equal Core::GitService::HTTP_WRITE_TIMEOUT, http.write_timeout
  end
end

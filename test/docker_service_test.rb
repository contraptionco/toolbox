require_relative 'test_helper'
require_relative '../lib/docker_service'
require 'tmpdir'

class DockerServiceTest < Minitest::Test
  FakeStatus = Struct.new(:success?)

  def test_docker_run_has_bounded_logs_and_healthcheck
    captured = nil
    runner = lambda do |*arguments, **options|
      captured = [arguments, options]
      ['container-id', '', FakeStatus.new(true)]
    end
    config = {
      name: 'postcard',
      image: 'postcard',
      env_file: '/runtime/postcard.env',
      environment: { TOKEN: 'secret' },
      cmd: 'bundle exec puma',
      healthcheck: {
        test: 'curl --fail http://127.0.0.1:3000/.postcard',
        interval: '30s',
        timeout: '5s',
        retries: 3,
        start_period: '30s'
      }
    }

    capture_output do
      Core::OnePassword.stub(:resolve_env_vars, { TOKEN: 'secret' }) do
        Core::CommandRunner.stub(:capture3, runner) do
          Core::DockerService.start_container(config)
        end
      end
    end

    command, options = captured
    assert_equal 'docker', command.first
    assert_sequence command, '--log-driver', 'local'
    assert_sequence command, '--log-opt', 'max-size=10m'
    assert_sequence command, '--log-opt', 'max-file=3'
    assert_sequence command, '--env-file', '/runtime/postcard.env'
    assert_sequence command, '--health-cmd', config[:healthcheck][:test]
    assert_sequence command, '--health-start-period', '30s'
    assert_equal 'Docker container start', options[:label]
  end

  def test_stopped_container_is_found_and_removed_without_stopping_again
    commands = []
    runner = lambda do |*arguments, **_options|
      commands << arguments
      case arguments[1]
      when 'ps'
        ["container-id\n", '', FakeStatus.new(true)]
      when 'inspect'
        ["false\n", '', FakeStatus.new(true)]
      when 'rm'
        ['', '', FakeStatus.new(true)]
      else
        flunk "Unexpected command: #{arguments.inspect}"
      end
    end

    capture_output do
      Core::CommandRunner.stub(:capture3, runner) do
        Core::DockerService.stop_container('postcard')
      end
    end

    lookup = commands.find { |command| command[1] == 'ps' }
    assert_includes lookup, '-a'
    refute commands.any? { |command| command[1] == 'stop' }
    assert commands.any? { |command| command[1] == 'rm' }
  end

  def test_readiness_poll_waits_for_healthy
    statuses = %w[starting starting healthy]
    sleeps = []

    result = Core::DockerService.stub(:container_health_status, ->(_name) { statuses.shift }) do
      Core::DockerService.wait_for_healthy(
        'postcard',
        timeout: 10,
        interval: 0.01,
        sleeper: ->(seconds) { sleeps << seconds }
      )
    end

    assert_equal 'healthy', result
    assert_equal 2, sleeps.length
  end

  def test_logging_inspection_requires_local_caps
    calls = 0
    runner = lambda do |*arguments, **_options|
      calls += 1
      if arguments[1] == 'ps'
        ["container-id\n", '', FakeStatus.new(true)]
      else
        ['{"Type":"local","Config":{"max-size":"10m","max-file":"3"}}', '', FakeStatus.new(true)]
      end
    end

    compliant = Core::CommandRunner.stub(:capture3, runner) do
      Core::DockerService.container_logging_compliant?('postcard')
    end

    assert compliant
    assert_equal 2, calls
  end

  def test_standalone_container_recreates_to_apply_logging_caps
    events = []
    config = { name: 'postgres', image: 'postgres:latest' }

    capture_output do
      Core::DockerService.stub(:container_running?, true) do
        Core::DockerService.stub(:get_container_id, 'container-id') do
          Core::DockerService.stub(:get_container_image_details, { full_name: 'postgres:latest', id: 'old' }) do
            Core::DockerService.stub(:container_logging_compliant?, false) do
              Core::DockerService.stub(:stop_container, ->(name) { events << [:stop, name] }) do
                Core::DockerService.stub(:start_container, ->(service) { events << [:start, service[:name]] }) do
                  Core::DockerService.ensure_container_running(config)
                end
              end
            end
          end
        end
      end
    end

    assert_equal [[:stop, 'postgres'], [:start, 'postgres']], events
  end

  def test_old_unused_images_and_build_cache_are_pruned_at_most_daily
    commands = []
    runner = lambda do |*arguments, **_options|
      commands << arguments
      ['', '', FakeStatus.new(true)]
    end

    Dir.mktmpdir do |directory|
      marker = File.join(directory, 'prune.last_success')
      now = Time.at(1_800_000_000)
      capture_output do
        Core::CommandRunner.stub(:capture3, runner) do
          assert Core::DockerService.prune_old_cache(marker_path: marker, now: now)
          refute Core::DockerService.prune_old_cache(marker_path: marker, now: now + 60)
        end
      end

      assert_equal 2, commands.length
      assert_equal ['docker', 'image', 'prune', '--all', '--force', '--filter', 'until=168h'], commands[0]
      assert_equal ['docker', 'builder', 'prune', '--all', '--force', '--filter', 'until=168h'], commands[1]
      assert_equal 0o600, File.stat(marker).mode & 0o777
    end
  end

  def test_failed_prune_does_not_write_success_marker
    runner = ->(*_arguments, **_options) { ['', 'daemon failed', FakeStatus.new(false)] }

    Dir.mktmpdir do |directory|
      marker = File.join(directory, 'prune.last_success')
      capture_output do
        Core::CommandRunner.stub(:capture3, runner) do
          assert_raises(RuntimeError) do
            Core::DockerService.prune_old_cache(marker_path: marker)
          end
        end
      end
      refute File.exist?(marker)
    end
  end

  private

  def assert_sequence(command, *sequence)
    index = command.each_index.find { |candidate| command[candidate, sequence.length] == sequence }
    refute_nil index, "Expected #{command.inspect} to include #{sequence.inspect}"
  end
end

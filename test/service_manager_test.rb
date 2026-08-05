require_relative 'test_helper'
require_relative '../lib/service_manager'

class ServiceManagerTest < Minitest::Test
  def test_git_service_failures_do_not_block_later_services
    original = Config::GIT_SERVICES.dup
    Config::GIT_SERVICES.replace([{ name: 'first' }, { name: 'second' }])
    calls = []
    updater = lambda do |service|
      calls << service[:name]
      raise 'first failed' if service[:name] == 'first'
    end

    failures = nil
    capture_output do
      Core::GitService.stub(:update_git_service, updater) do
        failures = Core::ServiceManager.start_git_services
      end
    end

    assert_equal %w[first second], calls
    assert_equal ['git:first'], failures.map { |failure| failure[:component] }
  ensure
    Config::GIT_SERVICES.replace(original) if original
  end

  def test_failures_suppress_uptime_and_scripts_run_before_git_deploys
    events = []
    script_failure = { component: 'script:postgres_backup', error: StandardError.new('backup failed') }
    git_failure = { component: 'git:postcard', error: StandardError.new('deploy failed') }
    disk_status = Core::DiskMonitor::Status.new(percent_used: 50, level: :ok)

    error = capture_output do
      Core::ServiceManager.stub(:ensure_prerequisites, -> { events << :prerequisites }) do
        Core::ServiceManager.stub(:handle_tunnel, ->(_changed) { events << :tunnel }) do
          Core::ServiceManager.stub(:start_system_services, -> { events << :system }) do
            Core::ServiceManager.stub(:start_docker_services, -> { events << :docker }) do
              Core::ServiceManager.stub(:prune_docker_cache, -> { events << :prune; [] }) do
                Core::ServiceManager.stub(:run_scripts, -> { events << :scripts; [script_failure] }) do
                  Core::ServiceManager.stub(:start_git_services, -> { events << :git; [git_failure] }) do
                    Core::ServiceManager.stub(:configured_healthcheck_failures, []) do
                      Core::ServiceManager.stub(:report_uptime, -> { events << :uptime; true }) do
                        Core::DiskMonitor.stub(:check, disk_status) do
                          assert_raises(Core::ServiceManager::RunFailed) do
                            Core::ServiceManager.start_all
                          end
                        end
                      end
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    assert_operator events.index(:prune), :<, events.index(:docker)
    assert_operator events.index(:scripts), :<, events.index(:git)
    refute_includes events, :uptime
    assert error
  end

  def test_unhealthy_configured_container_is_a_failure
    failures = nil

    capture_output do
      Core::DockerService.stub(:wait_for_healthy, 'unhealthy') do
        failures = Core::ServiceManager.configured_healthcheck_failures
      end
    end

    assert_includes failures.map { |failure| failure[:component] }, 'health:postcard'
  end

  def test_critical_preflight_stops_before_write_heavy_work
    critical = Core::DiskMonitor::Status.new(percent_used: 95, level: :critical)
    prerequisites_started = false

    capture_output do
      Core::DiskMonitor.stub(:check, critical) do
        Core::ServiceManager.stub(:ensure_prerequisites, -> { prerequisites_started = true }) do
          assert_raises(Core::ServiceManager::RunFailed) do
            Core::ServiceManager.start_all
          end
        end
      end
    end

    refute prerequisites_started
  end
end

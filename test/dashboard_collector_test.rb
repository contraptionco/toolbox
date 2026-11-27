require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/dashboard/collector'

class DashboardCollectorTest < Minitest::Test
  GIB = 1024**3
  POSTCARD_ID = 'a' * 64
  OTHER_ID = 'b' * 64
  HELPER_ID = 'c' * 64
  EXITED_ID = 'd' * 64
  HEAD = 'e' * 40
  IMAGE_ID = 'sha256:' + '1' * 64
  OTHER_IMAGE_ID = 'sha256:' + '2' * 64

  class FakeRunner
    Status = Struct.new(:exitstatus) do
      def success?
        exitstatus == 0
      end
    end
    attr_reader :calls

    def initialize
      @responses = {}
      @calls = []
    end

    def add(argv, stdout, success: true, stderr: '', exitstatus: nil)
      @responses[argv] = [stdout, stderr, Status.new(exitstatus || (success ? 0 : 1))]
    end

    def capture3(*argv, **options)
      @calls << [argv, options]
      raise "Unexpected command in hermetic test: #{argv.inspect}" unless @responses.key?(argv)

      response = @responses.fetch(argv)
      raise response if response.is_a?(Exception)

      response
    end
  end

  def setup
    @directory = Dir.mktmpdir('dashboard-collector-test')
    @now = Time.utc(2026, 11, 2, 20, 0, 0)
    @runner = FakeRunner.new
    @config = Module.new
    @config.const_set(:HOME_DIR, @directory)
    @config.const_set(:DOCKER_SERVICES, [{ name: 'postgres', environment: { password: 'should-never-appear' } }])
    @config.const_set(:GIT_SERVICES, [{ name: 'postcard', container_config: { image_name: 'postcard' }, env_config: 'secret' }])
    @config.const_set(:SYSTEM_SERVICES, [{ name: 'netdata', cmd: 'never-run' }])
    @collector = Dashboard::Collector.new(repo_dir: @directory, config: @config, runner: @runner,
                                          clock: -> { @now }, hostname: 'Mac mini', platform: 'arm64-darwin',
                                          docker_disk_path: File.join(@directory, 'Docker.raw'))
    stub_host
    stub_inventory
    stub_deployment
  end

  def teardown
    FileUtils.remove_entry(@directory)
  end

  def test_snapshot_has_host_metrics_without_double_counting_reclaimable_storage
    result = @collector.snapshot
    disk = result.fetch(:host).fetch(:disk)
    assert_equal 500 * GIB, disk[:total_bytes]
    assert_equal 34 * GIB, disk[:free_bytes]
    assert_equal 220 * GIB, disk[:available_bytes]
    assert_equal 93, disk[:used_percent]
    assert_equal 56, disk[:effective_used_percent]
    assert_equal 'warning', disk[:level]
    assert disk[:reclaimable_available]
    assert_equal [0.4, 0.6, 0.8], result[:host][:load_average]
    assert_equal 8, result[:host][:cpu_count]
    assert_equal 7200, result[:host][:uptime_seconds]
    assert_equal 6 * GIB, result[:host][:memory][:available_bytes]
    assert_equal 10 * GIB, result[:host][:memory][:used_bytes]
    assert_empty result[:errors]
    refute_includes JSON.generate(result), 'should-never-appear'
    refute_includes JSON.generate(result), 'never-run'
  end

  def test_explicit_compose_containers_are_observed_without_service_commands
    @config.const_set(:COMPOSE_APPLICATIONS, [{ name: 'external-project', containers: ['forgotten-app'] }])
    collector = Dashboard::Collector.new(repo_dir: @directory, config: @config, runner: @runner,
                                         clock: -> { @now }, hostname: 'Mac mini', platform: 'arm64-darwin',
                                         docker_disk_path: File.join(@directory, 'Docker.raw'))
    result = collector.snapshot
    assert result[:containers].find { |item| item[:name] == 'forgotten-app' }[:configured]
    refute result[:warnings].any? { |line| line.include?('forgotten-app') }
    assert result[:applications].any? { |item| item[:name] == 'forgotten-app' && item[:status] == 'running' }
  end

  def test_optional_companion_is_only_expected_after_runtime_provisioning
    marker = File.join(@directory, 'analytics')
    @config.const_set(:COMPOSE_APPLICATIONS, [{ name: 'analytics', containers: ['analytics'], enabled_if: marker }])
    refute @collector.send(:configured_applications).any? { |item| item[:name] == 'analytics' }
    Dir.mkdir(marker)
    assert @collector.send(:configured_applications).any? { |item| item[:name] == 'analytics' }
  end

  def test_runtime_capability_changes_refresh_without_restarting_the_collector
    collector = bully_pulpit_collector
    stub_bully_inventory
    before = collector.snapshot
    refute before[:containers].find { |row| row[:name] == 'bully-pulpit-production-analytics' }[:configured]
    assert_includes before[:warnings], 'Running container bully-pulpit-production-analytics is not configured in Toolbox.'

    write_bully_runtime
    result = collector.snapshot
    assert result[:containers].find { |row| row[:name] == 'bully-pulpit-production-analytics' }[:configured]
    assert_equal 'running', result[:applications].find { |row| row[:name] == 'bully-pulpit-production-analytics' }[:status]
    %w[bully-pulpit bully-pulpit-postgres bully-pulpit-proxy].each do |name|
      assert_equal 'standby', result[:applications].find { |row| row[:name] == name }[:status]
      refute_includes result[:warnings], "Configured application #{name} is not running."
    end
    assert_equal 'exited', result[:containers].find { |row| row[:name] == 'bully-pulpit' }[:state]
    refute result[:warnings].any? { |warning| warning.include?('production-analytics') }
    refute_includes JSON.generate(result), 'private-record-value'
    assert_empty result[:errors]
  end

  def test_analytics_requires_current_recorded_capability_not_a_preserved_data_directory
    collector = bully_pulpit_collector
    stub_bully_inventory
    write_bully_runtime
    assert collector.snapshot[:containers].find { |row| row[:name] == 'bully-pulpit-production-analytics' }[:configured]
    write_bully_runtime(analytics: false)
    assert Dir.exist?(File.join(@bully_runtime, 'analytics'))
    result = collector.snapshot
    refute result[:applications].any? { |row| row[:name] == 'bully-pulpit-production-analytics' }
    assert_includes result[:warnings], 'Running container bully-pulpit-production-analytics is not configured in Toolbox.'

    write_bully_runtime
    manifest = JSON.parse(File.read(File.join(@bully_runtime, 'compose.json')))
    manifest['x-toolbox-required-services'].delete('analytics')
    File.write(File.join(@bully_runtime, 'compose.json'), JSON.generate(manifest))
    refute collector.snapshot[:containers].find { |row| row[:name] == 'bully-pulpit-production-analytics' }[:configured]
  end

  def test_primary_standby_does_not_hide_production_failures_or_running_unhealthy_pilot
    collector = bully_pulpit_collector
    write_bully_runtime
    stub_bully_inventory(production: false, analytics: false)
    result = collector.snapshot
    assert_includes result[:warnings], 'Configured application bully-pulpit-production is not running.'
    assert_includes result[:warnings], 'Configured application bully-pulpit-production-analytics is not running.'
    assert_equal 'standby', result[:applications].find { |row| row[:name] == 'bully-pulpit' }[:status]

    stub_bully_inventory(pilot_state: 'running', pilot_health: 'unhealthy')
    result = collector.snapshot
    assert_equal 'running', result[:applications].find { |row| row[:name] == 'bully-pulpit' }[:status]
    assert_includes result[:warnings], 'Container bully-pulpit is unhealthy.'
  end

  def test_missing_malformed_or_mismatched_activation_never_suppresses_pilot_failures
    collector = bully_pulpit_collector
    stub_bully_inventory
    mutations = [
      -> { File.delete(File.join(@bully_runtime, 'primary.json')) },
      -> { File.write(File.join(@bully_runtime, 'primary.json'), JSON.generate(copy_sha256: 'b' * 64)) },
      -> { File.write(File.join(@bully_runtime, 'deployment.json'), '{') },
      -> { File.write(File.join(@bully_runtime, 'deployment.json'), 'x' * 16_385) },
      -> { File.write(File.join(@bully_runtime, 'database-copy.json'), JSON.generate(verified: false, application_database: 'bully_pulpit', source_sha256: 'a' * 64)) },
      -> { File.write(File.join(@bully_runtime, 'enabled.json'), JSON.generate(copy_sha256: 'c' * 64)) },
      -> { File.rename(File.join(@bully_runtime, 'primary.json'), File.join(@bully_runtime, 'outside.json')); File.symlink(File.join(@bully_runtime, 'outside.json'), File.join(@bully_runtime, 'primary.json')) },
      -> { write_bully_runtime(role: 'parallel') }
    ]
    mutations.each do |mutate|
      FileUtils.rm_f(File.join(@bully_runtime, 'primary.json'))
      write_bully_runtime
      mutate.call
      result = collector.snapshot
      assert_equal 'stopped', result[:applications].find { |row| row[:name] == 'bully-pulpit' }[:status]
      assert_includes result[:warnings], 'Configured application bully-pulpit is not running.'
    end
  end

  def test_activation_records_do_not_turn_failed_inventory_into_standby_or_running
    collector = bully_pulpit_collector
    write_bully_runtime
    @runner.add(['docker', 'ps', '-a', '--no-trunc', '--format', Dashboard::Collector::PS_FORMAT], '', success: false)
    result = collector.snapshot
    assert result[:applications].select { |row| row[:type] == 'docker' }.all? { |row| row[:status] == 'unknown' }
    assert_includes result[:errors], { source: 'Docker inventory', message: 'Temporarily unavailable' }
    refute result[:warnings].any? { |warning| warning.include?('not running') }
  end

  def test_container_metrics_use_only_safe_inspect_fields_and_flag_unconfigured_running
    result = @collector.snapshot
    postcard = result[:containers].find { |item| item[:name] == 'postcard' }
    assert postcard[:configured]
    assert_equal 'postcard', postcard[:application]
    assert_equal 15.5, postcard[:cpu_percent]
    assert_equal 512 * 1024**2, postcard[:memory_bytes]
    assert_equal 2 * GIB, postcard[:memory_limit_bytes]
    assert_equal 1200, postcard[:network_rx_bytes]
    assert_equal 2_500_000, postcard[:network_tx_bytes]
    assert_equal 4 * GIB, postcard[:block_write_bytes]
    assert_equal 'healthy', postcard[:health]
    assert_equal 2, postcard[:restarts]
    assert_equal 17, postcard[:pids]
    assert_includes result[:warnings], 'Running container forgotten-app is not configured in Toolbox.'
    refute result[:warnings].any? { |line| line.include?('toolbox-op-') || line.include?('old-app') }
    refute result[:log_sources].any? { |source| source[:id].include?('toolbox-op-') }
    assert_equal 'stopped', result[:applications].find { |app| app[:name] == 'postgres' }[:status]
    @runner.calls.each do |argv, options|
      assert_equal 8, options[:timeout]
      assert_operator options[:capture_limit], :<=, Dashboard::Collector::MAX_OUTPUT
      refute_match(/Config\.Env|\.Command|\.Health\.Log|launchctl|docker exec/, argv.join(' '))
    end
  end

  def test_disk_falls_back_conservatively_when_native_capacity_is_invalid
    @runner.add(native_capacity_command, '{"NSURLVolumeTotalCapacityKey":1,"NSURLVolumeAvailableCapacityKey":0,"NSURLVolumeAvailableCapacityForImportantUsageKey":1}')
    disk = @collector.snapshot[:host][:disk]
    assert_equal 35 * GIB, disk[:available_bytes]
    assert_equal 93, disk[:effective_used_percent]
    assert_equal 'critical', disk[:level]
    refute disk[:reclaimable_available]
  end

  def test_compose_app_uses_explicit_container_name_and_migration_is_managed_inventory
    collector = compose_collector
    stub_compose_inventory(app_running: true, migration_state: 'running')

    result = collector.snapshot
    app = result[:applications].find { |item| item[:name] == 'wiki' }
    assert_equal 'wiki-web-custom', app[:container_name]
    assert_equal 'running', app[:status]
    migration = result[:containers].find { |item| item[:name] == 'wiki-init-custom' }
    assert migration[:configured]
    assert migration[:one_shot]
    assert_equal 'wiki', migration[:application]
    refute result[:applications].any? { |item| item[:container_name] == 'wiki-init-custom' }
    refute result[:warnings].any? { |line| line.include?('wiki') }
    assert_includes result[:log_sources], { id: 'container:wiki-init-custom', label: 'wiki-init-custom' }
    assert_empty result[:errors]
  end

  def test_completed_or_absent_compose_migration_does_not_raise_stopped_warning
    collector = compose_collector
    ['exited', nil].each do |migration_state|
      stub_compose_inventory(app_running: true, migration_state: migration_state)
      result = collector.snapshot
      assert_equal 'running', result[:applications].find { |item| item[:name] == 'wiki' }[:status]
      refute result[:warnings].any? { |line| line.include?('wiki') }
      assert_empty result[:errors]
    end
  end

  def test_missing_compose_app_warns_even_when_migration_is_running
    collector = compose_collector
    stub_compose_inventory(app_running: false, migration_state: 'running')

    result = collector.snapshot
    assert_equal 'stopped', result[:applications].find { |item| item[:name] == 'wiki' }[:status]
    assert_includes result[:warnings], 'Configured application wiki is not running.'
    refute result[:warnings].any? { |line| line.include?('wiki-init-custom') }
    assert_empty result[:errors]
  end

  def test_immediate_free_reserve_cannot_be_satisfied_by_reclaimable_capacity
    @runner.add(native_capacity_command, JSON.generate('NSURLVolumeTotalCapacityKey' => 500 * GIB,
                                                       'NSURLVolumeAvailableCapacityKey' => 19 * GIB,
                                                       'NSURLVolumeAvailableCapacityForImportantUsageKey' => 220 * GIB))
    disk = @collector.snapshot[:host][:disk]
    assert_equal 'critical', disk[:level]
    assert_equal 19 * GIB, disk[:free_bytes]
  end

  def test_failed_inventory_reports_unknown_instead_of_claiming_services_stopped
    @runner.add(['docker', 'ps', '-a', '--no-trunc', '--format', Dashboard::Collector::PS_FORMAT], '', success: false, stderr: 'token=do-not-expose')
    result = @collector.snapshot
    assert_empty result[:containers]
    assert result[:applications].select { |app| app[:type] == 'docker' }.all? { |app| app[:status] == 'unknown' }
    assert_includes result[:errors], { source: 'Docker inventory', message: 'Temporarily unavailable' }
    refute_includes JSON.generate(result), 'do-not-expose'
    refute result[:warnings].any? { |line| line.include?('not running') }
  end

  def test_checkout_heartbeat_and_last_successful_revisions_are_distinct_evidence
    FileUtils.mkdir_p(File.join(@directory, '.runtime/deployments'))
    File.write(File.join(@directory, '.runtime/deployments/postcard.head'), "#{'a' * 40}\nprivate-configuration-digest\n")
    write_status(status: 'healthy', commit: 'b' * 40, finished_at: @now.iso8601)
    result = @collector.snapshot
    assert_equal HEAD, result[:deployment][:checkout_commit]
    assert_equal 'main', result[:deployment][:checkout_branch]
    assert_equal 'b' * 40, result[:deployment][:heartbeat_commit]
    app = result[:applications].find { |row| row[:name] == 'postcard' }
    assert_equal 'a' * 40, app[:commit]
    assert_equal 'a' * 40, app[:last_successful_commit]
    assert_equal IMAGE_ID, app[:running_image_id]
    assert_equal 'last_successful_only', app[:revision_evidence]
    assert_nil app[:running_commit]
    refute_includes JSON.generate(result), 'private-configuration-digest'
  end

  def test_recorded_app_revision_is_running_only_when_the_immutable_image_matches
    collector = bully_pulpit_collector
    write_bully_runtime
    stub_bully_inventory
    result = collector.snapshot
    %w[bully-pulpit-production bully-pulpit-production-analytics].each do |name|
      app = result[:applications].find { |row| row[:name] == name }
      assert_equal HEAD, app[:running_commit]
      assert_equal HEAD, app[:recorded_commit]
      assert_equal IMAGE_ID, app[:running_image_id]
      assert_equal IMAGE_ID, app[:recorded_image_id]
      assert_equal @now.iso8601, app[:deployed_at]
      assert_equal 'image_match', app[:revision_evidence]
    end
    pilot = result[:applications].find { |row| row[:name] == 'bully-pulpit' }
    assert_equal 'not_running', pilot[:revision_evidence]
    assert_nil pilot[:running_commit]
    assert_nil pilot[:running_image_id]
    assert_equal IMAGE_ID, result[:containers].find { |row| row[:name] == 'bully-pulpit' }[:image_id]
  end

  def test_mismatched_or_missing_running_image_never_claims_the_recorded_commit
    collector = bully_pulpit_collector
    write_bully_runtime
    stub_bully_inventory(production_image: OTHER_IMAGE_ID)
    app = collector.snapshot[:applications].find { |row| row[:name] == 'bully-pulpit-production' }
    assert_equal 'image_mismatch', app[:revision_evidence]
    assert_equal IMAGE_ID, app[:recorded_image_id]
    assert_equal OTHER_IMAGE_ID, app[:running_image_id]
    assert_equal HEAD, app[:recorded_commit]
    assert_nil app[:running_commit]

    [nil, 'sha256:short', 'private-image-value'].each do |image|
      stub_bully_inventory(production_image: image)
      result = collector.snapshot
      app = result[:applications].find { |row| row[:name] == 'bully-pulpit-production' }
      assert_equal 'unknown', app[:revision_evidence]
      assert_nil app[:running_commit]
      assert_nil app[:running_image_id]
      refute_includes JSON.generate(result), 'private-image-value'
    end
    stub_bully_inventory(production: false)
    app = collector.snapshot[:applications].find { |row| row[:name] == 'bully-pulpit-production' }
    assert_equal 'not_running', app[:revision_evidence]
    assert_nil app[:running_commit]
    assert_nil app[:running_image_id]
  end

  def test_full_revision_identifiers_are_required_and_inspection_failure_is_unknown
    ['f' * 39, 'f' * 41, 'f' * 63, 'private-invalid-revision'].each do |sha|
      write_status(status: 'healthy', commit: sha, finished_at: @now.iso8601)
      assert_nil @collector.snapshot[:deployment][:heartbeat_commit]
    end
    collector = bully_pulpit_collector
    write_bully_runtime
    stub_bully_inventory
    path = File.join(@bully_runtime, 'deployment.json')
    record = JSON.parse(File.read(path))
    record['application_sha'] = 'f' * 41
    File.write(path, JSON.generate(record))
    app = collector.snapshot[:applications].find { |row| row[:name] == 'bully-pulpit-production' }
    assert_equal 'unknown', app[:revision_evidence]
    assert_nil app[:running_commit]
    assert_nil app[:recorded_commit]

    write_bully_runtime
    @runner.add(['docker', 'inspect', '--format', Dashboard::Collector::INSPECT_FORMAT, POSTCARD_ID, OTHER_ID, EXITED_ID], '', success: false)
    result = collector.snapshot
    app = result[:applications].find { |row| row[:name] == 'bully-pulpit-production' }
    assert_equal 'unknown', app[:revision_evidence]
    assert_nil app[:running_commit]
    assert_nil app[:running_image_id]
    assert_includes result[:errors], { source: 'container state', message: 'Temporarily unavailable' }
  end

  def test_heartbeat_is_unknown_without_marker_and_reads_only_sha_from_app_marker
    FileUtils.mkdir_p(File.join(@directory, '.runtime/deployments'))
    File.write(File.join(@directory, '.runtime/deployments/postcard.head'), "#{HEAD}\nprivate-configuration-digest\n")
    result = @collector.snapshot
    assert_equal 'unknown', result[:deployment][:status]
    assert_equal HEAD, result[:deployment][:commit]
    assert_equal HEAD, result[:applications].find { |app| app[:name] == 'postcard' }[:commit]
    refute_includes JSON.generate(result), 'private-configuration-digest'
  end

  def test_heartbeat_success_becomes_stale_and_running_build_does_not_imply_healthy
    write_status(status: 'healthy', started_at: (@now - 650).iso8601, finished_at: (@now - 600).iso8601,
                 last_success_at: (@now - 600).iso8601, message: 'Services verified.', secret: 'never-include')
    result = @collector.snapshot
    assert_equal 'stale', result[:deployment][:status]
    assert_equal (@now - 600).iso8601, result[:deployment][:last_success_at]
    refute_includes JSON.generate(result), 'never-include'
    write_status(status: 'running', started_at: (@now - 600).iso8601, message: 'Deploying verified main.')
    assert_equal 'running', @collector.snapshot[:deployment][:status]
  end

  def test_malformed_heartbeat_cannot_claim_health
    write_status(status: 'healthy', message: 'token=concealed')
    result = @collector.snapshot
    assert_equal 'unknown', result[:deployment][:status]
    refute_includes result[:deployment][:message], 'concealed'
  end

  def test_native_dashboard_is_reported_running_without_exposing_access_configuration
    @config.const_set(:DASHBOARD, { enabled: true, hostname: 'toolbox.example.test', audience: 'private-not-metrics', issuer: 'irrelevant' })
    collector = Dashboard::Collector.new(repo_dir: @directory, config: @config, runner: @runner,
                                         clock: -> { @now }, platform: 'arm64-darwin', hostname: 'Mac mini')
    result = collector.snapshot
    dashboard = result[:applications].find { |app| app[:name] == 'toolbox' }
    assert_equal 'host', dashboard[:type]
    assert_equal 'running', dashboard[:status]
    assert_equal 'https://toolbox.example.test', dashboard[:url]
    refute_includes JSON.generate(result), 'private-not-metrics'
    refute @runner.calls.any? { |argv, _| argv.include?('never-run') }
  end

  def test_native_process_probes_use_fixed_names_and_do_not_return_process_details
    @config.const_set(:TUNNEL_CONFIG, { credentials: 'never-show', detection: 'never-run' })
    @config::SYSTEM_SERVICES << { name: 'other-service', detection: 'never-run' }
    @runner.add(['/usr/bin/pgrep', '-x', 'cloudflared'], "1234\n")
    collector = Dashboard::Collector.new(repo_dir: @directory, config: @config, runner: @runner,
                                         clock: -> { @now }, platform: 'arm64-darwin', hostname: 'Mac mini')
    result = collector.snapshot
    assert_equal 'running', result[:applications].find { |app| app[:name] == 'cloudflare-tunnel' }[:status]
    assert_equal 'running', result[:applications].find { |app| app[:name] == 'netdata' }[:status]
    assert_equal 'unknown', result[:applications].find { |app| app[:name] == 'other-service' }[:status]
    refute_includes JSON.generate(result), 'never-show'
    refute @runner.calls.any? { |argv, _| argv.include?('never-run') }
    @runner.add(['/usr/bin/pgrep', '-x', 'netdata'], '', success: false)
    assert_equal 'stopped', collector.snapshot[:applications].find { |app| app[:name] == 'netdata' }[:status]
    @runner.add(['/usr/bin/pgrep', '-x', 'netdata'], 'secret diagnostic', exitstatus: 2, stderr: 'password=secret')
    failed = collector.snapshot
    assert_equal 'unknown', failed[:applications].find { |app| app[:name] == 'netdata' }[:status]
    assert_includes failed[:errors], { source: 'netdata process', message: 'Temporarily unavailable' }
    refute_includes JSON.generate(failed), 'secret diagnostic'
  end

  def test_retired_native_services_are_not_listed_or_probed
    @config::SYSTEM_SERVICES.clear
    collector = Dashboard::Collector.new(repo_dir: @directory, config: @config, runner: @runner,
                                         clock: -> { @now }, platform: 'arm64-darwin', hostname: 'Mac mini')
    result = collector.snapshot
    refute result[:applications].any? { |app| app[:name] == 'netdata' }
    refute @runner.calls.any? { |argv, _| argv == ['/usr/bin/pgrep', '-x', 'netdata'] }
    assert_empty result[:errors]
  end

  def test_invalid_docker_json_types_cannot_escape_safe_errors
    [[], nil, 'secret', 7].each do |invalid|
      @runner.add(['docker', 'ps', '-a', '--no-trunc', '--format', Dashboard::Collector::PS_FORMAT], JSON.generate(invalid))
      result = @collector.snapshot
      assert_empty result[:containers]
      assert_includes result[:errors], { source: 'Docker inventory', message: 'Temporarily unavailable' }
      refute_includes JSON.generate(result), 'secret'
    end
  end

  def test_inventory_array_is_bounded_and_ignores_invalid_ids_and_names
    invalids = [{ id: 'hostile-id;echo', name: 'invalid', state: 'running' }, { id: 'f' * 64, name: '../../private', state: 'running' }]
    rows = (invalids + (1..200).map { |n| { id: format('%064x', n), name: "stopped-#{n}", state: 'exited', status: 'Exited', image: 'example' } }).map { |r| JSON.generate(r) }.join("\n")
    @runner.add(['docker', 'ps', '-a', '--no-trunc', '--format', Dashboard::Collector::PS_FORMAT], rows)
    ids = (1..126).map { |n| format('%064x', n) }
    @runner.add(['docker', 'inspect', '--format', Dashboard::Collector::INSPECT_FORMAT, *ids], '')
    result = @collector.snapshot
    assert_equal 126, result[:containers].length
    refute result[:containers].any? { |container| container[:name].include?('invalid') || container[:name].include?('private') }
    refute @runner.calls.any? { |argv, _| argv.include?('hostile-id;echo') }
  end

  def test_log_tail_limits_lines_and_redacts_sensitive_lines
    File.write(File.join(@directory, 'heartbeat.log'), (1..240).map { |n| "Line #{n}\n" }.join + "OP_SERVICE_ACCOUNT_TOKEN=private-value\n")
    result = @collector.logs('heartbeat', lines: 1000)
    assert_equal 200, result[:lines].length
    assert result[:truncated]
    assert_equal 'Line 42', result[:lines].first
    assert_equal '[sensitive log line omitted]', result[:lines].last
    refute_includes JSON.generate(result), 'private-value'
  end

  def test_tail_does_not_read_arbitrary_paths_or_follow_symlinks
    assert_raises(Dashboard::Collector::UnknownLogSource) { @collector.logs('../config.rb') }
    assert_raises(Dashboard::Collector::UnknownLogSource) { @collector.logs('container:postcard;whoami') }
    assert_empty @runner.calls
    File.write(File.join(@directory, 'private.env'), 'password=secret')
    File.symlink(File.join(@directory, 'private.env'), File.join(@directory, 'heartbeat.log'))
    assert_raises(Dashboard::Collector::Unavailable) { @collector.logs('heartbeat') }
  end

  def test_docker_logs_are_bounded_and_use_id_from_live_inventory
    @runner.add(['docker', 'logs', '--tail', '25', '--timestamps', POSTCARD_ID], 'Connected to postgres://user:password@db/app?token=opaquecredential', stderr: "user@example.com\n")
    result = @collector.logs('container:postcard', lines: 25)
    assert_equal 'container:postcard', result[:source]
    refute_includes result[:lines].join, 'password'
    refute_includes result[:lines].join, 'opaquecredential'
    refute_includes result[:lines].join, 'user@example.com'
    assert_equal Dashboard::Collector::LOG_BYTES, @runner.calls.last.last[:capture_limit]
    assert_raises(Dashboard::Collector::UnknownLogSource) { @collector.logs('container:unknown') }
    assert_raises(Dashboard::Collector::UnknownLogSource) { @collector.logs('container:toolbox-op-test') }
  end

  def test_docker_log_streams_merge_chronologically_before_selecting_latest_lines
    stdout = "2026-11-02T20:00:03.000000001Z stdout three\n2026-11-02T20:00:04.000000001Z stdout four\n2026-11-02T20:00:06.000000001Z stdout six\n"
    stderr = "2026-11-02T20:00:01.000000001Z stderr one\n2026-11-02T20:00:02.000000001Z stderr two\n2026-11-02T20:00:05.000000001Z stderr five\n"
    @runner.add(['docker', 'logs', '--tail', '3', '--timestamps', POSTCARD_ID], stdout, stderr: stderr)
    result = @collector.logs('container:postcard', lines: 3)
    assert_equal ['stdout four', 'stderr five', 'stdout six'], result[:lines].map { |line| line.split(' ', 2).last }
    assert result[:truncated]
    assert_equal Dashboard::Collector::LOG_BYTES, @runner.calls.last.last[:capture_limit]
  end

  def test_docker_log_merge_preserves_nanoseconds_continuations_and_safe_utf8
    stdout = "2026-11-02T20:00:00.000000002Z newest\ncontinued message\n".b
    stderr = "not timestamped\n2026-11-02T20:00:00.000000001Z older\nbad\xFF\n".b
    @runner.add(['docker', 'logs', '--tail', '6', '--timestamps', POSTCARD_ID], stdout, stderr: stderr)
    result = @collector.logs('container:postcard', lines: 6)
    assert_equal ['not timestamped', '2026-11-02T20:00:00.000000001Z older', 'bad�',
                  '2026-11-02T20:00:00.000000002Z newest', 'continued message'], result[:lines]
    assert result[:lines].all?(&:valid_encoding?)
    refute result[:truncated]
  end

  def test_docker_log_byte_limit_applies_after_merge_and_reports_capture_truncation
    log_line = ->(n) { "#{(@now + n).iso8601(9)} entry #{n}: #{'word ' * 290}\n" }
    stdout = (80..159).map(&log_line).join
    stderr = (0..79).map(&log_line).join
    @runner.add(['docker', 'logs', '--tail', '200', '--timestamps', POSTCARD_ID], stdout, stderr: stderr)
    result = @collector.logs('container:postcard')
    assert_operator JSON.generate(result[:lines]).bytesize, :<=, Dashboard::Collector::LOG_BYTES
    assert_includes result[:lines].last, 'entry 159:'
    assert result[:truncated]
    refute result[:lines].any? { |line| line.include?('entry 0:') }

    @runner.add(['docker', 'logs', '--tail', '200', '--timestamps', POSTCARD_ID], "#{log_line.call(1)}#{Core::CommandRunner::TRUNCATION_MARKER}", stderr: log_line.call(2))
    clipped = @collector.logs('container:postcard')
    assert clipped[:truncated]
    assert_equal 3, clipped[:lines].length
    refute clipped[:lines].any? { |line| line == Core::CommandRunner::TRUNCATION_MARKER.strip }
  end

  def test_large_line_is_bounded_and_does_not_return_partial_tail_prefix
    File.write(File.join(@directory, 'heartbeat.log'), "prefix #{'x' * (Dashboard::Collector::LOG_BYTES + 100)}\nretained\n")
    result = @collector.logs('heartbeat')
    assert_equal ['retained'], result[:lines]
    assert result[:truncated]
  end

  private

  def bully_pulpit_collector
    @bully_runtime = File.join(@directory, 'bully-runtime')
    FileUtils.mkdir_p(@bully_runtime)
    @config::GIT_SERVICES << {
      name: 'bully-pulpit-production', use_compose: true,
      compose_file: File.join(@bully_runtime, 'compose.json'),
      enabled_if: File.join(@bully_runtime, 'enabled.json'),
      compose_readiness_services: %w[app proxy scheduler], compose_optional_readiness_services: ['analytics'],
      dashboard: { container_name: 'bully-pulpit-production' }
    }
    @config.const_set(:COMPOSE_APPLICATIONS, [
      { name: 'bully-pulpit-pilot', containers: %w[bully-pulpit bully-pulpit-postgres bully-pulpit-proxy] },
      { name: 'bully-pulpit-production-analytics', containers: ['bully-pulpit-production-analytics'], enabled_if: File.join(@bully_runtime, 'analytics') }
    ])
    Dashboard::Collector.new(repo_dir: @directory, config: @config, runner: @runner,
      clock: -> { @now }, hostname: 'Mac mini', platform: 'arm64-darwin',
      docker_disk_path: File.join(@directory, 'Docker.raw'))
  end

  def write_bully_runtime(analytics: true, role: 'primary')
    FileUtils.mkdir_p(File.join(@bully_runtime, 'analytics'))
    digest = 'a' * 64
    manifest = { name: 'bully-pulpit-production', 'x-toolbox-required-services' => %w[app proxy scheduler] + (analytics ? ['analytics'] : []) }
    records = {
      'database-copy.json' => { verified: true, application_database: 'bully_pulpit', source_sha256: digest },
      'enabled.json' => { copy_sha256: digest }, 'primary.json' => { copy_sha256: digest },
      'compose.json' => manifest,
      'deployment.json' => { copy_sha256: digest, role: role, ready_at: @now.iso8601, compose: manifest, application_sha: HEAD, image: IMAGE_ID,
        analytics_protocol: analytics ? 1 : nil, private_field: 'private-record-value' }
    }
    records.each { |name, value| File.write(File.join(@bully_runtime, name), JSON.generate(value)) }
  end

  def stub_bully_inventory(production: true, analytics: true, pilot_state: 'exited', pilot_health: 'none', production_image: IMAGE_ID)
    rows = []
    rows << { id: POSTCARD_ID, name: 'bully-pulpit-production', image: 'fixture-production', state: 'running', status: 'Up' } if production
    rows << { id: OTHER_ID, name: 'bully-pulpit-production-analytics', image: 'fixture-production', state: 'running', status: 'Up' } if analytics
    rows << { id: EXITED_ID, name: 'bully-pulpit', image: 'fixture-pilot', state: pilot_state, status: pilot_state }
    @runner.add(['docker', 'ps', '-a', '--no-trunc', '--format', Dashboard::Collector::PS_FORMAT], rows.map { |row| JSON.generate(row) }.join("\n"))
    running = rows.select { |row| row[:state] == 'running' }
    @runner.add(['docker', 'stats', '--no-stream', '--no-trunc', '--format', Dashboard::Collector::STATS_FORMAT, *running.map { |row| row[:id] }], '') unless running.empty?
    details = rows.map { |row| { id: row[:id], image_id: row[:id] == POSTCARD_ID ? production_image : IMAGE_ID, health: row[:id] == EXITED_ID ? pilot_health : 'healthy' } }
    @runner.add(['docker', 'inspect', '--format', Dashboard::Collector::INSPECT_FORMAT, *rows.map { |row| row[:id] }], details.map { |row| JSON.generate(row) }.join("\n"))
  end

  def compose_collector
    @config::GIT_SERVICES << {
      name: 'wiki', use_compose: true,
      dashboard: { container_name: 'wiki-web-custom', one_shot_containers: ['wiki-init-custom'] }
    }
    Dashboard::Collector.new(repo_dir: @directory, config: @config, runner: @runner,
                             clock: -> { @now }, hostname: 'Mac mini', platform: 'arm64-darwin',
                             docker_disk_path: File.join(@directory, 'Docker.raw'))
  end

  def stub_compose_inventory(app_running:, migration_state:)
    rows = []
    rows << { id: POSTCARD_ID, name: 'wiki-web-custom', image: 'wiki-app', state: 'running', status: 'Up' } if app_running
    rows << { id: OTHER_ID, name: 'wiki-init-custom', image: 'wiki-migrate', state: migration_state, status: migration_state } if migration_state
    @runner.add(['docker', 'ps', '-a', '--no-trunc', '--format', Dashboard::Collector::PS_FORMAT], rows.map { |row| JSON.generate(row) }.join("\n"))
    running = rows.select { |row| row[:state] == 'running' }
    @runner.add(['docker', 'stats', '--no-stream', '--no-trunc', '--format', Dashboard::Collector::STATS_FORMAT, *running.map { |row| row[:id] }], '') unless running.empty?
    @runner.add(['docker', 'inspect', '--format', Dashboard::Collector::INSPECT_FORMAT, *rows.map { |row| row[:id] }], '') unless rows.empty?
  end

  def stub_host
    @runner.add(['df', '-Pk', @directory], "Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk 524288000 487587840 36700160 93% /\n")
    @runner.add(native_capacity_command, JSON.generate('NSURLVolumeTotalCapacityKey' => 500 * GIB,
                                                       'NSURLVolumeAvailableCapacityKey' => 34 * GIB,
                                                       'NSURLVolumeAvailableCapacityForImportantUsageKey' => 220 * GIB))
    @runner.add(['/usr/sbin/sysctl', '-n', 'hw.memsize'], (16 * GIB).to_s)
    @runner.add(['/usr/bin/vm_stat'], "Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 131072.\nPages inactive: 196608.\nPages speculative: 65536.\n")
    @runner.add(['/usr/sbin/sysctl', '-n', 'hw.logicalcpu'], '8')
    @runner.add(['/usr/sbin/sysctl', '-n', 'vm.loadavg'], '{ 0.4 0.6 0.8 }')
    @runner.add(['/usr/sbin/sysctl', '-n', 'kern.boottime'], "{ sec = #{@now.to_i - 7200}, usec = 0 }")
    @runner.add(['/usr/bin/pgrep', '-x', 'netdata'], "9876\n")
  end

  def native_capacity_command
    ['/usr/bin/osascript', '-l', 'JavaScript', '-e', Core::DiskMonitor::MACOS_CAPACITY_SCRIPT, @directory]
  end

  def stub_inventory
    rows = [
      { id: POSTCARD_ID, name: 'postcard', image: 'postcard:latest', state: 'running', status: 'Up 2 days (healthy)' },
      { id: OTHER_ID, name: 'forgotten-app', image: 'image:1', state: 'running', status: 'Up 1 day' },
      { id: HELPER_ID, name: 'toolbox-op-test', image: '1password/op', state: 'running', status: 'Up 1 second' },
      { id: EXITED_ID, name: 'old-app', image: 'image:old', state: 'exited', status: 'Exited' }
    ]
    @runner.add(['docker', 'ps', '-a', '--no-trunc', '--format', Dashboard::Collector::PS_FORMAT], rows.map { |r| JSON.generate(r) }.join("\n"))
    @runner.add(['docker', 'stats', '--no-stream', '--no-trunc', '--format', Dashboard::Collector::STATS_FORMAT, POSTCARD_ID, OTHER_ID],
                JSON.generate(id: POSTCARD_ID, name: 'postcard', cpu: '15.5%', memory: '512MiB / 2GiB', memory_percent: '25%', network: '1.2kB / 2.5MB', block: '0B / 4GiB', pids: '17'))
    @runner.add(['docker', 'inspect', '--format', Dashboard::Collector::INSPECT_FORMAT, POSTCARD_ID, OTHER_ID, EXITED_ID],
                [JSON.generate(id: POSTCARD_ID, image_id: IMAGE_ID, started_at: (@now - 172800).iso8601, restarts: 2, health: 'healthy'),
                 JSON.generate(id: EXITED_ID, started_at: (@now - 172800).iso8601, restarts: 0, health: 'unhealthy')].join("\n"))
  end

  def stub_deployment
    @runner.add(['git', '-C', @directory, 'rev-parse', 'HEAD'], HEAD)
    @runner.add(['git', '-C', @directory, 'symbolic-ref', '--quiet', '--short', 'HEAD'], 'main')
  end

  def write_status(**data)
    FileUtils.mkdir_p(File.join(@directory, '.runtime'))
    File.write(File.join(@directory, '.runtime/heartbeat-status.json'), JSON.generate(data))
  end
end

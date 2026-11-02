require_relative 'test_helper'
require_relative '../lib/disk_monitor'

class DiskMonitorTest < Minitest::Test
  FakeStatus = Struct.new(:success?)

  def test_warns_at_eighty_percent
    status = nil
    output, = capture_output do
      Core::CommandRunner.stub(:capture3, [df_output(80), '', FakeStatus.new(true)]) do
        status = Core::DiskMonitor.check('/tmp', macos: false)
      end
    end

    assert_equal :warning, status.level
    assert_includes output, 'WARNING'
  end

  def test_is_critical_at_ninety_percent
    status = nil
    output, = capture_output do
      Core::CommandRunner.stub(:capture3, [df_output(90), '', FakeStatus.new(true)]) do
        status = Core::DiskMonitor.check('/tmp', macos: false)
      end
    end

    assert status.critical?
    assert_includes output, 'CRITICAL'
  end

  def test_macos_reclaimable_space_allows_deployment_but_preserves_raw_warning
    status, output, commands = check_macos

    refute status.critical?
    assert_equal :warning, status.level
    assert_equal 92, status.percent_used
    assert_equal 57, status.effective_percent_used
    assert_equal 35 * 1024**3, status.available_bytes
    assert_includes output, '35.0 GiB immediately free'
    assert_includes output, '200.0 GiB available including reclaimable space'
    assert_equal '/tmp/a path;literal', commands.last.last
  end

  def test_reclaimable_space_cannot_replace_the_physical_reserve
    status, output, = check_macos(free_gib: 19)

    assert status.critical?
    assert_includes output, 'minimum: 20 GiB'
  end

  def test_exact_physical_reserve_is_allowed
    status, = check_macos(free_gib: 20)
    refute status.critical?
  end

  def test_lower_foundation_free_reading_controls_the_reserve
    status, = check_macos(capacity: capacity_json(free_gib: 19))
    assert status.critical?
  end

  def test_critical_effective_usage_still_blocks
    status, = check_macos(capacity: capacity_json(important_gib: 35))
    assert status.critical?
  end

  def test_invalid_foundation_responses_fall_back_to_raw_limits
    ['invalid JSON', '[]', '{}', capacity_json(total_gib: 900),
     capacity_json(important_gib: 500), capacity_json(important_gib: -1),
     capacity_json(free_gib: 40, important_gib: 35),
     capacity_json(total_gib: 460.5)].each do |response|
      status, output, = check_macos(capacity: response)
      assert status.critical?, response
      assert_equal 92, status.effective_percent_used
      assert_includes output, 'using df limits'
    end
  end

  def test_capacity_command_failure_falls_back
    status, output, = check_macos(capacity_success: false)
    assert status.critical?
    assert_includes output, 'using df limits'
  end

  def test_capacity_timeout_or_missing_command_falls_back
    [Core::CommandRunner::TimeoutError, Core::CommandRunner::StartError].each do |error_class|
      status, output, = check_macos(capacity_error: error_class)
      assert status.critical?
      assert_includes output, 'using df limits'
    end
  end

  def test_physical_reserve_still_applies_when_capacity_query_fails
    status, = check_macos(percent: 80, free_gib: 19, capacity_success: false)
    assert status.critical?
  end

  def test_non_macos_does_not_run_foundation_query
    commands = []
    runner = lambda do |*command, **_options|
      commands << command
      [df_output(50), '', FakeStatus.new(true)]
    end
    capture_output do
      Core::CommandRunner.stub(:capture3, runner) do
        refute Core::DiskMonitor.check('/tmp', macos: false).critical?
      end
    end
    assert_equal [%w[df -Pk /tmp]], commands
  end

  def test_invalid_df_does_not_allow_deployment
    Core::CommandRunner.stub(:capture3, ['invalid df', '', FakeStatus.new(true)]) do
      assert_raises(RuntimeError) { Core::DiskMonitor.check('/tmp', macos: true) }
    end
  end

  private

  def check_macos(percent: 92, free_gib: 35, capacity: nil, capacity_success: true, capacity_error: nil)
    commands = []
    runner = lambda do |*command, **_options|
      commands << command
      if command.first == 'df'
        total = 460 * 1024**2
        free = free_gib * 1024**2
        ["Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/disk1 #{total} #{total - free} #{free} #{percent}% /\n",
         '', FakeStatus.new(true)]
      else
        raise capacity_error, 'fixture failure' if capacity_error

        [capacity || capacity_json, '', FakeStatus.new(capacity_success)]
      end
    end
    status = nil
    output, = capture_output do
      Core::CommandRunner.stub(:capture3, runner) do
        status = Core::DiskMonitor.check('/tmp/a path;literal', macos: true)
      end
    end
    [status, output, commands]
  end

  def capacity_json(total_gib: 460, free_gib: 35, important_gib: 200)
    JSON.generate({
      'NSURLVolumeTotalCapacityKey' => total_gib * 1024**3,
      'NSURLVolumeAvailableCapacityKey' => free_gib * 1024**3,
      'NSURLVolumeAvailableCapacityForImportantUsageKey' => important_gib * 1024**3
    })
  end

  def df_output(percent)
    <<~OUTPUT
      Filesystem 1024-blocks Used Available Capacity Mounted on
      /dev/disk1 100 50 50 #{percent}% /
    OUTPUT
  end
end

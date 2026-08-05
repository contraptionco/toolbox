require_relative 'test_helper'
require_relative '../lib/disk_monitor'

class DiskMonitorTest < Minitest::Test
  FakeStatus = Struct.new(:success?)

  def test_warns_at_eighty_percent
    status = nil
    output, = capture_output do
      Core::CommandRunner.stub(:capture3, [df_output(80), '', FakeStatus.new(true)]) do
        status = Core::DiskMonitor.check('/tmp')
      end
    end

    assert_equal :warning, status.level
    assert_includes output, 'WARNING'
  end

  def test_is_critical_at_ninety_percent
    status = nil
    output, = capture_output do
      Core::CommandRunner.stub(:capture3, [df_output(90), '', FakeStatus.new(true)]) do
        status = Core::DiskMonitor.check('/tmp')
      end
    end

    assert status.critical?
    assert_includes output, 'CRITICAL'
  end

  private

  def df_output(percent)
    <<~OUTPUT
      Filesystem 1024-blocks Used Available Capacity Mounted on
      /dev/disk1 100 50 50 #{percent}% /
    OUTPUT
  end
end

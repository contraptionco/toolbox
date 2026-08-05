require_relative 'test_helper'
require_relative '../lib/script_runner'

class ScriptRunnerTest < Minitest::Test
  FakeStatus = Struct.new(:success?)

  def test_script_failure_does_not_block_later_scripts
    original = Config::SCRIPTS.dup
    Config::SCRIPTS.replace([
      { name: 'first', type: 'shell', command: 'first' },
      { name: 'second', type: 'shell', command: 'second' }
    ])
    calls = []
    runner = lambda do |command, **_options|
      calls << command
      success = command == 'second'
      ['', success ? '' : 'failed', FakeStatus.new(success)]
    end

    failures = nil
    capture_output do
      Core::CommandRunner.stub(:capture3, runner) do
        failures = Core::ScriptRunner.run_scripts
      end
    end

    assert_equal %w[first second], calls
    assert_equal ['script:first'], failures.map { |failure| failure[:component] }
  ensure
    Config::SCRIPTS.replace(original) if original
  end
end

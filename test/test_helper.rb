require 'minitest/autorun'
require 'stringio'

module OutputHelpers
  def capture_output
    original_stdout = $stdout
    original_stderr = $stderr
    stdout = StringIO.new
    stderr = StringIO.new
    $stdout = stdout
    $stderr = stderr
    yield
    [stdout.string, stderr.string]
  ensure
    $stdout = original_stdout
    $stderr = original_stderr
  end
end

class Minitest::Test
  include OutputHelpers
end

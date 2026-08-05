require 'stringio'
require 'tmpdir'
require_relative 'test_helper'
require_relative '../lib/bounded_log_writer'

class BoundedLogWriterTest < Minitest::Test
  def test_one_unbounded_run_keeps_current_log_and_archives_capped
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'heartbeat.log')
      Core::BoundedLogWriter.new(path, max_bytes: 10, archives: 2)
                            .write_stream(StringIO.new('x' * 105))

      files = [path, "#{path}.1", "#{path}.2"]
      assert files.all? { |file| File.exist?(file) }
      assert files.all? { |file| File.size(file) <= 10 }
      assert_operator files.sum { |file| File.size(file) }, :<=, 30
    end
  end

  def test_legacy_oversized_files_are_truncated_before_rotation
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'heartbeat.log')
      File.binwrite(path, 'old' * 100)

      Core::BoundedLogWriter.new(path, max_bytes: 20, archives: 2)
                            .write_stream(StringIO.new('new'))

      assert_operator File.size("#{path}.1"), :<=, 20
      assert_operator File.size(path), :<=, 20
    end
  end
end

require 'json'
require 'time'
require 'fileutils'
require_relative 'command_runner'

module Core
  # A small, atomic status record avoids guessing deployment success from log
  # strings. It contains no command output, environment, URLs or exception text.
  class HeartbeatStatus
    def initialize(repo_dir, clock: -> { Time.now.utc }, command_runner: Core::CommandRunner, stderr: $stderr)
      @repo_dir, @clock, @runner, @stderr = repo_dir, clock, command_runner, stderr
      @path = File.join(repo_dir, '.runtime', 'heartbeat-status.json')
    end

    def start
      previous = previous_record
      @record = { 'status' => 'running', 'started_at' => @clock.call.iso8601,
                  'last_success_at' => previous['last_success_at'], 'commit' => revision,
                  'pid' => Process.pid, 'message' => 'Heartbeat is running' }
      write
      true
    rescue StandardError
      unavailable
    end

    def finish(success:, exit_code:)
      @record ||= {}
      now = @clock.call.iso8601
      @record.merge!('status' => success ? 'healthy' : 'failed', 'finished_at' => now,
                     'commit' => revision, 'exit_code' => exit_code,
                     'message' => success ? 'All configured services checked successfully' : 'Heartbeat failed; inspect the redacted logs')
      @record['last_success_at'] = now if success
      write
      true
    rescue StandardError
      unavailable
    end

    private

    def previous_record
      value = File.file?(@path) ? JSON.parse(File.read(@path, 8192)) : {}
      value.is_a?(Hash) ? value : {}
    rescue StandardError
      {}
    end

    def unavailable
      # Telemetry must never prevent a deployment or turn a successful service
      # check into a failure, including when disk capacity is exhausted.
      @stderr.puts 'Could not write heartbeat status; continuing service checks.'
      false
    rescue StandardError
      false
    end

    def revision
      output, _error, status = @runner.capture3('git', 'rev-parse', 'HEAD', chdir: @repo_dir, timeout: 5, label: 'Heartbeat revision')
      value = output.strip
      value if status.success? && value.match?(/\A[0-9a-f]{40}\z/)
    rescue StandardError
      nil
    end

    def write
      FileUtils.mkdir_p(File.dirname(@path), mode: 0o700)
      temp = "#{@path}.#{Process.pid}.tmp"
      begin
        File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
          file.write(JSON.generate(@record))
          file.flush
          file.fsync
        end
        File.rename(temp, @path)
      ensure
        File.delete(temp) if File.exist?(temp)
      end
    end
  end
end

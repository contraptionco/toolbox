require 'open3'

module Core
  module CommandRunner
    DEFAULT_TIMEOUT = 120
    DEFAULT_CAPTURE_LIMIT = 10 * 1024 * 1024
    TERMINATION_GRACE = 2
    IO_JOIN_GRACE = 1
    READ_CHUNK_SIZE = 16 * 1024
    TRUNCATION_MARKER = "\n[output truncated]\n".b

    class TimeoutError < StandardError; end
    class StartError < StandardError; end

    def self.capture3(*command, env: {}, timeout: DEFAULT_TIMEOUT, chdir: nil, stdin_data: nil,
                      label: nil, capture_limit: DEFAULT_CAPTURE_LIMIT)
      validate_command!(command, timeout)
      raise ArgumentError, 'capture_limit must be positive' unless capture_limit.positive?

      display_label = safe_label(label)
      options = { pgroup: true }
      options[:chdir] = chdir if chdir
      deadline = monotonic_time + timeout
      stdout_data = ''.b
      stderr_data = ''.b
      status = nil
      timed_out = false

      Open3.popen3(env, *command, **options) do |stdin, stdout, stderr, wait_thread|
        stdout_reader = Thread.new { read_bounded(stdout, capture_limit) }
        stderr_reader = Thread.new { read_bounded(stderr, capture_limit) }
        stdin_writer = Thread.new do
          begin
            stdin.write(stdin_data) if stdin_data
          rescue Errno::EPIPE, IOError
            nil
          ensure
            stdin.close unless stdin.closed?
          end
        end
        io_threads = [stdin_writer, stdout_reader, stderr_reader]

        remaining = [deadline - monotonic_time, 0].max
        if wait_thread.join(remaining)
          status = wait_thread.value
        else
          timed_out = true
          terminate_process_group(wait_thread.pid, wait_thread)
        end

        drain_deadline = timed_out ? monotonic_time + IO_JOIN_GRACE : deadline
        unless join_threads_until(io_threads, drain_deadline)
          timed_out = true
          terminate_process_group(wait_thread.pid, wait_thread)
          [stdin, stdout, stderr].each { |io| io.close unless io.closed? }
          io_threads.each do |thread|
            thread.join(IO_JOIN_GRACE)
            thread.kill if thread.alive?
          end
        end

        stdout_data = thread_value(stdout_reader)
        stderr_data = thread_value(stderr_reader)
      end

      raise TimeoutError, "#{display_label} timed out after #{timeout} seconds" if timed_out

      [stdout_data, stderr_data, status]
    rescue TimeoutError
      raise
    rescue SystemCallError => e
      raise StartError, "#{display_label} could not start (#{e.class})"
    end

    def self.run(*command, env: {}, timeout: DEFAULT_TIMEOUT, chdir: nil,
                 stdin: File::NULL, out: $stdout, err: $stderr, label: nil)
      validate_command!(command, timeout)
      display_label = safe_label(label)
      options = { pgroup: true, in: stdin, out: out, err: err }
      options[:chdir] = chdir if chdir
      pid = Process.spawn(env, *command, **options)
      wait_thread = Process.detach(pid)

      unless wait_thread.join(timeout)
        terminate_process_group(pid, wait_thread)
        raise TimeoutError, "#{display_label} timed out after #{timeout} seconds"
      end

      wait_thread.value
    rescue TimeoutError
      raise
    rescue SystemCallError => e
      raise StartError, "#{display_label} could not start (#{e.class})"
    end

    def self.spawn_detached(*command, env: {}, chdir: nil, out: File::NULL, err: File::NULL, label: nil)
      raise ArgumentError, 'command is required' if command.empty?

      display_label = safe_label(label)
      options = { pgroup: true, in: File::NULL, out: out, err: err }
      options[:chdir] = chdir if chdir
      pid = Process.spawn(env, *command, **options)
      Process.detach(pid)
      pid
    rescue SystemCallError => e
      raise StartError, "#{display_label} could not start (#{e.class})"
    end

    def self.read_bounded(io, limit)
      output = ''.b
      truncated = false

      loop do
        chunk = io.readpartial(READ_CHUNK_SIZE)
        remaining = limit - output.bytesize
        if remaining.positive?
          output << chunk.byteslice(0, remaining)
          truncated ||= chunk.bytesize > remaining
        else
          truncated = true
        end
      end
    rescue EOFError, IOError
      if truncated
        content_limit = [limit - TRUNCATION_MARKER.bytesize, 0].max
        output = output.byteslice(0, content_limit).to_s.b
        output << TRUNCATION_MARKER.byteslice(0, limit - output.bytesize)
      end
      output
    end
    private_class_method :read_bounded

    def self.join_threads_until(threads, deadline)
      while threads.any?(&:alive?) && monotonic_time < deadline
        threads.each { |thread| thread.join(0) }
        sleep 0.01
      end
      threads.none?(&:alive?)
    end
    private_class_method :join_threads_until

    def self.thread_value(thread)
      thread.value || ''.b
    rescue StandardError
      ''.b
    end
    private_class_method :thread_value

    def self.terminate_process_group(pid, wait_thread)
      signal_process_group('TERM', pid)
      deadline = monotonic_time + TERMINATION_GRACE
      while process_group_alive?(pid) && monotonic_time < deadline
        wait_thread.join(0)
        sleep 0.02
      end

      signal_process_group('KILL', pid) if process_group_alive?(pid)
      wait_thread.join(TERMINATION_GRACE)
    end
    private_class_method :terminate_process_group

    def self.signal_process_group(signal, pid)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end
    private_class_method :signal_process_group

    def self.process_group_alive?(pid)
      Process.kill(0, -pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end
    private_class_method :process_group_alive?

    def self.validate_command!(command, timeout)
      raise ArgumentError, 'command is required' if command.empty?
      raise ArgumentError, 'timeout must be positive' unless timeout && timeout.positive?
    end
    private_class_method :validate_command!

    def self.safe_label(label)
      label.to_s.strip.empty? ? 'Command' : label.to_s
    end
    private_class_method :safe_label

    def self.monotonic_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
    private_class_method :monotonic_time
  end
end

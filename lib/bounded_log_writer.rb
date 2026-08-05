require 'fileutils'

module Core
  class BoundedLogWriter
    CHUNK_SIZE = 16 * 1024

    def initialize(path, max_bytes:, archives:)
      raise ArgumentError, 'max_bytes must be positive' unless max_bytes.positive?
      raise ArgumentError, 'archives must be positive' unless archives.positive?

      @path = path
      @max_bytes = max_bytes
      @archives = archives
      @output = nil
      @size = 0
    end

    def write_stream(input)
      write_error = nil
      begin
        prepare
      rescue SystemCallError, IOError => e
        write_error = e
      end

      while (chunk = input.read(CHUNK_SIZE))
        next if write_error

        begin
          write(chunk)
        rescue SystemCallError, IOError => e
          write_error = e
          @output&.close
          @output = nil
        end
      end

      raise write_error if write_error
    ensure
      @output&.close
    end

    private

    def prepare
      FileUtils.mkdir_p(File.dirname(@path))
      cap_existing_files
      rotate if File.exist?(@path) && File.size(@path) >= @max_bytes
      open_output
    end

    def cap_existing_files
      ([@path] + (1..@archives).map { |number| "#{@path}.#{number}" }).each do |path|
        File.truncate(path, @max_bytes) if File.exist?(path) && File.size(path) > @max_bytes
      end
    end

    def write(chunk)
      offset = 0
      while offset < chunk.bytesize
        rotate_and_reopen if @size >= @max_bytes
        length = [@max_bytes - @size, chunk.bytesize - offset].min
        segment = chunk.byteslice(offset, length)
        @output.write(segment)
        @output.flush
        @size += length
        offset += length
      end
    end

    def rotate_and_reopen
      @output.close
      rotate
      open_output
    end

    def rotate
      File.delete("#{@path}.#{@archives}") if File.exist?("#{@path}.#{@archives}")
      @archives.downto(2) do |number|
        previous = "#{@path}.#{number - 1}"
        File.rename(previous, "#{@path}.#{number}") if File.exist?(previous)
      end
      File.rename(@path, "#{@path}.1") if File.exist?(@path)
    end

    def open_output
      @output = File.open(@path, File::WRONLY | File::CREAT | File::APPEND, 0o600)
      File.chmod(0o600, @path)
      @size = @output.size
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    path, max_bytes, archives = ARGV
    abort 'usage: bounded_log_writer.rb PATH MAX_BYTES ARCHIVES' unless path && max_bytes && archives

    $stdin.binmode
    Core::BoundedLogWriter.new(
      path,
      max_bytes: Integer(max_bytes),
      archives: Integer(archives)
    ).write_stream($stdin)
  rescue StandardError => e
    warn "Bounded log writer failed: #{e.class}"
    exit 1
  end
end

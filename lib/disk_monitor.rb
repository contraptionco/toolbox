require 'json'
require_relative '../config'
require_relative 'command_runner'

module Core
  module DiskMonitor
    WARN_PERCENT = 80
    CRITICAL_PERCENT = 90
    COMMAND_TIMEOUT = 10
    MIN_FREE_BYTES = 20 * 1024**3
    MACOS_CAPACITY_SCRIPT = <<~JAVASCRIPT.freeze
      function run(argv) {
        ObjC.import('Foundation');
        var url = $.NSURL.fileURLWithPath(argv[0]);
        var keys = $([$.NSURLVolumeTotalCapacityKey,
                      $.NSURLVolumeAvailableCapacityKey,
                      $.NSURLVolumeAvailableCapacityForImportantUsageKey]);
        var values = url.resourceValuesForKeysError(keys, null);
        if (!values) throw new Error('Volume capacity unavailable');
        return JSON.stringify(ObjC.deepUnwrap(values));
      }
    JAVASCRIPT

    Status = Struct.new(:percent_used, :level, :available_bytes, :effective_percent_used,
                        :effective_available_bytes, keyword_init: true) do
      def critical?
        level == :critical
      end
    end

    def self.check(path = Config::HOME_DIR, macos: RUBY_PLATFORM.include?('darwin'))
      stdout, stderr, status = Core::CommandRunner.capture3(
        'df', '-Pk', path,
        timeout: COMMAND_TIMEOUT,
        label: 'Disk usage check'
      )
      raise "Disk usage check failed: #{stderr.strip}" unless status.success?

      usage = parse_usage(stdout)
      percent_used = usage.fetch(:percent_used)
      available_bytes = usage.fetch(:available_bytes)
      effective_percent_used = percent_used
      effective_available_bytes = available_bytes
      if macos && (capacity = macos_capacity(path, usage.fetch(:total_bytes)))
        # Use the smaller immediate-free reading; reclaimable storage does not
        # satisfy the reserve needed before a backup/build starts.
        available_bytes = [available_bytes, capacity.fetch(:available_bytes)].min
        effective_available_bytes = capacity.fetch(:important_bytes)
        effective_percent_used = ((capacity.fetch(:total_bytes) - effective_available_bytes) * 100.0 /
                                  capacity.fetch(:total_bytes)).ceil
      end
      reserve_exhausted = macos && available_bytes < MIN_FREE_BYTES
      level = if reserve_exhausted || effective_percent_used >= CRITICAL_PERCENT
                :critical
              elsif [percent_used, effective_percent_used].max >= WARN_PERCENT
                :warning
              else
                :ok
              end

      details = "Disk usage is #{percent_used}%"
      if macos
        details += format('; %.1f GiB immediately free (minimum: 20 GiB)', available_bytes.fdiv(1024**3))
        if capacity
          details += format('; %.1f GiB available including reclaimable space (%d%% effectively used)',
                            effective_available_bytes.fdiv(1024**3), effective_percent_used)
        end
      end
      case level
      when :critical
        puts "CRITICAL: #{details}."
      when :warning
        puts "WARNING: #{details}."
      else
        puts "#{details}."
      end

      Status.new(percent_used: percent_used, level: level, available_bytes: available_bytes,
                 effective_percent_used: effective_percent_used,
                 effective_available_bytes: effective_available_bytes)
    end

    def self.parse_usage(output)
      data_line = output.lines.map(&:strip).reject(&:empty?).last
      fields = data_line.to_s.split
      total, available, percent = fields.values_at(1, 3, 4)
      unless total.to_s.match?(/\A\d+\z/) && available.to_s.match?(/\A\d+\z/) &&
             percent.to_s.match?(/\A\d+%\z/) && total.to_i.positive? && available.to_i <= total.to_i
        raise 'Unable to parse disk usage.'
      end

      { percent_used: percent.delete_suffix('%').to_i,
        total_bytes: total.to_i * 1024, available_bytes: available.to_i * 1024 }
    end
    private_class_method :parse_usage

    def self.macos_capacity(path, expected_total)
      stdout, _stderr, status = Core::CommandRunner.capture3(
        '/usr/bin/osascript', '-l', 'JavaScript', '-e', MACOS_CAPACITY_SCRIPT, File.expand_path(path),
        timeout: COMMAND_TIMEOUT,
        label: 'macOS available disk capacity'
      )
      raise ArgumentError, 'Capacity query failed' unless status.success?

      data = JSON.parse(stdout)
      raise ArgumentError, 'Invalid capacity response' unless data.is_a?(Hash)
      total, available, important = data.values_at('NSURLVolumeTotalCapacityKey',
                                                  'NSURLVolumeAvailableCapacityKey',
                                                  'NSURLVolumeAvailableCapacityForImportantUsageKey')
      unless [total, available, important].all? { |value| value.is_a?(Integer) } && total.positive? &&
             available.between?(0, total) && important.between?(available, total) &&
             (total - expected_total).abs <= 1024
        raise ArgumentError, 'Invalid volume capacity'
      end

      { total_bytes: total, available_bytes: available, important_bytes: important }
    rescue JSON::ParserError, ArgumentError,
           Core::CommandRunner::StartError, Core::CommandRunner::TimeoutError => e
      puts "WARNING: macOS reclaimable capacity unavailable (#{e.class}); using df limits."
      nil
    end
    private_class_method :macos_capacity
  end
end

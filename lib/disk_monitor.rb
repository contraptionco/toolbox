require_relative '../config'
require_relative 'command_runner'

module Core
  module DiskMonitor
    WARN_PERCENT = 80
    CRITICAL_PERCENT = 90
    COMMAND_TIMEOUT = 10

    Status = Struct.new(:percent_used, :level, keyword_init: true) do
      def critical?
        level == :critical
      end
    end

    def self.check(path = Config::HOME_DIR)
      stdout, stderr, status = Core::CommandRunner.capture3(
        'df', '-Pk', path,
        timeout: COMMAND_TIMEOUT,
        label: 'Disk usage check'
      )
      raise "Disk usage check failed: #{stderr.strip}" unless status.success?

      percent_used = parse_percent_used(stdout)
      level = if percent_used >= CRITICAL_PERCENT
                :critical
              elsif percent_used >= WARN_PERCENT
                :warning
              else
                :ok
              end

      case level
      when :critical
        puts "CRITICAL: Disk usage is #{percent_used}% (threshold: #{CRITICAL_PERCENT}%)."
      when :warning
        puts "WARNING: Disk usage is #{percent_used}% (threshold: #{WARN_PERCENT}%)."
      else
        puts "Disk usage is #{percent_used}%."
      end

      Status.new(percent_used: percent_used, level: level)
    end

    def self.parse_percent_used(output)
      data_line = output.lines.map(&:strip).reject(&:empty?).last
      percent = data_line.to_s.split.find { |field| field.match?(/\A\d+%\z/) }
      raise 'Unable to parse disk usage.' unless percent

      percent.delete_suffix('%').to_i
    end
    private_class_method :parse_percent_used
  end
end

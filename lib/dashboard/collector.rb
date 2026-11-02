require 'json'
require 'socket'
require 'time'
require_relative '../command_runner'
require_relative '../disk_monitor'
require_relative 'redactor'

module Dashboard
  # Read-only host collector. Every subprocess uses a fixed executable and argv,
  # bounded output and a timeout. Injectable dependencies keep tests off the host.
  class Collector
    MAX_OUTPUT = 256 * 1024
    LOG_BYTES = 128 * 1024
    MAX_LOG_LINES = 200
    MAX_CONTAINERS = 128
    NAME = /\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\z/
    SHA = /\A[0-9a-f]{40,64}\z/
    PS_FORMAT = '{"id":{{json .ID}},"name":{{json .Names}},"image":{{json .Image}},"state":{{json .State}},"status":{{json .Status}}}'.freeze
    STATS_FORMAT = '{"id":{{json .ID}},"name":{{json .Name}},"cpu":{{json .CPUPerc}},"memory":{{json .MemUsage}},"memory_percent":{{json .MemPerc}},"network":{{json .NetIO}},"block":{{json .BlockIO}},"pids":{{json .PIDs}}}'.freeze
    INSPECT_FORMAT = '{"id":{{json .Id}},"started_at":{{json .State.StartedAt}},"restarts":{{json .RestartCount}},"health":{{with index .State "Health"}}{{json .Status}}{{else}}"none"{{end}}}'.freeze
    HOST_PROCESSES = { 'netdata' => 'netdata', 'cloudflare-tunnel' => 'cloudflared' }.freeze

    class Unavailable < StandardError; end
    class UnknownLogSource < ArgumentError; end

    def initialize(repo_dir: File.expand_path('../..', __dir__), config: Config,
                   runner: Core::CommandRunner, clock: -> { Time.now },
                   home_dir: nil, hostname: Socket.gethostname, platform: RUBY_PLATFORM,
                   docker_disk_path: nil)
      @repo_dir = File.expand_path(repo_dir)
      @config = config
      @runner = runner
      @clock = clock
      @home_dir = home_dir || config::HOME_DIR
      @hostname = hostname
      @platform = platform
      @docker_disk_path = docker_disk_path || File.join(@home_dir, 'Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw')
      @log_paths = { 'heartbeat' => File.join(@repo_dir, 'heartbeat.log'),
                     'tunnel' => File.join(@repo_dir, 'tunnel.log') }.freeze
      @applications = configured_applications.freeze
    end

    def snapshot
      errors = []
      warnings = []
      host = { name: Redactor.line(@hostname), os: @platform.include?('darwin') ? 'macOS' : @platform }
      collect(errors, 'host disk') { host[:disk] = disk_usage }
      collect(errors, 'host memory') { host[:memory] = memory_usage }
      collect(errors, 'host load') { host.merge!(system_usage) }
      collect(errors, 'Docker disk') { host[:docker_disk] = docker_disk }
      inventory_result = collect(errors, 'Docker inventory') { inventory }
      containers = inventory_result || []
      if !containers.empty?
        collect(errors, 'container metrics') { add_stats(containers) }
        collect(errors, 'container state') { add_details(containers) }
      end
      applications = @applications.map do |app|
        container = containers.find { |item| item[:name] == app[:container_name] }
        deployed = deployment_marker(app[:name]) if app[:type] == 'docker'
        app_status = if app[:status]
                       app[:status]
                     elsif app[:type] == 'host'
                       collect(errors, "#{app[:name]} process") { host_process_status(app[:name]) } || 'unknown'
                     elsif inventory_result.nil?
                       'unknown'
                     elsif container && container[:state] == 'running'
                       'running'
                     else
                       'stopped'
                     end
        app.merge(status: app_status, image: container&.dig(:image),
                  started_at: container&.dig(:started_at), commit: deployed).compact
      end
      containers.each do |container|
        if container[:state] == 'running' && !container[:configured] && !container[:transient]
          warnings << "Running container #{container[:name]} is not configured in Toolbox."
        elsif container[:state] == 'running' && container[:health] == 'unhealthy'
          warnings << "Container #{container[:name]} is unhealthy."
        end
      end
      applications.select { |app| app[:type] == 'docker' && app[:status] == 'stopped' }.each do |app|
        warnings << "Configured application #{app[:name]} is not running."
      end
      deployment = deployment_status(errors)
      warnings << 'The heartbeat has not completed recently.' if deployment[:status] == 'stale'
      warnings << 'The last heartbeat failed.' if deployment[:status] == 'failed'
      if host.dig(:disk, :level) == 'critical'
        warnings << 'Disk capacity is below the deployment safety threshold.'
      end
      { generated_at: timestamp, host: host, deployment: deployment,
        applications: applications, containers: containers, warnings: warnings,
        errors: errors, log_sources: sources(containers) }
    end

    def logs(source, lines: MAX_LOG_LINES)
      count = Integer(lines).clamp(1, MAX_LOG_LINES)
      raw_lines, truncated = if @log_paths.key?(source)
                               output, clipped = tail(@log_paths.fetch(source), LOG_BYTES)
                               [output.lines(chomp: true), clipped]
                             elsif source.is_a?(String) && source.start_with?('container:')
                               name = source.delete_prefix('container:')
                               raise UnknownLogSource, 'Unknown log source' unless name.match?(NAME)

                               container = inventory.find { |item| item[:name] == name && !item[:transient] }
                               raise UnknownLogSource, 'Unknown log source' unless container

                               docker_log_lines(container.fetch(:id), count)
                             else
                               raise UnknownLogSource, 'Unknown log source'
                             end
      truncated ||= raw_lines.length > count
      safe_lines = raw_lines.last(count).map { |line| Redactor.line(line) }
      # Keep the newest complete lines after sorting/redaction. Account for
      # JSON escaping as well as UTF-8 so the final array is bounded too.
      while JSON.generate(safe_lines).bytesize > LOG_BYTES
        safe_lines.shift
        truncated = true
      end
      { source: source, updated_at: timestamp, lines: safe_lines, truncated: truncated }
    rescue ArgumentError, TypeError
      raise UnknownLogSource, 'Invalid log request'
    end

    private

    def configured_applications
      direct = @config::DOCKER_SERVICES.map { |item| { name: item.fetch(:name), type: 'docker', container_name: item.fetch(:name), configured: true } }
      git = @config::GIT_SERVICES.filter_map do |item|
        next unless item[:container_config]

        { name: item.fetch(:name), type: 'docker', container_name: item[:container_config].fetch(:name, item.fetch(:name)), configured: true }
      end
      host = @config.const_defined?(:SYSTEM_SERVICES) ? @config::SYSTEM_SERVICES.map do |item|
        { name: item.fetch(:name), type: 'host', configured: true }
      end : []
      if @config.const_defined?(:DASHBOARD) && @config::DASHBOARD[:enabled]
        dashboard = { name: 'toolbox', type: 'host', configured: true, status: 'running' }
        hostname = @config::DASHBOARD[:hostname].to_s
        dashboard[:url] = "https://#{hostname}" if hostname.match?(/\A[a-z0-9]+(?:[.-][a-z0-9]+)*\z/i)
        host << dashboard
      end
      host << { name: 'cloudflare-tunnel', type: 'host', configured: true } if @config.const_defined?(:TUNNEL_CONFIG) && @config::TUNNEL_CONFIG
      direct + git + host
    end

    def host_process_status(name)
      executable = HOST_PROCESSES[name]
      return 'unknown' unless executable

      # Only exit status matters. Never return command lines, process environment
      # or launchctl state; the latter can contain service-account credentials.
      _output, _error, status = @runner.capture3('/usr/bin/pgrep', '-x', executable,
                                                timeout: 8, capture_limit: 4096,
                                                env: { 'LC_ALL' => 'C' }, label: 'Dashboard process presence')
      return 'running' if status.success?
      return 'stopped' if status.exitstatus == 1

      raise Unavailable
    rescue Core::CommandRunner::StartError, Core::CommandRunner::TimeoutError
      raise Unavailable
    end

    def command(*argv, limit: MAX_OUTPUT)
      capture_streams(*argv, limit: limit).first
    end

    def capture_streams(*argv, limit:)
      output, stderr, status = @runner.capture3(*argv, timeout: 8, capture_limit: limit,
                                               env: { 'LC_ALL' => 'C', 'GIT_OPTIONAL_LOCKS' => '0', 'GIT_TERMINAL_PROMPT' => '0' },
                                               label: 'Dashboard read-only inspection')
      raise Unavailable, 'Inspection unavailable' unless status.success?

      [output, stderr].map do |value|
        value.byteslice(0, limit).to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '�')
      end
    rescue Core::CommandRunner::StartError, Core::CommandRunner::TimeoutError
      raise Unavailable, 'Inspection unavailable'
    end

    def docker_log_lines(id, count)
      streams = capture_streams('docker', 'logs', '--tail', count.to_s, '--timestamps', id, limit: LOG_BYTES)
      marker = Core::CommandRunner::TRUNCATION_MARKER.strip
      truncated = streams.any? { |stream| stream.include?(marker) }
      entries = streams.each_with_index.flat_map do |stream, stream_index|
        previous_timestamp = nil
        stream.lines(chomp: true).each_with_index.filter_map do |line, line_index|
          next if line == marker

          # Docker timestamps each log entry. Multiline continuations inherit
          # the preceding entry's time; untimestamped diagnostics sort first.
          value = line[/\A(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,9})?(?:Z|[+-]\d{2}:\d{2}))\s/, 1]
          begin
            previous_timestamp = Time.iso8601(value).to_r if value
          rescue ArgumentError
            # Invalid timestamps remain plain, redacted diagnostics.
          end
          [previous_timestamp || -1, stream_index, line_index, line]
        end
      end
      # Equal timestamps retain per-stream order. Cross-stream ordering cannot
      # be inferred more precisely than Docker's timestamp resolution.
      [entries.sort_by { |entry| entry.first(3) }.map(&:last), truncated]
    end

    def collect(errors, source)
      yield
    rescue Unavailable, JSON::ParserError, ArgumentError, TypeError, KeyError, SystemCallError, IOError
      errors << { source: source, message: 'Temporarily unavailable' }
      nil
    end

    def disk_usage
      begin
        usage = Core::DiskMonitor.send(:parse_usage, command('df', '-Pk', @home_dir))
      rescue RuntimeError
        raise Unavailable
      end
      total = usage.fetch(:total_bytes)
      immediate = usage.fetch(:available_bytes)
      available = immediate
      effective = usage.fetch(:percent_used)
      reclaimable_available = false
      if @platform.include?('darwin')
        begin
          data = JSON.parse(command('/usr/bin/osascript', '-l', 'JavaScript', '-e', Core::DiskMonitor::MACOS_CAPACITY_SCRIPT, File.expand_path(@home_dir)))
          native_total, native_free, important = data.values_at('NSURLVolumeTotalCapacityKey', 'NSURLVolumeAvailableCapacityKey', 'NSURLVolumeAvailableCapacityForImportantUsageKey')
          if [native_total, native_free, important].all? { |v| v.is_a?(Integer) } &&
             native_total.positive? && (total - native_total).abs <= 1024 &&
             native_free.between?(0, native_total) && important.between?(native_free, native_total)
            immediate = [immediate, native_free].min
            available = important
            effective = ((native_total - important) * 100.0 / native_total).ceil
            reclaimable_available = true
          end
        rescue Unavailable, JSON::ParserError, TypeError, NoMethodError
          # Same fail-closed disk thresholds as the production disk guard.
        end
      end
      level = if (@platform.include?('darwin') && immediate < Core::DiskMonitor::MIN_FREE_BYTES) || effective >= Core::DiskMonitor::CRITICAL_PERCENT
                'critical'
              elsif [usage[:percent_used], effective].max >= Core::DiskMonitor::WARN_PERCENT
                'warning'
              else
                'ok'
              end
      { total_bytes: total, free_bytes: immediate, available_bytes: available,
        used_percent: usage[:percent_used], effective_used_percent: effective, level: level,
        minimum_free_bytes: Core::DiskMonitor::MIN_FREE_BYTES, reclaimable_available: reclaimable_available }
    end

    def memory_usage
      raise Unavailable unless @platform.include?('darwin')

      total = Integer(command('/usr/sbin/sysctl', '-n', 'hw.memsize').strip)
      stats = command('/usr/bin/vm_stat')
      page_size = Integer(stats[/page size of (\d+) bytes/, 1] || '')
      pages = stats.scan(/^([^:]+):\s+(\d+)\./).to_h.transform_values(&:to_i)
      raise Unavailable unless total.positive? && page_size.positive? && pages.key?('Pages free')

      available = %w[free inactive speculative].sum { |key| pages.fetch("Pages #{key}", 0) } * page_size
      available = available.clamp(0, total)
      { total_bytes: total, used_bytes: total - available, available_bytes: available,
        description: 'Available memory includes inactive and speculative pages.' }
    end

    def system_usage
      raise Unavailable unless @platform.include?('darwin')

      cpu_count = Integer(command('/usr/sbin/sysctl', '-n', 'hw.logicalcpu').strip)
      load = command('/usr/sbin/sysctl', '-n', 'vm.loadavg').scan(/\d+(?:\.\d+)?/).first(3).map(&:to_f)
      boot_time = command('/usr/sbin/sysctl', '-n', 'kern.boottime')[/\bsec\s*=\s*(\d+)/, 1]
      raise Unavailable unless cpu_count.positive? && load.length == 3 && boot_time

      { cpu_count: cpu_count, load_average: load, uptime_seconds: [@clock.call.to_i - boot_time.to_i, 0].max }
    end

    def docker_disk
      stat = File.lstat(@docker_disk_path)
      raise Unavailable unless stat.file? && !stat.symlink?

      { allocated_bytes: stat.blocks * 512, logical_bytes: stat.size }
    rescue Errno::ENOENT
      nil
    end

    def inventory
      output = command('docker', 'ps', '-a', '--no-trunc', '--format', PS_FORMAT)
      output.lines.first(MAX_CONTAINERS).filter_map do |line|
        row = object(line)
        id, name = row.values_at('id', 'name')
        next unless id.is_a?(String) && id.match?(/\A[0-9a-f]{12,64}\z/) && name.is_a?(String) && name.match?(NAME)

        app = @applications.find { |item| item[:container_name] == name }
        { id: id, name: name, image: Redactor.line(row['image']), state: safe_state(row['state']),
          status: Redactor.line(row['status']), configured: !app.nil?, application: app&.dig(:name),
          transient: name.start_with?('toolbox-op-') }
      end
    end

    def add_stats(containers)
      # 1Password helpers can disappear between ps and stats. They remain visible
      # as transient inventory, without failing metrics for persistent apps.
      running = containers.select { |item| item[:state] == 'running' && !item[:transient] }
      return if running.empty?

      output = command('docker', 'stats', '--no-stream', '--no-trunc', '--format', STATS_FORMAT, *running.map { |item| item[:id] })
      output.lines.first(MAX_CONTAINERS).each do |line|
        row = object(line)
        container = containers.find { |item| item[:id] == row['id'] || item[:name] == row['name'] }
        next unless container

        memory, memory_limit = pair(row['memory'])
        rx, tx = pair(row['network'])
        read, written = pair(row['block'])
        container.merge!(cpu_percent: percent(row['cpu']), memory_bytes: memory, memory_limit_bytes: memory_limit,
                         memory_percent: percent(row['memory_percent']), network_rx_bytes: rx, network_tx_bytes: tx,
                         block_read_bytes: read, block_write_bytes: written,
                         pids: row['pids'].to_s.match?(/\A\d+\z/) ? row['pids'].to_i : nil)
      end
    end

    def add_details(containers)
      persistent = containers.reject { |item| item[:transient] }
      return if persistent.empty?

      output = command('docker', 'inspect', '--format', INSPECT_FORMAT, *persistent.map { |item| item[:id] })
      output.lines.first(MAX_CONTAINERS).each do |line|
        row = object(line)
        container = containers.find { |item| item[:id] == row['id'] }
        next unless container

        container.merge!(started_at: safe_time(row['started_at']),
                         restarts: row['restarts'].is_a?(Integer) && row['restarts'] >= 0 ? row['restarts'] : nil,
                         health: %w[healthy unhealthy starting none].include?(row['health']) ? row['health'] : 'unknown')
      end
    end

    def deployment_status(errors)
      deployment = { status: 'unknown', commit: nil, branch: nil, last_success_at: nil, last_run_at: nil,
                     message: 'Waiting for heartbeat status.' }
      collect(errors, 'Toolbox revision') do
        sha = command('git', '-C', @repo_dir, 'rev-parse', 'HEAD').strip
        branch = command('git', '-C', @repo_dir, 'symbolic-ref', '--quiet', '--short', 'HEAD').strip
        deployment[:commit] = sha if sha.match?(SHA)
        deployment[:branch] = branch if branch.match?(NAME)
      end
      marker = safe_read(File.join(@repo_dir, '.runtime/heartbeat-status.json'), 8192)
      return deployment unless marker

      data = JSON.parse(marker)
      raise Unavailable unless data.is_a?(Hash)

      status = data['status']
      status = 'unknown' unless %w[running healthy failed].include?(status)
      started = safe_time(data['started_at'])
      finished = safe_time(data['finished_at'])
      latest = finished || started
      status = 'unknown' unless latest
      # Builds and backups are legitimately long-running. Show the start time
      # throughout their bounded 48h execution window; never imply success.
      stale_after = status == 'running' ? 48 * 60 * 60 : 5 * 60
      status = 'stale' if latest && @clock.call.to_i - Time.parse(latest).to_i > stale_after
      deployment.merge(status: status, last_run_at: started, last_success_at: safe_time(data['last_success_at']),
                       message: Redactor.line(data.fetch('message', "Heartbeat #{status}.")))
    rescue JSON::ParserError, Unavailable, SystemCallError, IOError
      errors << { source: 'heartbeat status', message: 'Temporarily unavailable' }
      deployment
    end

    def deployment_marker(name)
      return unless name.match?(NAME)

      value = safe_read(File.join(@repo_dir, '.runtime/deployments', "#{name}.head"), 512)&.lines&.first&.strip
      value if value&.match?(SHA)
    rescue SystemCallError, IOError
      nil
    end

    def sources(containers)
      [{ id: 'heartbeat', label: 'Toolbox heartbeat' }, { id: 'tunnel', label: 'Cloudflare Tunnel' }] +
        containers.reject { |item| item[:transient] }.map { |item| { id: "container:#{item[:name]}", label: item[:name] } }
    end

    def safe_read(path, limit)
      flags = File::RDONLY
      flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
      File.open(path, flags) do |file|
        raise Unavailable unless file.stat.file? && file.stat.size <= limit

        file.read(limit)
      end
    rescue Errno::ENOENT
      nil
    end

    def tail(path, limit)
      flags = File::RDONLY
      flags |= File::NOFOLLOW if defined?(File::NOFOLLOW)
      File.open(path, flags) do |file|
        raise Unavailable unless file.stat.file?

        size = file.stat.size
        truncated = size > limit
        file.seek([size - limit, 0].max)
        content = file.read(limit).to_s
        content = content.sub(/\A[^\n]*\n?/, '') if truncated
        [content, truncated]
      end
    rescue Errno::ENOENT
      ['', false]
    rescue SystemCallError, IOError
      raise Unavailable, 'Logs unavailable'
    end

    def safe_time(value)
      return unless value.is_a?(String) && value.length <= 40

      parsed = Time.iso8601(value)
      parsed.utc.iso8601 if parsed.year >= 2000 && parsed <= @clock.call + 300
    rescue ArgumentError
      nil
    end

    def safe_state(value)
      %w[created restarting running removing paused exited dead].include?(value) ? value : 'unknown'
    end

    def object(line)
      parsed = JSON.parse(line)
      raise Unavailable unless parsed.is_a?(Hash)

      parsed
    end

    def pair(value)
      value.to_s.split('/', 2).map { |part| bytes(part.strip) }.values_at(0, 1)
    end

    def bytes(value)
      match = value.match(/\A(\d+(?:\.\d+)?)\s*(B|kB|KB|MB|GB|TB|KiB|MiB|GiB|TiB)\z/)
      return unless match

      units = { 'B' => 1, 'kB' => 1000, 'KB' => 1000, 'MB' => 1000**2, 'GB' => 1000**3, 'TB' => 1000**4,
                'KiB' => 1024, 'MiB' => 1024**2, 'GiB' => 1024**3, 'TiB' => 1024**4 }
      (match[1].to_f * units.fetch(match[2])).round
    end

    def percent(value)
      value.to_s.match?(/\A\d+(?:\.\d+)?%\z/) ? value.to_f : nil
    end

    def timestamp
      @clock.call.utc.iso8601
    end
  end
end

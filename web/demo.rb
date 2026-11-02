require 'time'

module Dashboard
  # Synthetic preview only. No filesystem, subprocess, Docker, or network reads.
  class Demo
    GIB = 1024**3
    MIB = 1024**2

    def snapshot
      now = Time.now.utc
      names = %w[postcard postgres trivet printing-press redirects wedding-next fonts quesogpt]
      containers = names.each_with_index.map do |name, index|
        { name: name, id: format('%012x', index + 1), image: name == 'postgres' ? 'pgvector/pgvector:pg17' : "#{name}:latest",
          state: 'running', health: index < 2 ? 'healthy' : 'none', configured: true, application: name,
          started_at: (now - 12 * 86_400).iso8601, cpu_percent: [1.7, 0.6, 0.1, 0.2, 0.0, 0.1, 0.0, 0.1][index],
          memory_bytes: [460, 218, 136, 92, 18, 84, 17, 64][index] * MIB,
          memory_limit_bytes: 8 * GIB, memory_percent: [5.6, 2.7, 1.7, 1.1, 0.2, 1.0, 0.2, 0.8][index],
          network_rx_bytes: 143 * MIB, network_tx_bytes: 268 * MIB, block_read_bytes: 31 * MIB,
          block_write_bytes: 87 * MIB, pids: index < 2 ? 17 : 4, restarts: 0, transient: false }
      end
      containers << { name: 'old-preview', id: '000000000099', image: 'preview:2026-10-20', state: 'running', health: 'none',
                      configured: false, transient: false, started_at: (now - 2 * 86_400).iso8601,
                      cpu_percent: 0.2, memory_bytes: 73 * MIB, memory_limit_bytes: 8 * GIB, memory_percent: 0.9,
                      network_rx_bytes: 3 * MIB, network_tx_bytes: 8 * MIB,
                      block_read_bytes: 5 * MIB, block_write_bytes: 9 * MIB, pids: 2, restarts: 0 }
      applications = names.map do |name|
        { name: name, type: 'docker', configured: true, status: 'running', container_name: name }
      end
      applications << { name: 'cloudflared', type: 'host', configured: true, status: 'unknown' }
      {
        generated_at: now.iso8601,
        host: { name: 'Mac mini · Demo', os: 'macOS · synthetic preview', uptime_seconds: 12 * 86_400 + 9 * 3600,
                cpu_count: 10, load_average: [1.84, 1.62, 1.41],
                memory: { total_bytes: 24 * GIB, used_bytes: (14.3 * GIB).to_i, available_bytes: (9.7 * GIB).to_i, pressure: 'Normal' },
                disk: { total_bytes: (460.4 * GIB).to_i, free_bytes: (35.2 * GIB).to_i,
                        available_bytes: (225.5 * GIB).to_i, used_percent: 92, effective_used_percent: 52,
                        level: 'warning', minimum_free_bytes: 20 * GIB },
                docker_disk: { allocated_bytes: (15.5 * GIB).to_i, logical_bytes: 1024 * GIB } },
        deployment: { status: 'healthy', branch: 'main', commit: '8e2d4e09e484e6213666379dbdbca30c601916d4',
                      last_run_at: (now - 22).iso8601, last_success_at: (now - 19).iso8601,
                      message: 'All configured services checked successfully. Deployments follow main.' },
        applications: applications, containers: containers, warnings: [], errors: [],
        log_sources: [{ id: 'heartbeat', label: 'Toolbox heartbeat' }, { id: 'tunnel', label: 'Cloudflare Tunnel' }] +
          containers.map { |container| { id: "container:#{container[:name]}", label: container[:name] } }
      }
    end

    def logs(source, lines: 100)
      now = Time.now.utc
      messages = case source
                 when 'heartbeat'
                   ['Heartbeat started', 'Verified production checkout: main',
                    'Disk check: 35.2 GiB immediately free; 225.5 GiB available with reclaimable space',
                    'postcard: current image is running', 'postgres: current image is running',
                    'trivet: current image is running', 'printing-press: current image is running',
                    'redirects: current image is running', 'wedding-next: current image is running',
                    'fonts: current image is running', 'quesogpt: current image is running',
                    'Cloudflare Tunnel is running', 'Database backup is recent',
                    'All services started successfully', 'Heartbeat completed']
                 when 'tunnel'
                   ['Tunnel connection registered', 'Configuration update applied', 'Connection healthy']
                 else
                   ['Application started', 'Listening for requests', 'GET /health 200', 'Request completed successfully']
                 end
      content = messages.each_with_index.map do |message, index|
        "#{(now - messages.length + index).iso8601}  INFO  #{message}"
      end
      { source: source, updated_at: now.iso8601, lines: content.last(lines), truncated: content.length > lines }
    end
  end
end

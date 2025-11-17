require 'fileutils'
require 'open3'
require 'shellwords'
require 'time'

require_relative '../config'
require_relative '../lib/docker_service'
require_relative '../lib/one_password'

module Scripts
  class PostgresBackup
    LOCK_FILE = File.expand_path('../postgres_backup.lock.txt', __dir__)
    LAST_SUCCESS_FILE = File.expand_path('../postgres_backup.last_success.txt', __dir__)
    LOCK_TIMEOUT = 3600 # seconds
    MIN_INTERVAL = 86_400 # seconds (24 hours)
    TMP_DIR = '/tmp'
    AWS_ITEM = 'toolbox'
    AWS_ACCESS_KEY_FIELD = 'AWS_ACCESS_KEY_ID'
    AWS_SECRET_KEY_FIELD = 'AWS_SECRET_ACCESS_KEY'
    AWS_REGION_FIELD = 'AWS_REGION'
    AWS_BUCKET_FIELD = 'S3_BUCKET'

    def self.run
      new.run
    end

    def initialize
      @timestamp = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
    end

    def run
      with_lock do
        last_run = last_success_time
        if last_run && Time.now.utc - last_run < MIN_INTERVAL
          log(:info, "Skipping backup; last success at #{last_run.utc.iso8601}.")
          next
        end

        dump_path = nil
        begin
          dump_path = export_databases
          upload_to_s3(dump_path)
          mark_success
          log(:info, 'Postgres backup completed successfully.')
        ensure
          cleanup_tempfile(dump_path)
        end
      end
    end

    private

    def with_lock
      acquire_lock
      yield
    ensure
      release_lock
    end

    def acquire_lock
      return if @lock_acquired

      FileUtils.mkdir_p(File.dirname(LOCK_FILE))

      loop do
        begin
          File.open(LOCK_FILE, File::WRONLY | File::CREAT | File::EXCL) do |file|
            file.write(lock_timestamp)
          end
          @lock_acquired = true
          log(:debug, 'Lock acquired.')
          break
        rescue Errno::EEXIST
          if lock_stale?
            log(:warn, 'Stale lock detected, removing...')
            File.delete(LOCK_FILE)
            next
          end

          timestamp = lock_file_timestamp
          raise "[PostgresBackup] Backup already running since #{timestamp || 'unknown time'}."
        end
      end
    end

    def release_lock
      return unless @lock_acquired

      File.delete(LOCK_FILE) if File.exist?(LOCK_FILE)
      @lock_acquired = false
      log(:debug, 'Lock released.')
    end

    def lock_timestamp
      @lock_timestamp ||= Time.now.utc.iso8601
    end

    def lock_file_timestamp
      return unless File.exist?(LOCK_FILE)

      content = File.read(LOCK_FILE).strip
      Time.parse(content)
    rescue ArgumentError
      nil
    end

    def lock_stale?
      timestamp = lock_file_timestamp
      return true unless timestamp

      Time.now.utc - timestamp > LOCK_TIMEOUT
    end

    def export_databases
      ensure_postgres_running!

      dump_path = File.join(TMP_DIR, "postgres-#{@timestamp}.sql.gz")
      log(:info, "Starting Postgres export to #{dump_path}...")

      command = <<~CMD
        set -euo pipefail
        docker exec -i -e PGPASSWORD=#{Shellwords.escape(postgres_password)} #{Shellwords.escape(postgres_container_name)} pg_dumpall -U #{Shellwords.escape(postgres_user)} | gzip -c > #{Shellwords.escape(dump_path)}
      CMD

      started_at = Time.now
      stdout = ''
      stderr = ''
      stdout, stderr, status = Open3.capture3('bash', '-lc', command)

      unless status.success?
        log(:error, "pg_dumpall failed: #{stderr.strip}")
        raise "[PostgresBackup] pg_dumpall failed with status #{status.exitstatus}."
      end

      duration = Time.now - started_at
      size = File.exist?(dump_path) ? File.size(dump_path) : 0
      size_mb = size.to_f / (1024 * 1024)
      log(:info, format('Database export finished in %.2fs (%.2f MB).', duration, size_mb))
      log(:debug, stdout.strip) unless stdout.strip.empty?
      log(:warn, stderr.strip) unless stderr.strip.empty?

      dump_path
    rescue Errno::ENOENT => e
      raise "[PostgresBackup] Command failed: #{e.message}"
    end

    def upload_to_s3(dump_path)
      raise '[PostgresBackup] Dump file missing; aborting upload.' unless dump_path && File.exist?(dump_path)

      key = "#{nyc_iso_date}/postgres-#{@timestamp}.sql.gz"
      destination = "s3://#{aws_bucket}/#{key}"
      log(:info, "Uploading #{dump_path} to #{destination}...")

      env = aws_credentials
      started_at = Time.now
      stdout, stderr, status = Open3.capture3(env, 'aws', 's3', 'cp', dump_path, destination, '--only-show-errors')
      unless status.success?
        log(:error, "AWS upload failed: #{stderr.strip}")
        raise "[PostgresBackup] Failed to upload to S3 (status #{status.exitstatus})."
      end

      duration = Time.now - started_at
      log(:info, format('Upload complete in %.2fs.', duration))
      log(:debug, stdout.strip) unless stdout.to_s.strip.empty?
    rescue Errno::ENOENT
      raise '[PostgresBackup] AWS CLI not found. Please install it via Homebrew (`brew install awscli`).'
    end

    def cleanup_tempfile(path)
      return unless path && File.exist?(path)

      File.delete(path)
      log(:debug, "Removed temporary file #{path}.")
    end

    def mark_success
      File.write(LAST_SUCCESS_FILE, Time.now.utc.iso8601)
    end

    def last_success_time
      return unless File.exist?(LAST_SUCCESS_FILE)

      Time.parse(File.read(LAST_SUCCESS_FILE).strip)
    rescue ArgumentError
      nil
    end

    def ensure_postgres_running!
      return if Core::DockerService.container_running?(postgres_container_name)

      raise "[PostgresBackup] Postgres container '#{postgres_container_name}' is not running."
    end

    def postgres_service_config
      @postgres_service_config ||= Config::DOCKER_SERVICES.find { |service| service[:name] == 'postgres' }
      raise "[PostgresBackup] Unable to locate Postgres service configuration." unless @postgres_service_config

      @postgres_service_config
    end

    def postgres_container_name
      postgres_service_config[:name]
    end

    def postgres_env
      @postgres_env ||= Core::OnePassword.resolve_env_vars(postgres_service_config[:environment] || {})
    end

    def postgres_user
      postgres_env.fetch(:POSTGRES_USER) { raise '[PostgresBackup] POSTGRES_USER missing from configuration.' }
    end

    def postgres_password
      postgres_env.fetch(:POSTGRES_PASSWORD) { raise '[PostgresBackup] POSTGRES_PASSWORD missing from configuration.' }
    end

    def aws_credentials
      @aws_credentials ||= {
        'AWS_ACCESS_KEY_ID' => Core::OnePassword.get_item(AWS_ITEM, AWS_ACCESS_KEY_FIELD),
        'AWS_SECRET_ACCESS_KEY' => Core::OnePassword.get_item(AWS_ITEM, AWS_SECRET_KEY_FIELD),
        'AWS_REGION' => Core::OnePassword.get_item(AWS_ITEM, AWS_REGION_FIELD)
      }
    end

    def aws_bucket
      @aws_bucket ||= Core::OnePassword.get_item(AWS_ITEM, AWS_BUCKET_FIELD)
    end

    def nyc_iso_date
      original_tz = ENV['TZ']
      ENV['TZ'] = 'America/New_York'
      Time.now.strftime('%Y-%m-%d')
    ensure
      ENV['TZ'] = original_tz
    end

    def log(level, message)
      puts format('[PostgresBackup][%<level>s] %<time>s - %<message>s',
                  level: level.to_s.upcase,
                  time: Time.now.utc.iso8601,
                  message: message)
    end
  end
end


require 'base64'
require 'fileutils'
require 'json'
require 'net/http'
require 'open3'
require 'openssl'
require 'time'
require 'uri'
require_relative '../config'
require_relative '../lib/git_service'
require_relative '../lib/one_password'

module Scripts
  class GhostBackup
    REPO_URL = 'git@github.com:contraptionco/ghost-backup.git'
    REPO_PATH = File.join(Config::CODE_DIR, 'ghost-backup')
    GHOST_DATA_PATH = File.join(Config::DATA_DIR, 'ghost')
    EXPORTS_DIR = File.join(REPO_PATH, 'exports')
    LOCK_FILE = File.expand_path('../ghost_backup.lock.txt', __dir__)
    LOCK_TIMEOUT = 3600 # seconds
    API_BASE = 'https://write.contraption.co/ghost/api/admin'
    API_VERSION = 'v5'
    MEMBERS_EXPORT_ENDPOINT = '/members/export/'
    CONFIG_EXPORT_ENDPOINT = '/db/'
    API_KEY_ITEM = 'toolbox'
    API_KEY_FIELD = 'GHOST_ADMIN_API_KEY'

    def self.run
      new.run
    end

    def initialize
      @timestamp = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')
    end

    def run
      with_lock do
        ensure_backup_repo
        mirror_ghost_data
        export_members
        export_configuration
        commit_and_push_changes
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
          puts '[GhostBackup] Lock acquired.'
          break
        rescue Errno::EEXIST
          if lock_stale?
            puts '[GhostBackup] Stale lock detected, removing...'
            File.delete(LOCK_FILE)
            next
          end

          timestamp = lock_file_timestamp
          raise "[GhostBackup] Backup already running since #{timestamp || 'an unknown time'}."
        end
      end
    end

    def release_lock
      return unless @lock_acquired

      File.delete(LOCK_FILE) if File.exist?(LOCK_FILE)
      @lock_acquired = false
      puts '[GhostBackup] Lock released.'
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

    def ensure_backup_repo
      unless Dir.exist?(REPO_PATH)
        puts '[GhostBackup] Cloning backup repository...'
        Core::GitService.clone_repo(REPO_URL, REPO_PATH, 'main')
      end

      puts '[GhostBackup] Updating backup repository...'
      Core::GitService.pull_latest(REPO_PATH, 'main')
    end

    def mirror_ghost_data
      raise "[GhostBackup] Source data directory not found: #{GHOST_DATA_PATH}" unless Dir.exist?(GHOST_DATA_PATH)

      destination = File.join(REPO_PATH, 'ghost')
      puts "[GhostBackup] Copying Ghost data into #{destination}..."
      FileUtils.rm_rf(destination)
      FileUtils.mkdir_p(destination)
      FileUtils.cp_r("#{GHOST_DATA_PATH}/.", destination)
    end

    def export_members
      target = File.join(exports_directory, "ghost-members-#{@timestamp}.csv")
      puts "[GhostBackup] Exporting members to #{target}..."
      response = download_admin_resource(MEMBERS_EXPORT_ENDPOINT)
      save_response(response, target)
    end

    def export_configuration
      target = File.join(exports_directory, "ghost-configuration-#{@timestamp}.json")
      puts "[GhostBackup] Exporting configuration to #{target}..."
      response = download_admin_resource(CONFIG_EXPORT_ENDPOINT)
      save_response(response, target)
    end

    def exports_directory
      FileUtils.mkdir_p(EXPORTS_DIR)
      EXPORTS_DIR
    end

    def save_response(response, path)
      File.binwrite(path, response.body)
      path
    end

    def download_admin_resource(endpoint)
      uri = build_uri(endpoint)
      request = Net::HTTP::Get.new(uri)
      request['Authorization'] = "Ghost #{jwt_token}"

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.read_timeout = 120

      response = http.request(request)
      unless response.is_a?(Net::HTTPSuccess)
        raise "[GhostBackup] Failed to download #{endpoint}: #{response.code} #{response.body}"
      end

      response
    end

    def api_key
      @api_key ||= Core::OnePassword.get_item(API_KEY_ITEM, API_KEY_FIELD)
    end

    def jwt_token
      return @jwt_token if defined?(@jwt_token)

      key_id, secret = api_key.split(':')
      raise '[GhostBackup] Invalid Ghost Admin API key format' if key_id.nil? || secret.nil?

      iat = Time.now.to_i
      payload = {
        iat: iat,
        exp: iat + 300,
        aud: '/admin/'
      }
      header = {
        alg: 'HS256',
        typ: 'JWT',
        kid: key_id
      }

      token_body = [
        base64_url_encode(header.to_json),
        base64_url_encode(payload.to_json)
      ].join('.')

      signature = OpenSSL::HMAC.digest('sha256', [secret].pack('H*'), token_body)
      @jwt_token = [token_body, base64_url_encode(signature)].join('.')
    end

    def base64_url_encode(data)
      Base64.urlsafe_encode64(data).tr('=', '')
    end

    def build_uri(endpoint)
      endpoint = endpoint.sub(%r{^/}, '')
      URI.parse("#{API_BASE}/#{API_VERSION}/#{endpoint}")
    end

    def commit_and_push_changes
      Dir.chdir(REPO_PATH) do
        status = `git status --porcelain`.strip
        if status.empty?
          puts '[GhostBackup] No changes detected, skipping commit.'
          return
        end

        run_git!('git add .')
        run_git!("git commit -m \"Automated Ghost backup #{@timestamp}\"")
        run_git!('git push origin main')
      end
    end

    def run_git!(command)
      stdout, stderr, status = Open3.capture3(command)
      raise "[GhostBackup] #{command} failed: #{stderr}" unless status.success?
      stdout
    end
  end
end

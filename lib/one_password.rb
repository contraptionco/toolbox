require 'json'
require 'securerandom'
require 'digest'
require 'fileutils'
require_relative '../config'
require_relative 'command_runner'

module Core
  module OnePassword
    HOST_COMMAND_TIMEOUT = 30
    DOCKER_COMMAND_TIMEOUT = 120
    DOCKER_CLEANUP_TIMEOUT = 15
    BACKEND_ENV_VAR = 'TOOLBOX_OP_BACKEND'
    TOKEN_ENV_VAR = 'OP_SERVICE_ACCOUNT_TOKEN'
    HOST_BACKEND = 'host'
    DOCKER_BACKEND = 'docker'
    DOCKER_IMAGE = '1password/op@sha256:9c1824aac2a52c0b2a1cbc50049db9f122f51535f8f34d7847f0fca66be53c49'
    CACHE_TTL = 3600

    def self.logged_in?
      cached_success(['authenticated']) do
        _stdout, _stderr, status = run_op('whoami', label: '1Password authentication check')
        status.success?
      end
    end

    def self.ensure_logged_in
      return if logged_in?

      if backend == DOCKER_BACKEND
        puts '1Password service-account authentication failed. Check OP_SERVICE_ACCOUNT_TOKEN.'
      else
        puts 'Not logged in to 1Password CLI. Please log in with `eval $(op signin)`'
      end
      exit 1
    end

    def self.get_item(item_name, field_name)
      cached_success(['item', item_name, field_name]) do
        stdout, stderr, status = run_op(
          'item', 'get', item_name,
          '--vault', Config::OP_VAULT,
          '--fields', field_name,
          '--reveal',
          label: '1Password item lookup'
        )
        raise "Error fetching 1Password item: #{redact_token(stderr)}" unless status.success?

        stdout.strip
      end
    end

    # Heartbeats and Docker helpers are separate processes. Only service-account
    # results are cached; interactive accounts keep the CLI's normal behavior.
    def self.cached_success(lookup)
      token = ENV[TOKEN_ENV_VAR].to_s
      return yield if token.empty? || ENV['TOOLBOX_OP_CACHE'] == '0'

      directory = cache_directory
      context = [backend, Config::OP_VAULT, Digest::SHA256.hexdigest(token), lookup]
      key = Digest::SHA256.hexdigest(JSON.generate(context))
      path = File.join(directory, "#{key}.json")
      cached = read_cache_entry(path)
      if ENV['TOOLBOX_OP_REFRESH'] != '1' && cached &&
         cached['key'] == key && cached['fetched_at'].is_a?(Numeric) &&
         (0...CACHE_TTL).cover?(Time.now.to_f - cached['fetched_at']) &&
         (lookup.first == 'authenticated' ? cached['value'] == true : cached['value'].is_a?(String))
        return cached['value']
      end

      # A failed explicit refresh must not resurrect the previously fresh value.
      File.delete(path) if File.exist?(path)
      value = yield
      write_cache_entry(path, key, value) if value
      value
    end
    private_class_method :cached_success

    def self.cache_root
      File.join(Config::RUNTIME_DIR, 'one-password')
    end
    private_class_method :cache_root

    def self.cache_directory
      directory = cache_root
      parent = File.dirname(directory)
      FileUtils.mkdir_p(parent, mode: 0o700)
      parent_stat = File.lstat(parent)
      unless parent_stat.directory? && parent_stat.uid == Process.euid && (parent_stat.mode & 0o022).zero?
        raise '1Password cache parent must be an owned directory without group or world write access'
      end

      begin
        Dir.mkdir(directory, 0o700)
      rescue Errno::EEXIST
        # Validate an existing directory rather than changing its permissions.
      end
      stat = File.lstat(directory)
      unless stat.directory? && stat.uid == Process.euid && (stat.mode & 0o777) == 0o700
        raise '1Password cache directory must be owned by the current user with mode 0700'
      end
      directory
    end
    private_class_method :cache_directory

    def self.read_cache_entry(path)
      File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        stat = file.stat
        unless stat.file? && stat.uid == Process.euid && (stat.mode & 0o777) == 0o600 && stat.nlink == 1
          raise '1Password cache entry must be an owned regular file with mode 0600'
        end
        value = JSON.parse(file.read)
        value if value.is_a?(Hash)
      end
    rescue Errno::ENOENT
      nil
    rescue Errno::ELOOP
      raise '1Password cache entries cannot be symbolic links'
    rescue JSON::ParserError
      nil
    end
    private_class_method :read_cache_entry

    def self.write_cache_entry(path, key, value)
      temporary_path = "#{path}.tmp-#{Process.pid}-#{SecureRandom.hex(8)}"
      File.open(temporary_path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.write(JSON.generate(key: key, fetched_at: Time.now.to_f, value: value))
        file.flush
        file.fsync
      end
      File.rename(temporary_path, path)
    ensure
      File.delete(temporary_path) if temporary_path && File.exist?(temporary_path)
    end
    private_class_method :write_cache_entry

    # Resolve environment variables that may contain 1Password references
    def self.resolve_env_vars(env_vars)
      resolved_env = {}

      env_vars.each do |key, value|
        resolved_env[key] = if value.is_a?(Hash) && value[:type] == '1password'
          get_item(value[:item], value[:field])
        else
          value.to_s
        end
      end

      resolved_env
    end

    def self.run_op(*arguments, label:)
      return run_host_op(arguments, label:) if backend == HOST_BACKEND

      run_docker_op(arguments, label:)
    end
    private_class_method :run_op

    def self.run_host_op(arguments, label:)
      environment = {}
      environment[TOKEN_ENV_VAR] = ENV[TOKEN_ENV_VAR] if ENV.key?(TOKEN_ENV_VAR)
      Core::CommandRunner.capture3(
        'op', *arguments,
        env: environment,
        timeout: HOST_COMMAND_TIMEOUT,
        label: label
      )
    end
    private_class_method :run_host_op

    def self.run_docker_op(arguments, label:)
      token = ENV[TOKEN_ENV_VAR].to_s
      raise "#{TOKEN_ENV_VAR} is required for #{BACKEND_ENV_VAR}=#{DOCKER_BACKEND}" if token.empty?

      container_name = "toolbox-op-#{Process.pid}-#{SecureRandom.hex(8)}"
      result = nil
      primary_error = nil
      cleanup_error = nil

      begin
        result = Core::CommandRunner.capture3(
          'docker', 'run', '--rm',
          '--name', container_name,
          '--log-driver=none',
          '--env', TOKEN_ENV_VAR,
          DOCKER_IMAGE, 'op', '--cache=false', *arguments,
          env: { TOKEN_ENV_VAR => token },
          timeout: DOCKER_COMMAND_TIMEOUT,
          label: label
        )
      rescue StandardError => e
        primary_error = e
      ensure
        begin
          cleanup_docker_container(container_name)
        rescue StandardError => e
          cleanup_error = e
        end
      end

      if cleanup_error
        if primary_error || (result && !result.fetch(2).success?)
          warn "#{cleanup_error.message}; the original 1Password failure is preserved."
        else
          raise cleanup_error
        end
      end
      raise primary_error if primary_error

      result
    end
    private_class_method :run_docker_op

    def self.cleanup_docker_container(container_name)
      _stdout, stderr, status = Core::CommandRunner.capture3(
        'docker', 'rm', '--force', container_name,
        env: { TOKEN_ENV_VAR => nil },
        timeout: DOCKER_CLEANUP_TIMEOUT,
        label: '1Password Docker container cleanup'
      )
      return if status.success? || stderr.include?('No such container')

      raise "1Password Docker container cleanup failed: #{redact_token(stderr).strip}"
    end
    private_class_method :cleanup_docker_container

    def self.backend
      selected = ENV.fetch(BACKEND_ENV_VAR, HOST_BACKEND).strip.downcase
      return selected if [HOST_BACKEND, DOCKER_BACKEND].include?(selected)

      raise ArgumentError,
            "Unsupported #{BACKEND_ENV_VAR}; expected #{HOST_BACKEND.inspect} or #{DOCKER_BACKEND.inspect}"
    end
    private_class_method :backend

    def self.redact_token(message)
      token = ENV[TOKEN_ENV_VAR].to_s
      return message.to_s if token.empty?

      message.to_s.gsub(token, '[REDACTED]')
    end
    private_class_method :redact_token
  end
end

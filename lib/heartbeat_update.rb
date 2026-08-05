require 'rbconfig'
require_relative 'command_runner'
require_relative 'disk_monitor'

module Core
  class HeartbeatUpdate
    GIT_TIMEOUT = 120
    ASDF_TIMEOUT = 600
    # Toolbox runs bounded backup and deploy commands sequentially. A legal
    # worst-case pass can include a two-hour database backup plus one-hour
    # builds for every configured Git service. Keep an outer backstop without
    # interrupting those individually bounded child process groups.
    TOOLBOX_TIMEOUT = 48 * 60 * 60
    BRANCH = 'main'
    REMOTE_REF = 'refs/remotes/origin/main'

    def initialize(repo_dir, command_runner: Core::CommandRunner, disk_monitor: Core::DiskMonitor,
                   stdout: $stdout, stderr: $stderr)
      @repo_dir = repo_dir
      @command_runner = command_runner
      @disk_monitor = disk_monitor
      @stdout = stdout
      @stderr = stderr
    end

    def update
      disk_status = @disk_monitor.check
      raise "Disk usage is #{disk_status.percent_used}%; refusing Toolbox update" if disk_status.critical?

      log 'Fetching Toolbox main...'
      git!('fetch', '--no-tags', 'origin', "refs/heads/#{BRANCH}:#{REMOTE_REF}", label: 'Toolbox Git fetch')
      ensure_clean!

      unless current_branch == BRANCH
        log "Switching Toolbox checkout to #{BRANCH}..."
        git!('switch', BRANCH, label: 'Toolbox Git switch')
      end
      verify_main!

      upstream = git!('rev-parse', REMOTE_REF, label: 'Toolbox upstream lookup').strip
      local = git!('rev-parse', 'HEAD', label: 'Toolbox HEAD lookup').strip
      git!('merge-base', '--is-ancestor', 'HEAD', REMOTE_REF, label: 'Toolbox fast-forward check')
      changed = upstream != local

      if changed
        log 'Toolbox changes detected; fast-forwarding main...'
        git!('merge', '--ff-only', REMOTE_REF, label: 'Toolbox fast-forward merge')
        pulled = git!('rev-parse', 'HEAD', label: 'Toolbox pulled HEAD lookup').strip
        raise 'Toolbox pull did not reach origin/main' unless pulled == upstream

        install_dependencies
      else
        log 'No Toolbox changes detected.'
      end

      verify_synced_main!
      changed
    end

    def update_and_run
      changed = update
      mode = changed ? 'code_changed' : 'no_changes'
      verify_synced_main!
      status = @command_runner.run(
        RbConfig.ruby, 'toolbox.rb', mode,
        env: toolbox_environment,
        chdir: @repo_dir,
        timeout: TOOLBOX_TIMEOUT,
        out: @stdout,
        err: @stderr,
        label: 'Toolbox service run'
      )
      raise "Toolbox service run failed with status #{status.exitstatus}" unless status.success?

      true
    end

    private

    def current_branch
      git!('symbolic-ref', '--quiet', '--short', 'HEAD', label: 'Toolbox branch lookup').strip
    end

    def ensure_clean!
      status = git!('status', '--porcelain', label: 'Toolbox worktree check')
      raise 'Toolbox worktree is dirty; refusing automated update' unless status.strip.empty?
    end

    def verify_main!
      raise "Toolbox checkout is not #{BRANCH}; refusing to update" unless current_branch == BRANCH
    end

    def verify_synced_main!
      verify_main!
      ensure_clean!
      head = git!('rev-parse', 'HEAD', label: 'Toolbox final HEAD lookup').strip
      upstream = git!('rev-parse', REMOTE_REF, label: 'Toolbox final upstream lookup').strip
      raise 'Toolbox main does not match origin/main; refusing to run' unless head == upstream
    end

    def install_dependencies
      asdf = find_executable('asdf')
      unless asdf
        log 'asdf not found; skipping dependency installation.'
        return
      end

      log 'Installing Toolbox dependencies via asdf...'
      run!(asdf, 'install', label: 'Toolbox asdf install', timeout: ASDF_TIMEOUT)
    end

    def toolbox_environment
      token = ENV['OP_SERVICE_ACCOUNT_TOKEN'].to_s
      token.empty? ? {} : { 'OP_SERVICE_ACCOUNT_TOKEN' => token }
    end

    def find_executable(name)
      ENV.fetch('PATH', '').split(File::PATH_SEPARATOR).each do |directory|
        candidate = File.join(directory, name)
        return candidate if File.file?(candidate) && File.executable?(candidate)
      end
      nil
    end

    def run!(*command, label:, timeout: GIT_TIMEOUT)
      stdout, stderr, status = @command_runner.capture3(
        *command,
        env: { 'GIT_TERMINAL_PROMPT' => '0' },
        chdir: @repo_dir,
        timeout: timeout,
        label: label
      )
      raise "#{label} failed: #{stderr.strip}" unless status.success?

      stdout
    end

    def git!(*arguments, label:)
      run!('git', *arguments, label: label)
    end

    def log(message)
      @stderr.puts "#{Time.now}: #{message}"
    end
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    repo_dir = ARGV.fetch(0)
    Core::HeartbeatUpdate.new(repo_dir).update_and_run
  rescue StandardError => e
    warn "Heartbeat update failed: #{e.message}"
    exit 1
  end
end

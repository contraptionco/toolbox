require 'cgi'
require 'json'
require 'net/http'
require 'fileutils'
require 'rbconfig'
require_relative 'production_guard'
require_relative 'command_runner'
require_relative '../config'

module Core
  # Manage only the dashboard's own LaunchAgent. It has no 1Password token and
  # binds only to loopback. A dashboard problem must not prevent app deployments.
  class DashboardService
    LABEL = 'co.contraption.toolbox.dashboard'
    DEPENDENCY_TIMEOUT = 180

    def self.ensure_running
      return true unless Config.const_defined?(:DASHBOARD) && Config::DASHBOARD[:enabled]
      new.ensure_running
    end

    def initialize(repo_dir: File.expand_path('..', __dir__), home_dir: Config::HOME_DIR,
                   runner: Core::CommandRunner, health_reader: nil, sleeper: ->(seconds) { sleep(seconds) },
                   uid: Process.uid, ruby: RbConfig.ruby)
      @repo, @home, @runner, @sleeper, @uid, @ruby = repo_dir, home_dir, runner, sleeper, uid, ruby
      @runtime = File.join(@repo, '.runtime', 'dashboard')
      @health_reader = health_reader || method(:health)
    end

    def ensure_running
      Core::ProductionGuard.validate_directory!(@repo)
      Core::ProductionGuard.verify_checkout!(@repo, command_runner: @runner)
      revision = capture!('git', 'rev-parse', 'HEAD').strip
      raise 'Invalid dashboard revision' unless revision.match?(/\A[0-9a-f]{40}\z/)
      return true if @health_reader.call == revision

      FileUtils.mkdir_p(@runtime, mode: 0o700)
      install_dependencies
      path = File.join(@home, 'Library', 'LaunchAgents', "#{LABEL}.plist")
      content = plist
      changed = !File.file?(path) || File.binread(path) != content
      if changed
        FileUtils.mkdir_p(File.dirname(path))
        atomic_write(path, content)
        # A missing agent is expected on first install. Never stop other labels.
        capture('launchctl', 'bootout', "gui/#{@uid}/#{LABEL}")
        capture!('launchctl', 'bootstrap', "gui/#{@uid}", path)
      else
        _out, _err, status = capture('launchctl', 'kickstart', '-k', "gui/#{@uid}/#{LABEL}")
        capture!('launchctl', 'bootstrap', "gui/#{@uid}", path) unless status.success?
      end
      20.times do
        return true if @health_reader.call == revision
        @sleeper.call(0.5)
      end
      raise 'Dashboard did not become ready on loopback'
    end

    def plist
      escape = ->(value) { CGI.escapeHTML(value.to_s) }
      environment = bundle_environment.merge(
        'HOME' => @home,
        'PATH' => "#{File.dirname(@ruby)}:#{@home}/.asdf/shims:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        'LANG' => 'en_US.UTF-8',
        'TOOLBOX_PRODUCTION_REPO_DIR' => @repo
      )
      entries = environment.map { |key, value| "<key>#{escape.call(key)}</key><string>#{escape.call(value)}</string>" }.join("\n")
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>#{LABEL}</string>
          <key>ProgramArguments</key><array><string>#{escape.call(@ruby)}</string><string>#{escape.call(File.join(@repo, 'web', 'server.rb'))}</string><string>--production</string></array>
          <key>WorkingDirectory</key><string>#{escape.call(@repo)}</string>
          <key>EnvironmentVariables</key><dict>#{entries}</dict>
          <key>RunAtLoad</key><true/>
          <key>KeepAlive</key><true/>
          <key>ThrottleInterval</key><integer>15</integer>
          <key>ProcessType</key><string>Background</string>
          <key>StandardOutPath</key><string>/dev/null</string>
          <key>StandardErrorPath</key><string>/dev/null</string>
        </dict></plist>
      XML
    end

    private

    def bundle_environment
      { 'BUNDLE_GEMFILE' => File.join(@repo, 'Gemfile'), 'BUNDLE_PATH' => File.join(@runtime, 'gems'),
        'BUNDLE_APP_CONFIG' => File.join(@runtime, 'bundle-config'), 'BUNDLE_WITHOUT' => 'test',
        'BUNDLE_FROZEN' => 'true' }
    end

    def install_dependencies
      bundle = File.join(File.dirname(@ruby), 'bundle')
      _out, _err, status = capture(@ruby, bundle, 'check', env: bundle_environment)
      return if status.success?
      capture!(@ruby, bundle, 'install', '--quiet', env: bundle_environment, timeout: DEPENDENCY_TIMEOUT)
    end

    def health
      response = Net::HTTP.start('127.0.0.1', Config::DASHBOARD.fetch(:port), open_timeout: 1, read_timeout: 1) do |http|
        http.get('/healthz')
      end
      return nil unless response.is_a?(Net::HTTPSuccess) && response.body.bytesize < 1024
      value = JSON.parse(response.body)
      value['revision'] if value['ok'] == true
    rescue StandardError
      nil
    end

    def capture(*args, env: {}, timeout: 15)
      @runner.capture3(*args, env: env, chdir: @repo, timeout: timeout, label: 'Dashboard service', capture_limit: 16_384)
    end

    def capture!(*args, **options)
      output, _error, status = capture(*args, **options)
      raise 'Dashboard service command failed; application services are unaffected' unless status.success?
      output
    end

    def atomic_write(path, content)
      temp = "#{path}.#{Process.pid}.tmp"
      begin
        File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(content) }
        File.chmod(0o600, temp)
        File.rename(temp, path)
      ensure
        File.delete(temp) if File.exist?(temp)
      end
    end
  end
end

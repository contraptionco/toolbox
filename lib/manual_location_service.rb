require 'cgi'
require 'digest'
require 'fileutils'
require 'json'
require 'net/http'
require 'rbconfig'
require_relative 'production_guard'
require_relative 'command_runner'
require_relative 'manual_location/config'
require_relative '../config'

module Core
  # Optional native helper with one narrow credential, isolated from deployment
  # credentials. Missing configuration means disabled, not an unhealthy service.
  class ManualLocationService
    LABEL = 'co.contraption.toolbox.manual-location'
    PORT = 4180

    def self.ensure_running
      new.ensure_running
    end

    def initialize(repo_dir: File.expand_path('..', __dir__), home_dir: Config::HOME_DIR,
                   runner: Core::CommandRunner, health_reader: nil, sleeper: ->(seconds) { sleep(seconds) },
                   uid: Process.uid, ruby: RbConfig.ruby)
      @repo, @home, @runner, @sleeper, @uid, @ruby = repo_dir, home_dir, runner, sleeper, uid, ruby
      @runtime = File.join(@repo, '.runtime', 'manual-location')
      @health_reader = health_reader || method(:health)
    end

    def ensure_running
      config_path = File.join(@runtime, 'config.json')
      unless File.exist?(config_path)
        path = File.join(@home, 'Library', 'LaunchAgents', "#{LABEL}.plist")
        if File.file?(path)
          Core::ProductionGuard.validate_directory!(@repo)
          Core::ProductionGuard.verify_checkout!(@repo, command_runner: @runner)
          capture('launchctl', 'bootout', "gui/#{@uid}/#{LABEL}")
          File.delete(path)
        end
        return true
      end
      Core::ProductionGuard.validate_directory!(@repo)
      Core::ProductionGuard.verify_checkout!(@repo, command_runner: @runner)
      ManualLocation::Configuration.load(config_path)
      revision = capture!('git', 'rev-parse', 'HEAD').strip
      raise 'Invalid location bridge revision' unless revision.match?(/\A[0-9a-f]{40}\z/)
      expected = "#{revision}:#{Digest::SHA256.file(config_path).hexdigest}"
      return true if @health_reader.call == expected

      install_dependencies
      compile_reader
      path = File.join(@home, 'Library', 'LaunchAgents', "#{LABEL}.plist")
      content = plist
      changed = !File.file?(path) || File.binread(path) != content
      if changed
        FileUtils.mkdir_p(File.dirname(path))
        atomic_write(path, content)
        capture('launchctl', 'bootout', "gui/#{@uid}/#{LABEL}")
        capture!('launchctl', 'bootstrap', "gui/#{@uid}", path)
      else
        _out, _err, status = capture('launchctl', 'kickstart', '-k', "gui/#{@uid}/#{LABEL}")
        capture!('launchctl', 'bootstrap', "gui/#{@uid}", path) unless status.success?
      end
      20.times do
        return true if @health_reader.call == expected
        @sleeper.call(0.5)
      end
      raise 'Location bridge did not become ready on loopback'
    end

    def plist
      escape = ->(value) { CGI.escapeHTML(value.to_s) }
      environment = bundle_environment.merge(
        'HOME' => @home,
        'PATH' => "#{File.dirname(@ruby)}:/usr/bin:/bin:/usr/sbin:/sbin",
        'LANG' => 'en_US.UTF-8',
        'TOOLBOX_PRODUCTION_REPO_DIR' => @repo
      )
      entries = environment.map { |key, value| "<key>#{escape.call(key)}</key><string>#{escape.call(value)}</string>" }.join("\n")
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0"><dict>
          <key>Label</key><string>#{LABEL}</string>
          <key>ProgramArguments</key><array><string>#{escape.call(@ruby)}</string><string>#{escape.call(File.join(@repo, 'native', 'manual_location_server.rb'))}</string><string>--production</string></array>
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
        'BUNDLE_APP_CONFIG' => File.join(@runtime, 'bundle-config'), 'BUNDLE_WITHOUT' => 'test', 'BUNDLE_FROZEN' => 'true' }
    end

    def install_dependencies
      bundle = File.join(File.dirname(@ruby), 'bundle')
      _out, _err, status = capture(@ruby, bundle, 'check', env: bundle_environment)
      capture!(@ruby, bundle, 'install', '--quiet', env: bundle_environment, timeout: 180) unless status.success?
    end

    def compile_reader
      source = File.join(@repo, 'native', 'find_my_reader.swift')
      executable = File.join(@runtime, 'find-my-reader')
      marker = File.join(@runtime, 'reader.sha256')
      hash = Digest::SHA256.file(source).hexdigest
      return if File.executable?(executable) && File.file?(marker) && File.read(marker).strip == hash
      temporary = "#{executable}.tmp-#{Process.pid}"
      begin
        capture!('/usr/bin/xcrun', 'swiftc', '-O', source, '-o', temporary, timeout: 180)
        File.chmod(0o700, temporary)
        File.rename(temporary, executable)
        atomic_write(marker, hash)
      ensure
        File.delete(temporary) if File.exist?(temporary)
      end
    end

    def health
      response = Net::HTTP.start('127.0.0.1', PORT, open_timeout: 1, read_timeout: 1) { |http| http.get('/healthz') }
      return nil unless response.is_a?(Net::HTTPSuccess) && response.body.bytesize < 1024
      value = JSON.parse(response.body)
      value['revision'] if value['ok'] == true
    rescue StandardError
      nil
    end

    def capture(*args, env: {}, timeout: 15)
      @runner.capture3(*args, env: env, chdir: @repo, timeout: timeout, label: 'Location bridge service', capture_limit: 16_384)
    end

    def capture!(*args, **options)
      output, _error, status = capture(*args, **options)
      raise 'Location bridge command failed; application services are unaffected' unless status.success?
      output
    end

    def atomic_write(path, content)
      temp = "#{path}.#{Process.pid}.tmp"
      begin
        File.open(temp, File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(content) }
        File.rename(temp, path)
      ensure
        File.delete(temp) if File.exist?(temp)
      end
    end
  end
end

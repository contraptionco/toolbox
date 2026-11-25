require 'fileutils'
require_relative 'production_guard'
require_relative 'command_runner'
require_relative '../config'

module Core
  # A narrow, permanent retirement hook prevents an old installed KeepAlive
  # LaunchAgent from restarting a helper that Manual no longer uses.
  class RetiredManualLocation
    LABEL = 'co.contraption.toolbox.manual-location'
    ABSENT_EXIT_STATUS = 3 # launchctl reports ESRCH for an unloaded service.

    def self.remove
      new.remove
    end

    def initialize(repo_dir: File.expand_path('..', __dir__), home_dir: Config::HOME_DIR,
                   runner: Core::CommandRunner, uid: Process.uid)
      @repo, @home, @runner, @uid = repo_dir, home_dir, runner, uid
    end

    def remove
      Core::ProductionGuard.validate_directory!(@repo)
      Core::ProductionGuard.verify_checkout!(@repo, command_runner: @runner)
      runtime_root = File.join(@repo, '.runtime')
      launch_root = File.join(@home, 'Library', 'LaunchAgents')
      # Never follow a substituted parent directory into unrelated state.
      [runtime_root, @home, File.join(@home, 'Library'), launch_root].each do |path|
        raise 'Retired location cleanup refuses a symlinked parent directory' if File.symlink?(path)
      end

      _output, _error, status = @runner.capture3(
        'launchctl', 'bootout', "gui/#{@uid}/#{LABEL}",
        chdir: @repo, timeout: 15, capture_limit: 1024,
        label: 'Retired location bridge cleanup'
      )
      unless status.success? || status.exitstatus == ABSENT_EXIT_STATUS
        raise 'Could not unload the retired location bridge; its files were preserved'
      end

      plist = File.join(launch_root, "#{LABEL}.plist")
      File.unlink(plist) if File.exist?(plist) || File.symlink?(plist)
      runtime = File.join(runtime_root, 'manual-location')
      FileUtils.remove_entry_secure(runtime) if File.exist?(runtime) || File.symlink?(runtime)
      true
    end
  end
end

module Core
  module ProductionGuard
    class Error < StandardError; end

    def self.production_directory(environment = ENV)
      configured = environment['TOOLBOX_PRODUCTION_REPO_DIR']
      directory = if configured && !configured.empty?
                    configured
                  else
                    home = environment['HOME']
                    raise Error, 'HOME is missing; cannot identify the production checkout' if home.to_s.empty?

                    File.join(home, 'code', 'toolbox')
                  end
      raise Error, 'Production checkout path must be absolute' unless directory.start_with?('/')

      directory
    end

    def self.validate_directory!(directory, environment: ENV)
      production = production_directory(environment)
      actual = File.realpath(directory)
      expected = File.realpath(production)
      unless actual == expected
        raise Error, "Refusing production actions outside the intended checkout: #{production}"
      end

      override = environment['TOOLBOX_REPO_DIR']
      if override && !override.empty?
        unless override.start_with?('/') && File.realpath(override) == expected
          raise Error, 'TOOLBOX_REPO_DIR must match the intended production checkout'
        end
      end
      actual
    rescue Errno::ENOENT, Errno::ENOTDIR => e
      raise Error, "Production checkout is unavailable (#{e.class})"
    end

    def self.require_production!(directory, arguments:, environment: ENV, modes: [])
      unless arguments.first == '--production'
        raise Error, 'Production actions require --production from the intended production checkout'
      end
      remaining = arguments.drop(1)
      unless remaining.empty? || (remaining.length == 1 && modes.include?(remaining.first))
        raise Error, 'Unexpected production arguments; refusing to run'
      end

      validate_directory!(directory, environment: environment)
    end

    # Direct runs must satisfy the same source requirements as heartbeat runs.
    # Only local Git state is inspected; the heartbeat owns fetching updates.
    def self.verify_checkout!(directory, command_runner:)
      git = lambda do |*arguments|
        stdout, stderr, status = command_runner.capture3(
          'git', *arguments,
          env: { 'GIT_TERMINAL_PROMPT' => '0', 'GIT_OPTIONAL_LOCKS' => '0' },
          chdir: directory,
          timeout: 120,
          label: 'Toolbox production source check'
        )
        raise Error, "Toolbox production source check failed: #{stderr.strip}" unless status.success?

        stdout.strip
      end

      raise Error, 'Toolbox checkout is not main; refusing to run' unless git.call('symbolic-ref', '--quiet', '--short', 'HEAD') == 'main'
      status = git.call('status', '--porcelain', '--untracked-files=all', '--ignore-submodules=none')
      raise Error, 'Toolbox worktree is dirty; refusing to run' unless status.empty?

      head = git.call('rev-parse', 'HEAD')
      upstream = git.call('rev-parse', 'refs/remotes/origin/main')
      raise Error, 'Toolbox main does not match origin/main; refusing to run' unless head == upstream
    end
  end
end

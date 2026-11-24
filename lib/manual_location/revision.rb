require 'digest'

module ManualLocation
  module Revision
    # Unrelated application deployments must not empty the location cache.
    # Any helper code, dependency, interpreter, or credential change still
    # restarts this process. Paths are fixed; no request can choose a file.
    FILES = %w[
      Gemfile Gemfile.lock
      native/manual_location_server.rb native/find_my_reader.swift
      lib/manual_location_service.rb lib/production_guard.rb lib/command_runner.rb
      lib/manual_location/config.rb lib/manual_location/find_my_source.rb
      lib/manual_location/app.rb lib/manual_location/revision.rb
    ].freeze

    def self.current(repo:, config_path:, ruby:, home:)
      digest = Digest::SHA256.new
      FILES.each do |relative|
        digest << relative << "\0" << Digest::SHA256.file(File.join(repo, relative)).hexdigest << "\0"
      end
      digest << File.expand_path(repo) << "\0" << home << "\0" << ruby << "\0" << Digest::SHA256.file(config_path).hexdigest
      "v2:#{digest.hexdigest}"
    end
  end
end

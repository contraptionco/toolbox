require 'json'

module ManualLocation
  class ConfigurationError < StandardError; end

  # This file is deliberately separate from the heartbeat's 1Password token.
  # The bridge receives only its narrow key. Manual sends only explicitly mapped, authorized people.
  class Configuration
    UUID = /\A[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/i
    MAX_BYTES = 32_768
    attr_reader :key

    def self.load(path)
      File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        stat = file.stat
        unless stat.file? && stat.uid == Process.euid && (stat.mode & 0o777) == 0o600 && stat.nlink == 1 && stat.size <= MAX_BYTES
          raise ConfigurationError, 'Location bridge configuration must be an owned private file.'
        end
        new(JSON.parse(file.read(MAX_BYTES + 1)))
      end
    rescue JSON::ParserError, Errno::ELOOP, Errno::ENOENT
      raise ConfigurationError, 'Location bridge configuration is unavailable.'
    end

    def initialize(value)
      unless value.is_a?(Hash) && value.keys == ['key'] && value['key'].is_a?(String) && value['key'].match?(/\A[A-Za-z0-9_-]{43,128}\z/)
        raise ConfigurationError, 'Location bridge configuration is invalid.'
      end
      @key = value['key'].freeze
    end
  end
end

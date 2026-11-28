require 'json'
require 'uri'

module Dashboard
  # The heartbeat writes only this dashboard's credentials, never its own vault
  # token or other applications' environment, into a private runtime file.
  module Settings
    KEYS = %w[secret smtp_host smtp_port smtp_user smtp_password smtp_from].freeze
    # Keep the previous sender valid while its private configuration is migrated.
    SENDERS = ['Toolbox <toolbox@contraption.co>', 'Toolbox <toolbox@ilic.nyc>'].freeze

    def self.parse(raw)
      raise ArgumentError, 'Invalid dashboard credential configuration' unless raw.is_a?(String) && raw.bytesize <= 16_384
      value = JSON.parse(raw)
      valid = value.is_a?(Hash) && value.keys.sort == KEYS.sort &&
        value['secret'].is_a?(String) && value['secret'].match?(/\A[0-9a-f]{64}\z/) &&
        value['smtp_host'].is_a?(String) && value['smtp_host'].match?(/\Aemail-smtp\.[a-z0-9-]+\.amazonaws\.com\z/) &&
        [465, 587].include?(value['smtp_port']) &&
        %w[smtp_user smtp_password].all? { |key| value[key].is_a?(String) && value[key].bytesize.between?(1, 512) && !value[key].match?(/[\r\n\x00]/) } &&
        SENDERS.include?(value['smtp_from'])
      raise ArgumentError, 'Invalid dashboard credential configuration' unless valid
      value
    rescue JSON::ParserError
      raise ArgumentError, 'Invalid dashboard credential configuration'
    end

    def self.load(path)
      File.open(path, File::RDONLY | File::NOFOLLOW | File::NONBLOCK) do |file|
        stat = file.stat
        raise ArgumentError, 'Dashboard credential file must be private and owned' unless stat.file? && stat.uid == Process.euid && (stat.mode & 0o777) == 0o600 && stat.nlink == 1
        parse(file.read(16_385))
      end
    end
  end
end

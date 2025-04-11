require 'json'
require 'open3'
require_relative '../config'

module Core
  module OnePassword
    def self.logged_in?
      stdout, stderr, status = Open3.capture3('op whoami')
      status.success?
    end

    def self.ensure_logged_in
      return if logged_in?

      puts 'Not logged in to 1Password CLI. Please log in with `eval $(op signin)`'
      exit 1
    end

    def self.get_item(item_name, field_name)
      cmd = "op item get \"#{item_name}\" --vault \"#{Config::OP_VAULT}\" --fields \"#{field_name}\""
      cmd += ' --reveal' if %w[password secret_access_key].include?(field_name.to_s.downcase)

      stdout, stderr, status = Open3.capture3(cmd)
      raise "Error fetching 1Password item: #{stderr}" unless status.success?

      stdout.strip
    end

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
  end
end
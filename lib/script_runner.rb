require 'open3'
require_relative '../config'

module Core
  module ScriptRunner
    def self.run_scripts
      return unless Config.const_defined?(:SCRIPTS)

      Config::SCRIPTS.each do |script_config|
        next if script_config[:enabled] == false

        puts "Running script: #{script_config[:name]}..."

        case script_config[:type].to_s
        when 'shell'
          run_shell_script(script_config)
        when 'ruby'
          run_ruby_script(script_config)
        else
          puts "Unknown script type '#{script_config[:type]}' for #{script_config[:name]}, skipping."
        end
      end
    end

    def self.run_shell_script(script_config)
      command = script_config[:command]
      raise "Shell command missing for #{script_config[:name]}" if command.to_s.strip.empty?

      stdout, stderr, status = Open3.capture3(command)
      puts stdout unless stdout.strip.empty?
      raise "Script #{script_config[:name]} failed: #{stderr}" unless status.success?
    end

    def self.run_ruby_script(script_config)
      require_path = script_config[:require]
      require_relative File.join('..', require_path) if require_path

      class_name = script_config[:class_name]
      raise "class_name missing for #{script_config[:name]}" if class_name.to_s.strip.empty?

      klass = constantize(class_name)
      method = script_config[:method] || :run
      args = Array(script_config[:args] || [])

      if klass.respond_to?(method)
        klass.public_send(method, *args)
      else
        klass.new.public_send(method, *args)
      end
    end

    def self.constantize(name)
      name.split('::').inject(Object) { |mod, const| mod.const_get(const) }
    end
  end
end

#!/usr/bin/env ruby
require_relative '../lib/production_guard'

# A development server has only synthetic fixture data. There is deliberately no
# switch that disables authentication while reading the production host.
demo = ARGV == ['--demo']
unless demo
  Core::ProductionGuard.require_production!(File.expand_path('..', __dir__), arguments: ARGV)
end

require 'bundler/setup'
require 'webrick'
require 'logger'
require_relative '../config'
require_relative '../lib/dashboard/app'
require_relative '../lib/dashboard/collector'
require_relative '../lib/command_runner'

if demo
  require_relative 'demo'
  collector = Dashboard::Demo.new
  access = Object.new
  def access.verify(_token) = { 'sub' => 'demo' }
  revision = 'demo'
  port = Integer(ENV.fetch('TOOLBOX_DEMO_PORT', '4179'))
else
  Core::ProductionGuard.verify_checkout!(File.expand_path('..', __dir__), command_runner: Core::CommandRunner)
  collector = Dashboard::Collector.new
  access = Dashboard::Access.new(issuer: Config::DASHBOARD.fetch(:issuer), audience: Config::DASHBOARD.fetch(:audience))
  revision, = Core::CommandRunner.capture3('git', 'rev-parse', 'HEAD', chdir: File.expand_path('..', __dir__), timeout: 5)
  revision = revision.strip
  port = Config::DASHBOARD.fetch(:port)
end

app = Dashboard::App.new(collector: collector, access: access, public_dir: File.join(__dir__, 'public'), revision: revision)
server = WEBrick::HTTPServer.new(BindAddress: '127.0.0.1', Port: port, MaxClients: 12,
                               RequestTimeout: 10, DoNotReverseLookup: true,
                               AccessLog: [], Logger: WEBrick::Log.new(File::NULL), ServerSoftware: 'Toolbox')
server.mount_proc('/') { |request, response| app.call(request, response) }
%w[TERM INT].each { |signal| trap(signal) { server.shutdown } }
server.start

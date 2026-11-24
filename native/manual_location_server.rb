#!/usr/bin/env ruby
require_relative '../lib/production_guard'

repo = File.expand_path('..', __dir__)
Core::ProductionGuard.require_production!(repo, arguments: ARGV)
require 'bundler/setup'
require 'webrick'
require 'digest'
require 'rbconfig'
require_relative '../lib/command_runner'
require_relative '../lib/manual_location/config'
require_relative '../lib/manual_location/find_my_source'
require_relative '../lib/manual_location/app'
require_relative '../lib/manual_location/revision'

Core::ProductionGuard.verify_checkout!(repo, command_runner: Core::CommandRunner)
runtime = File.join(repo, '.runtime', 'manual-location')
config_path = File.join(runtime, 'config.json')
config = ManualLocation::Configuration.load(config_path)
revision = ManualLocation::Revision.current(repo: repo, config_path: config_path, ruby: RbConfig.ruby, home: ENV.fetch('HOME'))
source = ManualLocation::FindMySource.new(executable: File.join(runtime, 'find-my-reader'))
app = ManualLocation::App.new(config: config, source: source, revision: revision)
server = WEBrick::HTTPServer.new(BindAddress: '127.0.0.1', Port: 4180, MaxClients: 4,
                               RequestTimeout: 5, DoNotReverseLookup: true,
                               AccessLog: [], Logger: WEBrick::Log.new(File::NULL), ServerSoftware: 'Manual location')
server.mount_proc('/') { |request, response| app.call(request, response) }
%w[TERM INT].each { |signal| trap(signal) { server.shutdown } }
server.start

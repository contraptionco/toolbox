#!/usr/bin/env ruby
require_relative '../lib/production_guard'

repo = File.expand_path('..', __dir__)
Core::ProductionGuard.require_production!(repo, arguments: ARGV)
require 'bundler/setup'
require 'webrick'
require 'digest'
require_relative '../lib/command_runner'
require_relative '../lib/manual_location/config'
require_relative '../lib/manual_location/find_my_source'
require_relative '../lib/manual_location/app'

Core::ProductionGuard.verify_checkout!(repo, command_runner: Core::CommandRunner)
runtime = File.join(repo, '.runtime', 'manual-location')
config_path = File.join(runtime, 'config.json')
config = ManualLocation::Configuration.load(config_path)
revision, = Core::CommandRunner.capture3('git', 'rev-parse', 'HEAD', chdir: repo, timeout: 5)
revision = "#{revision.strip}:#{Digest::SHA256.file(config_path).hexdigest}"
source = ManualLocation::FindMySource.new(executable: File.join(runtime, 'find-my-reader'))
app = ManualLocation::App.new(config: config, source: source, revision: revision)
server = WEBrick::HTTPServer.new(BindAddress: '127.0.0.1', Port: 4180, MaxClients: 4,
                               RequestTimeout: 5, DoNotReverseLookup: true,
                               AccessLog: [], Logger: WEBrick::Log.new(File::NULL), ServerSoftware: 'Manual location')
server.mount_proc('/') { |request, response| app.call(request, response) }
%w[TERM INT].each { |signal| trap(signal) { server.shutdown } }
server.start

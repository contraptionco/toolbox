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
require_relative '../config'
require_relative '../lib/dashboard/app'
require_relative '../lib/dashboard/collector'
require_relative '../lib/command_runner'
require_relative '../lib/dashboard/auth'
require_relative '../lib/dashboard/auth_store'
require_relative '../lib/dashboard/mailer'
require_relative '../lib/dashboard/settings'
require_relative '../lib/dashboard/http_handler'
require 'tmpdir'
require 'securerandom'

if demo
  require_relative 'demo'
  collector = Dashboard::Demo.new
  revision = 'demo'
  port = Integer(ENV.fetch('TOOLBOX_DEMO_PORT', '4179'))
  origin = "http://127.0.0.1:#{port}"
  demo_directory = Dir.mktmpdir('toolbox-auth-demo-')
  store = Dashboard::AuthStore.new(path: File.join(demo_directory, 'auth.sqlite3'))
  mailer = Object.new
  mailer.define_singleton_method(:configured?) { true }
  mailer.define_singleton_method(:send_code) do |email:, code:|
    File.open(File.join(demo_directory, 'latest-code'), File::WRONLY | File::CREAT | File::TRUNC, 0o600) { |file| file.write(code) }
    true
  end
  secret = SecureRandom.hex(32)
  warn "Synthetic demo only. Test email codes: #{File.join(demo_directory, 'latest-code')}"
  at_exit { FileUtils.remove_entry(demo_directory) if File.directory?(demo_directory) }
else
  Core::ProductionGuard.verify_checkout!(File.expand_path('..', __dir__), command_runner: Core::CommandRunner)
  collector = Dashboard::Collector.new
  origin = "https://#{Config::DASHBOARD.fetch(:hostname)}"
  settings = Dashboard::Settings.load(File.join(Config::RUNTIME_DIR, 'dashboard', 'auth-config.json'))
  store = Dashboard::AuthStore.new(path: File.join(Config::DASHBOARD.fetch(:auth_data_dir), 'auth.sqlite3'))
  secret = settings.fetch('secret')
  mailer = Dashboard::Mailer.new(host: settings.fetch('smtp_host'), port: settings.fetch('smtp_port'),
                                 user: settings.fetch('smtp_user'), password: settings.fetch('smtp_password'),
                                 from: settings.fetch('smtp_from'), origin: origin)
  revision, = Core::CommandRunner.capture3('git', 'rev-parse', 'HEAD', chdir: File.expand_path('..', __dir__), timeout: 5)
  revision = revision.strip
  port = Config::DASHBOARD.fetch(:port)
end

auth = Dashboard::Auth.new(store: store, origin: origin, secret: secret, mailer: mailer,
                           email_sign_in_enabled: Dashboard::Settings.email_sign_in_enabled?(demo: demo))
auth_http = Dashboard::AuthHTTP.new(auth: auth)
# Demo exercises the same UI/auth; OAuth keeps its exact HTTPS production resource.
oauth = Dashboard::OAuth.new(store: store, origin: demo ? 'https://toolbox.contraption.co' : origin)
app = Dashboard::App.new(collector: collector, auth_http: auth_http, oauth: oauth, origin: origin, public_dir: File.join(__dir__, 'public'), revision: revision)
server = WEBrick::HTTPServer.new(BindAddress: '127.0.0.1', Port: port, MaxClients: 12,
                               RequestTimeout: 10, DoNotReverseLookup: true,
                               AccessLog: [], Logger: WEBrick::Log.new(File::NULL), ServerSoftware: 'Toolbox')
server.mount('/', Dashboard::HTTPHandler, app)
%w[TERM INT].each { |signal| trap(signal) { server.shutdown } }
server.start

require_relative 'test_helper'
require 'tmpdir'
require 'fileutils'
require 'webrick'
require 'net/http'
require_relative '../lib/manual_location/config'
require_relative '../lib/manual_location/find_my_source'
require_relative '../lib/manual_location/app'

class ManualLocationTest < Minitest::Test
  PERSON = '54fd96db-9fd4-4b50-9a97-c96c4042750e'
  OTHER = 'c2bd6363-9e92-452d-b376-24343312ac08'
  UNMAPPED = 'd017d8ea-1dbd-4162-951e-ae1cc61e2198'
  KEY = 'fixture-key-' + 'x' * 43
  NOW = Time.iso8601('2026-11-24T16:00:00Z')

  def config
    ManualLocation::Configuration.new('key' => KEY)
  end

  def test_config_requires_private_owned_regular_file_and_a_narrow_key
    Dir.mktmpdir do |directory|
      path = File.join(directory, 'config.json')
      File.write(path, JSON.generate(key: KEY), mode: 'w', perm: 0o600)
      assert_equal KEY, ManualLocation::Configuration.load(path).key
      File.chmod(0o644, path)
      assert_raises(ManualLocation::ConfigurationError) { ManualLocation::Configuration.load(path) }
      File.chmod(0o600, path)
      link = File.join(directory, 'link.json')
      File.symlink(path, link)
      assert_raises(ManualLocation::ConfigurationError) { ManualLocation::Configuration.load(link) }
    end
    assert_raises(ManualLocation::ConfigurationError) { ManualLocation::Configuration.new('key' => 'weak') }
  end

  def test_pending_requests_are_bounded_and_coalesced
    jobs = []
    batches = []
    source = Object.new
    source.define_singleton_method(:refresh) do |names|
      batches << names
      {}
    end
    app = ManualLocation::App.new(config: config, source: source, revision: 'fixture', clock: -> { NOW }, thread: ->(&block) { jobs << block })
    100.times { |i| app.start_refresh([{ 'personId' => PERSON, 'findMyName' => "Person #{i}" }]) }
    assert_equal 1, jobs.length
    jobs.shift.call
    assert_equal 1, batches.length
    assert_equal 32, batches.first.length
    refute app.snapshot([{ 'personId' => PERSON, 'findMyName' => 'Person 0' }])[:refreshing]
  end

  def test_http_accepts_the_shared_family_limit_with_unicode_names_and_rejects_larger_batches
    jobs = []
    app = ManualLocation::App.new(config: config, source: Object.new, revision: 'fixture', thread: ->(&block) { jobs << block })
    people = 32.times.map { |i| { personId: format('00000000-0000-4000-8000-%012d', i), findMyName: ('家' * 190) + i.to_s } }
    with_server(app) do |uri|
      assert_equal 202, request(uri, body: { people: people, refresh: true }).code.to_i
      assert_equal 1, jobs.length
      too_many = people + [{ personId: PERSON, findMyName: 'One more person' }]
      assert_equal 400, request(uri, body: { people: too_many, refresh: true }).code.to_i
    end
  end

  def test_parser_accepts_only_explicit_freshness_and_never_treats_directions_eta_as_observation_time
    parse = ->(text) { ManualLocation::FindMySource.parse_row('Person One', text, NOW) }
    selected = parse.call('Person One, Open Details, 3 km, Manhattan Bridge, New York, Paused')
    assert_equal 'paused', selected[:status]
    assert_equal 'Manhattan Bridge, New York', selected[:label]
    assert_nil selected[:observed_at]
    unknown = parse.call('Person One, 1.1 km, Address unavailable · Paused')
    assert_equal 'paused', unknown[:status]
    assert_nil unknown[:label]
    assert_nil parse.call('Person One, 3 km, Manhattan Bridge, New York, 39 min')
    assert_nil parse.call('Person One, 3 km, Manhattan Bridge, New York')
    assert_nil parse.call('Another Person, 3 km, Home, Now')
    assert_equal NOW, parse.call('Person One, 500 m, Home, Now')[:observed_at]
    assert_equal NOW - 120, parse.call('Person One, 1 km, Home · 2 minutes ago')[:observed_at]
    assert_equal NOW - 120, parse.call('Person One, 1 km, Home · 2 min. ago')[:observed_at]
    assert_equal NOW - 3600, parse.call('Person One, 1 km, Home, 1 hour ago')[:observed_at]
    assert_nil parse.call('Person One, 1 km, Home, 3 hours ago')
  end

  def test_source_ignores_unrequested_rows_rejects_ambiguous_names_and_returns_safe_errors
    source = ManualLocation::FindMySource.new(executable: '/unused', clock: -> { NOW }, runner: ->(_names) {
      JSON.generate(rows: [
        { name: 'Person One', description: 'Person One, 1 km, Home, Now' },
        { name: 'Person One', description: 'Person One, 3 km, Work, Now' },
        { name: 'Person Two', description: 'Person Two, 1 km, Work · Paused' },
        { name: 'Unrelated', description: 'Unrelated, 0 m, Confidential, Now' }
      ])
    })
    result = source.refresh(['Person One', 'Person Two'])
    refute result.key?('Person One')
    refute result.key?('Unrelated')
    assert_equal 'paused', result['Person Two'][:status]
    denied = ManualLocation::FindMySource.new(executable: '/unused', runner: ->(_names) { JSON.generate(error: 'permission_required') })
    assert_equal 'permission_required', assert_raises(ManualLocation::SourceError) { denied.refresh(['Person One']) }.code
  end

  def test_real_http_is_authenticated_on_demand_coalesced_and_returns_only_requested_people
    now = NOW
    calls = []
    jobs = []
    source = Object.new
    source.define_singleton_method(:refresh) do |names|
      calls << names
      names.to_h { |name| [name, { status: 'located', label: 'Home', observed_at: NOW, checked_at: NOW }] }
    end
    app = ManualLocation::App.new(config: config, source: source, revision: 'fixture', clock: -> { now }, thread: ->(&block) { jobs << block })
    with_server(app) do |uri|
      response = Net::HTTP.get_response(URI("#{uri}/healthz"))
      assert_equal 200, response.code.to_i
      refute_includes response.body, 'Person'
      assert_equal 401, request(uri, key: 'invalid').code.to_i
      assert_equal 401, request(uri, origin: 'http://localhost').code.to_i
      assert_equal 400, request(uri, body: { people: [{ personId: PERSON, findMyName: 'Person One' }], refresh: true, path: '/etc/passwd' }).code.to_i
      assert_empty jobs
      response = request(uri)
      assert_equal 202, response.code.to_i
      assert_equal 'private, no-store', response['cache-control']
      assert_equal true, JSON.parse(response.body)['refreshing']
      request(uri)
      assert_equal 1, jobs.length
      jobs.shift.call
      assert_equal [['Person One']], calls
      response = request(uri, body: { people: [{ personId: PERSON, findMyName: 'Person One' }, { personId: UNMAPPED, findMyName: 'Missing Person' }], refresh: false })
      result = JSON.parse(response.body)
      assert_equal %w[ready unavailable], result['people'].map { |person| person['status'] }
      assert_equal [PERSON, UNMAPPED], result['people'].map { |person| person['personId'] }
      refute_includes response.body, OTHER
      refute_includes response.body, KEY
      request(uri)
      assert_empty jobs
      now += 901
      assert_equal 'unavailable', app.snapshot([{ 'personId' => PERSON, 'findMyName' => 'Person One' }])[:people][0][:status]
    end
  end

  def test_paused_and_failed_refresh_never_become_current_and_permission_revocation_clears_cache
    now = NOW
    mode = :paused
    source = Object.new
    source.define_singleton_method(:refresh) do |_names|
      raise ManualLocation::SourceError, 'permission_required' if mode == :denied
      { 'Person One' => { status: 'paused', label: 'Home', observed_at: nil, checked_at: now } }
    end
    app = ManualLocation::App.new(config: config, source: source, revision: 'fixture', clock: -> { now }, thread: ->(&block) { block.call })
    app.start_refresh([{ 'personId' => PERSON, 'findMyName' => 'Person One' }])
    result = app.snapshot([{ 'personId' => PERSON, 'findMyName' => 'Person One' }])[:people][0]
    assert_equal 'paused', result[:status]
    assert_nil result[:observedAt]
    refute result.key?(:latitude)
    now += 21
    mode = :denied
    app.start_refresh([{ 'personId' => PERSON, 'findMyName' => 'Person One' }])
    assert_equal 'permission_required', app.snapshot([{ 'personId' => PERSON, 'findMyName' => 'Person One' }])[:reason]
    assert_equal 'unavailable', app.snapshot([{ 'personId' => PERSON, 'findMyName' => 'Person One' }])[:people][0][:status]
    refute_includes JSON.generate(app.snapshot([{ 'personId' => PERSON, 'findMyName' => 'Person One' }])), 'Home'
  end

  private

  def request(uri, key: KEY, origin: nil, body: { people: [{ personId: PERSON, findMyName: 'Person One' }], refresh: true })
    request = Net::HTTP::Post.new(URI("#{uri}/v1/locations"))
    request['Authorization'] = "Bearer #{key}"
    request['Content-Type'] = 'application/json'
    request['Origin'] = origin if origin
    request.body = JSON.generate(body)
    Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
  end

  def with_server(app)
    server = WEBrick::HTTPServer.new(BindAddress: '127.0.0.1', Port: 0, AccessLog: [], Logger: WEBrick::Log.new(File::NULL))
    server.mount_proc('/') { |req, res| app.call(req, res) }
    thread = Thread.new { server.start }
    Thread.pass until server.status == :Running
    yield URI("http://127.0.0.1:#{server.config[:Port]}")
  ensure
    server&.shutdown
    thread&.join
  end
end

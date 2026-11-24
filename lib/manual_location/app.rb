require 'json'
require 'digest'
require 'openssl'
require 'time'
require 'set'
require_relative 'config'
require_relative 'find_my_source'

module ManualLocation
  class RequestError < StandardError; end

  # On-demand only. There is no timer collecting movements and no history.
  # Refresh jobs outlive individual HTTP requests but are globally coalesced.
  class App
    MAX_BODY_BYTES = 32_768
    MAX_PEOPLE = 32
    MAX_NAMES = 32
    REFRESH_INTERVAL = 20
    FRESH_SECONDS = 15 * 60
    EXPIRE_SECONDS = 2 * 60 * 60

    def initialize(config:, source:, revision:, clock: -> { Time.now }, thread: ->(&block) { Thread.new(&block) })
      @config, @source, @revision, @clock, @thread = config, source, revision, clock, thread
      @key_hash = Digest::SHA256.digest(config.key)
      @mutex = Mutex.new
      @observations = {}
      @refreshing = false
      @last_started = {}
      @pending = Set.new
      @checked_at = nil
      @last_error = nil
    end

    def call(request, response)
      response['Cache-Control'] = 'private, no-store'
      response['Content-Type'] = 'application/json; charset=utf-8'
      response['X-Content-Type-Options'] = 'nosniff'
      response['Referrer-Policy'] = 'no-referrer'
      response['Content-Security-Policy'] = "default-src 'none'; frame-ancestors 'none'"
      response['X-Robots-Tag'] = 'noindex, nofollow, noarchive'
      if request.path == '/healthz' && %w[GET HEAD].include?(request.request_method)
        respond(response, 200, ok: true, revision: @revision)
        return
      end
      unless authorized?(request)
        respond(response, 401, error: 'Unauthorized.')
        return
      end
      unless request.path == '/v1/locations' && request.request_method == 'POST'
        respond(response, 404, error: 'Not found.')
        return
      end
      input = parse_input(request)
      start_refresh(input.fetch('people')) if input.fetch('refresh')
      value = snapshot(input.fetch('people'))
      respond(response, value[:refreshing] ? 202 : 200, value)
    rescue RequestError
      respond(response, 400, error: 'Invalid location request.')
    rescue StandardError
      # No exception message, request, mapping, coordinates, or secret reaches logs.
      respond(response, 503, error: 'Locations are unavailable.')
    end

    def snapshot(people)
      @mutex.synchronize do
        now = @clock.call
        { refreshing: @refreshing, checkedAt: @checked_at&.utc&.iso8601, reason: @last_error,
          people: people.map { |person| visible_observation(person, now) } }.compact
      end
    end

    def start_refresh(people)
      should_start = @mutex.synchronize do
        people.map { |person| person.fetch('findMyName') }.uniq.each do |name|
          next if @last_started[name] && @clock.call - @last_started[name] < REFRESH_INTERVAL
          @pending.add(name) if @pending.length < MAX_NAMES
        end
        next false if @refreshing || @pending.empty?
        @refreshing = true
        true
      end
      return unless should_start

      @thread.call do
        loop do
          names = @mutex.synchronize do
            if @pending.empty?
              @refreshing = false
              nil
            else
              selected = @pending.to_a.first(MAX_NAMES)
              selected.each { |name| @pending.delete(name) }
              selected.each { |name| @last_started[name] = @clock.call }
              @last_started.shift while @last_started.length > MAX_NAMES * 2
              selected
            end
          end
          break unless names
          begin
            observations = @source.refresh(names)
            @mutex.synchronize do
              names.each { |name| @observations.delete(name); @observations[name] = observations[name] }
              @observations.shift while @observations.length > MAX_NAMES
              @last_started.delete_if { |_name, time| @clock.call - time > 600 }
              @checked_at = @clock.call
              @last_error = nil
            end
          rescue StandardError => error
            @mutex.synchronize do
              names.each { |name| @observations.delete(name) } if error.is_a?(SourceError) && error.code == 'permission_required'
              @last_error = error.is_a?(SourceError) ? error.code : 'source_unavailable'
              @checked_at = @clock.call
            end
          end
        end
      end
    rescue StandardError
      @mutex.synchronize { @refreshing = false }
    end

    private

    def authorized?(request)
      # This endpoint is server-to-server. Browser origins receive no CORS access.
      return false unless request['origin'].to_s.empty?
      value = request['authorization'].to_s
      return false unless value.match?(/\ABearer [A-Za-z0-9_-]{43,128}\z/)
      OpenSSL.fixed_length_secure_compare(@key_hash, Digest::SHA256.digest(value.delete_prefix('Bearer ')))
    end

    def parse_input(request)
      raise RequestError unless request['content-type'].to_s.split(';').first == 'application/json'
      raise RequestError if request['content-length'].to_i > MAX_BODY_BYTES
      body = +''
      request.body do |chunk|
        body << chunk
        raise RequestError if body.bytesize > MAX_BODY_BYTES
      end
      data = JSON.parse(body)
      people = data['people'] if data.is_a?(Hash)
      valid = people.is_a?(Array) && people.length.between?(1, MAX_PEOPLE) && people.all? do |person|
        person.is_a?(Hash) && person.keys.sort == %w[findMyName personId] &&
          person['personId'].is_a?(String) && Configuration::UUID.match?(person['personId']) &&
          person['findMyName'].is_a?(String) && person['findMyName'].length.between?(1, 200) &&
          !person['findMyName'].match?(/[\x00-\x1f\x7f]/)
      end
      unless valid && (data.keys - %w[people refresh]).empty? && [true, false].include?(data['refresh']) && people.map { |person| person['personId'].downcase }.uniq.length == people.length
        raise RequestError
      end
      data.merge('people' => people.map { |person| person.merge('personId' => person['personId'].downcase) })
    rescue JSON::ParserError
      raise RequestError
    end

    def visible_observation(person, now)
      person_id = person.fetch('personId')
      base = { personId: person_id, source: 'find-my' }
      source_id = person.fetch('findMyName')
      entry = @observations[source_id]
      return base.merge(status: 'unavailable') unless entry.is_a?(Hash)
      checked = entry[:checked_at]
      return base.merge(status: 'unavailable') unless checked.is_a?(Time) && (0..FRESH_SECONDS).cover?(now - checked)
      label = entry[:label].to_s.gsub(/[\x00-\x1f\x7f]/, ' ').strip[0, 160]
      if entry[:status] == 'paused'
        return base.merge(status: 'paused', observedAt: nil, label: label.empty? ? nil : label).reject { |key, value| key == :label && value.nil? }
      end
      observed = entry[:observed_at]
      return base.merge(status: 'unavailable') unless observed.is_a?(Time)
      age = now - observed
      return base.merge(status: 'unavailable') unless age >= -60 && age <= EXPIRE_SECONDS
      return base.merge(status: 'unavailable') if label.empty?
      base.merge(status: age <= FRESH_SECONDS && !@last_error ? 'ready' : 'stale', observedAt: observed.utc.iso8601, label: label)
    end

    def respond(response, status, value)
      response.status = status
      response.body = JSON.generate(value)
    end
  end
end

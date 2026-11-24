require 'json'
require 'time'
require 'open3'
require 'timeout'

module ManualLocation
  class SourceError < StandardError
    attr_reader :code
    def initialize(code)
      @code = %w[permission_required source_unavailable].include?(code) ? code : 'source_unavailable'
      super('Find My is unavailable.')
    end
  end

  class FindMySource
    TIMEOUT = 20
    MAX_OUTPUT = 128 * 1024

    def initialize(executable:, runner: nil, clock: -> { Time.now })
      @executable, @clock = executable, clock
      @runner = runner || method(:run_reader)
    end

    def refresh(names, source: 'person')
      raise SourceError, 'source_unavailable' unless %w[person device].include?(source)
      data = JSON.parse(@runner.call(names, source: source))
      raise SourceError, data['error'] if data['error']
      rows = data['rows']
      raise SourceError, 'source_unavailable' unless rows.is_a?(Array) && rows.length <= 128
      now = @clock.call
      names.to_h do |name|
        matches = rows.select { |row| row.is_a?(Hash) && row.fetch('source', 'person') == source &&
                      row['name'].is_a?(String) && row['name'].unicode_normalize(:nfc) == name.unicode_normalize(:nfc) && row['description'].is_a?(String) && row['description'].bytesize <= 4096 }
                      .map { |row| [row['description'], row['selected'] == true, self.class.clean_address(row['address']), row['label'], row['observationAge']] }.uniq
        # Duplicate display names cannot be mapped safely to a family account.
        entry = if matches.length == 1
                  row = matches.first
                  if source == 'device' && row[3].is_a?(String) && row[4].is_a?(String)
                    self.class.parse_observation(row[3], row[4], now)
                  else
                    self.class.parse_row(name, row[0], now, selected: row[1])
                  end
                end
        entry[:address] = matches.first[2] if entry && entry[:status] == 'located' && matches.first[2]
        [name, entry]
      end.compact
    rescue JSON::ParserError, TypeError
      raise SourceError, 'source_unavailable'
    end

    def self.parse_row(name, description, now, selected: false)
      return nil unless description.bytesize <= 4096
      description = description.unicode_normalize(:nfc)
      name = name.unicode_normalize(:nfc)
      # Locate the complete name using the one structured distance field. A
      # prefix alone could confuse Alex with Alex, Jr. Ambiguous rows fail closed.
      boundaries = description.to_enum(:scan, /,\s*(?:[<>≈]\s*)?\d+(?:[.,]\d+)?\s*(?:km|m|mi|ft)(?=,)/i).map { Regexp.last_match }
      return nil unless boundaries.length == 1
      boundary = boundaries.first
      complete_name = description[0...boundary.begin(0)]
      complete_name = complete_name.delete_suffix(', Open Details') if selected
      return nil unless complete_name == name
      # Distances are relative to the Mac, not the person's location or time.
      text = description[boundary.end(0)..].delete_prefix(',').lstrip
      if text.match?(/(?:,|·)\s*Paused\z/i)
        label = clean_label(text.sub(/(?:,|·)\s*Paused\z/i, ''))
        return { status: 'paused', label: label, observed_at: nil, checked_at: now }
      end
      match = /(?:,|·)\s*(Now|\d+\s+(?:min(?:ute)?s?\.?|hr\.?|hours?)\s+ago)\z/i.match(text)
      return nil unless match
      age = if match[1].casecmp?('Now')
              0
            else
              amount = match[1].to_i
              amount * (match[1].match?(/(?:hour|hr)/i) ? 3600 : 60)
            end
      return nil if age > 2 * 60 * 60
      label = clean_label(text[0...match.begin(0)])
      return nil if label.nil?
      { status: 'located', label: label, observed_at: now - age, checked_at: now }
    end

    def self.clean_label(value)
      label = value.to_s.gsub(/[\x00-\x1f\x7f]/, ' ').strip[0, 160]
      return nil if label.empty? || label.match?(/\A(?:Address unavailable|Location not found|No location found|Not sharing location)\z/i)
      label
    end

    def self.parse_observation(label, age_text, now)
      return nil unless label.bytesize <= 4096 && age_text.bytesize <= 80
      label = clean_label(label)
      age_text = age_text.strip
      return { status: 'paused', label: label, observed_at: nil, checked_at: now } if age_text.casecmp?('Paused')
      return nil if label.nil?
      match = /\A(Now|\d+\s+(?:min(?:ute)?s?\.?|hr\.?|hours?)\s+ago)\z/i.match(age_text)
      return nil unless match
      age = age_text.casecmp?('Now') ? 0 : age_text.to_i * (age_text.match?(/(?:hour|hr)/i) ? 3600 : 60)
      return nil if age > 7200
      { status: 'located', label: label, observed_at: now - age, checked_at: now }
    end

    def self.clean_address(value)
      return nil unless value.is_a?(String) && value.valid_encoding? && value.bytesize <= 240 && !value.match?(/[\p{Cc}\p{Cf}]/)
      address = value.unicode_normalize(:nfc).gsub(/\s+/, ' ').strip
      return nil unless address.match?(/\A\d+[A-Za-z-]*\s+[^,]*\b(?:Street|St|Avenue|Ave|Road|Rd|Lane|Ln|Drive|Dr|Broadway|Place|Pl|Boulevard|Blvd|Way|Court|Ct|Parkway|Pkwy|Square|Sq|Terrace|Ter|Highway|Hwy)\b[^,]*,\s*[^,]+,\s*[^,]+\z/i)
      address
    end

    private

    def run_reader(names, source:)
      # Names travel over stdin, not process arguments. stderr is discarded and
      # neither output nor native errors are sent to application logs.
      output = +''
      Open3.popen2(@executable, pgroup: true, err: File::NULL) do |stdin, stdout, wait|
        begin
          Timeout.timeout(TIMEOUT) do
            stdin.write(JSON.generate(names: names, source: source)); stdin.close
            loop do
              output << stdout.readpartial(4096)
              raise SourceError, 'source_unavailable' if output.bytesize > MAX_OUTPUT
            end
          rescue EOFError
            wait.value
          end
        rescue Timeout::Error, SourceError
          begin Process.kill('KILL', -wait.pid); rescue Errno::ESRCH; end
          raise SourceError, 'source_unavailable'
        ensure
          stdin.close unless stdin.closed?
          stdout.close unless stdout.closed?
        end
      end
      output
    rescue SystemCallError
      raise SourceError, 'source_unavailable'
    end
  end
end

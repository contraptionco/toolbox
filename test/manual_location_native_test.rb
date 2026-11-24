require_relative 'test_helper'
require 'json'
require 'open3'
require 'tmpdir'
require 'fileutils'
require_relative '../lib/manual_location/find_my_source'

class ManualLocationNativeTest < Minitest::Test
  NOW = Time.iso8601('2026-11-24T16:00:00Z')

  def setup
    skip 'The native Swift fixture harness requires macOS xcrun.' unless File.executable?('/usr/bin/xcrun')
    self.class.compile_reader
  end

  def self.compile_reader
    return @reader if @reader

    source = File.expand_path('../native/find_my_reader.swift', __dir__)
    # Never run a production reader as a fixture test. The compiled test branch
    # only transforms stdin fixtures; it cannot activate Find My or inspect AX.
    raise 'Native fixture harness is missing.' unless File.read(source).include?('#if MANUAL_LOCATION_TEST')

    directory = Dir.mktmpdir('manual-location-native-test-')
    Minitest.after_run { FileUtils.remove_entry(directory) if File.exist?(directory) }
    reader = File.join(directory, 'find-my-fixtures')
    _stdout, stderr, status = Open3.capture3('/usr/bin/xcrun', 'swiftc', '-D', 'MANUAL_LOCATION_TEST', source, '-o', reader)
    raise "Native fixture harness did not compile: #{stderr}" unless status.success?

    @reader = reader
  end

  def fixture(**changes)
    {
      name: 'Alex', description: 'Alex, Home, Home, 2 min. ago, 1.2 mi',
      detailName: 'Alex', candidateCount: 1, selected: true,
      wasSelected: false, hadMatchingHeader: false
    }.merge(changes)
  end

  def canonical(*fixtures)
    stdout, stderr, status = Open3.capture3(self.class.compile_reader, stdin_data: JSON.generate(fixtures))
    assert status.success?, "Native fixture harness failed: #{stderr}"
    parsed = JSON.parse(stdout)
    assert_equal fixtures.length, parsed.length
    parsed
  end

  def test_verified_legacy_rows_preserve_labels_and_explicit_observation_times
    descriptions = canonical(
      fixture,
      fixture(description: 'Alex, Office, 1 hr. ago, 3 km'),
      fixture(description: 'Alex, Home, Now, 500 m'),
      fixture(description: 'Alex, Home, Paused, 90 ft')
    )
    assert_equal [
      'Alex, 1.2 mi, Home, Home, 2 min. ago',
      'Alex, 3 km, Office, 1 hr. ago',
      'Alex, 500 m, Home, Now',
      'Alex, 90 ft, Home, Paused'
    ], descriptions

    observations = descriptions.map { |description| ManualLocation::FindMySource.parse_row('Alex', description, NOW, selected: true) }
    assert_equal %w[located located located paused], observations.map { |row| row[:status] }
    assert_equal [NOW - 120, NOW - 3600, NOW, nil], observations.map { |row| row[:observed_at] }
    assert_equal 'Home, Home', observations.first[:label]
    assert_equal 'Home', observations.last[:label]
  end

  def test_complete_names_and_labels_may_contain_commas_and_unicode
    name = 'Alex, Jr.'
    unicode_name = 'José'
    decomposed_name = "Jose\u0301"
    descriptions = canonical(
      fixture(name: name, detailName: name, description: "#{name}, 12 Example Street, Sample City, Now, 500 m"),
      fixture(name: unicode_name, detailName: decomposed_name, description: "#{decomposed_name}, Café, New York, 2 min. ago, 1 km")
    )
    assert_equal 'Alex, Jr., 500 m, 12 Example Street, Sample City, Now', descriptions[0]
    assert_equal 'José, 1 km, Café, New York, 2 min. ago', descriptions[1].unicode_normalize(:nfc)
    assert_equal '12 Example Street, Sample City', ManualLocation::FindMySource.parse_row(name, descriptions[0], NOW, selected: true)[:label]
    assert_equal NOW - 120, ManualLocation::FindMySource.parse_row(unicode_name, descriptions[1], NOW, selected: true)[:observed_at]
  end

  def test_prefixes_missing_or_changed_headers_and_unselected_rows_do_not_establish_identity
    cases = {
      prefix_name: fixture(description: 'Alex, Jr., Home, Now, 1 mi', detailName: 'Alex, Jr.'),
      missing_header: fixture(detailName: nil),
      wrong_header: fixture(detailName: 'Beth'),
      changed_header: fixture(wasSelected: true, hadMatchingHeader: true, detailName: 'Alex, Jr.'),
      different_case: fixture(detailName: 'alex'),
      partial_header: fixture(detailName: 'Alexandra'),
      unselected_candidate: fixture(selected: false),
      action_did_not_select: fixture(selected: false, wasSelected: false),
      changed_description: fixture(description: 'Beth, Home, Now, 1 mi')
    }
    canonical(*cases.values).zip(cases.keys).each { |value, reason| assert_nil value, reason.to_s }
  end

  def test_existing_details_cannot_validate_a_new_candidate_and_duplicates_remain_ambiguous
    cases = [
      fixture(hadMatchingHeader: true, wasSelected: false),
      fixture(candidateCount: 2),
      fixture(candidateCount: 0),
      fixture(candidateCount: -1)
    ]
    canonical(*cases).each { |value| assert_nil value }
    # A row proven to have already been selected is not a stale unrelated panel.
    assert_equal 'Alex, 1.2 mi, Home, Home, 2 min. ago', canonical(fixture(hadMatchingHeader: true, wasSelected: true)).first
  end

  def test_eta_only_missing_or_misplaced_freshness_cannot_become_a_location
    descriptions = [
      'Alex, Home, 39 min, 1 mi',
      'Alex, Home, 1 mi',
      'Alex, Home, Arrive in 2 min, 1 mi',
      'Alex, Home, Now, Directions, 1 mi',
      'Alex, Home, 2 min. ago',
      'Alex, Home, Now, unknown distance'
    ]
    canonical(*descriptions.map { |description| fixture(description: description) }).each { |value| assert_nil value }
  end

  def test_ruby_freshness_cutoff_still_rejects_old_native_observations
    description = canonical(fixture(description: 'Alex, Home, 3 hr. ago, 1 mi')).first
    assert_equal 'Alex, 1 mi, Home, 3 hr. ago', description
    assert_nil ManualLocation::FindMySource.parse_row('Alex', description, NOW, selected: true)
  end
end

require_relative 'test_helper'
require 'fileutils'
require 'tmpdir'
require_relative '../scripts/postgres_backup'

class PostgresBackupTest < Minitest::Test
  FakeStatus = Struct.new(:success?, :exitstatus)

  def test_daily_run_skips_a_recent_success
    with_backup do |backup, paths, calls|
      previous = Time.now.utc.iso8601
      File.write(paths[:LAST_SUCCESS_FILE], previous)

      backup.run

      assert_empty calls
      assert_equal previous, File.read(paths[:LAST_SUCCESS_FILE])
      refute File.exist?(paths[:LOCK_FILE])
    end
  end

  def test_forced_run_keeps_cluster_wide_dump_and_existing_s3_destination
    with_backup do |backup, paths, calls|
      File.write(paths[:LAST_SUCCESS_FILE], (Time.now.utc - 60).iso8601)

      backup.run(force: true)

      assert_equal 2, calls.length
      export, upload = calls
      assert_includes export[:args].last, 'pg_dumpall -U fixture-user'
      refute_includes export[:args].last, '--database'
      refute_includes export[:args].join(' '), 'fixture-password'
      assert_equal 'fixture-password', export[:options][:env]['PGPASSWORD']
      assert_equal ['aws', 's3', 'cp'], upload[:args].first(3)
      assert_match %r{\As3://fixture-bucket/\d{4}-\d{2}-\d{2}/postgres-20261116T120000Z\.sql\.gz\z}, upload[:args][4]
      refute_includes upload[:args].join(' '), 'fixture-secret'
      assert_equal 'fixture-secret', upload[:options][:env]['AWS_SECRET_ACCESS_KEY']
      assert_operator Time.parse(File.read(paths[:LAST_SUCCESS_FILE])), :>=, Time.now.utc - 5
      refute File.exist?(paths[:LOCK_FILE])
      assert_empty Dir.children(paths[:TMP_DIR])
    end
  end

  def test_force_never_overrides_an_active_backup_lock
    with_backup do |backup, paths, calls|
      lock = Time.now.utc.iso8601
      File.write(paths[:LOCK_FILE], lock)

      error = assert_raises(RuntimeError) { backup.run(force: true) }

      assert_includes error.message, 'already running'
      assert_empty calls
      assert_equal lock, File.read(paths[:LOCK_FILE])
      refute File.exist?(paths[:LAST_SUCCESS_FILE])
    end
  end

  def test_upload_failure_preserves_last_success_and_removes_temporary_dump
    with_backup(fail_at: 'aws') do |backup, paths, calls|
      previous = (Time.now.utc - 60).iso8601
      File.write(paths[:LAST_SUCCESS_FILE], previous)

      assert_raises(RuntimeError) { backup.run(force: true) }

      assert_equal 2, calls.length
      assert_equal previous, File.read(paths[:LAST_SUCCESS_FILE])
      refute File.exist?(paths[:LOCK_FILE])
      assert_empty Dir.children(paths[:TMP_DIR])
    end
  end

  def test_export_failure_does_not_upload_or_mark_success
    with_backup(fail_at: 'bash') do |backup, paths, calls|
      assert_raises(RuntimeError) { backup.run(force: true) }

      assert_equal 1, calls.length
      refute File.exist?(paths[:LAST_SUCCESS_FILE])
      refute File.exist?(paths[:LOCK_FILE])
      assert_empty Dir.children(paths[:TMP_DIR])
    end
  end

  def test_corrupt_or_empty_gzip_is_not_uploaded_or_marked_successful
    [:corrupt, :empty].each do |dump|
      with_backup(dump: dump) do |backup, paths, calls|
        assert_raises(RuntimeError) { backup.run(force: true) }

        assert_equal 1, calls.length
        refute File.exist?(paths[:LAST_SUCCESS_FILE])
        refute File.exist?(paths[:LOCK_FILE])
        assert_empty Dir.children(paths[:TMP_DIR])
      end
    end
  end

  def test_class_entrypoint_forwards_only_the_explicit_force_option
    instance = Minitest::Mock.new
    instance.expect(:run, nil, [], force: true)
    Scripts::PostgresBackup.stub(:new, instance) { Scripts::PostgresBackup.run(force: true) }
    instance.verify
  end

  private

  def with_backup(fail_at: nil, dump: :valid)
    klass = Scripts::PostgresBackup
    original = %i[LOCK_FILE LAST_SUCCESS_FILE TMP_DIR].to_h { |key| [key, klass.const_get(key)] }
    Dir.mktmpdir('postgres-backup-test-') do |directory|
      paths = {
        LOCK_FILE: File.join(directory, 'lock'),
        LAST_SUCCESS_FILE: File.join(directory, 'success'),
        TMP_DIR: File.join(directory, 'exports')
      }
      Dir.mkdir(paths[:TMP_DIR])
      paths.each { |key, value| klass.send(:remove_const, key); klass.const_set(key, value) }
      backup = klass.new
      backup.instance_variable_set(:@timestamp, '20261116T120000Z')
      backup.instance_variable_set(:@postgres_env, { POSTGRES_USER: 'fixture-user', POSTGRES_PASSWORD: 'fixture-password' })
      backup.instance_variable_set(:@aws_bucket, 'fixture-bucket')
      backup.instance_variable_set(:@aws_credentials, { 'AWS_ACCESS_KEY_ID' => 'fixture-key', 'AWS_SECRET_ACCESS_KEY' => 'fixture-secret' })
      calls = []
      command = lambda do |*args, **options|
        calls << { args: args, options: options }
        success = args.first != fail_at
        if args.first == 'bash'
          path = File.join(paths[:TMP_DIR], 'postgres-20261116T120000Z.sql.gz')
          Zlib::GzipWriter.open(path) { |gzip| gzip.write(dump == :empty ? '' : 'fixture dump') }
          File.truncate(path, File.size(path) - 3) if dump == :corrupt
        end
        ['', success ? '' : 'fixture failure', FakeStatus.new(success, success ? 0 : 1)]
      end
      capture_output do
        Core::DockerService.stub(:container_running?, true) do
          Core::CommandRunner.stub(:capture3, command) { yield backup, paths, calls }
        end
      end
    end
  ensure
    original&.each { |key, value| klass.send(:remove_const, key); klass.const_set(key, value) }
  end
end

"""Fixture-only database safety checks. No Docker, network, or real credentials."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('bully_database', Path(__file__).with_name('database.py'))
database = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(database)


SOURCE_URL = 'postgresql://fixture:password%27value@ep-fixture.us-east-2.aws.neon.tech/neondb?sslmode=require&channel_binding=require'
METADATA = {'version': 170006, 'snapshot': '00000003-000000A1-1',
            'size': 1024, 'extensions': ['plpgsql', 'pgcrypto']}
COUNTS = '\n'.join(json.dumps(row) for row in [
    {'schema': 'public', 'table': 'subscribers', 'count': 7},
    {'schema': 'drizzle', 'table': '__drizzle_migrations', 'count': 28}])


class FakeRunner:
    def __init__(self):
        self.calls = []
        self.snapshot_open = False
        self.occupied = False
        self.other_connections = False
        self.counts = COUNTS
        self.metadata = dict(METADATA)
        self.container = {'name': '/' + database.CONTAINER, 'image': database.IMAGE, 'running': True}
        self.archive_listing = '5; 2615 2200 SCHEMA - public owner\n'
        self.owner = ''

    def run(self, args, **kwargs):
        self.calls.append((args, kwargs))
        if args[:2] == ['docker', 'inspect']:
            return json.dumps(self.container)
        if 'pg_dump' in args:
            if '--snapshot' in args:
                assert self.snapshot_open
            with database.open_exclusive(kwargs['output_path']) as file:
                file.write(b'PGDMPfixture archive')
            return ''
        if 'pg_restore' in args:
            return self.archive_listing if '--list' in args else ''
        sql = kwargs.get('sql', '').removeprefix("SET statement_timeout='110s'; SET lock_timeout='10s';\n")
        if "'objects'" in sql:
            return json.dumps({'objects': int(self.occupied), 'connections': int(self.other_connections)})
        if sql == database.COUNTS_SQL:
            return self.counts
        if sql.startswith('SELECT pg_database_size'):
            return '1024\n'
        if sql.startswith('SELECT pg_get_userbyid'):
            return self.owner
        return ''


class FakeSnapshot:
    def __init__(self, args, runner):
        self.args, self.runner = args, runner

    def __enter__(self):
        self.runner.snapshot_open = True
        return self

    def query(self, sql):
        assert self.runner.snapshot_open
        return json.dumps(self.runner.metadata) if sql == database.METADATA_SQL else COUNTS

    def __exit__(self, *_):
        self.runner.snapshot_open = False


class DatabaseTest(unittest.TestCase):
    def setUp(self):
        # Resolve macOS /var -> /private/var before exercising symlink guards.
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name).resolve()
        (self.root / 'secrets').mkdir(mode=0o700)
        database.write_json(self.root / 'secrets' / 'source-database.json', {'url': SOURCE_URL})
        database.write_json(self.root / 'secrets' / 'identity.json', {
            'APP_DB_PASSWORD': "a'" + 'a' * 40, 'WORKFLOW_DB_PASSWORD': 'b' * 40})
        self.runner = FakeRunner()
        self.tool = database.DatabaseTool(self.root, self.runner, FakeSnapshot)
        self.space = patch.object(database.shutil, 'disk_usage', return_value=type('Usage', (), {'free': 20 * 1024**3})())
        self.space.start()
        # Any accidental real subprocess fails the test before invoking Docker.
        self.process = patch.object(subprocess, 'Popen', side_effect=AssertionError('Real process in fixture test'))
        self.process.start()

    def tearDown(self):
        self.process.stop()
        self.space.stop()
        self.temp.cleanup()

    def test_source_env_requires_explicit_neon_and_read_only_tls(self):
        values = database.source_environment(SOURCE_URL)
        self.assertEqual("password'value", values['PGPASSWORD'])
        self.assertIn('default_transaction_read_only=on', values['PGOPTIONS'])
        self.assertEqual('require', values['PGSSLMODE'])
        for invalid in [None, 7, 'postgres://u:p@localhost/prod',
                        SOURCE_URL + '&options=-c+default_transaction_read_only=off',
                        SOURCE_URL.replace('require&', 'disable&'),
                        SOURCE_URL.replace('password%27value', 'pass%0aPGHOST=evil')]:
            with self.assertRaises(database.Refused):
                database.source_environment(invalid)

    def test_secret_symlinks_and_public_permissions_refused(self):
        path = self.root / 'secrets' / 'source-database.json'
        path.chmod(0o644)
        with self.assertRaisesRegex(database.Refused, '0600'):
            database.private_json(path)
        path.chmod(0o600)
        link = self.root / 'link'
        link.symlink_to(path)
        with self.assertRaisesRegex(database.Refused, 'Symbolic'):
            database.private_json(link)

    def test_wrong_container_or_image_cannot_initialize(self):
        for field, value in [('name', '/postgres'), ('image', 'postgres:latest'), ('running', False)]:
            original = self.runner.container[field]
            self.runner.container[field] = value
            with self.assertRaisesRegex(database.Refused, 'identity'):
                self.tool.initialize()
            self.runner.container[field] = original
        self.assertTrue(all(args[1] == 'inspect' for args, _ in self.runner.calls))

    def test_initialize_scopes_roles_and_keeps_passwords_off_argv(self):
        self.tool.initialize()
        args = repr([args for args, _ in self.runner.calls])
        self.assertNotIn('a' * 40, args)
        sql = '\n'.join(kwargs.get('sql', '') for _, kwargs in self.runner.calls)
        self.assertIn("PASSWORD 'a''", sql)
        self.assertIn('NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS', sql)
        self.assertIn('CREATE DATABASE bully_pulpit_workflow_toolbox OWNER bully_workflow', sql)
        self.assertNotIn('REASSIGN OWNED', sql)
        for call, _ in self.runner.calls:
            if call[1] == 'exec':
                self.assertEqual(database.CONTAINER, call[3])

    def test_existing_owner_refuses_database_reassignment(self):
        self.runner.owner = 'someone_else'
        with self.assertRaisesRegex(database.Refused, 'unexpected owner'):
            self.tool.initialize()
        self.assertFalse(any('CREATE DATABASE' in kw.get('sql', '') for _, kw in self.runner.calls))

    def test_copy_refuses_existing_data_connections_or_marker(self):
        for attribute in ('occupied', 'other_connections'):
            setattr(self.runner, attribute, True)
            with self.assertRaisesRegex(database.Refused, 'empty and unused'):
                self.tool.copy()
            setattr(self.runner, attribute, False)
        database.write_json(self.root / 'database-copy.json', {'verified': True})
        with self.assertRaisesRegex(database.Refused, 'already exists'):
            self.tool.copy()
        self.assertFalse(any('pg_dump' in args or 'pg_restore' in args for args, _ in self.runner.calls))

    def test_newer_version_and_unsupported_extension_refuse_before_dump(self):
        for key, value in [('version', 180001), ('extensions', ['plpgsql', 'vector'])]:
            self.runner.metadata = {**METADATA, key: value}
            with self.assertRaises(database.Refused):
                self.tool.copy()
        self.assertFalse(any('pg_dump' in args or 'pg_restore' in args for args, _ in self.runner.calls))
        self.assertEqual([], list((self.root / 'secrets').glob('.source-*')))

    def test_copy_snapshot_counts_verified_before_marker_and_no_runtime_history(self):
        report = self.tool.copy()
        self.assertTrue(report['verified'])
        self.assertEqual(2, report['table_count'])
        self.assertEqual(35, report['total_rows'])
        self.assertFalse(self.runner.snapshot_open)
        self.assertEqual(report, json.loads((self.root / 'database-copy.json').read_text()))
        dump = next(args for args, _ in self.runner.calls if 'pg_dump' in args)
        self.assertEqual(METADATA['snapshot'], dump[dump.index('--snapshot') + 1])
        for schema in database.EXCLUDED_SCHEMAS:
            self.assertIn('--exclude-schema=' + schema, dump)
        self.assertNotIn("password'value", repr(dump))
        self.assertNotIn(SOURCE_URL, repr(dump))
        restore = next(args for args, _ in self.runner.calls if 'pg_restore' in args and '--list' not in args)
        self.assertIn('--single-transaction', restore)
        self.assertIn('--no-owner', restore)
        self.assertNotIn('--clean', restore)
        self.assertEqual(database.APP_DB, restore[restore.index('--dbname') + 1])
        self.assertEqual('bully_pulpit', restore[restore.index('--role') + 1])
        self.assertTrue(any(kw.get('sql', '').endswith('DROP SCHEMA public;') for _, kw in self.runner.calls))
        manifest = json.loads(Path(report['manifest_file']).read_text())
        self.assertEqual(64, len(manifest['sha256']))
        self.assertEqual(database.counts_list(database.parse_counts(COUNTS)), manifest['tables'])
        for path in [self.root / 'database-copy.json', Path(report['backup_file']), Path(report['manifest_file'])]:
            self.assertEqual(0o600, path.stat().st_mode & 0o777)
        self.assertEqual([], list((self.root / 'secrets').glob('.source-*')))

    def test_count_mismatch_preserves_backup_without_success_marker(self):
        self.runner.counts = COUNTS.replace('"count": 7', '"count": 6')
        with self.assertRaisesRegex(database.Refused, 'counts differ'):
            self.tool.copy()
        self.assertFalse((self.root / 'database-copy.json').exists())
        self.assertEqual(1, len(list((self.root / 'backups').glob('*.dump'))))
        self.assertEqual(1, len(list((self.root / 'backups').glob('*.json'))))

    def test_no_public_schema_drop_when_archive_does_not_create_it(self):
        self.runner.archive_listing = '10; 1259 5000 TABLE public subscribers owner\n'
        self.tool.copy()
        self.assertFalse(any('DROP SCHEMA' in kw.get('sql', '') for _, kw in self.runner.calls))

    def test_backup_both_local_databases_including_workflow_history(self):
        report = self.tool.backup()
        self.assertEqual(set(database.DATABASES), {row['database'] for row in report['backups']})
        for args, kwargs in self.runner.calls:
            if 'pg_dump' in args:
                self.assertNotIn('--env-file', args)
                self.assertFalse(any(arg.startswith('--exclude') for arg in args))
                self.assertEqual(database.CONTAINER, args[3])
                self.assertGreater(kwargs['timeout'], 0)
                self.assertGreater(kwargs['limit'], 0)

    def test_low_disk_aborts_before_dump(self):
        with patch.object(database.shutil, 'disk_usage', return_value=type('Usage', (), {'free': 10})()):
            with self.assertRaisesRegex(database.Refused, 'free space'):
                self.tool.copy()
        self.assertFalse(any('pg_dump' in args for args, _ in self.runner.calls))


if __name__ == '__main__':
    unittest.main()

#!/usr/bin/env python3
"""Initialize, copy, or back up only the dedicated Bully Pulpit databases."""
import argparse
from contextlib import contextmanager
import datetime
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import selectors
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from urllib.parse import parse_qs, unquote, urlsplit
import uuid

ROOT = Path('/Users/philip/data/bully-pulpit-local')
CONTAINER = 'bully-pulpit-postgres'
IMAGE = 'postgres:17-bookworm@sha256:839fbb5a4942a7758dd93e18b42ea5649807491a0545b5eeeb8f0b8bb11857a5'
ADMIN = 'bully_admin'
APP_DB = 'bully_pulpit_toolbox'
WORKFLOW_DB = 'bully_pulpit_workflow_toolbox'
DATABASES = {APP_DB: ('bully_pulpit', 'APP_DB_PASSWORD'),
             WORKFLOW_DB: ('bully_workflow', 'WORKFLOW_DB_PASSWORD')}
EXCLUDED_SCHEMAS = ('workflow', 'workflow_drizzle', 'graphile_worker')
SUPPORTED_EXTENSIONS = {'plpgsql', 'pgcrypto', 'uuid-ossp', 'citext', 'hstore',
                        'unaccent', 'btree_gin', 'btree_gist', 'pg_trgm'}
METADATA_LIMIT = 2 * 1024**2
ERROR_LIMIT = 128 * 1024
PSQL = ['psql', '--no-psqlrc', '--no-password', '--quiet', '--tuples-only',
        '--no-align', '--set', 'ON_ERROR_STOP=1']


class Refused(RuntimeError):
    """A safe, credential-free error suitable for operator output."""


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def secure_path(path):
    """Reject symbolic links in existing runtime paths, including ancestors."""
    for candidate in (path, *path.parents):
        if candidate.is_symlink():
            raise Refused('Symbolic links are not allowed in database runtime paths')


def private_json(path):
    secure_path(path)
    try:
        info = path.stat()
        if not stat.S_ISREG(info.st_mode) or info.st_mode & 0o077 or info.st_size > 16384:
            raise Refused('Database credential files must be regular private files (0600)')
        value = json.loads(path.read_text())
        if not isinstance(value, dict):
            raise Refused('Database credential file must contain a JSON object')
        return value
    except (OSError, ValueError):
        raise Refused('Required private database credential file is missing or invalid') from None


def write_json(path, value):
    secure_path(path)
    with open_exclusive(path) as file:
        file.write((json.dumps(value, indent=2) + '\n').encode())
        file.flush()
        os.fsync(file.fileno())


def open_exclusive(path):
    return os.fdopen(os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb')


def literal(value):
    if not isinstance(value, str) or '\x00' in value:
        raise Refused('Invalid database identity')
    return "'" + value.replace("'", "''") + "'"


def source_environment(url):
    """Credentials go only in a private Docker env file, never process argv."""
    try:
        if not isinstance(url, str):
            raise ValueError()
        parsed = urlsplit(url)
        query = parse_qs(parsed.query, strict_parsing=True)
        if (parsed.scheme not in ('postgres', 'postgresql') or not parsed.hostname or
                not parsed.hostname.endswith('.neon.tech') or parsed.fragment or
                not parsed.username or not parsed.password or parsed.port not in (None, 5432) or
                not parsed.path.startswith('/') or len(parsed.path) < 2 or
                set(query) - {'sslmode', 'channel_binding', 'connect_timeout'} or
                any(len(values) != 1 for values in query.values()) or
                query.get('sslmode', ['require'])[0] not in ('require', 'verify-full') or
                query.get('channel_binding', ['prefer'])[0] not in ('require', 'prefer', 'disable')):
            raise ValueError()
        values = {'PGHOST': parsed.hostname, 'PGPORT': '5432',
                  'PGUSER': unquote(parsed.username), 'PGPASSWORD': unquote(parsed.password),
                  'PGDATABASE': unquote(parsed.path[1:]),
                  'PGSSLMODE': query.get('sslmode', ['require'])[0],
                  'PGCHANNELBINDING': query.get('channel_binding', ['prefer'])[0],
                  'PGCONNECT_TIMEOUT': '10', 'PGAPPNAME': 'bully-pulpit-readonly-copy',
                  'PGOPTIONS': '-c default_transaction_read_only=on -c statement_timeout=120000 -c lock_timeout=10000'}
        if any(any(char in value for char in '\r\n\x00') for value in values.values()):
            raise ValueError()
        return values
    except (TypeError, ValueError):
        raise Refused('Source must be an explicit Neon PostgreSQL URL with supported TLS options') from None


class Runner:
    """Bound disk-backed output and runtime; never expose subprocess diagnostics."""
    def run(self, args, *, sql=None, input_path=None, output_path=None,
            limit=METADATA_LIMIT, timeout=120):
        with tempfile.TemporaryFile() as stdin, tempfile.TemporaryFile() as stderr:
            if sql is not None:
                stdin.write(sql.encode())
                stdin.seek(0)
            source = open(input_path, 'rb') if input_path else stdin
            target = open_exclusive(output_path) if output_path else tempfile.TemporaryFile()
            process = None
            try:
                process = subprocess.Popen(args, stdin=source, stdout=target, stderr=stderr)
                deadline = time.monotonic() + timeout
                while process.poll() is None:
                    if (time.monotonic() > deadline or os.fstat(target.fileno()).st_size > limit or
                            os.fstat(stderr.fileno()).st_size > ERROR_LIMIT):
                        raise Refused('Database command exceeded its time or output limit')
                    time.sleep(0.05)
                if (process.returncode or os.fstat(target.fileno()).st_size > limit or
                        os.fstat(stderr.fileno()).st_size > ERROR_LIMIT):
                    raise Refused('Database command failed; credentials and raw diagnostics were withheld')
                if output_path:
                    target.flush()
                    os.fsync(target.fileno())
                    return ''
                target.seek(0)
                return target.read(limit + 1).decode('utf-8', errors='strict')
            finally:
                if process is not None and process.poll() is None:
                    process.kill()
                    process.wait()
                target.close()
                if input_path:
                    source.close()


class Snapshot:
    """Keep one read-only transaction open while a second client exports it."""
    def __init__(self, args, runner):
        self.runner = runner
        self.args = args
        self.name = args[args.index('--name') + 1] if '--name' in args else None
        self.stderr = None
        self.process = None
        self.buffer = b''

    def __enter__(self):
        self.stderr = tempfile.TemporaryFile()
        self.process = subprocess.Popen(self.args, stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=self.stderr)
        try:
            self.query('BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY; SET LOCAL row_security=off;')
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def query(self, sql):
        token = 'done_' + uuid.uuid4().hex
        try:
            self.process.stdin.write((sql + '\nSELECT ' + literal(token) + ';\n').encode())
            self.process.stdin.flush()
        except (BrokenPipeError, OSError):
            raise Refused('Read-only snapshot connection failed') from None
        deadline = time.monotonic() + 150
        lines, size = [], 0
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            while time.monotonic() < deadline:
                while b'\n' in self.buffer:
                    line, self.buffer = self.buffer.split(b'\n', 1)
                    if line.decode('utf-8') == token:
                        return '\n'.join(lines)
                    if line:
                        lines.append(line.decode('utf-8'))
                if (size > METADATA_LIMIT or
                        os.fstat(self.stderr.fileno()).st_size > ERROR_LIMIT):
                    raise Refused('Read-only snapshot exceeded its output limit')
                if selector.select(0.1):
                    chunk = os.read(self.process.stdout.fileno(), 65536)
                    if not chunk:
                        raise Refused('Read-only snapshot connection failed')
                    self.buffer += chunk
                    size += len(chunk)
        raise Refused('Read-only snapshot query timed out')

    def __exit__(self, *_):
        if self.process:
            if self.process.poll() is None:
                self.process.kill()
            self.process.wait(timeout=10)
            self.process.stdin.close()
            self.process.stdout.close()
        if self.stderr:
            self.stderr.close()
        if self.name:
            try:
                self.runner.run(['docker', 'rm', '--force', self.name], timeout=15)
            except (Refused, OSError):
                pass


TABLE_FILTER = """n.nspname <> 'information_schema'
AND n.nspname NOT LIKE 'pg\\_%' ESCAPE '\\'
AND n.nspname NOT IN ('workflow', 'workflow_drizzle', 'graphile_worker')"""
COUNTS_SQL = """SELECT format(
  'SELECT json_build_object(''schema'', %L, ''table'', %L, ''count'', count(*)) FROM %I.%I;',
  n.nspname, c.relname, n.nspname, c.relname)
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'p', 'm') AND """ + TABLE_FILTER + """
ORDER BY n.nspname, c.relname
\\gexec
"""
METADATA_SQL = """SELECT json_build_object(
 'snapshot', pg_export_snapshot(),
 'version', current_setting('server_version_num')::int,
 'size', pg_database_size(current_database()),
 'extensions', (SELECT coalesce(json_agg(extname ORDER BY extname), '[]') FROM pg_extension));"""


def parse_counts(text):
    counts = {}
    for line in text.splitlines():
        item = json.loads(line)
        key = (item['schema'], item['table'])
        if (not all(isinstance(value, str) for value in key) or key in counts or
                type(item['count']) is not int or item['count'] < 0):
            raise Refused('Invalid table-count manifest')
        counts[key] = item['count']
    return counts


def counts_list(counts):
    return [{'schema': schema, 'table': table, 'count': count}
            for (schema, table), count in sorted(counts.items())]


def validate_source(metadata):
    if type(metadata.get('version')) is not int or not 120000 <= metadata['version'] < 180000:
        raise Refused('Source PostgreSQL version is unsupported by the pinned PostgreSQL 17 client')
    extensions = metadata.get('extensions')
    if not isinstance(extensions, list) or any(not isinstance(ext, str) for ext in extensions):
        raise Refused('Source extension metadata is invalid')
    unsupported = sorted(set(extensions) - SUPPORTED_EXTENSIONS)
    if unsupported:
        names = ', '.join(ext for ext in unsupported if re.fullmatch(r'[a-zA-Z0-9_-]{1,80}', ext))
        raise Refused('Source contains unsupported extensions: ' + (names or '(invalid names)'))
    if (not isinstance(metadata.get('snapshot'), str) or
            not re.fullmatch(r'[0-9A-Fa-f]+-[0-9A-Fa-f]+-[0-9]+', metadata['snapshot']) or
            type(metadata.get('size')) is not int or metadata['size'] <= 0):
        raise Refused('Source snapshot metadata is invalid')


class DatabaseTool:
    def __init__(self, root=ROOT, runner=None, snapshot_factory=Snapshot):
        self.root = Path(root)
        self.runner = runner or Runner()
        self.snapshot_factory = snapshot_factory

    def prepare(self):
        secure_path(self.root)
        if not self.root.is_dir():
            raise Refused('Provision the dedicated runtime directory first')
        for directory in (self.root / 'secrets', self.root / 'backups'):
            secure_path(directory)
            directory.mkdir(mode=0o700, exist_ok=True)
            if directory.stat().st_mode & 0o077:
                raise Refused('Database secrets and backups directories must have mode 0700')
        raw = self.runner.run(['docker', 'inspect', '--format',
                               '{"name":{{json .Name}},"image":{{json .Config.Image}},"running":{{json .State.Running}}}',
                               CONTAINER])
        state = json.loads(raw)
        if state != {'name': '/' + CONTAINER, 'image': IMAGE, 'running': True}:
            raise Refused('Dedicated PostgreSQL container identity does not match the pinned deployment')

    def local(self, database, sql):
        if database not in (*DATABASES, 'postgres'):
            raise Refused('Database target is not allowlisted')
        return self.runner.run(['docker', 'exec', '-i', CONTAINER, *PSQL,
                               '--username', ADMIN, '--dbname', database],
                               sql="SET statement_timeout='110s'; SET lock_timeout='10s';\n" + sql)

    def initialize(self):
        self.prepare()
        identities = private_json(self.root / 'secrets' / 'identity.json')
        for database, (role, password_key) in DATABASES.items():
            password = identities.get(password_key)
            if not isinstance(password, str) or len(password) < 32:
                raise Refused('Dedicated database passwords must contain at least 32 characters')
            # Passwords are passed over stdin; no SQL or database errors are printed.
            sql = ("SET standard_conforming_strings=on;\n"
                   f"SELECT 'CREATE ROLE {role}' WHERE NOT EXISTS "
                   f"(SELECT FROM pg_roles WHERE rolname={literal(role)})\n\\gexec\n"
                   f"ALTER ROLE {role} LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE "
                   f"NOREPLICATION NOBYPASSRLS PASSWORD {literal(password)};\n")
            self.local('postgres', sql)
            owner = self.local('postgres', f"SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname={literal(database)};").strip()
            if owner and owner != role:
                raise Refused('Existing dedicated database has an unexpected owner')
            if not owner:
                self.local('postgres', f"CREATE DATABASE {database} OWNER {role} TEMPLATE template0 ENCODING 'UTF8';")
            self.local(database, f"REVOKE ALL ON DATABASE {database} FROM PUBLIC;\n"
                       f"CREATE SCHEMA IF NOT EXISTS public AUTHORIZATION {role};\n"
                       f"ALTER SCHEMA public OWNER TO {role};\nREVOKE CREATE ON SCHEMA public FROM PUBLIC;")
        return {'initialized': list(DATABASES)}

    def require_empty(self):
        # Include sequences/views/foreign tables, not only tables containing rows.
        result = self.local(APP_DB, """SELECT json_build_object(
 'objects', (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace
 WHERE n.nspname <> 'information_schema' AND n.nspname NOT LIKE 'pg\\_%' ESCAPE '\\'
 AND c.relkind IN ('r','p','v','m','S','f')),
 'connections', (SELECT count(*) FROM pg_stat_activity WHERE datname=current_database() AND pid<>pg_backend_pid()));""")
        if json.loads(result) != {'objects': 0, 'connections': 0}:
            raise Refused('Application database must be empty and unused; existing data will never be replaced')

    @contextmanager
    def source_file(self):
        value = private_json(self.root / 'secrets' / 'source-database.json')
        environment = source_environment(value.get('url'))
        descriptor, name = tempfile.mkstemp(prefix='.source-', suffix='.env', dir=self.root / 'secrets')
        try:
            with os.fdopen(descriptor, 'w') as file:
                file.write(''.join(f'{key}={value}\n' for key, value in environment.items()))
            yield name
        finally:
            os.unlink(name)

    def source_args(self, env_file, command):
        return ['docker', 'run', '--rm', '-i', '--name',
                'toolbox-op-bully-pulpit-db-' + uuid.uuid4().hex,
                '--env-file', str(env_file), IMAGE, *command]

    def dump(self, database, *, source_file=None, snapshot=None, size):
        if shutil.disk_usage(self.root).free < 2 * size + 2 * 1024**3:
            raise Refused('Insufficient physical free space for a protected database backup')
        name = ('source' if source_file else database) + '-' + datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ') + '-' + uuid.uuid4().hex[:8]
        path = self.root / 'backups' / (name + '.dump')
        command = ['pg_dump', '--no-password', '--format=custom', '--no-owner', '--no-acl']
        if source_file:
            command += ['--snapshot', snapshot]
            command += ['--exclude-schema=' + schema for schema in EXCLUDED_SCHEMAS]
            args = self.source_args(source_file, command)
        else:
            args = ['docker', 'exec', '-i', CONTAINER, *command, '--username', ADMIN, '--dbname', database]
        try:
            self.runner.run(args, output_path=path, limit=2 * size + 64 * 1024**2, timeout=1800)
        finally:
            if source_file:
                try:
                    self.runner.run(['docker', 'rm', '--force', args[args.index('--name') + 1]], timeout=15)
                except (Refused, OSError):
                    pass
        with path.open('rb') as file:
            if file.read(5) != b'PGDMP':
                raise Refused('Backup is not a PostgreSQL custom archive')
            file.seek(0)
            digest = hashlib.sha256()
            for chunk in iter(lambda: file.read(1024**2), b''):
                digest.update(chunk)
            digest = digest.hexdigest()
        return path, {'database': database, 'created_at': now(), 'bytes': path.stat().st_size,
                      'sha256': digest, 'backup_file': str(path)}

    def copy(self):
        self.prepare()
        marker = self.root / 'database-copy.json'
        secure_path(marker)
        if marker.exists():
            raise Refused('A verified database copy already exists; automatic replacement is forbidden')
        self.require_empty()
        with self.source_file() as env_file:
            with self.snapshot_factory(self.source_args(env_file, PSQL), self.runner) as source:
                metadata = json.loads(source.query(METADATA_SQL))
                validate_source(metadata)
                expected = parse_counts(source.query(COUNTS_SQL))
                archive, manifest = self.dump(APP_DB, source_file=env_file,
                                              snapshot=metadata['snapshot'], size=metadata['size'])
        manifest.update({'source_version': metadata['version'], 'extensions': metadata['extensions'],
                         'excluded_schemas': list(EXCLUDED_SCHEMAS), 'tables': counts_list(expected)})
        manifest_path = archive.with_suffix('.json')
        write_json(manifest_path, manifest)
        self.require_empty()
        listing = self.runner.run(['docker', 'exec', '-i', CONTAINER, 'pg_restore', '--list'], input_path=archive)
        if re.search(r'^\d+;\s+\d+\s+\d+\s+SCHEMA\s+-\s+public\s', listing, re.MULTILINE):
            # Only remove an empty initial schema when the archive recreates it.
            # No CASCADE and no --clean: existing application objects are refused.
            self.local(APP_DB, 'DROP SCHEMA public;')
        self.runner.run(['docker', 'exec', '-i', '--env',
                         'PGOPTIONS=-c statement_timeout=1700000 -c lock_timeout=10000',
                         CONTAINER, 'pg_restore', '--no-password',
                         '--username', ADMIN, '--dbname', APP_DB, '--role', DATABASES[APP_DB][0],
                         '--no-owner', '--no-acl', '--no-comments', '--single-transaction', '--exit-on-error'],
                        input_path=archive, timeout=1800)
        actual = parse_counts(self.local(APP_DB, COUNTS_SQL))
        if actual != expected:
            raise Refused('Restored table counts differ from the exported source snapshot; copy is not verified')
        report = {'verified': True, 'application_database': APP_DB, 'backup_file': str(archive),
                  'manifest_file': str(manifest_path), 'verified_at': now(),
                  'table_count': len(actual), 'total_rows': sum(actual.values())}
        write_json(marker, report)
        return report

    def backup(self):
        self.prepare()
        backups = []
        for database in DATABASES:
            size = int(self.local(database, 'SELECT pg_database_size(current_database());').strip())
            archive, manifest = self.dump(database, size=size)
            write_json(archive.with_suffix('.json'), manifest)
            backups.append(manifest)
        return {'backups': backups}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('init', 'copy', 'backup'))
    args = parser.parse_args()
    secure_path(ROOT)
    lock_path = ROOT / 'database.lock'
    secure_path(lock_path)
    descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    with os.fdopen(descriptor, 'w') as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise Refused('Another dedicated database operation is already running') from None
        tool = DatabaseTool()
        operation = tool.initialize if args.operation == 'init' else getattr(tool, args.operation)
        print(json.dumps(operation(), indent=2))


if __name__ == '__main__':
    try:
        main()
    except Refused as error:
        print('Database operation refused: ' + str(error), file=sys.stderr)
        sys.exit(1)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError):
        print('Database operation failed; private diagnostics were withheld', file=sys.stderr)
        sys.exit(1)

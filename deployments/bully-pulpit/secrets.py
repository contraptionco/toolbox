#!/usr/bin/env python3
"""Render this deployment's runtime credentials from its dedicated 1Password item."""
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
from urllib.parse import unquote, urlsplit
import uuid

ROOT = Path('/Users/philip/data/bully-pulpit-local')
VAULT = 'ao6pgbthqnu4expub6pdb4z3oa'
ITEM = 'Bully Pulpit Toolbox'
IMAGE = '1password/op@sha256:9c1824aac2a52c0b2a1cbc50049db9f122f51535f8f34d7847f0fca66be53c49'


def parse_env(text):
    result = {}
    for line in text.splitlines():
        if line and not line.startswith('#'):
            key, value = line.split('=', 1)
            if not key.replace('_', '').isalnum() or key in result:
                raise ValueError('Invalid runtime environment keys')
            result[key] = value
    return result


def validate(app, postgres):
    if app.get('APP_RUNTIME') != 'toolbox' or app.get('DEPLOYMENT_ROLE') != 'parallel':
        raise ValueError('The secret item must identify the parallel Toolbox deployment')
    if app.get('APP_URL') != 'https://bully-pulpit.contraption.co':
        raise ValueError('Unexpected local application origin')
    if postgres.get('POSTGRES_USER') != 'bully_admin' or not postgres.get('POSTGRES_PASSWORD'):
        raise ValueError('Invalid dedicated PostgreSQL administrator')
    identity = {'POSTGRES_PASSWORD': postgres['POSTGRES_PASSWORD']}
    for key, user, db, password_key in [
        ('DATABASE_URL', 'bully_pulpit', 'bully_pulpit_toolbox', 'APP_DB_PASSWORD'),
        ('WORKFLOW_POSTGRES_URL', 'bully_workflow', 'bully_pulpit_workflow_toolbox', 'WORKFLOW_DB_PASSWORD'),
    ]:
        value = urlsplit(app.get(key, ''))
        if (value.scheme not in ('postgres', 'postgresql') or value.hostname != 'postgres'
                or value.username != user or value.path != '/' + db
                or not value.password or value.query or value.fragment):
            raise ValueError('A database secret does not target its dedicated local database')
        identity[password_key] = unquote(value.password)
    return identity


def write_private(path, text):
    if path.is_symlink(): raise ValueError('Refusing a symbolic link for a secret file')
    temporary = path.with_suffix('.new')
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as file:
        file.write(text)
        file.flush()
        os.fsync(file.fileno())
    os.replace(temporary, path)


def read_item(token):
    # Dashboard classifies this prefix as transient and never offers its logs.
    name = 'toolbox-op-bully-pulpit-secrets-' + uuid.uuid4().hex
    result = subprocess.run(
        ['docker', 'run', '--rm', '-i', '--name', name, '--log-driver=none', '--env', 'OP_SERVICE_ACCOUNT_TOKEN',
         IMAGE, 'op', '--cache=false', 'item', 'get', ITEM, '--vault', VAULT, '--format', 'json'],
        env={**os.environ, 'OP_SERVICE_ACCOUNT_TOKEN': token}, capture_output=True, timeout=60,
    )
    if result.returncode: raise ValueError('The dedicated 1Password item is not readable')
    return json.loads(result.stdout)


def main():
    # Reuse the existing read-only service account, without printing/copying its
    # token into app configuration or granting the application vault access.
    path = Path.home() / 'Library/LaunchAgents/co.contraption.toolbox.heartbeat.plist'
    with path.open('rb') as file: agent = plistlib.load(file)
    token = agent.get('EnvironmentVariables', {}).get('OP_SERVICE_ACCOUNT_TOKEN')
    if not token: raise ValueError('Toolbox 1Password service account is unavailable')
    item = read_item(token)
    fields = {field.get('label'): field.get('value', '') for field in item['fields']}
    app = parse_env(fields['ENV'])
    postgres = parse_env(fields['POSTGRES_ENV'])
    identity = validate(app, postgres)
    directory = ROOT / 'secrets'
    if directory.is_symlink(): raise ValueError('Refusing a symbolic link for secrets directory')
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    old_identity = directory / 'identity.json'
    if old_identity.exists():
        old = json.loads(old_identity.read_text())
        if any(old.get(key) != value for key, value in identity.items()):
            raise ValueError('Database credential rotation requires a separate reviewed operation')
        identity = {**old, **identity}
    write_private(directory / 'app.env', fields['ENV'].rstrip() + '\n')
    write_private(directory / 'postgres.env', fields['POSTGRES_ENV'].rstrip() + '\n')
    write_private(old_identity, json.dumps(identity))
    print('Local runtime credentials refreshed from the dedicated 1Password item')


if __name__ == '__main__':
    try: main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError):
        print('Secret refresh refused; check the dedicated item and local database identity', file=sys.stderr)
        sys.exit(1)

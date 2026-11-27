#!/usr/bin/env python3
"""Render this deployment's runtime credentials from its dedicated 1Password item."""
import json
import os
import re
from pathlib import Path
import plistlib
import subprocess
import sys
from urllib.parse import unquote, urlsplit
import uuid

ROOT = Path('/Users/philip/data/bully-pulpit')
VAULT = 'ao6pgbthqnu4expub6pdb4z3oa'
ITEM = 'Bully Pulpit Production'
IMAGE = '1password/op@sha256:9c1824aac2a52c0b2a1cbc50049db9f122f51535f8f34d7847f0fca66be53c49'


def parse_env(text):
    result = {}
    for line in text.splitlines():
        if line and not line.startswith('#'):
            key, value = line.split('=', 1)
            if not re.fullmatch(r'[A-Z_][A-Z0-9_]*', key) or key in result or '\x00' in value:
                raise ValueError('Invalid runtime environment keys')
            result[key] = value
    return result


def validate(app, require_runtime=False):
    if app.get('APP_ENV') != 'production':
        raise ValueError('APP_ENV must explicitly identify production')
    if app.get('APP_RUNTIME') != 'toolbox' or app.get('DEPLOYMENT_ROLE') not in ('parallel', 'primary'):
        raise ValueError('The secret item must explicitly identify the Toolbox deployment role')
    if app.get('APP_URL') != 'https://www.philipithomas.com':
        raise ValueError('Production origin must preserve the canonical host and JWT audience')
    identity = {}
    for key, user, db, password_key in [
        ('DATABASE_URL', 'bully_pulpit', 'bully_pulpit', 'APP_DB_PASSWORD'),
        ('WORKFLOW_POSTGRES_URL', 'bully_workflow', 'bully_pulpit_workflow', 'WORKFLOW_DB_PASSWORD'),
    ]:
        value = urlsplit(app.get(key, ''))
        if (value.scheme not in ('postgres', 'postgresql') or value.hostname != 'postgres'
                or value.username != user or value.path != '/' + db or value.port not in (None, 5432)
                or not value.password or value.query or value.fragment):
            raise ValueError('Database credentials must target the app-owned databases in managed Postgres')
        identity[password_key] = unquote(value.password)
    if require_runtime:
        required = ('JWT_SECRET', 'BELL_IDENTITY_SECRET', 'CRON_SECRET', 'TURNSTILE_SECRET_KEY',
                    'NEXT_PUBLIC_TURNSTILE_SITE_KEY', 'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY',
                    'AWS_REGION', 'OPENAI_API_KEY', 'PHOTO_ARCHIVE_S3_BUCKET', 'PHOTO_ARCHIVE_S3_REGION')
        if any(not app.get(key) for key in required):
            raise ValueError('Required production credentials are missing')
        if not app.get('STRIPE_SECRET_KEY', '').startswith(('sk_live_', 'rk_live_')):
            raise ValueError('A live Stripe key is required')
        if any(key.startswith('POSTGRES_') for key in app):
            raise ValueError('Cluster administrator credentials must never enter the application')
    return identity


def write_private(path, text):
    if path.is_symlink(): raise ValueError('Refusing a symbolic link for a secret file')
    if any(parent.is_symlink() for parent in path.parents): raise ValueError('Secret parent cannot be a symbolic link')
    temporary = path.with_suffix('.new-' + uuid.uuid4().hex)
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
    identity = validate(app)
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    if ROOT.stat().st_mode & 0o077: raise ValueError('Runtime directory must have mode 0700')
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
    write_private(old_identity, json.dumps(identity))
    print('Local runtime credentials refreshed from the dedicated 1Password item')


if __name__ == '__main__':
    try: main()
    except (ValueError, KeyError, OSError, subprocess.SubprocessError):
        print('Secret refresh refused; check the dedicated item and local database identity', file=sys.stderr)
        sys.exit(1)

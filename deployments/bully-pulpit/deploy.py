#!/usr/bin/env python3
"""Prepare a verified Toolbox release; activate only after the final cloud copy."""
import argparse
import datetime
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path('/Users/philip/data/bully-pulpit')
HERE = Path(__file__).resolve().parent
PUBLIC_BUILD_KEYS = ('NEXT_PUBLIC_TURNSTILE_SITE_KEY', 'NEXT_PUBLIC_GOOGLE_CLIENT_ID',
                     'NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY', 'PHONE_NUMBER')
SPEC = importlib.util.spec_from_file_location('bully_secret_rules', HERE / 'secrets.py')
secret_rules = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(secret_rules)


def command(args, *, env=None, cwd=None, log=None, timeout=3600):
    result = subprocess.run(args, env=env, cwd=cwd, stdout=log or subprocess.PIPE,
                            stderr=log or subprocess.PIPE, text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed; inspect the private deployment log')
    return result.stdout or ''


def read_env(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_mode & 0o077:
        raise RuntimeError('Runtime environment must be a regular private file (0600)')
    return secret_rules.parse_env(path.read_text())


def acquire_release_lock(root):
    fd = os.open(root / 'deploy.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    lock = os.fdopen(fd, 'w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock.close()
        raise RuntimeError('Another local release is already in progress') from None
    return lock


def atomic_record(path, data):
    secret_rules.write_private(path, json.dumps(data, indent=2) + '\n')


def copy_identity(root):
    marker = root / 'database-copy.json'
    if marker.is_symlink() or not marker.is_file():
        raise RuntimeError('A verified final cloud database copy is required')
    report = json.loads(marker.read_text())
    if report.get('verified') is not True or report.get('application_database') != 'bully_pulpit':
        raise RuntimeError('A verified final cloud database copy is required')
    digest = report.get('source_sha256', '')
    if not re.fullmatch(r'[a-f0-9]{64}', digest):
        raise RuntimeError('Database copy is missing its source archive identity')
    return digest


def validate_activation(root, env):
    digest = copy_identity(root)
    enabled = json.loads((root / 'enabled.json').read_text())
    if enabled.get('copy_sha256') != digest:
        raise RuntimeError('Enable marker does not match the verified cloud copy')
    if env['DEPLOYMENT_ROLE'] == 'primary':
        marker = root / 'primary.json'
        if not marker.is_file() or json.loads(marker.read_text()).get('copy_sha256') != digest:
            raise RuntimeError('Primary deployment needs the explicit final-copy activation marker')
    return digest


def freeze_files(directory, contents):
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    for name, content in contents.items():
        path = directory / name
        if path.exists() and path.read_text() != content:
            raise RuntimeError('Immutable infrastructure release changed')
        if not path.exists(): secret_rules.write_private(path, content)
        # The unprivileged nginx UID must read its public configuration. The
        # enclosing release directory remains private on the host.
        if name in ('nginx.conf', 'scheduler.py'): path.chmod(0o644)


def prepare(root=ROOT, source=None, environ=None):
    environ = os.environ if environ is None else environ
    source = Path.cwd() if source is None else Path(source)
    sha = environ.get('TOOLBOX_RELEASE_SHA', '')
    if not re.fullmatch(r'[a-f0-9]{40}', sha) or (source / '.git').exists():
        raise RuntimeError('Build must use the verified Toolbox archive and full release SHA')
    env_path = root / 'secrets/app.env'
    if environ.get('TOOLBOX_RUNTIME_ENV') != str(env_path):
        raise RuntimeError('Unexpected runtime environment path')
    env = read_env(env_path)
    secret_rules.validate(env, require_runtime=True)
    digest = validate_activation(root, env)
    if shutil.disk_usage(root).free < 20 * 1024**3:
        raise RuntimeError('At least 20 GiB immediately free is required before release')
    scheduler = root / 'scheduler'
    scheduler.mkdir(mode=0o700, exist_ok=True)
    secret_rules.write_private(root / 'secrets/scheduler.env',
                               'DEPLOYMENT_ROLE=' + env['DEPLOYMENT_ROLE'] + '\nCRON_SECRET=' + env['CRON_SECRET'] + '\n')
    contents = {name: (HERE / name).read_text() for name in ('compose.yml', 'nginx.conf', 'scheduler.py')}
    public = {key: env[key] for key in PUBLIC_BUILD_KEYS if env.get(key)}
    identity = hashlib.sha256(json.dumps({'sha': sha, 'files': contents, 'public': public}, sort_keys=True).encode()).hexdigest()
    build_directory = root / 'builds' / identity
    build_directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    image_id_file = build_directory / 'image.id'
    log_path = root / 'deploy.log'
    if log_path.exists() and log_path.stat().st_size > 10 * 1024**2:
        for index in (2, 1):
            old = root / f'deploy.log.{index}'
            if old.exists(): old.replace(root / f'deploy.log.{index + 1}')
        log_path.replace(root / 'deploy.log.1')
    fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'a') as log:
        build = ['docker', 'build', '--iidfile', str(image_id_file), '--tag',
                 'bully-pulpit-production:' + identity[:20], '--label',
                 'org.opencontainers.image.revision=' + sha, '--build-arg',
                 'APP_URL=https://www.philipithomas.com']
        for key, value in public.items(): build += ['--build-arg', key + '=' + value]
        command(build + [str(source)], log=log)
        image_id = image_id_file.read_text().strip()
        if not re.fullmatch(r'sha256:[a-f0-9]{64}', image_id):
            raise RuntimeError('Build did not produce an immutable image ID')
        command(['docker', 'tag', image_id, 'bully-pulpit-production:' + sha[:12] + '-' + image_id[-12:]], log=log)
        # Preserve both application and Workflow state before additive migrations.
        command([sys.executable, str(HERE / 'database.py'), 'backup'], log=log)
    infra = root / 'releases' / (identity + '-' + image_id[-12:])
    release_env = '\n'.join([
        'BULLY_RUNTIME_DIR=' + str(root), 'BULLY_IMAGE=' + image_id,
        'BULLY_HOST_UID=' + str(os.getuid()), 'BULLY_HOST_GID=' + str(os.getgid()), ''])
    freeze_files(infra, {**contents, 'release.env': release_env})
    compose = {'name': 'bully-pulpit-production', 'include': [{
        'path': str(infra / 'compose.yml'), 'project_directory': str(infra),
        'env_file': str(infra / 'release.env'),
    }]}
    atomic_record(root / 'compose.json', compose)
    atomic_record(root / 'pending-deployment.json', {
        'application_sha': sha, 'image': image_id, 'infrastructure': str(infra),
        'compose': compose, 'copy_sha256': digest, 'role': env['DEPLOYMENT_ROLE'],
        'prepared_at': datetime.datetime.now(datetime.timezone.utc).isoformat(),
    })
    print('Prepared immutable Bully Pulpit release; Compose will apply migrations and verify readiness')


def record(root=ROOT):
    pending = json.loads((root / 'pending-deployment.json').read_text())
    current = root / 'deployment.json'
    if current.exists(): atomic_record(root / 'previous-deployment.json', json.loads(current.read_text()))
    pending['ready_at'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
    atomic_record(current, pending)
    print('Recorded healthy Bully Pulpit deployment')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=('prepare', 'record', 'enable', 'activate'))
    parser.add_argument('--copy-sha256')
    args = parser.parse_args()
    if HERE.parent.parent != Path('/Users/philip/code/toolbox'):
        raise RuntimeError('Deployment commands must run from the production Toolbox checkout')
    if command(['git', 'status', '--porcelain'], cwd=HERE.parent.parent).strip():
        raise RuntimeError('Production Toolbox checkout must be clean')
    if command(['git', 'branch', '--show-current'], cwd=HERE.parent.parent).strip() != 'main':
        raise RuntimeError('Production Toolbox checkout must be on main')
    repository = HERE.parent.parent
    if command(['git', 'remote', 'get-url', 'origin'], cwd=repository).strip() != 'git@github.com:contraptionco/toolbox.git':
        raise RuntimeError('Unexpected production Toolbox remote')
    head = command(['git', 'rev-parse', 'HEAD'], cwd=repository).strip()
    remote = command(['git', 'ls-remote', '--exit-code', 'origin', 'refs/heads/main'], cwd=repository, timeout=120).split()
    if not remote or remote[0] != head:
        raise RuntimeError('Production Toolbox must match the current pushed main commit')
    with acquire_release_lock(ROOT):
        if args.operation == 'prepare': prepare()
        elif args.operation == 'record': record()
        else:
            digest = copy_identity(ROOT)
            if args.copy_sha256 != digest:
                raise RuntimeError('Supply the exact verified final source archive SHA256')
            marker = ROOT / ('enabled.json' if args.operation == 'enable' else 'primary.json')
            atomic_record(marker, {'copy_sha256': digest, 'created_at': datetime.datetime.now(datetime.timezone.utc).isoformat()})
            print('Recorded explicit deployment ' + args.operation + ' marker')


if __name__ == '__main__':
    try: main()
    except (RuntimeError, ValueError, KeyError, OSError, subprocess.SubprocessError):
        print('Deployment refused; check the verified release, private configuration and copy/activation records', file=sys.stderr)
        sys.exit(1)

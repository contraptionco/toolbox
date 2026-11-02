#!/usr/bin/env python3
"""Explicit parallel release from a verified remote commit, never a dev tree."""
import argparse
import datetime
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys

ROOT = Path('/Users/philip/data/bully-pulpit-local')
HERE = Path(__file__).resolve().parent
REPOSITORY = 'git@github.com:philipithomas/bully-pulpit.git'
PUBLIC_BUILD_KEYS = ('NEXT_PUBLIC_TURNSTILE_SITE_KEY',
                     'NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY', 'PHONE_NUMBER')


def command(args, *, env=None, cwd=None, log=None):
    result = subprocess.run(args, env=env, cwd=cwd, stdout=log or subprocess.PIPE,
                            stderr=log or subprocess.PIPE, text=True)
    if result.returncode:
        raise RuntimeError(f'{args[0]} failed; inspect the private deployment log')
    return result.stdout or ''


def read_env(path):
    if path.stat().st_mode & 0o077:
        raise RuntimeError('Runtime environment must have mode 0600')
    values = {}
    for line in path.read_text().splitlines():
        if line and not line.startswith('#'):
            key, value = line.split('=', 1)
            values[key] = value
    return values


def acquire_release_lock(root):
    fd = os.open(root / 'deploy.lock', os.O_RDWR | os.O_CREAT, 0o600)
    lock = os.fdopen(fd, 'w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        lock.close()
        raise RuntimeError('Another local release is already in progress') from None
    return lock


def atomic_record(path, data):
    temporary = path.with_suffix('.tmp')
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w') as file:
        file.write(json.dumps(data, indent=2) + '\n')
        file.flush()
        os.fsync(file.fileno())
    os.replace(temporary, path)


def verified_ref(repository, ref, sha):
    if not re.fullmatch(r'[0-9a-f]{40}', sha):
        raise RuntimeError('A full, explicitly selected commit is required')
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_./-]*', ref) or '..' in ref:
        raise RuntimeError('Invalid branch name')
    remote = command(['git', 'ls-remote', '--exit-code', repository,
                      f'refs/heads/{ref}']).split()
    if not remote or remote[0] != sha:
        raise RuntimeError('Selected commit is not the current pushed branch head')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--commit', required=True)
    parser.add_argument('--branch', default='feat/toolbox-self-hosting')
    parser.add_argument('--build-only', action='store_true')
    parser.add_argument('--apply', action='store_true')
    args = parser.parse_args()
    if args.build_only == args.apply:
        parser.error('Choose exactly one of --build-only or --apply')
    release_lock = acquire_release_lock(ROOT)
    verified_ref(REPOSITORY, args.branch, args.commit)
    # The orchestration itself must also be reviewed/pushed and clean.
    repo = HERE.parent.parent
    if command(['git', 'status', '--porcelain'], cwd=repo).strip():
        raise RuntimeError('Toolbox release checkout must be clean')
    toolbox_sha = command(['git', 'rev-parse', 'HEAD'], cwd=repo).strip()
    toolbox_branch = command(['git', 'branch', '--show-current'], cwd=repo).strip()
    toolbox_remote = command(['git', 'remote', 'get-url', 'origin'], cwd=repo).strip()
    if toolbox_remote != 'git@github.com:contraptionco/toolbox.git':
        raise RuntimeError('Unexpected Toolbox source remote')
    verified_ref(toolbox_remote, toolbox_branch, toolbox_sha)
    if shutil.disk_usage(ROOT).free < 8 * 1024**3:
        raise RuntimeError('At least 8 GiB physical free space is required')
    app_env = read_env(ROOT / 'secrets/app.env')
    if app_env.get('APP_RUNTIME') != 'toolbox' or app_env.get('DEPLOYMENT_ROLE') != 'parallel':
        raise RuntimeError('This release tool only supports the parallel Toolbox deployment')
    if not app_env.get('NEXT_PUBLIC_TURNSTILE_SITE_KEY'):
        raise RuntimeError('Production Turnstile site key is required at build time')
    if args.apply:
        required = ('JWT_SECRET', 'BELL_IDENTITY_SECRET', 'CRON_SECRET',
                    'TURNSTILE_SECRET_KEY', 'DATABASE_URL', 'WORKFLOW_POSTGRES_URL',
                    'AWS_ACCESS_KEY_ID', 'AWS_SECRET_ACCESS_KEY', 'OPENAI_API_KEY',
                    'AI_GATEWAY_API_KEY', 'PHOTO_ARCHIVE_READ_WRITE_TOKEN')
        if any(not app_env.get(key) for key in required):
            raise RuntimeError('Required production runtime credentials are missing')
        if not app_env.get('STRIPE_SECRET_KEY', '').startswith(('sk_live_', 'rk_live_')):
            raise RuntimeError('A live Stripe key is required; test keys are refused')
        copy_report = ROOT / 'database-copy.json'
        if not copy_report.exists() or not json.loads(copy_report.read_text()).get('verified'):
            raise RuntimeError('Verified cloud database copy is required before release')
    source = ROOT / 'releases' / args.commit
    if not source.exists():
        command(['git', 'clone', '--depth', '1', '--branch', args.branch, REPOSITORY, str(source)])
    if command(['git', 'rev-parse', 'HEAD'], cwd=source).strip() != args.commit:
        raise RuntimeError('Release checkout has a different commit')
    if command(['git', 'status', '--porcelain'], cwd=source).strip():
        raise RuntimeError('Release checkout has local changes')
    if command(['git', 'ls-files', '--others', '--ignored', '--exclude-standard'], cwd=source).strip():
        raise RuntimeError('Release checkout contains ignored build inputs')
    image = f'bully-pulpit-local:{args.commit}'
    log_path = ROOT / 'deploy.log'
    fd = os.open(log_path, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, 'a') as log:
        build = ['docker', 'build', '--tag', image, '--label',
                 f'org.opencontainers.image.revision={args.commit}', '--build-arg',
                 'APP_URL=https://bully-pulpit.contraption.co']
        for key in PUBLIC_BUILD_KEYS:
            if app_env.get(key): build += ['--build-arg', f'{key}={app_env[key]}']
        command(build + [str(source)], log=log)
        image_id = command(['docker', 'image', 'inspect', '--format', '{{.Id}}', image]).strip()
        if not re.fullmatch(r'sha256:[0-9a-f]{64}', image_id):
            raise RuntimeError('Unable to verify the built image identity')
        if args.build_only:
            print('Built verified image:', image)
            return
        # Freeze the proxy/Compose inputs alongside the app release for rollback.
        infra = ROOT / 'releases' / f'infra-{toolbox_sha}'
        infra.mkdir(exist_ok=True, mode=0o700)
        for filename in ('compose.yml', 'nginx.conf'):
            target = infra / filename
            content = (HERE / filename).read_bytes()
            if target.exists() and target.read_bytes() != content:
                raise RuntimeError('Immutable infrastructure release changed')
            target.write_bytes(content)
        env = {**os.environ, 'BULLY_RUNTIME_DIR': str(ROOT), 'BULLY_IMAGE': image_id}
        compose = ['docker', 'compose', '-f', str(infra / 'compose.yml')]
        command(compose + ['up', '-d', '--wait', 'postgres'], env=env, log=log)
        state = ROOT / 'deployment.json'
        if state.exists():
            atomic_record(ROOT / 'previous-deployment.json', json.loads(state.read_text()))
        command([sys.executable, str(HERE / 'database.py'), 'backup'], log=log)
        # Migrations are additive, and these scripts reject nonlocal DB targets.
        command(compose + ['run', '--rm', '--no-deps', 'app', 'corepack', 'pnpm', 'db:migrate'], env=env, log=log)
        command(compose + ['run', '--rm', '--no-deps', 'app', 'corepack', 'pnpm', 'workflow:bootstrap'], env=env, log=log)
        # One application version owns this workflow database. Compose stops
        # the old named container before starting its replacement.
        command(compose + ['up', '-d', '--wait', '--wait-timeout', '180', '--no-build', 'app', 'proxy'], env=env, log=log)
    record = {'commit': args.commit, 'toolbox_commit': toolbox_sha, 'image': image_id, 'image_tag': image,
              'compose': str(infra / 'compose.yml'), 'released_at': datetime.datetime.now(datetime.timezone.utc).isoformat()}
    atomic_record(ROOT / 'deployment.json', record)
    release_lock.close()
    print('Local release ready:', args.commit)
    print('Origin: http://127.0.0.1:4244 (Host: bully-pulpit.contraption.co)')
    print('Verify origin before changing Cloudflare ingress. Vercel is unchanged.')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, ValueError) as error:
        # Do not forward subprocess output or environment values.
        print(f'Release refused: {error}', file=sys.stderr)
        sys.exit(1)

"""Parse synthetic runtime files with Compose; never contact Docker services."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class ComposeEnvironmentTest(unittest.TestCase):
    def test_runtime_credentials_are_literal_in_both_services(self):
        docker = shutil.which('docker')
        if not docker:
            self.skipTest('Docker Compose CLI is unavailable; no daemon is required')
        version = subprocess.run([docker, 'compose', 'version', '--short'],
                                 capture_output=True, text=True, timeout=15)
        if version.returncode:
            self.skipTest('Docker Compose CLI is unavailable; no daemon is required')

        # Include quotes, both interpolation forms, spaces, #, and backslashes.
        # These are fixture strings, never credentials from the host or vault.
        password = '''literal'$BULLY_ENV_TEST_SUFFIX"${BULLY_ENV_TEST_SUFFIX} # tail\\end'''
        database_url = 'postgres://fixture:' + password + '@postgres/fixture'
        with tempfile.TemporaryDirectory(prefix='bully-compose-env-test-') as directory:
            root = Path(directory)
            secrets = root / 'secrets'
            secrets.mkdir()
            (secrets / 'scheduler.env').write_text('CRON_SECRET=' + password + '\n')
            (secrets / 'app.env').write_text('DATABASE_URL=' + database_url + '\n')
            result = subprocess.run(
                [docker, 'compose', '--project-directory', directory,
                 '-f', str(Path(__file__).with_name('compose.yml')),
                 'config', '--format', 'json'],
                env={**os.environ, 'BULLY_RUNTIME_DIR': directory,
                     'BULLY_IMAGE': 'fixture-image:unused', 'BULLY_HOST_UID': '1000', 'BULLY_HOST_GID': '1000',
                     'BULLY_ENV_TEST_SUFFIX': 'must-not-be-interpolated',
                     # An invalid endpoint proves config parsing needs no daemon.
                     'DOCKER_HOST': 'unix:///nonexistent/bully-compose-test.sock'},
                capture_output=True, text=True, timeout=30,
            )
            self.assertEqual(0, result.returncode, result.stderr)
            # The actual release uses an include wrapper and a nonsecret
            # interpolation file. Exercise that path without a Docker daemon.
            release_env = root / 'release.env'
            release_env.write_text('BULLY_RUNTIME_DIR=' + directory + '\nBULLY_IMAGE=fixture-image:unused\nBULLY_HOST_UID=1000\nBULLY_HOST_GID=1000\n')
            wrapper = root / 'compose.json'
            wrapper.write_text(json.dumps({'name': 'bully-pulpit-production', 'include': [{
                'path': str(Path(__file__).with_name('compose.yml')),
                'project_directory': str(Path(__file__).parent), 'env_file': str(release_env)}]}))
            included = subprocess.run([docker, 'compose', '-f', str(wrapper), 'config', '--format', 'json'],
                                      env={'PATH': os.environ['PATH'], 'DOCKER_HOST': 'unix:///nonexistent/bully-compose-test.sock'},
                                      capture_output=True, text=True, timeout=30)
            self.assertEqual(0, included.returncode, included.stderr)
            self.assertEqual('fixture-image:unused', json.loads(included.stdout)['services']['app']['image'])
            services = json.loads(result.stdout)['services']
            self.assertNotIn('postgres', services)
            self.assertEqual('toolbox_network', json.loads(result.stdout)['networks']['database']['name'])
            # Canonical Compose output escapes each literal $ as $$ so that
            # the rendered configuration can be safely consumed again. The
            # original variable names, quotes, spaces and backslash must remain.
            self.assertEqual(password.replace('$', '$$'),
                             services['scheduler']['environment']['CRON_SECRET'])
            self.assertEqual(database_url.replace('$', '$$'),
                             services['app']['environment']['DATABASE_URL'])


    def test_analytics_overlay_is_private_and_does_not_inherit_provider_credentials(self):
        docker = shutil.which('docker')
        if not docker:
            self.skipTest('Docker Compose CLI is unavailable; no daemon is required')
        version = subprocess.run([docker, 'compose', 'version', '--short'], capture_output=True, text=True, timeout=15)
        if version.returncode:
            self.skipTest('Docker Compose CLI is unavailable; no daemon is required')
        with tempfile.TemporaryDirectory(prefix='bully-analytics-compose-test-') as directory:
            root = Path(directory)
            (root / 'secrets').mkdir()
            (root / 'secrets/app.env').write_text('JWT_SECRET=app-only\nDATABASE_URL=private-db-fixture\nOPENAI_API_KEY=app-only\n')
            (root / 'secrets/scheduler.env').write_text('CRON_SECRET=scheduler-only\n')
            (root / 'analytics.env').write_text('ANALYTICS_TOKEN=fixture-only-service-token\n')
            for name in ['compose.yml', 'analytics.compose.yml', 'nginx.conf', 'scheduler.py']:
                shutil.copyfile(Path(__file__).with_name(name), root / name)
            (root / 'release.env').write_text('BULLY_RUNTIME_DIR=' + directory + '\nBULLY_IMAGE=fixture-image:unused\nBULLY_HOST_UID=1000\nBULLY_HOST_GID=1000\n')
            wrapper = root / 'compose.json'
            wrapper.write_text(json.dumps({'name': 'bully-pulpit-production',
                'x-toolbox-required-services': ['app', 'proxy', 'scheduler', 'analytics'],
                'include': [{'path': [str(root / 'compose.yml'), str(root / 'analytics.compose.yml')],
                             'project_directory': directory, 'env_file': str(root / 'release.env')}]}))
            parsed = subprocess.run([docker, 'compose', '-f', str(wrapper), 'config', '--format', 'json'],
                                    env={'PATH': os.environ['PATH'], 'DOCKER_HOST': 'unix:///nonexistent/bully-compose-test.sock'},
                                    capture_output=True, text=True, timeout=30)
            self.assertEqual(0, parsed.returncode, parsed.stderr)
            config = json.loads(parsed.stdout)
            app = config['services']['app']; analytics = config['services']['analytics']
            self.assertEqual('fixture-image:unused', analytics['image'])
            self.assertEqual(app['image'], analytics['image'])
            self.assertEqual('1000:1000', analytics['user'])
            self.assertEqual(['analytics'], list(analytics['networks']))
            self.assertEqual({'analytics', 'default', 'database'}, set(app['networks']))
            self.assertTrue(config['networks']['analytics']['internal'])
            self.assertNotIn('ports', analytics)
            self.assertTrue(analytics['read_only'])
            self.assertEqual('app-only', app['environment']['JWT_SECRET'])
            self.assertEqual('http://analytics:4100', app['environment']['ANALYTICS_URL'])
            self.assertEqual(app['environment']['ANALYTICS_TOKEN'], analytics['environment']['ANALYTICS_TOKEN'])
            for key in ['JWT_SECRET', 'DATABASE_URL', 'OPENAI_API_KEY', 'AWS_SECRET_ACCESS_KEY', 'CRON_SECRET']:
                self.assertNotIn(key, analytics['environment'])
            self.assertNotIn('ANALYTICS_TOKEN', config['services']['migrate']['environment'])
            self.assertNotIn('ANALYTICS_TOKEN', config['services']['scheduler']['environment'])
            self.assertEqual(str(root / 'analytics'), analytics['volumes'][0]['source'])
            self.assertEqual('2147483648', analytics['environment']['ANALYTICS_MAXIMUM_DATABASE_BYTES'])
            node = shutil.which('node')
            if node:
                health_script = analytics['healthcheck']['test'][-1]
                for status, expected in [
                    ({'ready': True, 'degraded': False, 'lastBackupErrorAt': None}, 0),
                    ({'ready': True, 'degraded': True, 'lastBackupErrorAt': None}, 1),
                    ({'ready': True, 'degraded': False, 'lastBackupErrorAt': 'fixture-time'}, 1),
                    ({'ready': False, 'degraded': False, 'lastBackupErrorAt': None}, 1),
                ]:
                    # Execute the exact health command against synthetic HTTP data.
                    fixture = 'globalThis.fetch=async()=>({ok:true,json:async()=>(' + json.dumps(status) + ')});'
                    checked = subprocess.run([node, '-e', fixture + health_script], capture_output=True, timeout=15)
                    self.assertEqual(expected, checked.returncode)


if __name__ == '__main__':
    unittest.main()

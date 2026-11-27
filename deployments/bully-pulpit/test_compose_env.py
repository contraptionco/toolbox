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


if __name__ == '__main__':
    unittest.main()

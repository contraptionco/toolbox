import importlib.util
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location('bully_secrets', Path(__file__).with_name('secrets.py'))
secrets = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(secrets)


class SecretBoundaryTest(unittest.TestCase):
    def fixture(self):
        return {
            'APP_RUNTIME': 'toolbox', 'DEPLOYMENT_ROLE': 'parallel',
            'APP_URL': 'https://bully-pulpit.contraption.co',
            'DATABASE_URL': 'postgres://bully_pulpit:fixture@postgres/bully_pulpit_toolbox',
            'WORKFLOW_POSTGRES_URL': 'postgres://bully_workflow:fixture@postgres/bully_pulpit_workflow_toolbox',
        }

    def test_rejects_cloud_credentials_and_role_changes(self):
        postgres = {'POSTGRES_USER': 'bully_admin', 'POSTGRES_PASSWORD': 'fixture'}
        self.assertEqual('fixture', secrets.validate(self.fixture(), postgres)['APP_DB_PASSWORD'])
        for key, value in [('DATABASE_URL', 'postgres://user:fixture@cloud.neon.tech/neondb'),
                           ('DEPLOYMENT_ROLE', 'primary'), ('APP_URL', 'https://www.philipithomas.com')]:
            with self.assertRaises(ValueError):
                secrets.validate({**self.fixture(), key: value}, postgres)

    def test_duplicate_or_invalid_keys_are_not_silently_overwritten(self):
        for value in ['NAME=first\nNAME=second\n', 'INVALID NAME=value\n']:
            with self.assertRaises(ValueError): secrets.parse_env(value)


if __name__ == '__main__': unittest.main()

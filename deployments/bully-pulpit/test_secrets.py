import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

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

    def test_credential_helpers_have_unique_transient_names_and_no_docker_logs(self):
        result = SimpleNamespace(returncode=0, stdout=b'{"fields": []}')
        with patch.object(secrets.subprocess, 'run', return_value=result) as run:
            for _ in range(2):
                self.assertEqual({'fields': []}, secrets.read_item('fixture-service-token'))

        names = []
        for call in run.call_args_list:
            args = call.args[0]
            name = args[args.index('--name') + 1]
            self.assertRegex(name, r'^toolbox-op-bully-pulpit-secrets-[0-9a-f]{32}$')
            names.append(name)
            self.assertIn('--rm', args)
            self.assertIn('--log-driver=none', args)
            self.assertNotIn('fixture-service-token', args)
            self.assertEqual('fixture-service-token', call.kwargs['env']['OP_SERVICE_ACCOUNT_TOKEN'])
            self.assertTrue(call.kwargs['capture_output'])
            self.assertEqual(60, call.kwargs['timeout'])
        self.assertNotEqual(*names)


if __name__ == '__main__': unittest.main()

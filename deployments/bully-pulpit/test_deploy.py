"""Hermetic release-guard tests: no Docker, network, credentials or real paths."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('bully_release', Path(__file__).with_name('deploy.py'))
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseGuardTest(unittest.TestCase):
    def test_release_lock_refuses_a_second_writer(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            with release.acquire_release_lock(root):
                with self.assertRaisesRegex(RuntimeError, 'already in progress'):
                    release.acquire_release_lock(root)
            with release.acquire_release_lock(root): pass

    def test_primary_needs_matching_final_copy_activation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            digest = 'a' * 64
            release.atomic_record(root / 'database-copy.json', {'verified': True, 'application_database': 'bully_pulpit', 'source_sha256': digest})
            release.atomic_record(root / 'enabled.json', {'copy_sha256': digest})
            self.assertEqual(digest, release.validate_activation(root, {'DEPLOYMENT_ROLE': 'parallel'}))
            with self.assertRaisesRegex(RuntimeError, 'activation marker'):
                release.validate_activation(root, {'DEPLOYMENT_ROLE': 'primary'})
            release.atomic_record(root / 'primary.json', {'copy_sha256': 'b' * 64})
            with self.assertRaises(RuntimeError): release.validate_activation(root, {'DEPLOYMENT_ROLE': 'primary'})
            release.atomic_record(root / 'primary.json', {'copy_sha256': digest})
            self.assertEqual(digest, release.validate_activation(root, {'DEPLOYMENT_ROLE': 'primary'}))

    def test_pilot_database_copy_cannot_enable_production(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            release.atomic_record(root / 'database-copy.json', {'verified': True, 'application_database': 'bully_pulpit_toolbox', 'source_sha256': 'a' * 64})
            with self.assertRaises(RuntimeError): release.copy_identity(root)

    def test_immutable_release_files_cannot_be_replaced(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            release.freeze_files(root, {'nginx.conf': 'reviewed'})
            release.freeze_files(root, {'nginx.conf': 'reviewed'})
            self.assertEqual(0o644, (root / 'nginx.conf').stat().st_mode & 0o777)
            with self.assertRaisesRegex(RuntimeError, 'Immutable'):
                release.freeze_files(root, {'nginx.conf': 'changed'})

    def test_world_readable_secrets_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'runtime.env'
            path.write_text('EXAMPLE=fixture\n'); path.chmod(0o644)
            with self.assertRaisesRegex(RuntimeError, '0600'): release.read_env(path)
            path.chmod(0o600)
            self.assertEqual({'EXAMPLE': 'fixture'}, release.read_env(path))

    def test_prepare_passes_only_public_build_arguments_and_preserves_backup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / 'secrets').mkdir()
            source = root / 'source'; source.mkdir()
            secret = 'private-fixture-never-build'
            values = {'APP_ENV': 'production', 'APP_RUNTIME': 'toolbox', 'DEPLOYMENT_ROLE': 'parallel', 'APP_URL': 'https://www.philipithomas.com',
                      'DATABASE_URL': 'postgres://bully_pulpit:password@postgres/bully_pulpit',
                      'WORKFLOW_POSTGRES_URL': 'postgres://bully_workflow:password@postgres/bully_pulpit_workflow',
                      'JWT_SECRET': secret, 'BELL_IDENTITY_SECRET': secret, 'CRON_SECRET': secret,
                      'TURNSTILE_SECRET_KEY': secret, 'NEXT_PUBLIC_TURNSTILE_SITE_KEY': 'public-site-key',
                      'AWS_ACCESS_KEY_ID': secret, 'AWS_SECRET_ACCESS_KEY': secret, 'AWS_REGION': 'us-east-2',
                      'OPENAI_API_KEY': secret, 'PHOTO_ARCHIVE_S3_BUCKET': 'fixture', 'PHOTO_ARCHIVE_S3_REGION': 'us-east-2',
                      'STRIPE_SECRET_KEY': 'sk_live_fixture'}
            release.secret_rules.write_private(root / 'secrets/app.env', ''.join(k + '=' + v + '\n' for k,v in values.items()))
            release.atomic_record(root / 'database-copy.json', {'verified': True, 'application_database': 'bully_pulpit', 'source_sha256': 'a' * 64})
            release.atomic_record(root / 'enabled.json', {'copy_sha256': 'a' * 64})
            calls = []
            def command(args, **kwargs):
                calls.append(args)
                if args[:2] == ['docker', 'build']:
                    Path(args[args.index('--iidfile') + 1]).write_text('sha256:' + 'b' * 64)
                return ''
            with patch.object(release, 'command', side_effect=command), patch.object(release.shutil, 'disk_usage', return_value=type('Usage', (), {'free': 30 * 1024**3})()):
                release.prepare(root, source, {'TOOLBOX_RELEASE_SHA': 'c' * 40, 'TOOLBOX_RUNTIME_ENV': str(root / 'secrets/app.env')})
            self.assertNotIn(secret, repr(calls))
            self.assertTrue(any(args[-1] == 'backup' for args in calls))
            pending = json.loads((root / 'pending-deployment.json').read_text())
            self.assertEqual('sha256:' + 'b' * 64, pending['image'])
            self.assertFalse((root / 'deployment.json').exists())
            self.assertNotIn('AWS_', (root / 'secrets/scheduler.env').read_text())
            release.record(root)
            self.assertEqual(pending['image'], json.loads((root / 'deployment.json').read_text())['image'])


if __name__ == '__main__': unittest.main()

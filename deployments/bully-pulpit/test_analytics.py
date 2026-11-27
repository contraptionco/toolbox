"""Analytics release fixtures: no services, real data, credentials or Docker writes."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('analytics_release', Path(__file__).with_name('deploy.py'))
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


def capable_source(source):
    service = source / 'services/analytics'
    service.mkdir(parents=True)
    (service / 'capabilities.json').write_text('{"protocol":1}')
    (service / 'server.ts').write_text('// fixture entrypoint')
    (source / 'package.json').write_text(json.dumps({'dependencies': {'@duckdb/node-api': '1.4.1'}}))


class AnalyticsReleaseTest(unittest.TestCase):
    def test_missing_capability_preserves_old_release_and_partial_capability_refuses(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory).resolve()
            self.assertFalse(release.analytics_capable(source))
            capable_source(source)
            self.assertTrue(release.analytics_capable(source))
            marker = source / 'services/analytics/capabilities.json'
            for content in ['{"protocol":true}', '{"protocol":2}', '{"protocol":1,"unexpected":true}', 'null']:
                marker.write_text(content)
                with self.assertRaises(RuntimeError): release.analytics_capable(source)
            marker.write_text('{"protocol":1}')
            (source / 'services/analytics/server.ts').unlink()
            with self.assertRaises(RuntimeError): release.analytics_capable(source)

    def test_token_is_generated_once_private_narrow_and_never_rotated(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / 'secrets').mkdir(mode=0o700)
            first = release.prepare_analytics(root)
            self.assertEqual(first, release.prepare_analytics(root))
            self.assertRegex(first, r'^ANALYTICS_TOKEN=[a-f0-9]{64}\n$')
            self.assertEqual(0o600, (root / 'secrets/analytics.env').stat().st_mode & 0o777)
            self.assertEqual(0o700, (root / 'analytics').stat().st_mode & 0o777)
            self.assertEqual([], list((root / 'analytics').iterdir()))
            (root / 'secrets/analytics.env').write_text(first + 'JWT_SECRET=must-not-leak\n')
            with self.assertRaises(RuntimeError): release.prepare_analytics(root)

    def test_data_and_token_symlinks_or_public_permissions_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            (root / 'secrets').mkdir(mode=0o700)
            outside = root / 'outside'; outside.mkdir()
            (root / 'analytics').symlink_to(outside)
            with self.assertRaises(RuntimeError): release.prepare_analytics(root)
            (root / 'analytics').unlink()
            (root / 'analytics').mkdir(mode=0o755)
            with self.assertRaises(RuntimeError): release.prepare_analytics(root)
            (root / 'analytics').chmod(0o700)
            (root / 'secrets/analytics.env').symlink_to(root / 'missing')
            with self.assertRaises(ValueError): release.prepare_analytics(root)

    def test_capable_release_freezes_private_token_without_build_arguments_or_vault_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            source = root / 'source'; source.mkdir()
            capable_source(source)
            (root / 'secrets').mkdir(mode=0o700)
            values = {'APP_ENV': 'production', 'APP_RUNTIME': 'toolbox', 'DEPLOYMENT_ROLE': 'parallel',
                      'APP_URL': 'https://www.philipithomas.com',
                      'DATABASE_URL': 'postgres://bully_pulpit:fixture@postgres/bully_pulpit',
                      'WORKFLOW_POSTGRES_URL': 'postgres://bully_workflow:fixture@postgres/bully_pulpit_workflow',
                      'JWT_SECRET': 'private-jwt-fixture', 'BELL_IDENTITY_SECRET': 'fixture', 'CRON_SECRET': 'fixture',
                      'TURNSTILE_SECRET_KEY': 'fixture', 'NEXT_PUBLIC_TURNSTILE_SITE_KEY': 'public-fixture',
                      'AWS_ACCESS_KEY_ID': 'fixture', 'AWS_SECRET_ACCESS_KEY': 'fixture', 'AWS_REGION': 'us-east-2',
                      'OPENAI_API_KEY': 'fixture', 'PHOTO_ARCHIVE_S3_BUCKET': 'fixture', 'PHOTO_ARCHIVE_S3_REGION': 'us-east-2',
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
            pending = json.loads((root / 'pending-deployment.json').read_text())
            self.assertEqual(1, pending['analytics_protocol'])
            self.assertEqual(['app', 'proxy', 'scheduler', 'analytics'], pending['compose']['x-toolbox-required-services'])
            self.assertEqual(2, len(pending['compose']['include'][0]['path']))
            infra = Path(pending['infrastructure'])
            frozen = (infra / 'analytics.env').read_text()
            self.assertEqual(frozen, (root / 'secrets/analytics.env').read_text())
            self.assertEqual(0o600, (infra / 'analytics.env').stat().st_mode & 0o777)
            token = release.read_env(infra / 'analytics.env')['ANALYTICS_TOKEN']
            self.assertNotIn(token, repr(calls))
            self.assertNotIn(token, json.dumps(pending))
            self.assertNotIn('JWT_SECRET', frozen)
            self.assertFalse((root / 'deployment.json').exists())
            release.record(root)
            self.assertEqual(1, json.loads((root / 'deployment.json').read_text())['analytics_protocol'])


if __name__ == '__main__': unittest.main()

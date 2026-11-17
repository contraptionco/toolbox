"""Hermetic release-guard tests: no Docker, network, credentials or real paths."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location('bully_release', Path(__file__).with_name('deploy.py'))
release = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(release)


class ReleaseGuardTest(unittest.TestCase):
    def test_parallel_release_lock_refuses_a_second_writer(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with release.acquire_release_lock(root):
                with self.assertRaisesRegex(RuntimeError, 'already in progress'):
                    release.acquire_release_lock(root)
            with release.acquire_release_lock(root):
                pass

    def test_only_exact_remote_commit_can_release(self):
        sha = 'a' * 40
        with patch.object(release, 'command', return_value=f'{sha}\trefs/heads/feature\n'):
            release.verified_ref('known-remote', 'feature', sha)
            with self.assertRaisesRegex(RuntimeError, 'pushed branch head'):
                release.verified_ref('known-remote', 'feature', 'b' * 40)

    def test_invalid_input_does_not_call_git(self):
        with patch.object(release, 'command') as command:
            for branch, sha in [('main', 'short'), ('--upload-pack=bad', 'a' * 40), ('a/../b', 'a' * 40)]:
                with self.assertRaises(RuntimeError):
                    release.verified_ref('remote', branch, sha)
            command.assert_not_called()

    def test_world_readable_secrets_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'runtime.env'
            path.write_text('EXAMPLE=fixture\n')
            path.chmod(0o644)
            with self.assertRaisesRegex(RuntimeError, '0600'):
                release.read_env(path)
            path.chmod(0o600)
            self.assertEqual({'EXAMPLE': 'fixture'}, release.read_env(path))


if __name__ == '__main__':
    unittest.main()

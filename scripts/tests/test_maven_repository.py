"""Check cache selection with real filesystem permissions, without Maven or services."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[1] / "lib" / "maven-repository.sh"


class MavenRepositoryTest(unittest.TestCase):
    def select(self, root, explicit=None):
        env = dict(os.environ, WORKSPACE=str(root))
        env.pop("OPENREC_MAVEN_REPO", None)
        if explicit is not None:
            env["OPENREC_MAVEN_REPO"] = str(explicit)
        return subprocess.run(
            ["bash", "-eu", "-c", 'source "$1"; openrec_setup_maven_repository; '
             'printf "%s" "${OPENREC_MAVEN_REPO:-}"', "test", str(HELPER)],
            env=env, capture_output=True, text=True)

    def test_no_workspace_cache_preserves_maven_default(self):
        with tempfile.TemporaryDirectory() as directory:
            result = self.select(Path(directory))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "")

    def test_writable_shared_cache_is_reused(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / ".cache/maven-repository"
            cache.mkdir(parents=True)
            result = self.select(root)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, str(cache))

    def test_explicit_cache_is_created(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / "custom cache"
            result = self.select(root, cache)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, str(cache))
            self.assertTrue(cache.is_dir())

    @unittest.skipIf(os.geteuid() == 0, "root bypasses file write permissions")
    def test_readonly_nested_artifacts_fall_back_but_explicit_cache_fails(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            cache = root / ".cache/maven-repository"
            nested = cache / "io/prometheus"
            nested.mkdir(parents=True)
            nested.chmod(0o555)
            try:
                result = self.select(root)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, str(root / f".cache/maven-repository-{os.getuid()}"))
                self.assertIn("inaccessible", result.stderr)
                result = self.select(root, cache)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("not writable", result.stderr)
            finally:
                nested.chmod(0o755)

"""Regression coverage for relocated workflow entry points and release packaging."""
import hashlib
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKSPACE = ROOT.parent


class DistributionPathsTest(unittest.TestCase):
    def test_workflow_local_entry_points_resolve_from_working_directory(self):
        references = 0
        for workflow in (ROOT / ".github/workflows").glob("*.yml"):
            # These workflows declare working-directory before run in each step.
            # Inspect local source entry points without executing workflow commands.
            cwd = ROOT
            for line in workflow.read_text().splitlines():
                if line.lstrip().startswith("- name:"):
                    cwd = ROOT
                match = re.match(r"\s*working-directory:\s*(\S+)", line)
                if match:
                    value = match.group(1)
                    self.assertTrue(value == "openrec" or value.startswith("openrec/"), value)
                    cwd = WORKSPACE if value == "openrec" else WORKSPACE / value.removeprefix("openrec/")
                    self.assertTrue(cwd.is_dir(), str(cwd))
                for entry in re.findall(r"(?:\./)?(?:scripts|openrec|bigdata-platform)/[\w/.-]+\.(?:sh|py|yml)\b", line):
                    path = cwd / entry
                    self.assertTrue(path.is_file(), f"{workflow.name}: {path}")
                    if path.suffix == ".sh":
                        self.assertTrue(os.access(path, os.X_OK), str(path))
                    references += 1
            if workflow.name != "release.yml":
                self.assertIn("path: openrec/openrec", workflow.read_text())
        self.assertGreaterEqual(references, 10)

    def test_release_script_packages_relocated_files_from_its_own_root(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "workspace" / "openrec"
            root.mkdir(parents=True)
            files = ["VERSION", "release/openrec.json", "scripts/release/package-release.sh",
                     "scripts/release/validate_distribution.py", "standalone/start.sh", "cluster/start.sh",
                     "init/tools/ensure-model-artifacts.sh"]
            for name in files:
                target = root / name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(ROOT / name, target)
            (root / "README.md").write_text("# Packaging fixture\n")
            def git(*args):
                subprocess.run(["git", "-C", str(root), *args], check=True,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            git("init", "-q")
            git("add", ".")
            git("-c", "user.name=Test", "-c", "user.email=test@invalid", "-c", "commit.gpgsign=false",
                "commit", "-qm", "packaging fixture")
            result = subprocess.run(["bash", str(root / "scripts/release/package-release.sh")],
                                    cwd=temporary, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
            version = (root / "VERSION").read_text().strip()
            archive = root / "dist" / f"openrec-{version}.tar.gz"
            checksum = root / "dist" / f"openrec-{version}.sha256"
            self.assertEqual(checksum.read_text().split()[0], hashlib.sha256(archive.read_bytes()).hexdigest())
            with tarfile.open(archive) as bundle:
                names = set(bundle.getnames())
                for name in files:
                    self.assertIn(f"openrec-{version}/{name}", names)
                self.assertFalse(any("example_cluster" in name or "example_standalone" in name for name in names))

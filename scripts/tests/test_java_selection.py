"""Verify that the transitional build never runs old consumers with the server JDK."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class JavaSelectionTest(unittest.TestCase):
    def test_server_maven_uses_21_without_changing_consumer_java(self):
        helper = Path(__file__).resolve().parents[1] / "lib" / "java.sh"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for major in (8, 21):
                binary = root / str(major) / "bin"
                binary.mkdir(parents=True)
                version = "1.8.0_462" if major == 8 else "21.0.12"
                for name in ("java", "javac"):
                    path = binary / name
                    path.write_text(f'#!/bin/sh\necho \'openjdk version "{version}"\' >&2\n')
                    path.chmod(0o755)
            maven = root / "mvn"
            maven.write_text('#!/bin/sh\nprintf "%s\\n" "$JAVA_HOME"\n')
            maven.chmod(0o755)
            env = dict(os.environ, WORKSPACE=directory,
                       OPENREC_JAVA8_HOME=str(root / "8"),
                       OPENREC_JAVA21_HOME=str(root / "21"), MVN=str(maven))
            result = subprocess.run(
                ["bash", "-eu", "-c", 'source "$1"; openrec_setup_java; '
                 'openrec_maven21; printf "%s\\n" "$JAVA_HOME" "$JAVA"', "bash", str(helper)],
                env=env, capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.splitlines(),
                             [str(root / "21"), str(root / "8"), str(root / "8/bin/java")])

    def test_wrong_jdk_major_is_rejected(self):
        helper = Path(__file__).resolve().parents[1] / "lib" / "java.sh"
        with tempfile.TemporaryDirectory() as directory:
            binary = Path(directory) / "bin"
            binary.mkdir()
            for name in ("java", "javac"):
                path = binary / name
                path.write_text('#!/bin/sh\necho \'openjdk version "17.0.1"\' >&2\n')
                path.chmod(0o755)
            result = subprocess.run(
                ["bash", "-c", 'source "$1"; openrec_find_jdk 21 "$2"',
                 "bash", str(helper), directory], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("JDK 21 required", result.stderr)

"""Verify every source build and runtime selects the same Java 21 installation."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class JavaSelectionTest(unittest.TestCase):
    def test_only_java21_is_required_for_maven_and_runtime(self):
        helper = Path(__file__).resolve().parents[1] / "lib" / "java.sh"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            binary = root / "21" / "bin"
            binary.mkdir(parents=True)
            for name in ("java", "javac"):
                path = binary / name
                path.write_text('#!/bin/sh\necho \'openjdk version "21.0.12"\' >&2\n')
                path.chmod(0o755)
            maven = root / "mvn"
            maven.write_text('#!/bin/sh\nprintf "%s\\n" "$JAVA_HOME"\n')
            maven.chmod(0o755)
            for selector in ("OPENREC_JAVA21_HOME", "JAVA_HOME", "JAVA_HOME_21_X64"):
                with self.subTest(selector=selector):
                    env = dict(os.environ, WORKSPACE=directory, MVN=str(maven))
                    for key in ("OPENREC_JAVA21_HOME", "JAVA_HOME", "JAVA_HOME_21_X64",
                                "OPENREC_JAVA8_HOME", "JAVA_HOME_8_X64"):
                        env.pop(key, None)
                    env[selector] = str(root / "21")
                    result = subprocess.run(
                        ["bash", "-eu", "-c", 'source "$1"; openrec_setup_java; '
                         '\"$MVN\"; printf "%s\\n" "$JAVA_HOME" "$JAVA"', "bash", str(helper)],
                        env=env, capture_output=True, text=True, check=True)
                    self.assertEqual(result.stdout.splitlines(),
                                     [str(root / "21"), str(root / "21"), str(root / "21/bin/java")])

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

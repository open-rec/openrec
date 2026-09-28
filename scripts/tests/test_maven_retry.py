"""Exercise retry decisions without Maven, network access, or retry delays."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


LIBRARY = Path(__file__).resolve().parents[1] / 'lib' / 'maven.sh'


class MavenRetryTest(unittest.TestCase):
    def run_case(self, failure, failures, expected_calls, expected_status):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            maven = root / 'mvn'
            maven.write_text('''#!/usr/bin/env bash
count=0
[[ ! -f "$COUNT_FILE" ]] || read -r count < "$COUNT_FILE"
count=$((count + 1))
echo "$count" > "$COUNT_FILE"
printf '%s\\n' "$@" > "$ARGS_FILE"
if (( count <= FAILURES )); then
  echo "$FAILURE" >&2
  exit 7
fi
''')
            maven.chmod(0o755)
            sleep = root / 'sleep'
            sleep.write_text('#!/usr/bin/env bash\nexit 0\n')
            sleep.chmod(0o755)
            env = dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}',
                       WORKSPACE=directory, COUNT_FILE=str(root / 'count'),
                       ARGS_FILE=str(root / 'args'), FAILURE=failure,
                       FAILURES=str(failures))
            result = subprocess.run(
                ['bash', '-c', 'set -Eeuo pipefail; source "$1"; run_maven test "-Dname=two words"',
                 'test', str(LIBRARY)], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, expected_status, result.stdout + result.stderr)
            self.assertEqual(int((root / 'count').read_text()), expected_calls)
            args = (root / 'args').read_text().splitlines()
            self.assertIn('-U', args)
            self.assertIn('-Dname=two words', args)
            if failures:
                self.assertIn(failure, result.stdout)

    def test_success(self):
        self.run_case('', 0, 1, 0)

    def test_connection_reset_recovers(self):
        self.run_case('Could not transfer artifact io.swagger:swagger-annotations:pom:1.5.20: Connection reset', 1, 2, 0)

    def test_persistent_transfer_failure(self):
        self.run_case('Could not transfer artifact: Connection reset', 4, 3, 7)

    def test_compile_failure_is_not_retried(self):
        self.run_case('COMPILATION ERROR', 4, 1, 7)

    def test_test_failure_is_not_retried(self):
        self.run_case('There are test failures', 4, 1, 7)

    def test_missing_artifact_is_not_retried(self):
        self.run_case('Could not find artifact example:missing:jar:1.0', 4, 1, 7)

    def test_cached_transfer_failure_recovers(self):
        self.run_case('failure was cached in the local repository and resolution is not reattempted', 1, 2, 0)


if __name__ == '__main__':
    unittest.main()

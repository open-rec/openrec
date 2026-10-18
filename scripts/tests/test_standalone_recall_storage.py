"""Startup must validate i2i candidates in the serving Elasticsearch alias."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


STARTUP = Path(__file__).resolve().parents[2] / "standalone/init.sh"


class StandaloneRecallStorageTest(unittest.TestCase):
    def run_check(self, response, fail=False):
        source = STARTUP.read_text()
        block = source[source.index('i2i_query='):source.index('docker exec redis redis-cli ZSCORE')]
        with tempfile.TemporaryDirectory() as directory:
            docker = Path(directory) / "docker"
            docker.write_text('''#!/usr/bin/env python3
import json, os, sys
args = sys.argv[1:]
assert args[:3] == ['exec', 'elasticsearch', 'curl'], args
assert 'https://localhost:9200/openrec-recall-item-cf-i2i-active/_count' in args
query = json.loads(args[args.index('--data') + 1])
assert query == {'query': {'bool': {'filter': [
    {'term': {'scene': 'scene_0'}}, {'term': {'left_item': 'test-item'}}
]}}}, query
if os.environ['FAIL'] == 'true':
    sys.exit(22)
print(os.environ['RESPONSE'])
''')
            docker.chmod(0o755)
            env = dict(os.environ, PATH=directory + ':' + os.environ['PATH'],
                       RESPONSE=response, FAIL=str(fail).lower())
            return subprocess.run(['bash', '-eu', '-o', 'pipefail', '-c',
                                   'smoke_item=test-item; die() { echo "$*" >&2; exit 1; };\n' + block],
                                  env=env, text=True, capture_output=True)

    def test_candidates_in_elasticsearch_pass_without_redis_recall_keys(self):
        result = self.run_check('{"count": 3}')
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_empty_candidates_fail(self):
        result = self.run_check('{"count": 0}')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('no recall data in the active Elasticsearch index', result.stderr)

    def test_unavailable_or_invalid_response_fails(self):
        for response, fail in [('', True), ('invalid', False), ('{}', False)]:
            with self.subTest(response=response, fail=fail):
                result = self.run_check(response, fail)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('could not query the active Elasticsearch', result.stderr)

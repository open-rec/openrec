"""Exercise startup retries under errexit, including curl's HTTP error exit status."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


HELPER = Path(__file__).resolve().parents[1] / "lib" / "standalone-recommendation.sh"
CHANNELS = ["item_cf_i2i", "content_i2i", "user_cf_u2i", "item_seq_emb", "sparse", "hot"]


class StandaloneRecommendationTest(unittest.TestCase):
    def run_case(self, failures, channels=CHANNELS, rank=False, status="SUCCESS", candidate_count=1):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            curl = root / "curl"
            curl.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
p = pathlib.Path(os.environ["COUNT_FILE"])
n = int(p.read_text()) + 1 if p.exists() else 1
p.write_text(str(n))
if n in json.loads(os.environ["FAILURES"]):
    print('{"status":500,"error":"graph produced no result"}')
    print('500')
    sys.exit(0)
print(os.environ["RESPONSE"])
print('200')
''')
            curl.chmod(0o755)
            for name in ("docker", "sleep"):
                executable = root / name
                executable.write_text("#!/bin/sh\nexit 0\n")
                executable.chmod(0o755)
            results = [{"id": "final-item", "recallFrom": "hot"}]
            diagnostics = [{"channel": channel, "status": status, "candidateCount": candidate_count}
                           for channel in channels]
            if rank:
                results[0]["rankScore"] = 0.5
            env = dict(os.environ, PATH=f'{root}:{os.environ["PATH"]}', LOG_DIR=directory,
                       COUNT_FILE=str(root / "count"), FAILURES=json.dumps(failures),
                       RESPONSE=json.dumps({"code": 200, "status": True, "data": {"results": results, "recallDiagnostics": diagnostics}}))
            result = subprocess.run(
                ["bash", "-eu", "-o", "pipefail", "-c",
                 'smoke_user=test; note() { :; }; die() { echo "$*" >&2; exit 1; }; source "$1"',
                 "test", str(HELPER)], env=env, capture_output=True, text=True)
            return result, int((root / "count").read_text()), (root / "recommendation.log").read_text()

    def test_transient_http_500_during_smoke_recovers(self):
        result, count, log = self.run_case([1])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(count, 2)
        self.assertIn("graph produced no result", log)

    def test_persistent_http_500_fails_after_bounded_retries(self):
        result, count, log = self.run_case(list(range(1, 12)))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(count, 6)
        self.assertIn("smoke 6", log)

    def test_missing_channel_is_still_rejected(self):
        result, count, _ = self.run_case([], CHANNELS[:-1])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(count, 6)
        self.assertIn("missing channels: hot", result.stderr)

    def test_rank_scores_are_still_rejected(self):
        result, _, _ = self.run_case([], rank=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("unexpectedly used rank scores", result.stderr)

    def test_final_result_need_not_cover_all_successful_recall_channels(self):
        result, count, _ = self.run_case([])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(count, 1)

    def test_successful_but_empty_recall_is_rejected(self):
        result, _, _ = self.run_case([], candidate_count=0)
        self.assertNotEqual(result.returncode, 0)

    def test_timed_out_recall_is_rejected_even_with_positive_count(self):
        result, _, _ = self.run_case([], status="TIMED_OUT")
        self.assertNotEqual(result.returncode, 0)

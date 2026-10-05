"""Verify the startup client respects readiness HTTP status and bounded failure."""
import importlib.util
import io
import json
from pathlib import Path
import unittest
import urllib.error
from unittest.mock import Mock, patch


SPEC = importlib.util.spec_from_file_location(
    "wait_ready", Path(__file__).resolve().parents[1] / "wait-recommendation-ready.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ReadinessClientTest(unittest.TestCase):
    def test_503_ready_response_is_read_as_progress(self):
        opener = Mock()
        opener.open.side_effect = urllib.error.HTTPError(
            "http://server/ready", 503, "warming", {}, io.BytesIO(b'{"ready":false,"state":"VERIFYING"}'))
        self.assertEqual(MODULE.request(opener, "http://server/ready")["state"], "VERIFYING")

    def test_unauthorized_warmup_is_not_swallowed(self):
        opener = Mock()
        opener.open.side_effect = urllib.error.HTTPError("http://server/internal/recommendation-warmup", 401,
                                                         "unauthorized", {}, io.BytesIO(b"{}"))
        with self.assertRaises(urllib.error.HTTPError):
            MODULE.request(opener, "http://server/internal/recommendation-warmup", [{}])

    def test_waits_through_verification_then_returns(self):
        with patch("sys.argv", ["wait", "--user-id", "u"]), patch.object(MODULE, "request") as request, \
                patch.object(MODULE.time, "sleep"):
            request.side_effect = [{"state": "WARMING"}, {"state": "VERIFYING", "ready": False},
                                   {"state": "READY", "ready": True}]
            MODULE.main()
            self.assertEqual(request.call_count, 3)
            self.assertEqual(request.call_args_list[0].args[2][0]["userId"], "u")

    def test_failed_warmup_stops_startup(self):
        with patch("sys.argv", ["wait", "--user-id", "u"]), patch.object(MODULE, "request") as request:
            request.side_effect = [{"state": "WARMING"}, {"state": "FAILED", "ready": False}]
            with self.assertRaisesRegex(RuntimeError, "warmup failed"):
                MODULE.main()

import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location(
    "functional_graph", Path(__file__).resolve().parents[1] / "configure-functional-graph.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class FunctionalGraphTest(unittest.TestCase):
    def test_only_raises_short_deadlines(self):
        graph = {
            "nodes": [
                {"name": "recall", "timeout": 50, "open": True, "content": {"size": 100}},
                {"name": "rank", "timeout": 2000, "failurePolicy": "FAIL_GRAPH"},
            ],
            "edges": [{"from": "recall", "to": "rank"}],
        }
        updated = MODULE.with_timeout_floor(graph, 1000)
        self.assertEqual(1000, updated["nodes"][0]["timeout"])
        self.assertEqual(2000, updated["nodes"][1]["timeout"])
        self.assertEqual(graph["edges"], updated["edges"])
        self.assertEqual(graph["nodes"][0]["content"], updated["nodes"][0]["content"])
        self.assertEqual("FAIL_GRAPH", updated["nodes"][1]["failurePolicy"])
        self.assertEqual(50, graph["nodes"][0]["timeout"])

    def test_rejects_nonpositive_timeout(self):
        for value in (0, -1):
            with self.assertRaises(ValueError):
                MODULE.with_timeout_floor({"nodes": []}, value)

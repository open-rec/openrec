"""Test the actual DAG validator without requiring an Airflow installation."""
import ast
import csv
import copy
import os
from pathlib import Path
import unittest


SOURCE = Path(__file__).resolve().parents[2] / "example_cluster/airflow/dags/openrec_cluster_bootstrap.py"
tree = ast.parse(SOURCE.read_text())
selected = [node for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name in {"_validate_recall_channels", "_recommendation_request"}
            or isinstance(node, ast.Assign) and any(
                isinstance(target, ast.Name) and target.id in {"REQUIRED_RECALL_CHANNELS", "SMOKE_TRIGGER_ITEMS", "REC_SERVER"}
                for target in node.targets)]
namespace = {"_recall_counts": lambda: {"total": 100}}
exec(compile(ast.Module(body=selected, type_ignores=[]), str(SOURCE), "exec"), namespace)


class ClusterRecallValidationTest(unittest.TestCase):
    def test_warmup_covers_item_and_user_routes(self):
        function = copy.deepcopy(next(node for node in ast.walk(tree)
                                      if isinstance(node, ast.FunctionDef)
                                      and node.name == "recommendation_warmup"))
        function.decorator_list = []
        calls = []

        def request(url, **kwargs):
            calls.append(kwargs)
            return {"ready": True}

        scope = {**namespace, "os": os, "_request": request}
        exec(compile(ast.Module(body=[function], type_ignores=[]), str(SOURCE), "exec"), scope)
        scope["recommendation_warmup"]()
        self.assertEqual({sample["targetType"] for sample in calls[0]["body"]}, {"item", "user"})

    def payload(self):
        return {"results": [{"id": "selected", "recallFrom": "hot"}],
                "recallDiagnostics": [{"channel": channel, "status": "SUCCESS", "candidateCount": 5}
                                      for channel in namespace["REQUIRED_RECALL_CHANNELS"]]}

    def test_smoke_uses_explicit_triggers_independent_of_persisted_clicks(self):
        captured = {}
        namespace["_request"] = lambda url, **kwargs: captured.update(kwargs)
        namespace["_recommendation_request"]("test")
        triggers = captured["body"]["body"]["itemIds"]
        self.assertTrue(triggers)

    def test_smoke_triggers_exist_in_bundled_recall_data(self):
        triggers = namespace["SMOKE_TRIGGER_ITEMS"]
        root = SOURCE.parents[4] / "model" / "recall" / "item"
        if not root.is_dir():
            self.skipTest("requires the model repository with bundled recall fixtures")
        for table, key in [("item_cf_i2i", "left_item"),
                           ("content_i2i", "left_item"), ("item_seq_emb", "item")]:
            with (root / (table + ".csv")).open() as stream:
                ids = {row[key] for row in csv.DictReader(stream) if row["scene"] == "scene_0"}
            self.assertTrue(set(triggers) <= ids, table)

    def test_healthy_recall_passes_even_if_top_n_does_not_cover_channels(self):
        namespace["_validate_recall_channels"](self.payload())

    def test_failed_timed_out_disabled_empty_or_missing_recall_still_fails(self):
        for status, count in [("FAILED", 5), ("TIMED_OUT", 5), ("DISABLED", 0), ("SUCCESS", 0)]:
            with self.subTest(status=status, count=count):
                data = self.payload()
                data["recallDiagnostics"][0].update(status=status, candidateCount=count)
                with self.assertRaisesRegex(RuntimeError, "recall nodes failed or returned no candidates"):
                    namespace["_validate_recall_channels"](data)
        data = self.payload()
        del data["recallDiagnostics"]
        with self.assertRaises(RuntimeError):
            namespace["_validate_recall_channels"](data)

"""Test the actual DAG validator without requiring an Airflow installation."""
import ast
from pathlib import Path
import unittest


SOURCE = Path(__file__).resolve().parents[2] / "example_cluster/airflow/dags/openrec_cluster_bootstrap.py"
tree = ast.parse(SOURCE.read_text())
selected = [node for node in tree.body
            if isinstance(node, ast.FunctionDef) and node.name == "_validate_recall_channels"
            or isinstance(node, ast.Assign) and any(
                isinstance(target, ast.Name) and target.id == "REQUIRED_RECALL_CHANNELS"
                for target in node.targets)]
namespace = {"_recall_counts": lambda: {"total": 100}}
exec(compile(ast.Module(body=selected, type_ignores=[]), str(SOURCE), "exec"), namespace)


class ClusterRecallValidationTest(unittest.TestCase):
    def payload(self):
        return {"results": [{"id": "selected", "recallFrom": "hot"}],
                "recallDiagnostics": [{"channel": channel, "status": "SUCCESS", "candidateCount": 5}
                                      for channel in namespace["REQUIRED_RECALL_CHANNELS"]]}

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

#!/usr/bin/env python3
"""
Offline distribution check for the training-only DAG and feature transport.
"""

import ast
import copy
import io
import json
from datetime import datetime, timezone
from pathlib import Path
import re
import sys
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT.parent / "rec-algorithm"))


def verify_release_catalog_check():
    """Exercise the actual E2E assertion with current and mismatched catalogs."""
    from algorithm.feature.feature_catalog import FeatureCatalog

    script = ROOT / "example_cluster/verify_rank_model.sh"
    match = re.search(
        r"python3 -c '([^']+)'\s+\"\$\{VERSION_ONE\}\"", script.read_text()
    )
    assert match, "model release acceptance check was not found"
    check = compile(match.group(1), str(script), "exec")
    catalog = FeatureCatalog.load()
    identity = {"catalog_version": catalog.version, "catalog_sha256": catalog.sha256}
    releases = []
    for version, model_type in (("one", "lr"), ("two", "fm")):
        selection = {"user": ["user.age"], "candidate": ["item.weight"]}
        if model_type == "fm":
            selection["user"].append("user.gender")
            selection["candidate"].append("item.category")
        releases.append({
            **identity, "version": version, "model_type": model_type,
            "scene": "global", "feature_set": f"ranking-{model_type}-v1",
            "feature_selection": selection, "gate": {"passed": True},
            "feature_sha256": "artifact-hash", "input_dim": 2,
            "label_observation_cutoff": 1, "feature_join": "per_sample_point_in_time",
            "metrics": {"samples": 10, "training_samples": 8,
                        "validation_samples": 2, "positive_rate": 0.5, "auc": 0.7},
        })
    listing = {"active_version": "two", "releases": releases}
    with tempfile.TemporaryDirectory(prefix="openrec-catalog-check-") as directory:
        path = Path(directory) / "catalog.json"
        path.write_text(json.dumps(identity))

        def run(value):
            with patch.object(sys, "argv", ["-c", "one", "two", str(path)]), \
                    patch.object(sys, "stdin", io.StringIO(json.dumps(value))):
                exec(check, {})

        run(listing)
        for field, wrong in (("catalog_version", catalog.version + 1),
                             ("catalog_sha256", "wrong-catalog")):
            mismatch = copy.deepcopy(listing)
            mismatch["releases"][0][field] = wrong
            try:
                run(mismatch)
            except AssertionError:
                continue
            raise AssertionError("release check accepted mismatched " + field)
    print("PASS: release acceptance checks current catalog version and hash")


def main():
    from jobs.spark.runner import rank_command

    dag_path = ROOT / "example_cluster/airflow/dags/openrec_rank_model.py"
    tree = ast.parse(dag_path.read_text())
    factory = next(
        node
        for node in tree.body
        if isinstance(node, ast.FunctionDef) and node.name == "rank_model"
    )
    tasks = [
        node for node in factory.body if isinstance(node, ast.FunctionDef)
    ]
    assert [node.name for node in tasks] == ["train"], (
        "training DAG must not publish"
    )
    train = tasks[0]
    train.decorator_list = []
    calls = []
    selection = {"user": ["user.age"], "candidate": ["item.weight"]}

    def request(url, payload):
        calls.append((url, payload))
        command = rank_command(payload)
        import json

        assert (
            json.loads(command[command.index("--feature-selection") + 1])
            == selection
        )
        assert command[command.index("--scene") + 1] == "global"
        return {
            "status": "success",
            "manifest": {"version": "test", "feature_selection": selection},
        }

    namespace = {
        "request": request,
        "datetime": datetime,
        "timezone": timezone,
    }
    exec(
        compile(
            ast.Module(body=[train], type_ignores=[]), str(dag_path), "exec"
        ),
        namespace,
    )
    from types import SimpleNamespace

    for index, model_type in enumerate(("lr", "fm", "lightgbm"), 1):
        config = {
            "business_date": "2026-09-16",
            "revision": "r%03d" % index,
            "scene": "global",
            "epochs": 1,
            "min_auc": 0,
            "model_type": model_type,
            "target_type": "item",
            "factor_dim": 8,
            "batch_size": 16,
            "validation_ratio": 0.2,
            "feature_selection": selection,
        }
        result = namespace["train"](
            dag_run=SimpleNamespace(conf=config), params=config
        )
        assert result["feature_selection"] == selection
        assert calls[-1][1]["model_type"] == model_type
    assert len(calls) == 3
    assert all(call[0].endswith("/jobs/rank/train") for call in calls)
    print(
        "PASS: training-only DAG preserves global scope and selected features "
        "through Spark runner for LR, FM, and LightGBM"
    )
    verify_release_catalog_check()


if __name__ == "__main__":
    main()

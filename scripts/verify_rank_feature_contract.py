#!/usr/bin/env python3
"""
Offline distribution check for the training-only DAG and feature transport.
"""

import ast
from datetime import datetime, timezone
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT.parent / "rec-algorithm"))


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


if __name__ == "__main__":
    main()

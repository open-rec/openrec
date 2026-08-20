"""Manually roll one recall alias back to a retained Elasticsearch index."""

import json
import urllib.error
import urllib.request
from datetime import datetime, timezone

from airflow.sdk import dag, task


@dag(
    dag_id="openrec_recall_rollback",
    schedule=None,
    start_date=datetime(2026, 1, 1, tzinfo=timezone.utc),
    catchup=False,
    max_active_runs=1,
    tags=["openrec", "recall", "rollback"],
    description="Atomically roll an active recall alias back without rerunning Spark",
)
def openrec_recall_rollback():
    @task
    def rollback(algorithm, target_index):
        body = {"algorithm": algorithm}
        if target_index:
            body["target_index"] = target_index
        request = urllib.request.Request(
            "http://rec-console:8095/api/recall/releases/rollback",
            data=json.dumps(body).encode(),
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                result = json.loads(response.read().decode())
        except urllib.error.HTTPError as error:
            raise RuntimeError(error.read().decode(errors="replace")) from error
        if not result.get("index") or not result.get("alias"):
            raise RuntimeError("rollback returned an invalid result: %s" % result)
        return result

    rollback(
        "{{ dag_run.conf.get('algorithm', '') if dag_run else '' }}",
        "{{ dag_run.conf.get('target_index', '') if dag_run else '' }}",
    )


openrec_recall_rollback()

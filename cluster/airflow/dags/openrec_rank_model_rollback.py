"""Roll rank-engine back to one retained evaluated model version."""

import json
import urllib.request
from datetime import datetime, timezone

from airflow.decorators import dag, task
from airflow.models.param import Param


@dag(dag_id="openrec_rank_model_rollback", schedule=None, catchup=False,
     start_date=datetime(2026, 1, 1, tzinfo=timezone.utc),
     params={"scene": Param("scene_0", type="string"),
             "target_version": Param("", type=["null", "string"])},
     tags=["openrec", "rank", "rollback"],
     description="Atomically reactivate a retained evaluated rank model")
def rollback_model():
    @task
    def rollback(**context):
        conf, params = context["dag_run"].conf or {}, context["params"]
        body = {"scene": conf.get("scene", params["scene"]),
                "target_version": conf.get("target_version") or params.get("target_version") or None}
        request = urllib.request.Request(
            "http://rec-console:8095/api/models/releases/rollback",
            data=json.dumps(body).encode(), headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(request, timeout=90) as response:
            result = json.loads(response.read())
        if not result.get("active_version"):
            raise RuntimeError("model rollback returned invalid result: %s" % result)
        return result

    rollback()


rollback_model()

"""Train, evaluate, publish, and verify a versioned rank model."""

import json
import urllib.request
from datetime import datetime, timezone

from airflow.decorators import dag, task
from airflow.models.param import Param


def request(url, body=None, timeout=7200):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data,
                                 headers={"Content-Type": "application/json"},
                                 method="POST" if data else "GET")
    with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.loads(response.read())


@dag(dag_id="openrec_rank_model", schedule=None, catchup=False,
     start_date=datetime(2026, 1, 1, tzinfo=timezone.utc),
     params={"business_date": Param("", type="string"), "revision": Param("r001", type="string"),
             "scene": Param("scene_0", type="string"), "epochs": Param(5, type="integer", minimum=1),
             "model_type": Param("lr", type="string", enum=["lr", "fm"]),
             "factor_dim": Param(8, type="integer", minimum=1, maximum=256),
             "min_auc": Param(0.0, type="number", minimum=0, maximum=1)},
     tags=["openrec", "rank", "model"],
     description="Cumulative Hive data -> train -> evaluate gate -> atomic rank publish")
def rank_model():
    @task
    def train(**context):
        conf = context["dag_run"].conf or {}
        params = context["params"]
        business_date = conf.get("business_date") or params["business_date"]
        if not business_date:
            business_date = datetime.now(timezone.utc).date().isoformat()
        payload = {key: conf.get(key, params[key]) for key in
                   ("revision", "scene", "epochs", "min_auc", "model_type", "factor_dim")}
        payload["date"] = business_date
        result = request("http://rec-algorithm-runner:8090/jobs/rank/train", payload)
        if result.get("status") != "success":
            raise RuntimeError("rank training failed: %s" % result)
        return result["manifest"]

    @task
    def publish(manifest):
        return request("http://rec-console:8095/api/models/releases/publish",
                       {"scene": manifest["scene"], "version": manifest["version"]})

    @task
    def verify(release):
        health = request("http://rank-engine:8123/health")
        active = release.get("active") or release.get("activated") or {}
        if health.get("status") != "success" or not health.get("data", {}).get("model_loaded"):
            raise RuntimeError("rank-engine did not load the published model: %s" % health)
        if release.get("active_version") != active.get("version"):
            raise RuntimeError("model registry active version mismatch: %s" % release)
        return {"version": release["active_version"], "ready": True}

    verify(publish(train()))


rank_model()

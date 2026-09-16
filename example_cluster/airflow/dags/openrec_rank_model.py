"""Train and evaluate an immutable rank model; deployment is manual."""

import json
import urllib.request
import urllib.error
from datetime import datetime, timezone

from airflow.decorators import dag, task
from airflow.models.param import Param


def request(url, body=None, timeout=7200):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST" if data else "GET",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise RuntimeError(
            "training runner rejected request: %s" % detail
        ) from error


@dag(
    dag_id="openrec_rank_model",
    schedule=None,
    catchup=False,
    start_date=datetime(2026, 1, 1, tzinfo=timezone.utc),
    params={
        "business_date": Param("", type="string"),
        "revision": Param("r001", type="string"),
        "scene": Param("global", type="string"),
        "epochs": Param(5, type="integer", minimum=1),
        "model_type": Param("lr", type="string", enum=["lr", "fm"]),
        "target_type": Param("item", type="string", enum=["item", "user"]),
        "feature_selection": Param(None, type=["null", "object"]),
        "batch_size": Param(256, type="integer", minimum=1),
        "validation_ratio": Param(
            0.2, type="number", exclusiveMinimum=0, exclusiveMaximum=1
        ),
        "factor_dim": Param(8, type="integer", minimum=1, maximum=256),
        "min_auc": Param(0.0, type="number", minimum=0, maximum=1),
    },
    tags=["openrec", "rank", "model"],
    description="Train and evaluate selected features from cumulative Hive",
)
def rank_model():
    @task
    def train(**context):
        conf = context["dag_run"].conf or {}
        params = context["params"]
        business_date = conf.get("business_date") or params["business_date"]
        if not business_date:
            business_date = datetime.now(timezone.utc).date().isoformat()
        payload = {
            key: conf.get(key, params[key])
            for key in (
                "revision",
                "scene",
                "epochs",
                "min_auc",
                "model_type",
                "target_type",
                "factor_dim",
                "feature_selection",
                "batch_size",
                "validation_ratio",
            )
        }
        payload["date"] = business_date
        result = request(
            "http://rec-algorithm-runner:8090/jobs/rank/train", payload
        )
        if result.get("status") != "success":
            raise RuntimeError("rank training failed: %s" % result)
        return result["manifest"]

    train()


rank_model()

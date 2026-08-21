"""Compute daily recall tables and atomically publish them to Elasticsearch."""

import json
import socket
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

from airflow.sdk import dag, task


RUNNER = "http://rec-algorithm-runner:8090"
REC_SERVER = "http://rec-server:13579"
REC_CONSOLE = "http://rec-console:8095"
DEFAULT_CONFIG = {
    "schedule": "0 2 * * *", "algorithms": ["hot", "new", "i2i"],
    "default_revision": "r001", "max_index_versions": 2,
    "retries": 1, "retry_delay_minutes": 5,
}
CONFIG_PATH = Path("/opt/openrec/dag-config/openrec_daily_recall.json")
try:
    CONFIG = {**DEFAULT_CONFIG, **json.loads(CONFIG_PATH.read_text())}
except (OSError, ValueError):
    CONFIG = DEFAULT_CONFIG


def _request(url, method="GET", body=None, headers=None, timeout=30, context=None):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    try:
        with urllib.request.urlopen(request, timeout=timeout, context=context) as response:
            payload = response.read().decode()
            return json.loads(payload) if payload else {}
    except urllib.error.HTTPError as error:
        payload = error.read().decode(errors="replace")
        raise RuntimeError("%s returned HTTP %s: %s" % (url, error.code, payload)) from error


def _redis_command(*parts):
    encoded = [str(part).encode() for part in parts]
    request = b"*%d\r\n" % len(encoded)
    request += b"".join(b"$%d\r\n%s\r\n" % (len(part), part) for part in encoded)
    with socket.create_connection(("redis", 6379), timeout=10) as connection:
        connection.sendall(request)
        response = connection.recv(4096)
    if not response or response.startswith(b"-"):
        raise RuntimeError("Redis command failed: %r" % response)
    return response


@dag(
    dag_id="openrec_daily_recall",
    schedule=CONFIG["schedule"],
    start_date=datetime(2026, 1, 1, tzinfo=timezone.utc),
    catchup=False,
    max_active_runs=1,
    tags=["openrec", "recall", "daily"],
    description="Spark daily recall tables -> versioned ES indexes -> atomic online switch",
)
def openrec_daily_recall():
    @task(retries=CONFIG["retries"],
          retry_delay=timedelta(minutes=CONFIG["retry_delay_minutes"]))
    def publish(algorithm, business_date, revision):
        response = _request(
            RUNNER + "/jobs/recall",
            method="POST",
            headers={"Content-Type": "application/json"},
            body={
                "algorithm": algorithm,
                "date": business_date,
                "revision": revision,
                "output_table": "openrec.recall_%s" % algorithm,
                "max_index_versions": CONFIG["max_index_versions"],
            },
            timeout=7500,
        )
        if response.get("status") != "success":
            raise RuntimeError("%s publish failed: %s" % (algorithm, response))
        return {"algorithm": algorithm, "date": business_date, "revision": revision}

    @task
    def verify_aliases_and_online_recall(business_date, revision, algorithms):
        version = business_date.replace("-", "")
        for algorithm in algorithms:
            expected = "openrec-recall-%s-%s-%s" % (algorithm, version, revision)
            release = _request("%s/api/recall/releases/%s" % (REC_CONSOLE, algorithm))
            active = release.get("active_indexes") or []
            if active != [expected]:
                raise RuntimeError("%s active indexes are %s, expected %s" %
                                   (algorithm, active, expected))

        exposure_key = "event:{user_0}:scene_0:expose"
        _redis_command("DEL", exposure_key)
        try:
            response = _request(
                REC_SERVER + "/api/recommend",
                method="POST",
                headers={"Content-Type": "application/json"},
                body={"requestId": "daily-recall-smoke", "body": {
                    "scene": "scene_0", "size": 50, "userId": "user_0",
                    "deviceId": "daily-recall-smoke", "type": "click", "debug": False,
                }},
            )
        finally:
            _redis_command("DEL", exposure_key)
        results = (response.get("data") or {}).get("results") or []
        channels = {result.get("recallFrom") for result in results}
        missing = set(algorithms) - channels
        if missing:
            raise RuntimeError("online recall misses channels %s: %s" % (sorted(missing), response))

    business_date = "{{ data_interval_start | ds }}"
    revision = "{{ dag_run.conf.get('revision', '%s') if dag_run else '%s' }}" % (
        CONFIG["default_revision"], CONFIG["default_revision"])
    published = [publish.override(task_id="publish_%s" % algorithm)(
        algorithm, business_date, revision) for algorithm in CONFIG["algorithms"]]
    verified = verify_aliases_and_online_recall(
        business_date, revision, CONFIG["algorithms"])
    for upstream, downstream in zip(published, published[1:]):
        upstream >> downstream
    published[-1] >> verified


openrec_daily_recall()

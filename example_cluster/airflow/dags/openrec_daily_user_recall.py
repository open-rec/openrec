"""Compute daily user-to-user recall tables and atomically publish them."""

import json
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from airflow.sdk import dag, task

RUNNER = "http://rec-algorithm-runner:8090"
REC_SERVER = "http://rec-server:13579"
REC_CONSOLE = "http://rec-console:8095"
DEFAULT_CONFIG = {
    "schedule": "30 2 * * *",
    "algorithms": ["user_cf_u2u", "content_u2u", "user_emb_u2u"],
    "default_revision": "r001", "max_index_versions": 2,
    "retries": 1, "retry_delay_minutes": 5,
}
SERVING_TABLES = {
    "user_cf_u2u": "user-cf-u2u", "content_u2u": "content-u2u",
    "user_emb_u2u": "user-als-emb",
}
CONFIG_PATH = Path("/opt/openrec/dag-config/openrec_daily_user_recall.json")
try:
    CONFIG = {**DEFAULT_CONFIG, **json.loads(CONFIG_PATH.read_text())}
except (OSError, ValueError):
    CONFIG = DEFAULT_CONFIG


def _request(url, method="GET", body=None, timeout=30):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method,
                                     headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            payload = response.read().decode()
            return json.loads(payload) if payload else {}
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        raise RuntimeError("%s returned HTTP %s: %s" % (url, error.code, detail)) from error


@dag(
    dag_id="openrec_daily_user_recall",
    schedule=CONFIG["schedule"],
    start_date=datetime(2026, 1, 1, tzinfo=timezone.utc),
    catchup=False,
    max_active_runs=1,
    tags=["openrec", "recall", "user", "daily"],
    description="Spark daily U2U tables -> versioned ES indexes -> atomic online switch",
)
def openrec_daily_user_recall():
    @task(retries=CONFIG["retries"],
          retry_delay=timedelta(minutes=CONFIG["retry_delay_minutes"]))
    def publish(algorithm, business_date, revision):
        response = _request(RUNNER + "/jobs/recall", method="POST", body={
            "algorithm": algorithm, "date": business_date, "revision": revision,
            "output_table": "openrec.recall_%s" % algorithm,
            "max_index_versions": CONFIG["max_index_versions"],
        }, timeout=7500)
        if response.get("status") != "success":
            raise RuntimeError("%s publish failed: %s" % (algorithm, response))
        return {"algorithm": algorithm, "date": business_date, "revision": revision}

    @task
    def verify_aliases_and_online_recall(business_date, revision, algorithms):
        version = business_date.replace("-", "")
        for algorithm in algorithms:
            table = SERVING_TABLES[algorithm]
            expected = "openrec-recall-%s-%s-%s" % (table, version, revision)
            release = _request("%s/api/recall/releases/%s" % (REC_CONSOLE, table))
            if (release.get("active_indexes") or []) != [expected]:
                raise RuntimeError("%s alias did not activate %s: %s" %
                                   (algorithm, expected, release))
        response = _request(REC_SERVER + "/api/recommend/user", method="POST", body={
            "requestId": "daily-user-recall-smoke", "body": {
                "scene": "scene_0", "size": 50, "userId": "user_0",
                "deviceId": "daily-user-recall-smoke", "debug": False,
            }})
        results = (response.get("data") or {}).get("results") or []
        channels = {result.get("recallFrom") for result in results}
        for result in results:
            channels.update((result.get("recallScores") or {}).keys())
        missing = set(algorithms) - channels
        if missing:
            raise RuntimeError("online user recall misses channels %s: %s" %
                               (sorted(missing), response))

    business_date = "{{ dag_run.conf['business_date'] if dag_run and dag_run.conf.get('business_date') else (data_interval_start | ds) }}"
    revision = "{{ dag_run.conf.get('revision', '%s') if dag_run else '%s' }}" % (
        CONFIG["default_revision"], CONFIG["default_revision"])
    published = [publish.override(task_id="publish_%s" % algorithm)(
        algorithm, business_date, revision) for algorithm in CONFIG["algorithms"]]
    verified = verify_aliases_and_online_recall(business_date, revision, CONFIG["algorithms"])
    for upstream, downstream in zip(published, published[1:]): upstream >> downstream
    published[-1] >> verified


openrec_daily_user_recall()

"""Validate the initialized OpenRec cluster recommendation path.

Container and long-running process lifecycle deliberately stays in start.sh. Tasks here only use
the services' network protocols, so the Airflow scheduler needs no Docker socket.
"""

import json
import socket
import ssl
import time
import urllib.request
import uuid
from datetime import datetime, timedelta, timezone

from airflow.sdk import dag, task, task_group


REC_SERVER = "rec-server"


def _request(url, method="GET", body=None, headers=None, context=None):
    data = json.dumps(body).encode() if body is not None else None
    request = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    with urllib.request.urlopen(request, timeout=15, context=context) as response:
        payload = response.read().decode()
        return json.loads(payload) if payload else {}


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


def _recommendation_request(request_id):
    return _request(
        "http://%s:13579/api/recommend" % REC_SERVER,
        method="POST",
        headers={"Content-Type": "application/json"},
        body={"requestId": request_id, "body": {
            "scene": "scene_0", "size": 12, "userId": "user_0",
            "deviceId": "airflow-cluster-smoke", "type": "click", "debug": False,
        }},
    )


def _recall_counts():
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    token = __import__("base64").b64encode(b"elastic:openrec-es-password").decode()
    counts = {}
    for name in ("openrec-recall-hot-active", "openrec-recall-new-active",
                 "openrec-recall-i2i-active", "scene_0-item-vector-index"):
        try:
            response = _request(
                "https://elasticsearch:9200/%s/_count" % name,
                headers={"Authorization": "Basic " + token}, context=context)
            counts[name] = response.get("count")
        except Exception as error:  # diagnostics must not hide the recommendation failure
            counts[name] = "error: %s" % error
    return counts


@dag(
    dag_id="openrec_cluster_bootstrap",
    schedule=None,
    start_date=datetime(2026, 1, 1, tzinfo=timezone.utc),
    catchup=False,
    tags=["openrec", "cluster", "bootstrap"],
    description="Verify platform, serving stores, online services, and the recommendation path",
)
def openrec_cluster_bootstrap():
    @task(retries=5, retry_delay=timedelta(seconds=10))
    def tcp_ready(name, host, port):
        with socket.create_connection((host, port), timeout=10):
            return "%s ready at %s:%s" % (name, host, port)

    @task(retries=5, retry_delay=timedelta(seconds=10))
    def spark_ready():
        status = _request("http://spark-master:8080/json/")
        alive = [worker for worker in status.get("workers", []) if worker.get("state") == "ALIVE"]
        if not alive:
            raise RuntimeError("Spark has no ALIVE workers")
        return {"alive_workers": len(alive)}

    @task(retries=5, retry_delay=timedelta(seconds=10))
    def redis_ready():
        if not _redis_command("PING").startswith(b"+PONG"):
            raise RuntimeError("Redis did not return PONG")

    @task(retries=5, retry_delay=timedelta(seconds=10))
    def elasticsearch_ready():
        context = ssl.create_default_context()
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE
        token = __import__("base64").b64encode(b"elastic:openrec-es-password").decode()
        status = _request(
            "https://elasticsearch:9200/_cluster/health?wait_for_status=yellow&timeout=10s",
            headers={"Authorization": "Basic " + token},
            context=context,
        )
        if status.get("status") not in ("yellow", "green"):
            raise RuntimeError("Elasticsearch is not ready: %s" % status)

    @task(retries=10, retry_delay=timedelta(seconds=10))
    def rank_engine_ready():
        _request("http://rank-engine:8123/health")

    @task(retries=10, retry_delay=timedelta(seconds=10))
    def rec_server_ready():
        _request("http://%s:13579/health" % REC_SERVER)

    @task(retries=10, retry_delay=timedelta(seconds=10))
    def rec_algorithm_runner_ready():
        _request("http://rec-algorithm-runner:8090/health")

    @task(retries=10, retry_delay=timedelta(seconds=10))
    def rec_console_ready():
        _request("http://rec-console:8095/health")

    @task
    def recommendation_warmup():
        # Warm rec-server's Elasticsearch TLS connection and client pools outside the latency
        # assertion. Empty cold-start responses are acceptable here; the next task validates the
        # recommendation path with the normal online node deadlines unchanged.
        exposure_key = "event:{user_0}:scene_0:expose"
        for attempt in range(5):
            _redis_command("DEL", exposure_key)
            try:
                response = _recommendation_request("airflow-cluster-warmup-%d" % attempt)
            finally:
                _redis_command("DEL", exposure_key)
            if (response.get("data") or response).get("results"):
                return
            time.sleep(1)

    @task(retries=6, retry_delay=timedelta(seconds=10))
    def recommendation_smoke():
        # Redis persists across cluster restarts. Previous smoke requests write exposure events for
        # user_0, which can eventually filter every sample candidate and make a healthy chain look
        # empty. Clear only this smoke user's exposure state before and after the request.
        exposure_key = "event:{user_0}:scene_0:expose"
        _redis_command("DEL", exposure_key)
        try:
            response = _recommendation_request("airflow-cluster-smoke")
        finally:
            _redis_command("DEL", exposure_key)
        if response.get("code") != 200 or response.get("status") is not True:
            raise RuntimeError("recommendation failed: %s" % response)
        # JsonRes wraps the business payload in `data`; retain top-level compatibility for older
        # rec-server responses used by some local deployments.
        data = response.get("data") or response
        if not data.get("results"):
            raise RuntimeError("recommendation returned no candidates: %s; recall counts: %s"
                               % (response, _recall_counts()))

    @task
    def ingestion_smoke():
        # A unique key proves this DAG run traversed rec-server -> Kafka -> data-processor -> Redis;
        # a fixed key could pass because a previous run had already written it.
        user_id = "airflow_cluster_smoke_user_%s" % uuid.uuid4().hex
        response = _request(
            "http://%s:13579/api/push/user" % REC_SERVER,
            method="POST",
            headers={"Content-Type": "application/json"},
            body={"requestId": "airflow-cluster-push-smoke", "body": {
                "cmd": "INSERT", "data": [{"id": user_id, "deviceId": "airflow-cluster-smoke",
                "name": "Airflow Cluster Smoke", "age": 0, "tags": []}],
            }},
        )
        if response.get("code") != 200 or response.get("status") is not True:
            raise RuntimeError("Kafka push failed: %s" % response)
        for _ in range(60):
            if _redis_command("EXISTS", "user:{%s}" % user_id).startswith(b":1"):
                return
            time.sleep(1)
        raise RuntimeError("Kafka message did not reach Redis through data-processor")

    @task_group(group_id="platform_preflight")
    def platform_preflight():
        checks = [
            tcp_ready.override(task_id="kafka")("Kafka", "kafka-1", 9092),
            tcp_ready.override(task_id="hive")("HiveServer2", "hiveserver2", 10000),
            tcp_ready.override(task_id="hdfs")("HDFS", "namenode", 8020),
            spark_ready(),
            redis_ready(),
            elasticsearch_ready(),
        ]
        # Keep references local so TaskFlow registers every check in this group.
        assert checks

    @task_group(group_id="online_services")
    def online_services():
        checks = [rank_engine_ready(), rec_server_ready(), rec_algorithm_runner_ready(),
                  rec_console_ready()]
        assert checks

    platform = platform_preflight()
    services = online_services()
    warmup = recommendation_warmup()
    recommend = recommendation_smoke()
    ingest = ingestion_smoke()
    platform >> services >> warmup >> recommend >> ingest


openrec_cluster_bootstrap()

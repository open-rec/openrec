#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATE_DIR="${SCRIPT_DIR}/.runtime"
LOG_DIR="${STATE_DIR}/logs"
BUILD_DIR="${STATE_DIR}/build"
SPARK_PID_FILE="/tmp/openrec-data-processor.pid"
SPARK_LOG_FILE="/tmp/openrec-data-processor.log"
LOCAL_MODE=false

usage() {
  cat <<EOF
Usage: ${0##*/} [--local]

  --local  Use the repository's mainland-China PyTorch and PyPI mirrors.
  -h, --help  Show this help.

Explicit RANK_BASE_IMAGE and RANK_PIP_INDEX_URL values take precedence over --local defaults.
EOF
}

while (($#)); do
  case "$1" in
    --local) LOCAL_MODE=true ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; echo "error: unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ "${LOCAL_MODE}" == true ]]; then
  : "${RANK_BASE_IMAGE:=mirrors-ssl.aliyuncs.com/pytorch/pytorch:2.8.0-cuda12.9-cudnn9-devel}"
  : "${RANK_PIP_INDEX_URL:=https://pypi.tuna.tsinghua.edu.cn/simple}"
  export RANK_BASE_IMAGE RANK_PIP_INDEX_URL
fi

note() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "error: $*" >&2; return 1; }

cleanup_on_error() {
  local status=$?
  trap - ERR
  echo "startup failed; stopping services started by the OpenRec examples" >&2
  "${SCRIPT_DIR}/stop.sh" || true
  exit "${status}"
}
trap cleanup_on_error ERR

if [[ "${LOCAL_MODE}" == true ]]; then
  note "Local mirrors enabled (rank base: ${RANK_BASE_IMAGE}, pip: ${RANK_PIP_INDEX_URL})"
fi

if command -v mvn >/dev/null 2>&1; then
  MVN="$(command -v mvn)"
else
  MVN="${WORKSPACE}/.tools/apache-maven-3.9.9/bin/mvn"
fi
if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/java" ]]; then
  JAVA="${JAVA_HOME}/bin/java"
elif command -v java >/dev/null 2>&1 && command -v javac >/dev/null 2>&1; then
  JAVA="$(command -v java)"
else
  export JAVA_HOME="${WORKSPACE}/.tools/jdk8u462-b08"
  export PATH="${JAVA_HOME}/bin:${PATH}"
  JAVA="${JAVA_HOME}/bin/java"
fi

[[ -x "${MVN}" ]] || die "Maven not found; install Maven 3.6+ or place it under .tools"
[[ -x "${JAVA}" ]] || die "Java not found; install JDK 8"
"${JAVA}" -version 2>&1 | head -n 1 | grep -Eq 'version "1\.8\.' || die "JDK 8 is required"
command -v docker >/dev/null 2>&1 || die "Docker is required"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v rsync >/dev/null 2>&1 || die "rsync is required"
command -v python3 >/dev/null 2>&1 || die "Python 3 is required"

MVN_ARGS=()
if [[ -d "${WORKSPACE}/.cache/maven-repository" ]]; then
  MVN_ARGS+=("-Dmaven.repo.local=${WORKSPACE}/.cache/maven-repository")
fi

mkdir -p "${LOG_DIR}"
pid_file="${STATE_DIR}/web.pid"
if [[ -f "${pid_file}" ]]; then
  pid="$(cat "${pid_file}")"
  if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
    die "cluster applications are already running; use ${SCRIPT_DIR}/stop.sh first"
  fi
  rm -f "${pid_file}"
fi

for required_port in 13579 12345 8123 8091 8095; do
  if (echo >/dev/tcp/127.0.0.1/"${required_port}") >/dev/null 2>&1; then
    die "required port ${required_port} is occupied; run ${SCRIPT_DIR}/stop.sh and retry"
  fi
done

wait_for_url() {
  local name="$1" url="$2" attempts="${3:-90}" i
  for ((i = 1; i <= attempts; i++)); do
    if curl --noproxy '*' -fsS "${url}" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  die "${name} did not become ready: ${url}"
}

wait_for_es_documents() {
  local name="$1" index="$2" attempts="${3:-30}" response="" i
  for ((i = 1; i <= attempts; i++)); do
    response="$(docker exec elasticsearch curl -fksS -u elastic:openrec-es-password \
      "https://localhost:9200/${index}/_count" 2>/dev/null || true)"
    if grep -Eq '"count"[[:space:]]*:[[:space:]]*[1-9][0-9]*' <<<"${response}"; then
      return 0
    fi
    sleep 1
  done
  die "${name} is missing or empty after ${attempts}s: ${response:-no response}"
}

port_in_use() { (echo >/dev/tcp/127.0.0.1/"$1") >/dev/null 2>&1; }

start_jar() {
  local name="$1" pid_file="$2" log_file="$3"
  shift 3
  nohup "$@" >"${log_file}" 2>&1 &
  local pid=$!
  echo "${pid}" >"${pid_file}"
  note "${name} started (pid ${pid}, log ${log_file})"
}

run_airflow_dag() {
  local dag_id="$1" run_id="$2" output state attempt loaded=false
  note "Waiting for Airflow DAG ${dag_id}"
  for attempt in {1..60}; do
    if docker exec airflow-api-server airflow dags list -o plain 2>/dev/null \
        | grep -Fq "${dag_id}"; then
      loaded=true
      break
    fi
    sleep 2
  done
  [[ "${loaded}" == true ]] || die "Airflow did not load DAG ${dag_id}"

  docker exec airflow-api-server airflow dags unpause -y "${dag_id}" >/dev/null
  docker exec airflow-api-server airflow dags trigger -r "${run_id}" "${dag_id}" >/dev/null
  note "Waiting for Airflow run ${run_id}"
  for attempt in {1..180}; do
    # Airflow 3 can emit log records around the selected output format. Scan the mixed stream for
    # the JSON value instead of assuming stdout is one clean JSON document.
    output="$(docker exec airflow-api-server airflow dags list-runs "${dag_id}" -o json 2>&1)"
    state="$(python3 -c '
import json, sys
payload = sys.stdin.read()
run_id = sys.argv[1]
decoder = json.JSONDecoder()
state = ""
for offset, char in enumerate(payload):
    if char not in "[{":
        continue
    try:
        value, _ = decoder.raw_decode(payload, offset)
    except json.JSONDecodeError:
        continue
    runs = value if isinstance(value, list) else [value]
    state = next((run.get("state", "") for run in runs
                  if isinstance(run, dict) and run.get("run_id") == run_id), "")
    if state:
        break
print(state)
' "${run_id}" <<<"${output}")"
    case "${state}" in
      success) return 0 ;;
      failed)
        echo "Airflow task states for failed run ${run_id}:" >&2
        docker exec airflow-api-server \
          airflow tasks states-for-dag-run "${dag_id}" "${run_id}" -o table >&2 || true
        echo "Airflow task log excerpts for failed run ${run_id}:" >&2
        docker logs --tail 1000 airflow-scheduler 2>&1 \
          | grep -F "run_id=${run_id}" >&2 || true
        die "Airflow DAG ${dag_id} failed (run ${run_id})"
        ;;
    esac
    sleep 2
  done
  die "Airflow DAG ${dag_id} timed out (run ${run_id}, last state ${state:-unknown})"
}

note "Building the cluster infrastructure images"
"${WORKSPACE}/bigdata-platform/platform.sh" build cluster

note "Starting the complete cluster platform"
export AIRFLOW_DAGS_PATH="${SCRIPT_DIR}/airflow/dags"
"${WORKSPACE}/bigdata-platform/platform.sh" up cluster
note "Waiting for the Airflow scheduler heartbeat"
airflow_scheduler_ready=false
for attempt in {1..60}; do
  if docker exec airflow-scheduler airflow jobs check \
      --job-type SchedulerJob --hostname airflow-scheduler >/dev/null 2>&1; then
    airflow_scheduler_ready=true
    break
  fi
  sleep 2
done
[[ "${airflow_scheduler_ready}" == true ]] || die "Airflow scheduler did not become ready"
"${WORKSPACE}/bigdata-platform/platform.sh" smoke cluster

note "Preparing isolated build workspaces"
mkdir -p "${BUILD_DIR}/rec-server" "${BUILD_DIR}/sdk/java-client" \
  "${BUILD_DIR}/data-processor" "${BUILD_DIR}/example/init" "${BUILD_DIR}/example/web"
rsync -a --delete --exclude .git --exclude target/ "${WORKSPACE}/rec-server/" "${BUILD_DIR}/rec-server/"
rsync -a --delete --exclude .git --exclude target/ "${WORKSPACE}/sdk/java-client/" "${BUILD_DIR}/sdk/java-client/"
rsync -a --delete --exclude .git --exclude target/ "${WORKSPACE}/data-processor/" "${BUILD_DIR}/data-processor/"
rsync -a --delete --exclude target/ "${WORKSPACE}/example/init/" "${BUILD_DIR}/example/init/"
rsync -a --delete --exclude target/ "${WORKSPACE}/example/web/" "${BUILD_DIR}/example/web/"

note "Building SDK, feature processor, loader, and Web Demo"
"${MVN}" "${MVN_ARGS[@]}" -f "${BUILD_DIR}/rec-server/pom.xml" -pl proto -am clean install -DskipTests
"${MVN}" "${MVN_ARGS[@]}" -f "${BUILD_DIR}/sdk/java-client/pom.xml" clean install -DskipTests
"${MVN}" "${MVN_ARGS[@]}" -f "${BUILD_DIR}/data-processor/pom.xml" -pl spark -am clean package -DskipTests
"${MVN}" "${MVN_ARGS[@]}" -f "${BUILD_DIR}/example/init/pom.xml" clean package -DskipTests
"${MVN}" "${MVN_ARGS[@]}" -f "${BUILD_DIR}/example/web/pom.xml" clean package -DskipTests

note "Installing Hive daily-partition entity tables"
docker cp "${BUILD_DIR}/data-processor/sql/openrec_entities.sql" hiveserver2:/tmp/openrec_entities.sql
docker exec hiveserver2 beeline -u jdbc:hive2://hiveserver2:10000 -n hive \
  -f /tmp/openrec_entities.sql >/dev/null

note "Starting Spark data-processor"
if docker exec spark-master test -f "${SPARK_PID_FILE}"; then
  old_spark_pid="$(docker exec spark-master cat "${SPARK_PID_FILE}" | tr -d '\r')"
  docker exec spark-master kill -0 "${old_spark_pid}" 2>/dev/null \
    && die "Spark data-processor is already running (container pid ${old_spark_pid})"
fi
docker cp "${BUILD_DIR}/data-processor/spark/target/rec-spark-1.0-SNAPSHOT.jar" \
  spark-master:/tmp/openrec-data-processor.jar
docker exec -d spark-master bash -lc \
  "echo \$\$ >${SPARK_PID_FILE}; exec /opt/spark/bin/spark-submit --class com.openrec.dp.spark.SparkFeatureJob --master spark://spark-master:7077 --total-executor-cores ${OPENREC_SPARK_TOTAL_EXECUTOR_CORES:-4} /tmp/openrec-data-processor.jar >${SPARK_LOG_FILE} 2>&1"
for attempt in {1..30}; do
  if docker exec spark-master test -s "${SPARK_PID_FILE}"; then
    spark_pid="$(docker exec spark-master cat "${SPARK_PID_FILE}" | tr -d '\r')"
    docker exec spark-master kill -0 "${spark_pid}" 2>/dev/null && break
  fi
  sleep 1
done
docker exec spark-master kill -0 "${spark_pid:-0}" 2>/dev/null \
  || die "Spark data-processor failed; inspect docker exec spark-master cat ${SPARK_LOG_FILE}"

note "Loading sample serving data"
(
  cd "${WORKSPACE}/example"
  "${JAVA}" -cp "${BUILD_DIR}/example/init/target/rec-example-init-1.0-SNAPSHOT-jar-with-dependencies.jar" \
    com.openrec.example.InitStandalone \
    127.0.0.1 6380 127.0.0.1 9200 elastic openrec-es-password
)

note "Verifying loaded cluster serving data"
docker exec redis redis-cli EXISTS 'user:{user_0}' | grep -qx 1 \
  || die "sample user was not loaded into Redis"
for recall_kind in hot new i2i; do
  wait_for_es_documents "${recall_kind} recall alias" \
    "openrec-recall-${recall_kind}-active"
done
wait_for_es_documents "embedding recall index" "scene_0-item-vector-index"

note "Building and starting rec-server, rank-engine, rec-algorithm runner, and rec-console containers"
docker compose -f "${SCRIPT_DIR}/docker-compose.yml" up -d --build --wait --wait-timeout 300

run_airflow_dag "openrec_cluster_bootstrap" "openrec-start-$(date -u +%Y%m%dT%H%M%SZ)"

port_in_use 12345 && die "Web Demo port 12345 is already occupied"
start_jar "Web Demo" "${STATE_DIR}/web.pid" "${LOG_DIR}/web.log" \
  "${JAVA}" -jar "${BUILD_DIR}/example/web/target/rec-example-web-1.0-SNAPSHOT.jar" \
  --server.port=12345 --demo.exposure-mode=viewport
wait_for_url "Web Demo" http://127.0.0.1:12345/

cat <<EOF

Cluster recommendation chain is ready.
Web Demo:    http://127.0.0.1:12345
API health:  http://127.0.0.1:13579/health
Rank health: http://127.0.0.1:8123/health
Console:     http://127.0.0.1:8095 (or http://<host>:8095)
Console API: http://127.0.0.1:8095/docs
Airflow UI:  http://127.0.0.1:8091
Spark UI:    http://127.0.0.1:8083
Flink UI:    http://127.0.0.1:8087
Stop apps:   ${SCRIPT_DIR}/stop.sh
EOF
trap - ERR

#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATE_DIR="${SCRIPT_DIR}/.runtime"
LOG_DIR="${STATE_DIR}/logs"
BUILD_DIR="${STATE_DIR}/build"
SPARK_PID_FILE="/tmp/openrec-data-processor.pid"
SPARK_LOG_FILE="/tmp/openrec-data-processor.log"

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

MVN_ARGS=()
if [[ -d "${WORKSPACE}/.cache/maven-repository" ]]; then
  MVN_ARGS+=("-Dmaven.repo.local=${WORKSPACE}/.cache/maven-repository")
fi

mkdir -p "${LOG_DIR}"
for pid_file in "${STATE_DIR}/rec-server.pid" "${STATE_DIR}/web.pid"; do
  if [[ -f "${pid_file}" ]]; then
    pid="$(cat "${pid_file}")"
    if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
      die "cluster applications are already running; use ${SCRIPT_DIR}/stop.sh first"
    fi
    rm -f "${pid_file}"
  fi
done

for required_port in 13579 12345 8123; do
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

port_in_use() { (echo >/dev/tcp/127.0.0.1/"$1") >/dev/null 2>&1; }

assert_openrec_success() {
  local name="$1" payload="$2"
  grep -Fq '"code":200' <<<"${payload}" \
    && grep -Fq '"status":true' <<<"${payload}" \
    || die "${name} failed: ${payload}"
}

start_jar() {
  local name="$1" pid_file="$2" log_file="$3"
  shift 3
  nohup "$@" >"${log_file}" 2>&1 &
  local pid=$!
  echo "${pid}" >"${pid_file}"
  note "${name} started (pid ${pid}, log ${log_file})"
}

note "Refreshing locally maintained platform images"
"${WORKSPACE}/bigdata-platform/platform.sh" build hdfs kafka

note "Starting the complete cluster platform"
"${WORKSPACE}/bigdata-platform/platform.sh" up cluster
"${WORKSPACE}/bigdata-platform/platform.sh" smoke cluster

note "Preparing isolated build workspaces"
mkdir -p "${BUILD_DIR}/rec-server" "${BUILD_DIR}/sdk/java-client" \
  "${BUILD_DIR}/data-processor" "${BUILD_DIR}/example/init" "${BUILD_DIR}/example/web"
rsync -a --delete --exclude .git --exclude target/ "${WORKSPACE}/rec-server/" "${BUILD_DIR}/rec-server/"
rsync -a --delete --exclude .git --exclude target/ "${WORKSPACE}/sdk/java-client/" "${BUILD_DIR}/sdk/java-client/"
rsync -a --delete --exclude .git --exclude target/ "${WORKSPACE}/data-processor/" "${BUILD_DIR}/data-processor/"
rsync -a --delete --exclude target/ "${WORKSPACE}/example/init/" "${BUILD_DIR}/example/init/"
rsync -a --delete --exclude target/ "${WORKSPACE}/example/web/" "${BUILD_DIR}/example/web/"

note "Building rec-server, SDK, feature processor, loader, and Web Demo"
"${MVN}" "${MVN_ARGS[@]}" -f "${BUILD_DIR}/rec-server/pom.xml" clean install -DskipTests
"${MVN}" "${MVN_ARGS[@]}" -f "${BUILD_DIR}/sdk/java-client/pom.xml" clean install -DskipTests
"${MVN}" "${MVN_ARGS[@]}" -f "${BUILD_DIR}/data-processor/pom.xml" -pl spark -am clean package -DskipTests
"${MVN}" "${MVN_ARGS[@]}" -f "${BUILD_DIR}/example/init/pom.xml" clean package -DskipTests
"${MVN}" "${MVN_ARGS[@]}" -f "${BUILD_DIR}/example/web/pom.xml" clean package -DskipTests
mkdir -p "${BUILD_DIR}/rec-server/server/plugins"
cp "${BUILD_DIR}/rec-server/contrib/target/rec-contrib-1.0-SNAPSHOT.jar" \
  "${BUILD_DIR}/rec-server/server/plugins/"

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
  "echo \$\$ >${SPARK_PID_FILE}; exec /opt/spark/bin/spark-submit --class com.openrec.dp.spark.SparkFeatureJob --master spark://spark-master:7077 /tmp/openrec-data-processor.jar >${SPARK_LOG_FILE} 2>&1"
for attempt in {1..30}; do
  if docker exec spark-master test -s "${SPARK_PID_FILE}"; then
    spark_pid="$(docker exec spark-master cat "${SPARK_PID_FILE}" | tr -d '\r')"
    docker exec spark-master kill -0 "${spark_pid}" 2>/dev/null && break
  fi
  sleep 1
done
docker exec spark-master kill -0 "${spark_pid:-0}" 2>/dev/null \
  || die "Spark data-processor failed; inspect docker exec spark-master cat ${SPARK_LOG_FILE}"

note "Starting rank-engine"
docker compose -f "${WORKSPACE}/rank-engine/docker-compose.cluster.yml" up -d --build
wait_for_url "rank-engine" http://127.0.0.1:8123/health 180

note "Loading sample serving data"
(
  cd "${WORKSPACE}/example"
  "${JAVA}" -cp "${BUILD_DIR}/example/init/target/rec-example-init-1.0-SNAPSHOT-jar-with-dependencies.jar" \
    com.openrec.example.InitStandalone \
    127.0.0.1 6380 127.0.0.1 9200 elastic openrec-es-password
)

port_in_use 13579 && die "rec-server port 13579 is already occupied"
start_jar "rec-server" "${STATE_DIR}/rec-server.pid" "${LOG_DIR}/rec-server.log" \
  "${JAVA}" \
  "-Dopenrec.operation.plugin=${BUILD_DIR}/rec-server/server/plugins/rec-contrib-1.0-SNAPSHOT.jar" \
  -jar "${BUILD_DIR}/rec-server/server/target/rec-server-1.0-SNAPSHOT.jar" \
  --spring.profiles.active=cluster \
  --redis.hostName=127.0.0.1 --redis.port=6380 \
  --es.host=127.0.0.1 --es.port=9200 --es.user=elastic --es.password=openrec-es-password \
  --rank.host=127.0.0.1 --rank.port=8123 \
  --spring.kafka.bootstrap-servers=localhost:19092,localhost:29092,localhost:39092
wait_for_url "rec-server" http://127.0.0.1:13579/health

note "Verifying cluster recommendation and Kafka push paths"
response="$(curl --noproxy '*' -fsS -X POST http://127.0.0.1:13579/api/recommend \
  -H 'Content-Type: application/json' \
  --data '{"requestId":"cluster-smoke","body":{"scene":"scene_0","size":12,"userId":"user_0","deviceId":"cluster-smoke","type":"click","debug":false}}')"
assert_openrec_success "recommendation smoke" "${response}"
grep -Fq '"results":[{' <<<"${response}" \
  || die "recommendation smoke returned no candidates: ${response}"
push_response="$(curl --noproxy '*' -fsS -X POST http://127.0.0.1:13579/api/push/user \
  -H 'Content-Type: application/json' \
  --data '{"requestId":"cluster-push-smoke","body":{"cmd":"INSERT","data":[{"id":"cluster_smoke_user","deviceId":"cluster-smoke","name":"Cluster Smoke","age":0,"tags":[]}]}}')"
assert_openrec_success "Kafka push smoke" "${push_response}"
processed=false
for attempt in {1..60}; do
  if docker exec redis redis-cli EXISTS 'user:{cluster_smoke_user}' | tr -d '\r' | grep -Fxq 1; then
    processed=true
    break
  fi
  sleep 1
done
[[ "${processed}" == true ]] \
  || die "Kafka message did not reach Redis through the Spark data-processor"

port_in_use 12345 && die "Web Demo port 12345 is already occupied"
start_jar "Web Demo" "${STATE_DIR}/web.pid" "${LOG_DIR}/web.log" \
  "${JAVA}" -jar "${BUILD_DIR}/example/web/target/rec-example-web-1.0-SNAPSHOT.jar" \
  --server.port=12345
wait_for_url "Web Demo" http://127.0.0.1:12345/

cat <<EOF

Cluster recommendation chain is ready.
Web Demo:    http://127.0.0.1:12345
API health:  http://127.0.0.1:13579/health
Rank health: http://127.0.0.1:8123/health
Spark UI:    http://127.0.0.1:8083
Flink UI:    http://127.0.0.1:8087
Stop apps:   ${SCRIPT_DIR}/stop.sh
EOF
trap - ERR

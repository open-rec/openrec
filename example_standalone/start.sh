#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATE_DIR="${SCRIPT_DIR}/.runtime"
LOG_DIR="${STATE_DIR}/logs"
BUILD_DIR="${STATE_DIR}/build"

note() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

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
[[ -x "${JAVA}" ]] || die "Java not found; install OpenJDK 8 or Oracle JDK 8"
"${JAVA}" -version 2>&1 | head -n 1 | grep -Eq 'version "1\.8\.' || die "JDK 8 is required"
command -v javac >/dev/null 2>&1 || [[ -x "${JAVA_HOME:-}/bin/javac" ]] || die "a JDK is required, not a JRE"
command -v docker >/dev/null 2>&1 || die "Docker is required"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v rsync >/dev/null 2>&1 || die "rsync is required for the isolated Java build"
command -v python3 >/dev/null 2>&1 || die "Python 3 is required"

MVN_ARGS=()
if [[ -d "${WORKSPACE}/.cache/maven-repository" ]]; then
  MVN_ARGS+=("-Dmaven.repo.local=${WORKSPACE}/.cache/maven-repository")
fi

mkdir -p "${LOG_DIR}"

managed_pid_file="${STATE_DIR}/web.pid"
if [[ -f "${managed_pid_file}" ]]; then
  managed_pid="$(cat "${managed_pid_file}")"
  if [[ "${managed_pid}" =~ ^[0-9]+$ ]] && kill -0 "${managed_pid}" 2>/dev/null; then
    die "standalone applications are already running; use ${SCRIPT_DIR}/stop.sh before restarting"
  fi
  rm -f "${managed_pid_file}"
fi

wait_for_url() {
  local name="$1" url="$2" attempts="${3:-60}"
  local i
  for ((i = 1; i <= attempts; i++)); do
    if curl --noproxy '*' -fsS "${url}" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  die "${name} did not become ready: ${url}"
}

port_in_use() {
  (echo >/dev/tcp/127.0.0.1/"$1") >/dev/null 2>&1
}

assert_port_free() {
  local port="$1" service="$2" container project
  port_in_use "${port}" || return 0
  container="$(docker ps --filter "publish=${port}" --format '{{.Names}}' | head -n 1)"
  if [[ -n "${container}" ]]; then
    project="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "${container}" 2>/dev/null || true)"
    if [[ "${project}" == "openrec-cluster-apps" ]]; then
      die "${service} port ${port} is occupied by cluster container ${container}; run ${WORKSPACE}/example/example_cluster/stop.sh --keep-platform before starting standalone"
    fi
    die "${service} port ${port} is occupied by container ${container}${project:+ (Compose project ${project})}; stop that container before starting standalone"
  fi
  die "${service} port ${port} is occupied by a non-Docker process; stop that process before starting standalone"
}

switch_from_cluster() {
  local cluster_web_pid_file="${WORKSPACE}/example/example_cluster/.runtime/web.pid"
  local cluster_running=false cluster_web_pid=""
  if [[ -n "$(docker ps -q --filter label=com.docker.compose.project=openrec-cluster-apps 2>/dev/null)" ]]; then
    cluster_running=true
  fi
  if [[ -f "${cluster_web_pid_file}" ]]; then
    cluster_web_pid="$(cat "${cluster_web_pid_file}" 2>/dev/null || true)"
    if [[ "${cluster_web_pid}" =~ ^[0-9]+$ ]] && kill -0 "${cluster_web_pid}" 2>/dev/null; then
      cluster_running=true
    fi
  fi
  [[ "${cluster_running}" == true ]] || return 0
  note "Switching from cluster applications to standalone (keeping shared platform services)"
  "${WORKSPACE}/example/example_cluster/stop.sh" --keep-platform
}

start_jar() {
  local name="$1" pid_file="$2" log_file="$3"
  shift 3
  nohup "$@" >"${log_file}" 2>&1 &
  local pid=$!
  echo "${pid}" >"${pid_file}"
  note "${name} started (pid ${pid}, log ${log_file})"
}

switch_from_cluster

# Detect unrelated conflicts before platform startup, builds, or data import. Previously this check
# happened after Loading standalone sample data, wasting work and leaving mutated storage behind.
assert_port_free 13579 "rec-server"
assert_port_free 8095 "rec-console"
assert_port_free 12345 "Web Demo"

note "Starting standalone Redis and Elasticsearch"
"${WORKSPACE}/bigdata-platform/platform.sh" up standalone
"${WORKSPACE}/bigdata-platform/platform.sh" smoke standalone

note "Ensuring deployable model artifacts match the raw sample data"
"${WORKSPACE}/example/scripts/ensure-model-artifacts.sh"

note "Preparing an isolated Java build workspace"
mkdir -p "${BUILD_DIR}/rec-server" "${BUILD_DIR}/sdk/java-client" \
  "${BUILD_DIR}/example/init" "${BUILD_DIR}/example/web"
rsync -a --delete --exclude .git --exclude target/ \
  "${WORKSPACE}/rec-server/" "${BUILD_DIR}/rec-server/"
rsync -a --delete --exclude .git --exclude target/ \
  "${WORKSPACE}/sdk/java-client/" "${BUILD_DIR}/sdk/java-client/"
rsync -a --delete --exclude target/ \
  "${WORKSPACE}/example/init/" "${BUILD_DIR}/example/init/"
rsync -a --delete --exclude target/ \
  "${WORKSPACE}/example/web/" "${BUILD_DIR}/example/web/"

note "Building Java SDK, data loader, and Web Demo"
"${MVN}" "${MVN_ARGS[@]}" -f "${BUILD_DIR}/rec-server/pom.xml" -pl proto -am clean install -DskipTests
"${MVN}" "${MVN_ARGS[@]}" -f "${BUILD_DIR}/sdk/java-client/pom.xml" clean install -DskipTests
"${MVN}" "${MVN_ARGS[@]}" -f "${BUILD_DIR}/example/init/pom.xml" clean package -DskipTests
"${MVN}" "${MVN_ARGS[@]}" -f "${BUILD_DIR}/example/web/pom.xml" clean package -DskipTests

note "Loading standalone sample data"
(
  cd "${WORKSPACE}/example"
  "${JAVA}" -cp "${BUILD_DIR}/example/init/target/rec-example-init-1.0-SNAPSHOT-jar-with-dependencies.jar" \
    com.openrec.example.InitStandalone \
    127.0.0.1 6380 127.0.0.1 9200 elastic openrec-es-password \
    "${WORKSPACE}/example/data/test" "${WORKSPACE}/model"
)

redis_size="$(docker exec redis redis-cli DBSIZE | tr -d '\r')"
[[ "${redis_size}" =~ ^[1-9][0-9]*$ ]] || die "sample data was not loaded into Redis"
read -r smoke_user smoke_item < <(python3 - "${WORKSPACE}" <<'PY'
import csv, pathlib, sys
root = pathlib.Path(sys.argv[1])
left = {row["left_item"] for row in csv.DictReader(
    (root / "model/recall/item_cf_i2i.csv").open()) if row["scene"] == "scene_0"}
user_cf = {row["user"] for row in csv.DictReader(
    (root / "model/recall/user_cf_u2i.csv").open()) if row["scene"] == "scene_0"}
for row in csv.DictReader((root / "example/data/test/event.csv").open()):
    if (row["scene"] == "scene_0" and row["type"] == "click" and
            row["item_id"] in left and row["user_id"] in user_cf):
        print(row["user_id"], row["item_id"]); break
else:
    raise SystemExit("no scene_0 click has an i2i recall table")
PY
)
i2i_count="$(docker exec redis redis-cli ZCARD "item-cf-i2i:{${smoke_item}}:scene_0" | tr -d '\r')"
[[ "${i2i_count}" =~ ^[1-9][0-9]*$ ]] || die "the default i2i trigger item has no recall data"
docker exec redis redis-cli ZSCORE "event:{${smoke_user}}:scene_0:click" "\"${smoke_item}\"" | grep -Eq '[0-9]+' \
  || die "the default user has no i2i-covered click event"
docker exec elasticsearch curl -fksS -u elastic:openrec-es-password \
  'https://localhost:9200/_cat/indices/scene_0-item-vector-index?h=index' >/dev/null \
  || die "sample vectors were not loaded into Elasticsearch"
for recall_kind in hot item-cf-i2i content-i2i user-cf-u2i; do
  docker exec elasticsearch curl -fksS -u elastic:openrec-es-password \
    "https://localhost:9200/_alias/openrec-recall-${recall_kind}-active" >/dev/null \
    || die "${recall_kind} recall alias was not loaded into Elasticsearch"
done

note "Building and starting the standalone rec-server and rec-console containers"
docker compose -f "${SCRIPT_DIR}/docker-compose.yml" up -d --build --wait
wait_for_url "rec-server" http://127.0.0.1:13579/health
wait_for_url "rec-console" http://127.0.0.1:8095/health
note "rec-server is ready: http://127.0.0.1:13579"
note "rec-console is ready: http://127.0.0.1:8095"

note "Verifying the complete standalone recommendation chain"
recommend_response=""
recommend_ok=false
recommend() {
  local request_id="$1"
  curl --noproxy '*' -fsS -X POST \
    http://127.0.0.1:13579/api/recommend \
    -H 'Content-Type: application/json' \
    --data "{\"requestId\":\"${request_id}\",\"body\":{\"scene\":\"scene_0\",\"size\":12,\"userId\":\"${smoke_user}\",\"deviceId\":\"standalone-smoke\",\"type\":\"click\",\"debug\":false,\"params\":{\"ab\":\"default\"}}}"
}

# The health endpoint does not initialize rec-server's Elasticsearch TLS connection or search
# client. On a constrained CI runner those first requests can exceed the normal online node
# deadlines and leave the timeout pool busy briefly. Warm the complete graph before asserting its
# latency-sensitive output, just as the cluster bootstrap does.
for attempt in 1 2 3 4 5; do
  docker exec redis redis-cli DEL "event:{${smoke_user}}:scene_0:expose" >/dev/null
  recommend_response="$(recommend "standalone-warmup-${attempt}")"
  docker exec redis redis-cli DEL "event:{${smoke_user}}:scene_0:expose" >/dev/null
  if python3 -c '
import json, sys
results = (json.load(sys.stdin).get("data") or {}).get("results") or []
raise SystemExit(0 if results else 1)
' <<<"${recommend_response}"; then
    break
  fi
  sleep 2
done

for attempt in 1 2 3 4 5 6; do
  # A previous smoke request must not affect this attempt through the expose filter.
  docker exec redis redis-cli DEL "event:{${smoke_user}}:scene_0:expose" >/dev/null
  recommend_response="$(recommend "standalone-smoke-${attempt}")"
  if python3 -c '
import json, sys
response = json.load(sys.stdin)
results = (response.get("data") or {}).get("results") or []
channels = {item.get("recallFrom") for item in results if item.get("recallFrom")}
for item in results:
    channels.update((item.get("recallScores") or {}).keys())
required = {"item_cf_i2i", "content_i2i", "user_cf_u2i", "item_seq_emb", "hot"}
missing = required - channels
if missing:
    raise SystemExit("missing channels: %s" % ",".join(sorted(missing)))
' <<<"${recommend_response}"; then
    recommend_ok=true
  else
    recommend_ok=false
  fi
  [[ "${recommend_ok}" == true ]] && break
  # Let timed-out cold searches leave the graph executor before starting another assertion.
  sleep 10
done
docker exec redis redis-cli DEL "event:{${smoke_user}}:scene_0:expose" >/dev/null
[[ "${recommend_ok}" == true ]] \
  || die "default weighted-channel smoke missed an enabled recall channel: ${recommend_response}"
# A bypassed RankNode leaves rankScore unset. Do not depend on its INFO log here: container
# logging level and asynchronous flushing can hide that line even though ranking was skipped.
if grep -Eq '"rankScore":[[:space:]]*-?[0-9]' <<<"${recommend_response}"; then
  die "standalone recommendation unexpectedly used rank scores: ${recommend_response}"
fi
if docker logs rec-server 2>&1 \
    | grep -Eq 'rank score failed|KafkaService|KafkaTemplate|KafkaAdmin'; then
  die "standalone log contains an unexpected Rank or Kafka service call"
fi
note "Default weighted-channel smoke passed: item-CF, content, UserCF, embedding, and hot are present; new-item supply is time-dependent; Rank and Kafka are bypassed"

web_port=12345
port_in_use "${web_port}" && die "Web Demo port 12345 is already occupied"

start_jar "Web Demo" "${STATE_DIR}/web.pid" "${LOG_DIR}/web.log" \
  "${JAVA}" -jar "${BUILD_DIR}/example/web/target/rec-example-web-1.0-SNAPSHOT.jar" \
  "--server.port=${web_port}"
wait_for_url "Web Demo" "http://127.0.0.1:${web_port}/"
echo "${web_port}" >"${STATE_DIR}/web.port"
note "Web Demo is ready: http://127.0.0.1:${web_port}"

cat <<EOF

Standalone recommendation chain is ready.
Web Demo:  http://127.0.0.1:${web_port}
Rec Server: http://127.0.0.1:13579
Console:    http://127.0.0.1:8095
API health: http://127.0.0.1:13579/health
Stop apps:  ${SCRIPT_DIR}/stop.sh
EOF

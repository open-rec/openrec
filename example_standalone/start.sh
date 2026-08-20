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

MVN_ARGS=()
if [[ -d "${WORKSPACE}/.cache/maven-repository" ]]; then
  MVN_ARGS+=("-Dmaven.repo.local=${WORKSPACE}/.cache/maven-repository")
fi

mkdir -p "${LOG_DIR}"

for managed_pid_file in "${STATE_DIR}/web.pid"; do
  if [[ -f "${managed_pid_file}" ]]; then
    managed_pid="$(cat "${managed_pid_file}")"
    if [[ "${managed_pid}" =~ ^[0-9]+$ ]] && kill -0 "${managed_pid}" 2>/dev/null; then
      die "standalone applications are already running; use ${SCRIPT_DIR}/stop.sh before restarting"
    fi
    rm -f "${managed_pid_file}"
  fi
done

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

start_jar() {
  local name="$1" pid_file="$2" log_file="$3"
  shift 3
  nohup "$@" >"${log_file}" 2>&1 &
  local pid=$!
  echo "${pid}" >"${pid_file}"
  note "${name} started (pid ${pid}, log ${log_file})"
}

note "Starting standalone Redis and Elasticsearch"
"${WORKSPACE}/bigdata-platform/platform.sh" up standalone
"${WORKSPACE}/bigdata-platform/platform.sh" smoke standalone

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
    127.0.0.1 6380 127.0.0.1 9200 elastic openrec-es-password
)

redis_size="$(docker exec redis redis-cli DBSIZE | tr -d '\r')"
[[ "${redis_size}" =~ ^[1-9][0-9]*$ ]] || die "sample data was not loaded into Redis"
now_secs="$(date +%s)"
new_window_count="$(docker exec redis redis-cli ZCOUNT 'new:{scene_0}' "$((now_secs - 86400))" "${now_secs}" | tr -d '\r')"
[[ "${new_window_count}" =~ ^[1-9][0-9]*$ ]] \
  || die "new items were not loaded into the current 24-hour window"
i2i_count="$(docker exec redis redis-cli ZCARD 'i2i:{item_8571}:scene_0' | tr -d '\r')"
[[ "${i2i_count}" =~ ^[1-9][0-9]*$ ]] || die "the default i2i trigger item has no recall data"
docker exec redis redis-cli ZSCORE 'event:{user_0}:scene_0:click' '"item_8571"' | grep -Eq '[0-9]+' \
  || die "the default user has no i2i-covered click event"
docker exec elasticsearch curl -fksS -u elastic:openrec-es-password \
  'https://localhost:9200/_cat/indices/scene_0-item-vector-index?h=index' >/dev/null \
  || die "sample vectors were not loaded into Elasticsearch"
for recall_kind in hot new i2i; do
  docker exec elasticsearch curl -fksS -u elastic:openrec-es-password \
    "https://localhost:9200/_alias/openrec-recall-${recall_kind}-active" >/dev/null \
    || die "${recall_kind} recall alias was not loaded into Elasticsearch"
done

port_in_use 13579 && die "rec-server port 13579 is already occupied; run ${SCRIPT_DIR}/stop.sh before starting standalone"
note "Building and starting the standalone rec-server container"
docker compose -f "${SCRIPT_DIR}/docker-compose.yml" up -d --build --wait
wait_for_url "rec-server" http://127.0.0.1:13579/health
note "rec-server is ready: http://127.0.0.1:13579"

note "Verifying the complete standalone recommendation chain"
recommend_response=""
recommend_ok=false
for attempt in 1 2 3 4 5; do
  # A previous smoke request must not affect this attempt through the expose filter.
  docker exec redis redis-cli DEL 'event:{user_0}:scene_0:expose' >/dev/null
  recommend_response="$(curl --noproxy '*' -fsS -X POST \
    http://127.0.0.1:13579/api/recommend \
    -H 'Content-Type: application/json' \
    --data '{"requestId":"standalone-smoke","body":{"scene":"scene_0","size":12,"userId":"user_0","deviceId":"standalone-smoke","type":"click","debug":false}}')"
  recommend_ok=true
  for channel in i2i embedding hot new; do
    if ! grep -Fq "\"recallFrom\":\"${channel}\"" <<<"${recommend_response}"; then
      recommend_ok=false
      break
    fi
  done
  [[ "${recommend_ok}" == true ]] && break
  sleep 1
done
docker exec redis redis-cli DEL 'event:{user_0}:scene_0:expose' >/dev/null
[[ "${recommend_ok}" == true ]] \
  || die "recommendation smoke test did not return i2i, embedding, hot, and new: ${recommend_response}"
# A bypassed RankNode leaves rankScore unset. Do not depend on its INFO log here: container
# logging level and asynchronous flushing can hide that line even though ranking was skipped.
if grep -Eq '"rankScore":[[:space:]]*-?[0-9]' <<<"${recommend_response}"; then
  die "standalone recommendation unexpectedly used rank scores: ${recommend_response}"
fi
if docker logs rec-server 2>&1 \
    | grep -Eq 'rank score failed|KafkaService|KafkaTemplate|KafkaAdmin'; then
  die "standalone log contains an unexpected Rank or Kafka service call"
fi
note "Recommendation smoke passed: i2i, embedding, hot, and new are all present; Rank and Kafka are bypassed"

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
API health: http://127.0.0.1:13579/health
Stop apps:  ${SCRIPT_DIR}/stop.sh
EOF

#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "${SCRIPT_DIR}/../.." && pwd)"
STATE_DIR="${SCRIPT_DIR}/.runtime"
LOG_DIR="${STATE_DIR}/logs"
BUILD_DIR="${STATE_DIR}/build"

for argument in "$@"; do
  case "${argument}" in
    --reuse-images) export OPENREC_REUSE_IMAGES=true ;;
    -h|--help) echo "Usage: ${0##*/} [--reuse-images]"; exit 0 ;;
    *) echo "error: unknown option: ${argument}" >&2; exit 2 ;;
  esac
done

note() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

if command -v mvn >/dev/null 2>&1; then
  MVN="$(command -v mvn)"
else
  MVN="${WORKSPACE}/.tools/apache-maven-3.9.9/bin/mvn"
fi

source "${WORKSPACE}/openrec/scripts/lib/java.sh"
openrec_setup_java
[[ -x "${MVN}" ]] || die "Maven not found; install Maven 3.9+ or place it under .tools"

command -v docker >/dev/null 2>&1 || die "Docker is required"
docker compose version >/dev/null 2>&1 || die "Docker Compose v2 is required"
command -v curl >/dev/null 2>&1 || die "curl is required"
command -v rsync >/dev/null 2>&1 || die "rsync is required for the isolated Java build"
command -v python3 >/dev/null 2>&1 || die "Python 3 is required"

source "${WORKSPACE}/openrec/scripts/lib/maven-repository.sh"
openrec_setup_maven_repository
MVN_ARGS=()
if [[ -n "${OPENREC_MAVEN_REPO:-}" ]]; then
  MVN_ARGS+=("-Dmaven.repo.local=${OPENREC_MAVEN_REPO}")
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
      die "${service} port ${port} is occupied by cluster container ${container}; run ${WORKSPACE}/openrec/cluster/stop.sh --keep-platform before starting standalone"
    fi
    die "${service} port ${port} is occupied by container ${container}${project:+ (Compose project ${project})}; stop that container before starting standalone"
  fi
  die "${service} port ${port} is occupied by a non-Docker process; stop that process before starting standalone"
}

switch_from_cluster() {
  local cluster_web_pid_file="${WORKSPACE}/openrec/cluster/.runtime/web.pid"
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
  "${WORKSPACE}/openrec/cluster/stop.sh" --keep-platform
}

start_jar() {
  local name="$1" pid_file="$2" log_file="$3"
  shift 3
  # Detach from the invoking process group as well as its terminal when available.
  if command -v setsid >/dev/null 2>&1; then
    nohup setsid "$@" </dev/null >"${log_file}" 2>&1 &
  else
    nohup "$@" </dev/null >"${log_file}" 2>&1 &
  fi
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

source "${SCRIPT_DIR}/init.sh"
openrec_prepare_init

note "Starting standalone Redis and Elasticsearch"
"${WORKSPACE}/bigdata-platform/platform.sh" up standalone
"${WORKSPACE}/bigdata-platform/platform.sh" smoke standalone

note "Preparing an isolated Java build workspace"
mkdir -p "${BUILD_DIR}/rec-server" "${BUILD_DIR}/sdk/java-client" \
  "${BUILD_DIR}/openrec/init" "${BUILD_DIR}/openrec/web"
rsync -a --delete --exclude .git --exclude target/ \
  "${WORKSPACE}/rec-server/" "${BUILD_DIR}/rec-server/"
rsync -a --delete --exclude .git --exclude target/ \
  "${WORKSPACE}/sdk/java-client/" "${BUILD_DIR}/sdk/java-client/"
rsync -a --delete --exclude target/ \
  "${WORKSPACE}/openrec/init/" "${BUILD_DIR}/openrec/init/"
rsync -a --delete --exclude target/ \
  "${WORKSPACE}/openrec/web/" "${BUILD_DIR}/openrec/web/"

note "Building Java SDK, data loader, and Web Demo"
"${MVN}" "${MVN_ARGS[@]}" -f "${BUILD_DIR}/rec-server/pom.xml" -pl proto -am clean install -DskipTests
"${MVN}" "${MVN_ARGS[@]}" -f "${BUILD_DIR}/sdk/java-client/pom.xml" clean install -DskipTests
"${MVN}" "${MVN_ARGS[@]}" -f "${BUILD_DIR}/openrec/init/pom.xml" clean package -DskipTests
"${MVN}" "${MVN_ARGS[@]}" -f "${BUILD_DIR}/openrec/web/pom.xml" clean package -DskipTests

if [[ "${EMBEDDING_ENABLED:-false}" == "true" ]]; then
  note "Starting optional vLLM embedding infrastructure"
  if [[ "${OPENREC_REUSE_IMAGES:-false}" != true ]]; then
    "${WORKSPACE}/bigdata-platform/platform.sh" build vllm
  fi
  "${WORKSPACE}/bigdata-platform/platform.sh" up vllm
  embedding_ready=false
  for attempt in {1..60}; do
    if "${WORKSPACE}/bigdata-platform/platform.sh" smoke vllm; then
      embedding_ready=true
      break
    fi
    sleep 5
  done
  [[ "${embedding_ready}" == "true" ]] || die "vLLM embedding service did not become ready"
  python3 "${WORKSPACE}/openrec/scripts/runtime/verify_embedding.py" \
    --items "${OPENREC_DATA_DIR}/item.csv" \
    --vectors "${OPENREC_MODEL_ROOT}/recall/item/item_title_emb.csv"
fi

openrec_initialize

note "Starting the standalone rec-server and rec-console containers"
if [[ "${OPENREC_REUSE_IMAGES:-false}" == true ]]; then
  source "${WORKSPACE}/openrec/scripts/lib/local-source.sh"
  openrec_start_local_source standalone
else
  docker compose -f "${SCRIPT_DIR}/docker-compose.yml" up -d --build --wait
fi
wait_for_url "rec-server" http://127.0.0.1:13579/health
wait_for_url "rec-console" http://127.0.0.1:8095/health
note "rec-server process is healthy; recommendation warmup is pending"
note "rec-console is ready: http://127.0.0.1:8095"

note "Verifying the complete standalone recommendation chain"
if [[ -n "${OPENREC_GRAPH_NODE_TIMEOUT_MS:-}" ]]; then
  python3 "${WORKSPACE}/openrec/scripts/runtime/configure-functional-graph.py" \
    --node-timeout-ms "${OPENREC_GRAPH_NODE_TIMEOUT_MS}"
fi
python3 "${WORKSPACE}/openrec/scripts/runtime/wait-recommendation-ready.py" \
  --user-id "${smoke_user}" --scene "${smoke_scene}" \
  --item-query "${smoke_item_query}" --user-query "${smoke_user_query}" --target item --target user
note "rec-server recommendation is ready: http://127.0.0.1:13579"
if [[ "${OPENREC_FIXTURE_INPUT}" == true ]]; then
  source "${WORKSPACE}/openrec/standalone/verify.sh"
else
  openrec_verify_custom_data standalone
fi

web_port=12345
port_in_use "${web_port}" && die "Web Demo port 12345 is already occupied"

start_jar "Web Demo" "${STATE_DIR}/web.pid" "${LOG_DIR}/web.log" \
  "${JAVA}" -jar "${BUILD_DIR}/openrec/web/target/rec-example-web-0.2.0.jar" \
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

#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CLUSTER_STATE_DIR="${SCRIPT_DIR}/.runtime"
SPARK_PID_FILE="/tmp/openrec-data-processor.pid"
KEEP_PLATFORM=false
FAILED=0

case "${1:-}" in
  "") ;;
  --keep-platform) KEEP_PLATFORM=true ;;
  --with-platform) ;; # Backward compatible; stopping the platform is now the default.
  *) echo "usage: $0 [--keep-platform]" >&2; exit 2 ;;
esac

warn() { echo "warning: $*" >&2; FAILED=1; }

stop_pid_file() {
  local name="$1" pid_file="$2" marker="$3" pid
  [[ -f "${pid_file}" ]] || return 0
  pid="$(cat "${pid_file}" 2>/dev/null || true)"
  if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
    if [[ -r "/proc/${pid}/cmdline" ]] \
        && tr '\0' ' ' <"/proc/${pid}/cmdline" | grep -Fq "${marker}"; then
      kill "${pid}" 2>/dev/null || warn "could not stop ${name} (pid ${pid})"
      for attempt in {1..30}; do
        kill -0 "${pid}" 2>/dev/null || break
        sleep 0.2
      done
      if kill -0 "${pid}" 2>/dev/null; then
        kill -KILL "${pid}" 2>/dev/null || warn "could not force-stop ${name} (pid ${pid})"
      fi
      echo "stopped ${name} (pid ${pid})"
    else
      warn "skipped ${name}: pid ${pid} belongs to another process"
    fi
  fi
  rm -f "${pid_file}" || warn "could not remove ${pid_file}"
}

# Stop only processes owned by this example and verify the jar marker before signalling, so a
# reused PID or unrelated service is never killed.
stop_pid_file "cluster Web Demo" "${CLUSTER_STATE_DIR}/web.pid" "rec-example-web-1.0-SNAPSHOT.jar"
# Compatibility cleanup for clusters started before rec-server moved to Compose.
stop_pid_file "legacy cluster rec-server" "${CLUSTER_STATE_DIR}/rec-server.pid" "rec-server-1.0-SNAPSHOT.jar"

if docker ps --format '{{.Names}}' 2>/dev/null | grep -Fxq spark-master \
    && docker exec spark-master test -f "${SPARK_PID_FILE}" 2>/dev/null; then
  spark_pid="$(docker exec spark-master cat "${SPARK_PID_FILE}" 2>/dev/null | tr -d '\r')"
  if [[ "${spark_pid}" =~ ^[0-9]+$ ]] \
      && docker exec spark-master kill -0 "${spark_pid}" 2>/dev/null; then
    docker exec spark-master kill "${spark_pid}" 2>/dev/null \
      || warn "could not stop Spark data-processor (container pid ${spark_pid})"
    echo "stopped Spark data-processor (container pid ${spark_pid})"
  fi
  docker exec spark-master rm -f "${SPARK_PID_FILE}" 2>/dev/null \
    || warn "could not remove Spark PID file"
fi

docker compose -f "${SCRIPT_DIR}/docker-compose.yml" down \
  || warn "could not stop cluster business services"

if [[ "${KEEP_PLATFORM}" == false ]]; then
  "${WORKSPACE}/bigdata-platform/platform.sh" down cluster \
    || warn "could not stop the cluster platform"
fi

if [[ "${FAILED}" -ne 0 ]]; then
  echo "OpenRec stop completed with warnings" >&2
  exit 1
fi
echo "OpenRec cluster services stopped"

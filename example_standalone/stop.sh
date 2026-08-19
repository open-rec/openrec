#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${SCRIPT_DIR}/.runtime"

stop_app() {
  local name="$1" pid_file="$2" marker="$3"
  [[ -f "${pid_file}" ]] || return 0
  local pid
  pid="$(cat "${pid_file}")"
  if [[ "${pid}" =~ ^[0-9]+$ ]] && kill -0 "${pid}" 2>/dev/null; then
    if tr '\0' ' ' <"/proc/${pid}/cmdline" | grep -Fq "${marker}"; then
      kill "${pid}"
      echo "stopped ${name} (pid ${pid})"
    else
      echo "skipped ${name}: pid ${pid} now belongs to another process" >&2
    fi
  fi
  rm -f "${pid_file}"
}

stop_app "Web Demo" "${STATE_DIR}/web.pid" "rec-example-web-1.0-SNAPSHOT.jar"
stop_app "rec-server" "${STATE_DIR}/rec-server.pid" "rec-server-1.0-SNAPSHOT.jar"

if [[ "${1:-}" == "--with-storage" ]]; then
  "${SCRIPT_DIR}/../../bigdata-platform/platform.sh" down standalone
fi

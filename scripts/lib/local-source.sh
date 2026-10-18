#!/usr/bin/env bash
# Sourced by mode launchers after their isolated Java workspace is prepared.
openrec_start_local_source() {
  local mode="$1" image
  local -a images=(openrec/rec-server:latest openrec/rec-console:latest)
  if [[ "${mode}" == cluster ]]; then
    images+=(openrec/rank-engine:latest openrec/rec-algorithm:latest)
  fi
  for image in "${images[@]}"; do
    docker image inspect "${image}" >/dev/null 2>&1 || {
      echo "error: required local image missing: ${image}; build images explicitly first" >&2
      return 1
    }
  done

  note "Compiling current service code for existing local images"
  "${MVN}" "${MVN_ARGS[@]}" -f "${BUILD_DIR}/rec-server/pom.xml" clean package -DskipTests
  mkdir -p "${BUILD_DIR}/rec-console/rec_console"
  rsync -a --delete --exclude __pycache__ --exclude static/ \
    "${WORKSPACE}/rec-console/rec_console/" "${BUILD_DIR}/rec-console/rec_console/"
  (
    cd "${WORKSPACE}/rec-console/frontend"
    if [[ ! -x node_modules/.bin/tsc || ! -x node_modules/.bin/vite ]]; then
      npm ci
    fi
    npm run build -- --outDir "${BUILD_DIR}/rec-console/rec_console/static"
  )

  if [[ "${mode}" == cluster ]]; then
    mkdir -p "${BUILD_DIR}/rec-algorithm"
    rsync -a --delete --exclude .git --exclude .venv --exclude __pycache__ \
      --exclude build/ --exclude dist/ --exclude '*.egg-info' --exclude '*.zip' \
      "${WORKSPACE}/rec-algorithm/" "${BUILD_DIR}/rec-algorithm/"
  fi
  python3 "${WORKSPACE}/openrec/scripts/runtime/local-source-compose.py" \
    "${WORKSPACE}" "${STATE_DIR}" "${mode}"
  docker compose -f "${SCRIPT_DIR}/docker-compose.yml" \
    -f "${STATE_DIR}/local-source.json" up -d --no-build --pull never --wait --wait-timeout 300
}

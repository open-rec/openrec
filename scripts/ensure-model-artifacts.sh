#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DATA_DIR="${OPENREC_DATA_DIR:-${WORKSPACE}/example/data/test}"
MODEL_ROOT="${OPENREC_MODEL_ROOT:-${WORKSPACE}/model}"
BUILD_OUTPUT=""

cleanup() {
  if [[ -n "${BUILD_OUTPUT}" && -d "${BUILD_OUTPUT}" ]]; then
    rm -rf -- "${BUILD_OUTPUT}"
  fi
}
trap cleanup EXIT

if PYTHONPATH="${WORKSPACE}/rec-algorithm" python3 \
    "${WORKSPACE}/rec-algorithm/tool/check_default_artifacts.py" \
    --data "${DATA_DIR}" --model-root "${MODEL_ROOT}"; then
  echo "model artifacts match the current raw data; reusing ${MODEL_ROOT}"
  exit 0
fi

echo "model artifacts are missing or stale; rebuilding from ${DATA_DIR}"
if ! docker image inspect openrec/rank-engine:latest >/dev/null 2>&1; then
  docker compose -f "${WORKSPACE}/rank-engine/docker-compose.cluster.yml" build rank-engine
fi

# Do not let the container write directly into a Git checkout. GitHub-hosted runners and Docker
# user-namespace mappings can expose the bind mount with an owner different from the container's
# requested uid. A disposable, explicitly writable directory avoids that mismatch; the host then
# publishes the validated files as its own user.
BUILD_OUTPUT="$(mktemp -d "${WORKSPACE}/.openrec-model-build.XXXXXX")"
chmod 0777 "${BUILD_OUTPUT}"
docker run --rm --user "$(id -u):$(id -g)" --entrypoint python \
  -e PYTHONPATH=/openrec-algorithm \
  -v "${WORKSPACE}/rec-algorithm:/openrec-algorithm:ro" \
  -v "${DATA_DIR}:/openrec-input:ro" \
  -v "${BUILD_OUTPUT}:/openrec-output" \
  openrec/rank-engine:latest -m tool.build_default_artifacts \
  --data /openrec-input --model-root /openrec-output \
  --epochs "${OPENREC_DEFAULT_MODEL_EPOCHS:-8}" \
  --factor-dim "${OPENREC_DEFAULT_FM_FACTORS:-8}" \
  --min-auc "${OPENREC_DEFAULT_MIN_AUC:-0.70}"

PYTHONPATH="${WORKSPACE}/rec-algorithm" python3 \
  "${WORKSPACE}/rec-algorithm/tool/check_default_artifacts.py" \
  --data "${DATA_DIR}" --model-root "${BUILD_OUTPUT}"

mkdir -p "${MODEL_ROOT}/feature" "${MODEL_ROOT}/rank" "${MODEL_ROOT}/recall"
rsync -a "${BUILD_OUTPUT}/feature/" "${MODEL_ROOT}/feature/"
rsync -a "${BUILD_OUTPUT}/rank/" "${MODEL_ROOT}/rank/"
rsync -a "${BUILD_OUTPUT}/recall/" "${MODEL_ROOT}/recall/"
rsync -a "${BUILD_OUTPUT}/default.manifest.json" "${MODEL_ROOT}/default.manifest.json"

PYTHONPATH="${WORKSPACE}/rec-algorithm" python3 \
  "${WORKSPACE}/rec-algorithm/tool/check_default_artifacts.py" \
  --data "${DATA_DIR}" --model-root "${MODEL_ROOT}"
echo "model artifacts rebuilt and validated: ${MODEL_ROOT}"

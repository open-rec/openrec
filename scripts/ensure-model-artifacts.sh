#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DATA_DIR="${OPENREC_DATA_DIR:-${WORKSPACE}/example/data/test}"
MODEL_ROOT="${OPENREC_MODEL_ROOT:-${WORKSPACE}/model}"

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
docker run --rm --user "$(id -u):$(id -g)" --entrypoint python \
  -e PYTHONPATH=/openrec-algorithm \
  -v "${WORKSPACE}/rec-algorithm:/openrec-algorithm:ro" \
  -v "${DATA_DIR}:/openrec-input:ro" \
  -v "${MODEL_ROOT}:/openrec-output" \
  openrec/rank-engine:latest -m tool.build_default_artifacts \
  --data /openrec-input --model-root /openrec-output \
  --epochs "${OPENREC_DEFAULT_MODEL_EPOCHS:-8}" \
  --factor-dim "${OPENREC_DEFAULT_FM_FACTORS:-8}" \
  --min-auc "${OPENREC_DEFAULT_MIN_AUC:-0.70}"

PYTHONPATH="${WORKSPACE}/rec-algorithm" python3 \
  "${WORKSPACE}/rec-algorithm/tool/check_default_artifacts.py" \
  --data "${DATA_DIR}" --model-root "${MODEL_ROOT}"
echo "model artifacts rebuilt and validated: ${MODEL_ROOT}"

#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DATA_DIR="${OPENREC_DATA_DIR:-${WORKSPACE}/example/data/test}"
MODEL_ROOT="${OPENREC_MODEL_ROOT:-${WORKSPACE}/model}"
BUILD_OUTPUT=""

CATALOG_PUBLISHER="${WORKSPACE}/model/feature/catalog/publish_catalog.py"
ALGORITHM_CATALOG="${WORKSPACE}/rec-algorithm/algorithm/feature/definitions/feature.catalog.json"
PROCESSOR_CATALOG="${WORKSPACE}/data-processor/feature-core/src/main/resources/openrec-feature-catalog.json"
ALGORITHM_FIXTURE="${WORKSPACE}/rec-algorithm/algorithm/feature/definitions/event-feature-parity.json"
PROCESSOR_FIXTURE="${WORKSPACE}/data-processor/feature-core/src/test/resources/event-feature-parity.json"

if [[ -f "${CATALOG_PUBLISHER}" ]]; then
  python3 "${CATALOG_PUBLISHER}" --check
else
  # Distribution CI checks out only the components declared by release/openrec.json. The model
  # repository is intentionally absent because default artifacts are generated below. In that
  # layout, compare the two packaged copies directly so catalog drift still fails before a build.
  for required in "${ALGORITHM_CATALOG}" "${PROCESSOR_CATALOG}" \
      "${ALGORITHM_FIXTURE}" "${PROCESSOR_FIXTURE}"; do
    [[ -f "${required}" ]] || {
      echo "error: packaged feature contract is missing: ${required}" >&2
      exit 1
    }
  done
  cmp -s "${ALGORITHM_CATALOG}" "${PROCESSOR_CATALOG}" || {
    echo "error: rec-algorithm and data-processor feature catalogs differ" >&2
    exit 1
  }
  cmp -s "${ALGORITHM_FIXTURE}" "${PROCESSOR_FIXTURE}" || {
    echo "error: rec-algorithm and data-processor parity fixtures differ" >&2
    exit 1
  }
  echo "packaged feature catalog and parity fixture copies match"
fi

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
# Seed only the prior manifest and recall tables. The builder verifies their raw-input hashes before
# reuse, while rank artifacts are always rebuilt when the feature catalog is stale.
if [[ -f "${MODEL_ROOT}/default.manifest.json" && -d "${MODEL_ROOT}/recall" ]]; then
  mkdir -p "${BUILD_OUTPUT}/recall"
  rsync -a "${MODEL_ROOT}/default.manifest.json" "${BUILD_OUTPUT}/default.manifest.json"
  rsync -a "${MODEL_ROOT}/recall/" "${BUILD_OUTPUT}/recall/"
fi
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

mkdir -p "${MODEL_ROOT}/rank" "${MODEL_ROOT}/recall"
rsync -a "${BUILD_OUTPUT}/rank/" "${MODEL_ROOT}/rank/"
rsync -a "${BUILD_OUTPUT}/recall/" "${MODEL_ROOT}/recall/"
rsync -a "${BUILD_OUTPUT}/default.manifest.json" "${MODEL_ROOT}/default.manifest.json"

# Build version 9 binds the bundle manifest, every fitted space, and every model manifest to the
# canonical catalog hash. Catalog-only rebuilds preserve validated recall outputs.
# Remove only
# the two retired generated directories; feature/catalog is reviewed source metadata and remains.
for retired in "${MODEL_ROOT}/feature/item" "${MODEL_ROOT}/feature/user"; do
  if [[ -d "${retired}" ]]; then
    rm -rf -- "${retired}"
  fi
done

PYTHONPATH="${WORKSPACE}/rec-algorithm" python3 \
  "${WORKSPACE}/rec-algorithm/tool/check_default_artifacts.py" \
  --data "${DATA_DIR}" --model-root "${MODEL_ROOT}"
echo "model artifacts rebuilt and validated: ${MODEL_ROOT}"

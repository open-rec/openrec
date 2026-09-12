#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CATALOG_PUBLISHER="${WORKSPACE}/model/feature/catalog/publish_catalog.py"
ALGORITHM_CATALOG="${WORKSPACE}/rec-algorithm/algorithm/feature/definitions/feature.catalog.json"
ALGORITHM_FIXTURE="${WORKSPACE}/rec-algorithm/algorithm/feature/definitions/event-feature-parity.json"
PROCESSOR_CATALOG="${WORKSPACE}/data-processor/feature-core/src/main/resources/openrec-feature-catalog.json"
PROCESSOR_FIXTURES=(
  "${WORKSPACE}/data-processor/feature-core/src/test/resources/event-feature-parity.json"
  "${WORKSPACE}/data-processor/flink/src/test/resources/event-feature-parity.json"
  "${WORKSPACE}/data-processor/spark/src/test/resources/event-feature-parity.json"
)

if [[ -f "${CATALOG_PUBLISHER}" ]]; then
  python3 "${CATALOG_PUBLISHER}" --check
else
  for required in "${ALGORITHM_CATALOG}" "${ALGORITHM_FIXTURE}" \
      "${PROCESSOR_CATALOG}" "${PROCESSOR_FIXTURES[@]}"; do
    [[ -f "${required}" ]] || {
      echo "error: packaged feature parity contract is missing: ${required}" >&2
      exit 1
    }
  done
  cmp -s "${ALGORITHM_CATALOG}" "${PROCESSOR_CATALOG}" || {
    echo "error: rec-algorithm and data-processor feature catalogs differ" >&2
    exit 1
  }
  for fixture in "${PROCESSOR_FIXTURES[@]}"; do
    cmp -s "${ALGORITHM_FIXTURE}" "${fixture}" || {
      echo "error: feature parity fixture differs: ${fixture}" >&2
      exit 1
    }
  done
  echo "packaged feature catalog and all parity fixture copies match"
fi
(
  cd "${WORKSPACE}/rec-algorithm"
  PYTHONPATH="${WORKSPACE}/rec-algorithm" python3 -m pytest -q \
    test/algorithm/feature/test_event_feature.py
)
(
  cd "${WORKSPACE}/data-processor"
  mvn -pl flink,spark -am test \
    -Dtest=EventFeatureAccumulatorTest,FlinkFeatureParityTest,SparkFeatureParityTest \
    -Dsurefire.failIfNoSpecifiedTests=false
)

echo "Python, Flink, and Spark feature parity gate passed"

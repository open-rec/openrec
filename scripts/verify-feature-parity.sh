#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(cd "${SCRIPT_DIR}/../.." && pwd)"

python3 "${WORKSPACE}/model/feature/catalog/publish_catalog.py" --check
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

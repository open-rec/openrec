#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$(cd "${ROOT}/.." && pwd)"
source "${ROOT}/scripts/lib/maven.sh"
source "${ROOT}/scripts/lib/java.sh"
openrec_setup_java

for path in rec-server sdk/java-client; do
  [[ -f "${WORKSPACE}/${path}/pom.xml" ]] || {
    echo "error: missing ${WORKSPACE}/${path}; run scripts/checkout-components.sh first" >&2
    exit 1
  }
done

command -v rsync >/dev/null 2>&1 || { echo "error: rsync is required" >&2; exit 1; }
BUILD_ROOT="${ROOT}/.runtime/ci-build"
mkdir -p "${BUILD_ROOT}/sdk" "${BUILD_ROOT}/example"
rsync -a --no-owner --no-group --delete --exclude .git --exclude target/ --exclude logs/ \
  "${WORKSPACE}/rec-server/" "${BUILD_ROOT}/rec-server/"
rsync -a --no-owner --no-group --delete --exclude .git --exclude target/ --exclude logs/ \
  "${WORKSPACE}/sdk/java-client/" "${BUILD_ROOT}/sdk/java-client/"
rsync -a --no-owner --no-group --delete --exclude target/ \
  "${ROOT}/init/" "${BUILD_ROOT}/example/init/"
rsync -a --no-owner --no-group --delete --exclude target/ \
  "${ROOT}/web/" "${BUILD_ROOT}/example/web/"

run_maven -f "${BUILD_ROOT}/rec-server/pom.xml" clean install -DskipTests
mkdir -p "${BUILD_ROOT}/rec-server/server/plugins"
cp "${BUILD_ROOT}/rec-server/contrib/target/rec-contrib-1.0-SNAPSHOT.jar" \
  "${BUILD_ROOT}/rec-server/server/plugins/"
run_maven -f "${BUILD_ROOT}/rec-server/pom.xml" \
  -pl graph,proto,contrib test
run_maven -f "${BUILD_ROOT}/rec-server/pom.xml" \
  -pl server test \
  -Dtest=ServingGraphServiceTest,RecallStoreUnitTest,KafkaServiceUnitTest,ControllerAndServiceUnitTest
run_maven -f "${BUILD_ROOT}/sdk/java-client/pom.xml" clean install
run_maven -f "${BUILD_ROOT}/example/init/pom.xml" clean verify
run_maven -f "${BUILD_ROOT}/example/web/pom.xml" clean verify

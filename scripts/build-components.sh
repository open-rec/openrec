#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKSPACE="$(cd "${ROOT}/.." && pwd)"
MAVEN_ARGS=(--batch-mode --no-transfer-progress)
if [[ -d "${WORKSPACE}/.cache/maven-repository" ]]; then
  MAVEN_ARGS+=("-Dmaven.repo.local=${WORKSPACE}/.cache/maven-repository")
fi

if command -v mvn >/dev/null 2>&1; then
  MVN="$(command -v mvn)"
elif [[ -x "${WORKSPACE}/.tools/apache-maven-3.9.9/bin/mvn" ]]; then
  MVN="${WORKSPACE}/.tools/apache-maven-3.9.9/bin/mvn"
else
  echo "error: Maven is required" >&2
  exit 1
fi
if ! command -v javac >/dev/null 2>&1 && [[ -x "${WORKSPACE}/.tools/jdk8u462-b08/bin/javac" ]]; then
  export JAVA_HOME="${WORKSPACE}/.tools/jdk8u462-b08"
  export PATH="${JAVA_HOME}/bin:${PATH}"
fi

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

"${MVN}" "${MAVEN_ARGS[@]}" -f "${BUILD_ROOT}/rec-server/pom.xml" clean install -DskipTests
mkdir -p "${BUILD_ROOT}/rec-server/server/plugins"
cp "${BUILD_ROOT}/rec-server/contrib/target/rec-contrib-1.0-SNAPSHOT.jar" \
  "${BUILD_ROOT}/rec-server/server/plugins/"
"${MVN}" "${MAVEN_ARGS[@]}" -f "${BUILD_ROOT}/rec-server/pom.xml" \
  -pl graph,proto,contrib test
"${MVN}" "${MAVEN_ARGS[@]}" -f "${BUILD_ROOT}/rec-server/pom.xml" \
  -pl server test \
  -Dtest=ServingGraphServiceTest,RecallStoreUnitTest,KafkaServiceUnitTest,ControllerAndServiceUnitTest
"${MVN}" "${MAVEN_ARGS[@]}" -f "${BUILD_ROOT}/sdk/java-client/pom.xml" clean install
"${MVN}" "${MAVEN_ARGS[@]}" -f "${BUILD_ROOT}/example/init/pom.xml" clean verify
"${MVN}" "${MAVEN_ARGS[@]}" -f "${BUILD_ROOT}/example/web/pom.xml" clean verify

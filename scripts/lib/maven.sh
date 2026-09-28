#!/usr/bin/env bash
# Shared Maven setup and bounded retries for dependency transport failures.
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

run_maven() {
  local attempt status log_file
  local -a pipeline_status
  log_file="$(mktemp)" || return 1
  for attempt in 1 2 3; do
    # -U also retries missing releases cached by an earlier failed transfer.
    if "${MVN}" "${MAVEN_ARGS[@]}" -U "$@" 2>&1 | tee "${log_file}"; then
      rm -f "${log_file}"
      return 0
    else
      pipeline_status=("${PIPESTATUS[@]}")
      status=${pipeline_status[0]}
      if (( pipeline_status[1] != 0 )); then
        rm -f "${log_file}"
        return "${pipeline_status[1]}"
      fi
    fi
    if (( attempt == 3 )) || ! grep -Eq \
      'Could not transfer artifact|Could not transfer metadata|was cached in the local repository.*(resolution|transfer)' "${log_file}"; then
      rm -f "${log_file}"
      return "${status}"
    fi
    echo "warning: Maven dependency transfer failed; retrying (${attempt}/3) in $((attempt * 10))s" >&2
    sleep "$((attempt * 10))"
  done
}

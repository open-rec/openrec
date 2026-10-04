#!/usr/bin/env bash
# All OpenRec Java components build and run with Java 21.
# Explicit homes take precedence; setup-java exports the *_X64 homes in CI.
openrec_java_major() {
  "${1}/bin/java" -version 2>&1 | sed -n 's/.*version "\([^"]*\)".*/\1/p' | head -n 1 | \
    awk -F. '{ print ($1 == "1" ? $2 : $1) }'
}

openrec_find_jdk() {
  local major="$1" candidate
  shift
  for candidate in "$@"; do
    [[ -n "${candidate}" && -x "${candidate}/bin/javac" ]] || continue
    if [[ "$(openrec_java_major "${candidate}")" == "${major}" ]]; then
      printf '%s\n' "${candidate}"
      return 0
    fi
  done
  echo "error: JDK ${major} required; set OPENREC_JAVA${major}_HOME" >&2
  return 1
}

openrec_setup_java() {
  local path_home=""
  if command -v javac >/dev/null 2>&1; then
    path_home="$(dirname "$(dirname "$(readlink -f "$(command -v javac)")")")"
  fi
  OPENREC_JAVA21_HOME="$(openrec_find_jdk 21 "${OPENREC_JAVA21_HOME:-}" \
    "${JAVA_HOME_21_X64:-}" "${JAVA_HOME:-}" "${path_home}" "${WORKSPACE}/.tools/jdk21")" || return 1
  export OPENREC_JAVA21_HOME
  export JAVA_HOME="${OPENREC_JAVA21_HOME}"
  export PATH="${JAVA_HOME}/bin:${PATH}"
  JAVA="${JAVA_HOME}/bin/java"
}

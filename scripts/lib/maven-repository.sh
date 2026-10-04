#!/usr/bin/env bash
# A writable root is insufficient when a previous container created nested artifacts.
openrec_maven_repository_writable() {
  local blocked
  [[ -d "$1" && -w "$1" && -x "$1" ]] || return 1
  blocked="$(find "$1" \( ! -writable -o \( -type d ! -executable \) \) -print -quit)" || return 1
  [[ -z "${blocked}" ]]
}

openrec_setup_maven_repository() {
  local repository="${OPENREC_MAVEN_REPO:-}" shared="${WORKSPACE}/.cache/maven-repository"
  if [[ -z "${repository}" ]]; then
    # Preserve Maven's own settings/default cache when no workspace cache exists.
    [[ -d "${shared}" ]] || return 0
    repository="${shared}"
    if ! openrec_maven_repository_writable "${repository}"; then
      repository="${WORKSPACE}/.cache/maven-repository-$(id -u)"
      echo "warning: Maven cache ${shared} contains inaccessible paths; using ${repository}" >&2
    fi
  fi
  mkdir -p "${repository}" || return 1
  if ! openrec_maven_repository_writable "${repository}"; then
    echo "error: Maven cache ${repository} is not writable; set OPENREC_MAVEN_REPO to a writable directory" >&2
    return 1
  fi
  export OPENREC_MAVEN_REPO="${repository}"
}

#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_WORKSPACE="$(cd "${REPOSITORY_ROOT}/.." && pwd)"
WORKSPACE="${1:-${DEFAULT_WORKSPACE}}"
MANIFEST="${REPOSITORY_ROOT}/release/openrec.json"

command -v git >/dev/null 2>&1 || { echo "error: git is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "error: Python 3 is required" >&2; exit 1; }
mkdir -p "${WORKSPACE}"
WORKSPACE="$(cd "${WORKSPACE}" && pwd)"

resolve_component_commit() {
  local target="$1" ref="$2" candidate commit
  for candidate in "${ref}^{commit}" "refs/remotes/origin/${ref}^{commit}" \
      "refs/tags/${ref}^{commit}"; do
    if commit="$(git -C "${target}" rev-parse --verify "${candidate}" 2>/dev/null)"; then
      printf '%s\n' "${commit}"
      return 0
    fi
  done
  echo "error: cannot resolve component ref '${ref}' in ${target}" >&2
  echo "available remote branches:" >&2
  git -C "${target}" for-each-ref --format='  %(refname:short)' refs/remotes/origin >&2
  return 1
}

while IFS=$'\t' read -r name repository ref; do
  target="${WORKSPACE}/${name}"
  if [[ -e "${target}" && ! -d "${target}/.git" ]]; then
    echo "error: ${target} exists but is not a Git repository" >&2
    exit 1
  fi
  if [[ -d "${target}/.git" ]]; then
    if [[ -n "$(git -C "${target}" status --porcelain)" ]]; then
      echo "error: ${target} has local changes; refusing to change its ref" >&2
      exit 1
    fi
    echo "==> Updating ${name}"
    git -C "${target}" fetch --tags origin
  else
    echo "==> Cloning ${name}"
    git clone "${repository}" "${target}"
  fi
  commit="$(resolve_component_commit "${target}" "${ref}")"
  git -C "${target}" checkout --detach "${commit}"
  echo "    ${name}: ${ref} -> ${commit}"
done < <(python3 - "${MANIFEST}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as source:
    manifest = json.load(source)
for name, component in sorted(manifest["components"].items()):
    print(name, component["repository"], component["ref"], sep="\t")
PY
)

printf '\nOpenRec components are ready in %s.\nStart standalone:\n  %s/example/example_standalone/start.sh\n' \
  "${WORKSPACE}" "${WORKSPACE}"

#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEFAULT_WORKSPACE="$(cd "${REPOSITORY_ROOT}/.." && pwd)"
WORKSPACE="${1:-${DEFAULT_WORKSPACE}}"
MANIFEST="${REPOSITORY_ROOT}/release/openrec.json"
COMPONENTS="${OPENREC_COMPONENTS:-}"

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

checkout_component_ref() {
  local target="$1" ref="$2" commit
  if git -C "${target}" show-ref --verify --quiet "refs/remotes/origin/${ref}"; then
    if git -C "${target}" show-ref --verify --quiet "refs/heads/${ref}"; then
      git -C "${target}" checkout "${ref}"
      git -C "${target}" merge --ff-only "refs/remotes/origin/${ref}"
    else
      git -C "${target}" checkout --track -b "${ref}" "refs/remotes/origin/${ref}"
    fi
    commit="$(git -C "${target}" rev-parse HEAD)"
    printf '    %s: %s -> %s (branch)\n' "$(basename "${target}")" "${ref}" "${commit}"
    return 0
  fi

  commit="$(resolve_component_commit "${target}" "${ref}")"
  git -C "${target}" checkout --detach "${commit}"
  printf '    %s: %s -> %s (detached immutable ref)\n' \
    "$(basename "${target}")" "${ref}" "${commit}"
}

component_rows="$(python3 - "${MANIFEST}" "${COMPONENTS}" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as source:
    manifest = json.load(source)

components = manifest["components"]
requested = sys.argv[2].split()
unknown = sorted(set(requested) - set(components))
if unknown:
    raise SystemExit("unknown component(s): %s" % ", ".join(unknown))

names = requested or sorted(components)
for name in names:
    component = components[name]
    print(name, component["repository"], component["ref"], sep="\t")
PY
)"

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
  checkout_component_ref "${target}" "${ref}"
done <<< "${component_rows}"

printf '\nOpenRec components are ready in %s.\nStart standalone:\n  %s/example/example_standalone/start.sh\n' \
  "${WORKSPACE}" "${WORKSPACE}"

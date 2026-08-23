#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

python3 scripts/validate_distribution.py

mapfile -t shell_files < <(find . -type f -name '*.sh' \
  -not -path './.git/*' -not -path './.runtime/*' -not -path '*/target/*' | sort)
for file in "${shell_files[@]}"; do
  bash -n "${file}"
done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=error -x "${shell_files[@]}"
else
  echo "warning: shellcheck is unavailable; syntax checks only" >&2
fi

mapfile -t python_files < <(find . -type f -name '*.py' \
  -not -path './.git/*' -not -path './.runtime/*' -not -path '*/target/*' | sort)
python3 -m py_compile "${python_files[@]}"

docker compose -f example_standalone/docker-compose.yml config --quiet
docker compose -f example_cluster/docker-compose.yml config --quiet

generated_pattern='(^|/)(target|node_modules|__pycache__|\.pytest_cache|\.runtime)(/|$)|\.(class|iml|iws|pyc)$|(^|/)\.env$'
if git ls-files | grep -Eq "${generated_pattern}"; then
  echo "error: generated or local files are tracked:" >&2
  git ls-files | grep -E "${generated_pattern}" >&2
  exit 1
fi

echo "OpenRec distribution policy validation passed"

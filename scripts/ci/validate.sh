#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "${ROOT}"

python3 scripts/release/validate_distribution.py

mapfile -t shell_files < <(find . -type d \( -name .git -o -name .runtime -o -name target -o -name node_modules \
  -o -name __pycache__ -o -name build -o -name dist -o -name logs \) -prune \
  -o -type f -name '*.sh' -print | sort)
for file in "${shell_files[@]}"; do
  bash -n "${file}"
done
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck --severity=error -x "${shell_files[@]}"
else
  echo "warning: shellcheck is unavailable; syntax checks only" >&2
fi

# Parse source without writing bytecode caches or traversing runtime copies.
python3 - <<'PYTHON'
import ast
import os
from pathlib import Path
excluded = {".git", ".runtime", "target", "node_modules", "__pycache__", "build", "dist", "logs"}
for root, directories, files in os.walk("."):
    directories[:] = [name for name in directories if name not in excluded]
    for name in files:
        if name.endswith(".py"):
            path = Path(root) / name
            ast.parse(path.read_bytes(), filename=str(path))
PYTHON

docker compose -f standalone/docker-compose.yml config --quiet
docker compose -f cluster/docker-compose.yml config --quiet

generated_pattern='(^|/)(target|node_modules|__pycache__|\.pytest_cache|\.runtime)(/|$)|\.(class|iml|iws|pyc)$|(^|/)\.env$'
if git ls-files | grep -Eq "${generated_pattern}"; then
  echo "error: generated or local files are tracked:" >&2
  git ls-files | grep -E "${generated_pattern}" >&2
  exit 1
fi

echo "OpenRec distribution policy validation passed"

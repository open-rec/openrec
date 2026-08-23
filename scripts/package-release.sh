#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "${ROOT}/VERSION")"
DIST_DIR="${ROOT}/dist"
ARCHIVE="${DIST_DIR}/openrec-${VERSION}.tar.gz"

python3 "${ROOT}/scripts/validate_distribution.py" --require-immutable
mkdir -p "${DIST_DIR}"
git -C "${ROOT}" archive --format=tar.gz --prefix="openrec-${VERSION}/" -o "${ARCHIVE}" HEAD
(cd "${DIST_DIR}" && sha256sum "$(basename "${ARCHIVE}")" > "openrec-${VERSION}.sha256")
echo "created ${ARCHIVE}"

#!/usr/bin/env bash
# Copies the nozelt-core .aar artifact into the Flutter Android module.
#
# Run this after rebuilding nozelt-core. The .aar is intentionally not
# committed to VCS; this script is the supported way to refresh it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SRC="${APP_ROOT}/../nozelt-core/build/nozelt.aar"
DEST_DIR="${APP_ROOT}/android/app/libs"
DEST="${DEST_DIR}/nozelt.aar"

if [[ ! -f "${SRC}" ]]; then
  echo "error: ${SRC} not found" >&2
  echo "" >&2
  echo "Build the core library first:" >&2
  echo "  cd ../nozelt-core && ./scripts/build_aar.sh" >&2
  exit 1
fi

mkdir -p "${DEST_DIR}"
cp -f "${SRC}" "${DEST}"

size=$(wc -c <"${DEST}" | tr -d ' ')
echo "synced ${SRC} -> ${DEST} (${size} bytes)"

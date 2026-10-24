#!/usr/bin/env bash
# Builds nozelt.aar from the ./binding package via gomobile.
#
# Usage:
#   ./scripts/build_aar.sh              # release build
#   ./scripts/build_aar.sh --debug      # unoptimized build with symbols

set -euo pipefail

DEBUG=0
for arg in "$@"; do
    case "$arg" in
        --debug) DEBUG=1 ;;
        -h|--help)
            sed -n '1,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "unknown flag: $arg" >&2
            exit 2 ;;
    esac
done

# -------- environment checks --------

if ! command -v go >/dev/null 2>&1; then
    echo "error: 'go' not found in PATH. Install Go 1.22+." >&2
    exit 1
fi

GO_VERSION_RAW="$(go version | awk '{print $3}' | sed 's/^go//')"
GO_MAJOR="$(echo "$GO_VERSION_RAW" | cut -d. -f1)"
GO_MINOR="$(echo "$GO_VERSION_RAW" | cut -d. -f2)"
if [ "$GO_MAJOR" -lt 1 ] || { [ "$GO_MAJOR" -eq 1 ] && [ "$GO_MINOR" -lt 22 ]; }; then
    echo "error: Go $GO_VERSION_RAW detected; need >= 1.22." >&2
    exit 1
fi

if ! command -v gomobile >/dev/null 2>&1; then
    echo "error: 'gomobile' not found in PATH." >&2
    echo "       install: go install golang.org/x/mobile/cmd/gomobile@latest" >&2
    echo "                go install golang.org/x/mobile/cmd/gobind@latest" >&2
    echo "                gomobile init" >&2
    exit 1
fi

if [ -z "${ANDROID_NDK_HOME:-}${ANDROID_NDK_ROOT:-}${NDK_HOME:-}" ]; then
    echo "warning: ANDROID_NDK_HOME / ANDROID_NDK_ROOT / NDK_HOME not set." >&2
    echo "         gomobile may fail if it cannot locate the NDK." >&2
fi

# -------- build --------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD_DIR="$PROJECT_ROOT/build"
OUTPUT="$BUILD_DIR/nozelt.aar"

mkdir -p "$BUILD_DIR"

GOMOBILE_ARGS=(
    bind
    -target=android/arm64,android/arm
    -androidapi=24
    # Android app embedding mode: disables mihomo's privileged
    # /data/system/packages.xml package resolver. VpnService owns app rules.
    -tags=cmfa,with_gvisor
    -o "$OUTPUT"
)

if [ "$DEBUG" -eq 1 ]; then
    # -ldflags: leave symbol table in. -gcflags 'all=-N -l': disable inlining
    # and optimizations to make stack traces from logcat readable.
    GOMOBILE_ARGS+=(-ldflags="" -gcflags="all=-N -l")
    echo "building DEBUG nozelt.aar ..."
else
    # -s -w strips symbol/debug tables; -trimpath gives reproducible builds.
    GOMOBILE_ARGS+=(-ldflags="-s -w" -trimpath)
    echo "building RELEASE nozelt.aar ..."
fi

(
    cd "$PROJECT_ROOT"
    gomobile "${GOMOBILE_ARGS[@]}" ./binding
)

# -------- report --------

if [ ! -f "$OUTPUT" ]; then
    echo "error: build reported success but $OUTPUT is missing." >&2
    exit 1
fi

SIZE_BYTES="$(stat -c '%s' "$OUTPUT" 2>/dev/null || stat -f '%z' "$OUTPUT")"
SIZE_MB="$(awk "BEGIN {printf \"%.2f\", $SIZE_BYTES/1024/1024}")"
echo "built: $OUTPUT (${SIZE_MB} MB)"

#!/bin/sh
# Build the host.pdf MCP sidecar (pure-Go, go-pdf/fpdf) and deploy to src/bin/.
# Run from anywhere:   scripts/build-host-pdf.sh [linux|macos|windows]
#
# What this does:
#   1. go build the standalone sidecar in src/sidecars/host_pdf.
#   2. Copy the resulting binary into src/bin/ (named per platform).
#
# Standalone for the P1.1 MVP — NOT wired into build-extensions.sh. The fonts
# (DejaVuSans regular + bold) are embedded via go:embed, so the binary is
# self-contained and reads no OS font paths.

set -eu

# Resolve repo root from the script's own location so any cwd works.
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
REPO_ROOT=$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)

PLATFORM="${1:-}"

# Detect platform if not given.
if [ -z "$PLATFORM" ]; then
    case "$(uname -s)" in
        Linux)  PLATFORM="linux" ;;
        Darwin) PLATFORM="macos" ;;
        MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
        *) echo "Unknown platform: $(uname -s). Pass linux/macos/windows."; exit 1 ;;
    esac
fi

case "$PLATFORM" in
    linux)   BIN_NAME="minerva-host-pdf-linux" ;;
    macos)   BIN_NAME="minerva-host-pdf-macos" ;;
    windows) BIN_NAME="minerva-host-pdf-windows.exe" ;;
    *) echo "Unknown platform: $PLATFORM"; exit 1 ;;
esac

SRC_DIR="$REPO_ROOT/src/sidecars/host_pdf"
BIN_DIR="$REPO_ROOT/src/bin"
OUT="$BIN_DIR/$BIN_NAME"

echo "Building host.pdf sidecar for $PLATFORM -> src/bin/$BIN_NAME"
mkdir -p "$BIN_DIR"

# Build in the module directory; -C keeps the embedded fonts path correct.
( cd "$SRC_DIR" && go build -o "$OUT" . )

echo "Built $OUT"

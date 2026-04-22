#!/usr/bin/env bash
# Build the patched godot-cef GDExtension and deploy to the Minerva addon tree.
# Run from repo root:   scripts/build-godot-cef.sh [linux|macos|windows]
#
# What this does:
#   1. Ensures vendor/godot_cef submodule is init'd and pinned to v1.13.0.
#   2. Applies every patches/godot_cef/*.patch to the submodule (idempotent:
#      resets submodule to clean state first).
#   3. Installs prerequisites if missing: rust nightly, export-cef-dir,
#      CEF binary bundle (145.0.26).
#   4. Builds with `cargo +nightly xtask bundle --release` inside the submodule.
#   5. Deploys built artifacts into src/addons/godot_cef/bin/<platform>/.
#
# Platform mapping:
#   linux   -> bin/x86_64-unknown-linux-gnu/
#   macos   -> bin/universal-apple-darwin/
#   windows -> bin/x86_64-pc-windows-msvc/
#
# macOS / Windows note: cross-compiling from Linux is not supported here — run
# this script on the target OS. The build script is identical, only the
# deploy directory differs (and macOS needs Xcode / Windows needs MSVC).

set -euo pipefail
# Resolve repo root from the script's own location so running from any cwd
# (including a nested submodule) still lands us at Minerva's top-level.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR/.."

PLATFORM="${1:-}"
CEF_VERSION="145.0.26"

# ── Detect platform ───────────────────────────────────────────────────

if [ -z "$PLATFORM" ]; then
    case "$(uname -s)" in
        Linux)  PLATFORM="linux" ;;
        Darwin) PLATFORM="macos" ;;
        MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
        *) echo "Unknown platform: $(uname -s). Pass linux/macos/windows as argument."; exit 1 ;;
    esac
fi

case "$PLATFORM" in
    linux)    DEPLOY_TRIPLE="x86_64-unknown-linux-gnu" ;;
    macos)    DEPLOY_TRIPLE="universal-apple-darwin" ;;
    windows)  DEPLOY_TRIPLE="x86_64-pc-windows-msvc" ;;
    *) echo "Unknown platform: $PLATFORM"; exit 1 ;;
esac
echo "Building godot-cef for platform: $PLATFORM -> bin/$DEPLOY_TRIPLE/"

ADDON_BIN_DIR="src/addons/godot_cef/bin/$DEPLOY_TRIPLE"
SUBMODULE_DIR="vendor/godot_cef"
PATCH_DIR="patches/godot_cef"

# ── Submodule init ────────────────────────────────────────────────────

echo "Initializing submodule: $SUBMODULE_DIR"
git submodule update --init --recursive "$SUBMODULE_DIR"

# ── Reset submodule + apply patches ───────────────────────────────────

echo "Resetting $SUBMODULE_DIR to a clean state before applying patches..."
git -C "$SUBMODULE_DIR" reset --hard HEAD
git -C "$SUBMODULE_DIR" clean -fd

if [ -d "$PATCH_DIR" ]; then
    for patch in "$PATCH_DIR"/*.patch; do
        [ -e "$patch" ] || continue
        echo "Applying patch: $patch"
        git -C "$SUBMODULE_DIR" apply "$(pwd)/$patch"
    done
fi

# ── Install Rust nightly ──────────────────────────────────────────────

if ! command -v rustup &>/dev/null; then
    echo "ERROR: rustup not found. Install via https://rustup.rs/ and re-run."
    exit 1
fi
if ! rustup toolchain list | grep -q '^nightly'; then
    echo "Installing Rust nightly toolchain..."
    rustup toolchain install nightly
fi
echo "Rust nightly: $(rustc +nightly --version)"

# ── Install export-cef-dir ────────────────────────────────────────────

if ! command -v export-cef-dir &>/dev/null; then
    echo "Installing export-cef-dir (builds CEF binary fetcher)..."
    cargo +nightly install export-cef-dir
fi

# ── Fetch CEF binary bundle ───────────────────────────────────────────

CEF_DIR="$HOME/.local/share/cef"
# export-cef-dir is idempotent on the version: if the dir already has the
# matching release it's a no-op, otherwise it overwrites.
echo "Exporting CEF $CEF_VERSION to $CEF_DIR..."
export-cef-dir --version "$CEF_VERSION" --force "$CEF_DIR"
export CEF_PATH="$CEF_DIR"

# ── Build ─────────────────────────────────────────────────────────────

echo "Building godot-cef (cargo +nightly xtask bundle --release)..."
pushd "$SUBMODULE_DIR" > /dev/null
cargo +nightly xtask bundle --release
popd > /dev/null

# ── Deploy ────────────────────────────────────────────────────────────

BUILT_BIN_DIR="$SUBMODULE_DIR/addons/godot_cef/bin/$DEPLOY_TRIPLE"
if [ ! -d "$BUILT_BIN_DIR" ]; then
    echo "ERROR: expected built artifacts at $BUILT_BIN_DIR but it doesn't exist."
    exit 1
fi

echo "Deploying built artifacts to $ADDON_BIN_DIR/"
mkdir -p "$ADDON_BIN_DIR"
# Use `install` (not cp) to avoid SIGBUS'ing any running Minerva that has
# a stale libgdcef.so mmap'd — install unlinks+creates, preserving existing
# mmaps pointing at the old inode.
find "$BUILT_BIN_DIR" -maxdepth 1 -type f -print0 | while IFS= read -r -d '' f; do
    name="$(basename "$f")"
    if [ -x "$f" ]; then
        install -m 755 "$f" "$ADDON_BIN_DIR/$name"
    else
        install -m 644 "$f" "$ADDON_BIN_DIR/$name"
    fi
done
# Directories (e.g. locales/, Godot CEF.framework/) — copy recursively.
find "$BUILT_BIN_DIR" -maxdepth 1 -mindepth 1 -type d -print0 | while IFS= read -r -d '' d; do
    name="$(basename "$d")"
    rm -rf "$ADDON_BIN_DIR/$name"
    cp -r "$d" "$ADDON_BIN_DIR/$name"
done

echo ""
echo "✓ godot-cef build + deploy complete for $PLATFORM"
echo "  Artifacts: $ADDON_BIN_DIR/"
echo "  (If Minerva was running, close and relaunch to pick up the new binary.)"

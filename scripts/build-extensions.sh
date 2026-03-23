#!/usr/bin/env bash
# Build all Minerva GDExtensions (terminal + ghostty-vt shim).
# Run from repo root: scripts/build-extensions.sh
#
# Prerequisites installed automatically if missing:
#   - Zig 0.15.2 (downloaded to ~/.local/bin)
#   - SCons (via pip)
#   - Git submodules (godot-cpp, vendor/ghostty)

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

PLATFORM="${1:-}"
ZIG_VERSION="0.15.2"
ZIG_DIR="$HOME/.local/bin"

# ── Detect platform ───────────────────────────────────────────────────

if [ -z "$PLATFORM" ]; then
    case "$(uname -s)" in
        Linux)  PLATFORM="linux" ;;
        Darwin) PLATFORM="macos" ;;
        MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
        *) echo "Unknown platform: $(uname -s). Pass linux/macos/windows as argument."; exit 1 ;;
    esac
fi
echo "Building for platform: $PLATFORM"

# ── Git submodules ────────────────────────────────────────────────────

echo "Initializing git submodules..."
git submodule update --init --recursive

# ── Install Zig if needed ─────────────────────────────────────────────

if ! command -v zig &>/dev/null || [[ "$(zig version 2>/dev/null)" != "$ZIG_VERSION" ]]; then
    echo "Installing Zig $ZIG_VERSION..."
    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64)   ZIG_ARCH="x86_64-linux" ;;
        Linux-aarch64)  ZIG_ARCH="aarch64-linux" ;;
        Darwin-x86_64)  ZIG_ARCH="x86_64-macos" ;;
        Darwin-arm64)   ZIG_ARCH="aarch64-macos" ;;
        *) echo "No prebuilt Zig for $(uname -s)-$(uname -m). Install Zig $ZIG_VERSION manually."; exit 1 ;;
    esac
    ZIG_TAR="zig-${ZIG_ARCH}-${ZIG_VERSION}.tar.xz"
    ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/${ZIG_TAR}"
    TMP_DIR=$(mktemp -d)
    echo "Downloading $ZIG_URL..."
    curl -L -o "$TMP_DIR/$ZIG_TAR" "$ZIG_URL"
    tar xf "$TMP_DIR/$ZIG_TAR" -C "$TMP_DIR"
    mkdir -p "$ZIG_DIR"
    ln -sf "$TMP_DIR/zig-${ZIG_ARCH}-${ZIG_VERSION}/zig" "$ZIG_DIR/zig"
    # Zig needs its lib/ dir next to the binary, so symlink the whole dir
    ln -sf "$TMP_DIR/zig-${ZIG_ARCH}-${ZIG_VERSION}/lib" "$ZIG_DIR/zig-lib"
    export PATH="$ZIG_DIR:$PATH"
    echo "Zig $(zig version) installed to $ZIG_DIR"
else
    echo "Zig $(zig version) already installed"
fi

# ── Install SCons if needed ───────────────────────────────────────────

if ! command -v scons &>/dev/null; then
    echo "Installing SCons via pip..."
    pip3 install scons
fi
echo "SCons $(scons --version 2>&1 | grep -oP 'v[\d.]+' | head -1) ready"

# ── Build ghostty-vt shim (Zig) ──────────────────────────────────────

echo ""
echo "=== Building ghostty-vt shim ==="
cd src/gdextension/terminal/ghostty-shim
zig build -Doptimize=ReleaseFast
cd "$OLDPWD"

# Verify output
SHIM_DIR="src/gdextension/terminal/ghostty-shim/zig-out/lib"
case "$PLATFORM" in
    linux)  SHIM_LIB="$SHIM_DIR/libminerva-vt.so" ;;
    macos)  SHIM_LIB="$SHIM_DIR/libminerva-vt.dylib" ;;
    windows) SHIM_LIB="$SHIM_DIR/minerva-vt.dll" ;;
esac

if [ ! -f "$SHIM_LIB" ]; then
    echo "ERROR: Shim library not found at $SHIM_LIB"
    exit 1
fi
echo "Shim built: $SHIM_LIB ($(du -h "$SHIM_LIB" | cut -f1))"

# ── Build Godot C++ extension (SCons) ────────────────────────────────

echo ""
echo "=== Building Godot terminal extension ==="
cd src
scons platform="$PLATFORM"
cd ..

# ── Copy shim library to bin/ ─────────────────────────────────────────

echo ""
echo "=== Installing libraries ==="
cp "$SHIM_LIB" src/bin/
echo "Copied $(basename "$SHIM_LIB") to src/bin/"

# ── Verify ────────────────────────────────────────────────────────────

echo ""
echo "=== Build complete ==="
echo "Libraries in src/bin/:"
ls -lh src/bin/lib*.so src/bin/lib*.dylib src/bin/*.dll 2>/dev/null || true
echo ""
echo "Open src/project.godot in Godot 4.4+ to run Minerva."

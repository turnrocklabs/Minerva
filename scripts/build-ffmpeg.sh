#!/usr/bin/env bash
# Build EIRTeam.FFmpeg GDExtension from source.
# Run from repo root: scripts/build-ffmpeg.sh [platform]
#
# This builds FFmpeg from source via ffmpeg-kit, then compiles the
# GDExtension wrapper with SCons. First build takes 30-60 minutes;
# subsequent builds are skipped if the marker file is current.
#
# Prerequisites:
#   - macOS: Homebrew (for autotools, yasm, nasm, etc.)
#   - Linux: apt (for autotools, yasm, nasm, etc.)
#   - SCons (pip install scons)
#   - Git submodules initialized (vendor/EIRTeam.FFmpeg)

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

PLATFORM="${1:-}"

# ── Detect platform ──────────────────────────────────────────────────

if [ -z "$PLATFORM" ]; then
    case "$(uname -s)" in
        Linux)  PLATFORM="linux" ;;
        Darwin) PLATFORM="macos" ;;
        MINGW*|MSYS*|CYGWIN*) PLATFORM="windows" ;;
        *) echo "Unknown platform: $(uname -s). Pass linux/macos/windows as argument."; exit 1 ;;
    esac
fi

FFMPEG_DIR="vendor/EIRTeam.FFmpeg"
FFMPEG_BUILD_OUT="$FFMPEG_DIR/gdextension_build/build/addons/ffmpeg"
ADDON_DIR="src/addons/ffmpeg"
MARKER="$ADDON_DIR/.ffmpeg-built-$PLATFORM"

# ── Check if already built ───────────────────────────────────────────

needs_build() {
    if [ ! -f "$MARKER" ]; then
        return 0  # needs build
    fi

    local saved_hash current_hash
    saved_hash=$(cat "$MARKER")
    current_hash=$(git ls-tree HEAD "$FFMPEG_DIR" 2>/dev/null | awk '{print $3}')

    if [ "$saved_hash" != "$current_hash" ]; then
        return 0  # submodule updated, needs rebuild
    fi

    # Verify actual binaries exist
    case "$PLATFORM" in
        macos)
            if [ ! -d "$ADDON_DIR/macos/libgdffmpeg.macos.template_debug.framework" ] || \
               ! find "$ADDON_DIR/macos/libgdffmpeg.macos.template_debug.framework" -name '*.dylib' -o -name 'libgdffmpeg*' ! -name '*.plist' 2>/dev/null | grep -q .; then
                return 0
            fi
            ;;
        linux)
            if [ ! -f "$ADDON_DIR/linux64/libgdffmpeg.linux.template_debug.x86_64.so" ]; then
                return 0
            fi
            ;;
        windows)
            if [ ! -f "$ADDON_DIR/win64/libgdffmpeg.windows.template_debug.x86_64.dll" ]; then
                return 0
            fi
            ;;
    esac

    return 1  # already built
}

if ! needs_build; then
    echo "EIRTeam.FFmpeg already built for $PLATFORM (submodule unchanged)"
    exit 0
fi

echo ""
echo "=== Building EIRTeam.FFmpeg from source ($PLATFORM) ==="
echo "    First build takes 30-60 minutes. Subsequent builds are cached."
echo ""

# ── Ensure submodule and its dependencies are initialized ────────────

if [ ! -f "$FFMPEG_DIR/Makefile" ]; then
    echo "ERROR: vendor/EIRTeam.FFmpeg submodule not initialized."
    echo "       Run: git submodule update --init --recursive"
    exit 1
fi

echo "Initializing EIRTeam.FFmpeg submodules (ffmpeg-kit, godot-cpp)..."
cd "$FFMPEG_DIR"
git submodule update --init --recursive
cd "$(git rev-parse --show-toplevel)"

# ── Install build dependencies ───────────────────────────────────────

echo "Installing build dependencies..."
cd "$FFMPEG_DIR"
make bootstrap
cd "$(git rev-parse --show-toplevel)"

# ── Ensure SCons is available ────────────────────────────────────────

if ! command -v scons &>/dev/null; then
    echo "Installing SCons via pip..."
    pip3 install scons
fi

# ── Build FFmpeg from source ─────────────────────────────────────────

echo ""
echo "=== Compiling FFmpeg via ffmpeg-kit ==="

cd "$FFMPEG_DIR"

case "$PLATFORM" in
    macos)
        make ffmpeg PLATFORM=macos
        ;;
    linux)
        make ffmpeg PLATFORM=linux
        ;;
    windows)
        echo "WARNING: ffmpeg-kit does not support Windows native builds."
        echo "         Windows FFmpeg will be downloaded by SCons during GDExtension build."
        ;;
esac

# ── Build GDExtension wrapper ───────────────────────────────────────

echo ""
echo "=== Building FFmpeg GDExtension wrapper ==="

case "$PLATFORM" in
    macos)
        make gdextension PLATFORM=macos
        ;;
    linux)
        make gdextension PLATFORM=linux
        ;;
    windows)
        # Windows: SCons downloads FFmpeg automatically via ffmpeg_download.py
        cd gdextension_build
        scons platform=windows target=template_release
        scons platform=windows target=template_debug
        cd ..
        ;;
esac

cd "$(git rev-parse --show-toplevel)"

# ── Install built binaries ───────────────────────────────────────────

echo ""
echo "=== Installing FFmpeg addon binaries ==="

case "$PLATFORM" in
    macos)
        mkdir -p "$ADDON_DIR/macos"
        cp -r "$FFMPEG_BUILD_OUT/macos/"* "$ADDON_DIR/macos/"
        echo "  Installed macOS frameworks + dylibs"
        ;;
    linux)
        mkdir -p "$ADDON_DIR/linux64"
        cp -r "$FFMPEG_BUILD_OUT/linux64/"* "$ADDON_DIR/linux64/"
        echo "  Installed Linux shared libraries"
        ;;
    windows)
        mkdir -p "$ADDON_DIR/win64"
        cp -r "$FFMPEG_BUILD_OUT/win64/"* "$ADDON_DIR/win64/"
        echo "  Installed Windows DLLs"
        ;;
esac

# ── Write marker ─────────────────────────────────────────────────────

current_hash=$(git ls-tree HEAD "$FFMPEG_DIR" 2>/dev/null | awk '{print $3}')
echo "$current_hash" > "$MARKER"

echo ""
echo "=== EIRTeam.FFmpeg build complete ($PLATFORM) ==="
case "$PLATFORM" in
    macos)
        ls -lh "$ADDON_DIR/macos/"*.dylib "$ADDON_DIR/macos/"*.framework 2>/dev/null || true
        ;;
    linux)
        ls -lh "$ADDON_DIR/linux64/"*.so* 2>/dev/null || true
        ;;
    windows)
        ls -lh "$ADDON_DIR/win64/"*.dll 2>/dev/null || true
        ;;
esac

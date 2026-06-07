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
REPO_ROOT="$(git rev-parse --show-toplevel)"
cd "$REPO_ROOT"

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
            # Verify the actual Mach-O binary inside the framework AND a
            # representative dependency dylib exist. (A previous bug globbed
            # `libgdffmpeg*`, which matches the .framework DIRECTORY name itself,
            # so a hollow framework with no binary read as "built" and never got
            # repaired.) Mirror build-extensions.sh's ffmpeg_platform_has_binaries.
            local fw="$ADDON_DIR/macos/libgdffmpeg.macos.template_debug.framework/libgdffmpeg.macos.template_debug"
            if [ ! -f "$fw" ] || [ ! -f "$ADDON_DIR/macos/libavcodec.dylib" ]; then
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
cd "$REPO_ROOT"

# ── Patch ffmpeg-kit for CMake 4.x (x265 3.4 uses removed policy behaviors) ──
# CMake 4.3+ dropped cmake_policy(OLD) for CMP0025/CMP0054 and removed
# cmake_minimum_required<3.5 compat. x265 3.4's CMakeLists hits all three.
# Fix: add -DCMAKE_POLICY_VERSION_MINIMUM=3.5 to its cmake invocation.
if [ "$PLATFORM" = "macos" ]; then
    X265_SCRIPT="$FFMPEG_DIR/ffmpeg-kit/scripts/apple/x265.sh"
    if [ -f "$X265_SCRIPT" ] && ! grep -q "CMAKE_POLICY_VERSION_MINIMUM" "$X265_SCRIPT"; then
        echo "Patching ffmpeg-kit x265 script for CMake 4.x compatibility..."
        awk '
            {print}
            /^cmake -Wno-dev \\$/ { print "  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \\" }
        ' "$X265_SCRIPT" > "$X265_SCRIPT.tmp" && mv "$X265_SCRIPT.tmp" "$X265_SCRIPT"
        chmod +x "$X265_SCRIPT"
    fi

    # ffmpeg-kit overwrites x265's CMakeLists.txt with a patched copy that hardcodes
    # cmake_policy(SET CMP0025 OLD) and CMP0054 OLD — CMake 4.x refuses both.
    # Flip OLD → NEW so modern CMake accepts them.
    X265_CMAKE="$FFMPEG_DIR/ffmpeg-kit/tools/patch/cmake/x265/CMakeLists.txt"
    if [ -f "$X265_CMAKE" ] && grep -q "cmake_policy(SET CMP0025 OLD)" "$X265_CMAKE"; then
        echo "Patching ffmpeg-kit x265 CMakeLists.txt for CMake 4.x policies..."
        # Flip OLD → NEW to satisfy CMake 4.x; CMP0025 NEW makes Apple's compiler
        # report as "AppleClang" instead of "Clang", so broaden the identity check
        # at line 141 so CLANG=1 still gets set.
        sed -i '' \
            -e 's/cmake_policy(SET CMP0025 OLD)/cmake_policy(SET CMP0025 NEW)/' \
            -e 's/cmake_policy(SET CMP0054 OLD)/cmake_policy(SET CMP0054 NEW)/' \
            -e 's/\${CMAKE_CXX_COMPILER_ID} STREQUAL "Clang"/${CMAKE_CXX_COMPILER_ID} MATCHES "Clang"/' \
            "$X265_CMAKE"
    fi
fi

# ── Install build dependencies ───────────────────────────────────────

echo "Checking build dependencies..."
if [ "$PLATFORM" = "macos" ]; then
    # Replicate Makefile's `bootstrap` target but only install missing packages,
    # so re-runs don't spam brew with 16 already-installed formulae.
    REQUIRED_BREW_PKGS=(autoconf automake libtool pkg-config curl cmake gperf groff texinfo yasm nasm bison autogen git wget meson ninja guile)
    MISSING_PKGS=()
    for pkg in "${REQUIRED_BREW_PKGS[@]}"; do
        if ! brew list --formula "$pkg" &>/dev/null; then
            MISSING_PKGS+=("$pkg")
        fi
    done
    if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
        echo "Installing missing brew packages: ${MISSING_PKGS[*]}"
        brew install "${MISSING_PKGS[@]}"
    else
        echo "All brew build dependencies already installed"
    fi
else
    cd "$FFMPEG_DIR"
    make bootstrap
    cd "$REPO_ROOT"
fi

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
        # Minerva targets M-series only; override Makefile default (arm64 x86_64)
        # to skip the x86_64 half of the universal build.
        make ffmpeg PLATFORM=macos TARGET_ARCH=arm64
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
        make gdextension PLATFORM=macos TARGET_ARCH=arm64
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

cd "$REPO_ROOT"

# ── Install built binaries ───────────────────────────────────────────

echo ""
echo "=== Installing FFmpeg addon binaries ==="

case "$PLATFORM" in
    macos)
        mkdir -p "$ADDON_DIR/macos"
        cp -r "$FFMPEG_BUILD_OUT/macos/"* "$ADDON_DIR/macos/"
        echo "  Installed macOS frameworks + dylibs"
        # Ad-hoc codesign so Gatekeeper doesn't block dlopen at runtime.
        find "$ADDON_DIR/macos" -name '*.dylib' -exec codesign --force --sign - {} \;
        find "$ADDON_DIR/macos" -maxdepth 2 -name '*.framework' -exec codesign --force --sign - {} \;
        echo "  Codesigned (ad-hoc)"
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

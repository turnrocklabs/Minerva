#!/usr/bin/env bash
# Build Minerva native editor dependencies, including the MCP schema helper.
# Run from repo root: scripts/build-extensions.sh
#
# Prerequisites installed automatically if missing:
#   - Zig 0.15.2 (installed persistently under ~/.local/share/minerva)
#   - SCons (in .build-venv if missing)
#   - Rust/Cargo (must be pre-installed via rustup for godot_wry)
#   - Git submodules (godot-cpp, vendor/ghostty, vendor/godot_wry, vendor/EIRTeam.FFmpeg)
#
# Linux-only prereqs for godot_wry: libgtk-3-dev libwebkit2gtk-4.1-dev

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

PLATFORM=""
CHECK_ONLY=0
HELPER_ONLY=0
VOICE_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY=1 ;;
        --helper-only) HELPER_ONLY=1 ;;
        --voice-only) VOICE_ONLY=1 ;;
        linux|macos) PLATFORM="$arg" ;;
        -h|--help)
            echo "Usage: $0 [linux|macos] [--check] [--helper-only|--voice-only]"
            echo "--check validates installed artifacts without building or launching Godot."
            echo "--helper-only builds/checks only the MCP schema helper."
            echo "--voice-only builds/checks only the bundled Voice runtime."
            exit 0 ;;
        *) echo "Unknown argument: $arg. Use --help. For Windows use build-extensions.ps1."; exit 2 ;;
    esac
done
if [ "$HELPER_ONLY" = 1 ] && [ "$VOICE_ONLY" = 1 ]; then
    echo "--helper-only and --voice-only are mutually exclusive." >&2
    exit 2
fi
ZIG_VERSION="0.15.2"
ZIG_DIR="$HOME/.local/bin"

# ── Detect platform ───────────────────────────────────────────────────

if [ -z "$PLATFORM" ]; then
    case "$(uname -s)" in
        Linux)  PLATFORM="linux" ;;
        Darwin) PLATFORM="macos" ;;
        MINGW*|MSYS*|CYGWIN*) echo "Use scripts/build-extensions.ps1 on Windows."; exit 2 ;;
        *) echo "Unknown platform: $(uname -s). Pass linux/macos/windows as argument."; exit 1 ;;
    esac
fi
echo "Building for platform: $PLATFORM"

voice_target_for_host() {
    case "$(uname -s)-$(uname -m)" in
        Linux-x86_64|Linux-amd64) echo "linux-x86_64" ;;
        Darwin-arm64|Darwin-aarch64) echo "macos-arm64" ;;
        Darwin-x86_64|Darwin-amd64) echo "macos-amd64" ;;
        *) echo "Bundled Voice is not supported on $(uname -s)/$(uname -m)." >&2; return 1 ;;
    esac
}

build_voice_runtime() {
    local target
    target="$(voice_target_for_host)"
    echo ""
    echo "=== Building bundled Voice runtime ($target) ==="
    src/plugins/voice/scripts/build-runtime.sh "$target"
}

# Check-only needs Python but does not install tools or alter submodules.
command -v python3 >/dev/null || { echo "Install Python 3.9+ before running setup."; exit 1; }
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 9) else "Python 3.9+ is required")'
if [ "$CHECK_ONLY" = 1 ]; then
    if [ "$HELPER_ONLY" = 1 ]; then
        exec python3 scripts/check-editor-ready.py --helper-only
    fi
    if [ "$VOICE_ONLY" = 1 ]; then
        exec python3 scripts/check-editor-ready.py --voice-only
    fi
    exec python3 scripts/check-editor-ready.py
fi

if [ "$VOICE_ONLY" = 1 ]; then
    for tool in curl tar; do
        command -v "$tool" >/dev/null || { echo "Required Voice build tool missing: $tool. See Docs/Building.md."; exit 1; }
    done
    build_voice_runtime
    exec python3 scripts/check-editor-ready.py --voice-only
fi

# Fail before downloads/builds for missing required toolchains.
for tool in git c++; do
    command -v "$tool" >/dev/null || { echo "Required tool missing: $tool. See Docs/Building.md."; exit 1; }
done
if [ "$PLATFORM" = macos ]; then
    xcrun --find clang++ >/dev/null || { echo "Install Xcode command line tools: xcode-select --install"; exit 1; }
fi
if [ "$HELPER_ONLY" != 1 ]; then
    for tool in curl tar unzip; do
        command -v "$tool" >/dev/null || { echo "Required tool missing: $tool. See Docs/Building.md."; exit 1; }
    done
fi
if ! command -v scons >/dev/null; then
    python3 -m venv .build-venv
    .build-venv/bin/python -m pip install scons
    export PATH="$PWD/.build-venv/bin:$PATH"
fi

# The helper has no Godot/WRY dependency; repair it without touching loaded libraries.
python3 scripts/build-json-schema-helper.py --platform "$PLATFORM"
if [ "$HELPER_ONLY" = 1 ]; then
    exec python3 scripts/check-editor-ready.py --helper-only
fi

build_voice_runtime

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
    curl -fL -o "$TMP_DIR/$ZIG_TAR" "$ZIG_URL"
    tar xf "$TMP_DIR/$ZIG_TAR" -C "$TMP_DIR"
    ZIG_INSTALL="$HOME/.local/share/minerva/zig-${ZIG_ARCH}-${ZIG_VERSION}"
    mkdir -p "$(dirname "$ZIG_INSTALL")" "$ZIG_DIR"
    if [ ! -d "$ZIG_INSTALL" ]; then
        mv "$TMP_DIR/zig-${ZIG_ARCH}-${ZIG_VERSION}" "$ZIG_INSTALL"
    fi
    ln -sf "$ZIG_INSTALL/zig" "$ZIG_DIR/zig"
    rm -rf "$TMP_DIR"
    export PATH="$ZIG_DIR:$PATH"
    echo "Zig $(zig version) installed to $ZIG_DIR"
else
    echo "Zig $(zig version) already installed"
fi

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
# install (not cp): cp truncates the destination inode in place, which
# SIGBUSes a running Minerva that has the .so mmapped. install unlinks
# first so the old inode survives until the process exits.
install -m 755 "$SHIM_LIB" src/bin/
echo "Copied $(basename "$SHIM_LIB") to src/bin/"

# ── Build godot_wry WebView extension (Rust/Cargo) ───────────────────

echo ""
echo "=== Building godot_wry WebView extension ==="

if ! command -v cargo &>/dev/null; then
    echo "WARNING: Rust/Cargo not found. Install via https://rustup.rs"
    echo "         Skipping godot_wry build. WebView panels will show fallback."
else
    # Check Linux prereqs
    if [ "$PLATFORM" = "linux" ]; then
        for pkg in libgtk-3-dev libwebkit2gtk-4.1-dev; do
            if ! dpkg -s "$pkg" &>/dev/null; then
                echo "WARNING: $pkg not found. Install with: sudo apt install $pkg"
                echo "         Skipping godot_wry build."
                SKIP_WRY=1
                break
            fi
        done
    fi

    if [ "${SKIP_WRY:-}" != "1" ]; then
        python3 scripts/apply-wry-patches.py

        cd vendor/godot_wry/rust
        cargo build --release
        cd "$OLDPWD"

        # Copy binary to addons
        case "$PLATFORM" in
            linux)
                WRY_SRC="vendor/godot_wry/rust/target/release/libgodot_wry.so"
                WRY_DST="src/addons/godot_wry/bin/x86_64-unknown-linux-gnu/"
                ;;
            macos)
                WRY_SRC="vendor/godot_wry/rust/target/release/libgodot_wry.dylib"
                WRY_DST="src/addons/godot_wry/bin/universal-apple-darwin/"
                ;;
            windows)
                WRY_SRC="vendor/godot_wry/rust/target/release/godot_wry.dll"
                WRY_DST="src/addons/godot_wry/bin/x86_64-pc-windows-msvc/"
                ;;
        esac

        if [ -f "$WRY_SRC" ]; then
            mkdir -p "$WRY_DST"
            if [ "$PLATFORM" = "macos" ]; then
                # WRY.gdextension expects a proper .framework bundle on macOS.
                # Three things must be right or dyld silently crashes Godot:
                #   1. Info.plist with correct CFBundleExecutable
                #   2. Install name rewritten from cargo's abs build path to @rpath
                #   3. Codesigned as a bundle (not just the binary)
                FW_DIR="$WRY_DST/libgodot_wry.framework"
                mkdir -p "$FW_DIR/Resources"
                cp "$WRY_SRC" "$FW_DIR/libgodot_wry"

                cat > "$FW_DIR/Resources/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>libgodot_wry</string>
    <key>CFBundleIdentifier</key>
    <string>org.doceazedo.godot-wry</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>libgodot_wry</string>
    <key>CFBundlePackageType</key>
    <string>FMWK</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>MinimumOSVersion</key>
    <string>10.13</string>
</dict>
</plist>
PLIST

                install_name_tool -id "@rpath/libgodot_wry.framework/libgodot_wry" "$FW_DIR/libgodot_wry"
                codesign --force --sign - "$FW_DIR"
                echo "godot_wry built: $FW_DIR ($(du -h "$WRY_SRC" | cut -f1))"
            else
                cp "$WRY_SRC" "$WRY_DST"
                echo "godot_wry built: $WRY_DST$(basename "$WRY_SRC") ($(du -h "$WRY_SRC" | cut -f1))"
            fi
        else
            echo "WARNING: godot_wry binary not found at $WRY_SRC"
        fi

    fi
fi

# ── Install EIRTeam.FFmpeg (download prebuilt, fallback to source build) ──

FFMPEG_VERSION="1.1.4"
FFMPEG_TAG="autobuild-2025-11-12-13-44"
FFMPEG_ZIP="eirteam-ffmpeg-${FFMPEG_VERSION}.zip"
FFMPEG_URL="https://github.com/EIRTeam/EIRTeam.FFmpeg/releases/download/${FFMPEG_TAG}/${FFMPEG_ZIP}"
FFMPEG_MARKER="src/addons/ffmpeg/.ffmpeg-version"

ffmpeg_platform_has_binaries() {
    case "$PLATFORM" in
        macos)
            # Check for the framework binary (not just Info.plist)
            local framework="src/addons/ffmpeg/macos/libgdffmpeg.macos.template_debug.framework"
            local executable
            executable=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$framework/Resources/Info.plist" 2>/dev/null) || return 1
            test -f "$framework/$executable"
            ;;
        linux)
            test -f "src/addons/ffmpeg/linux64/libgdffmpeg.linux.template_debug.x86_64.so" 2>/dev/null
            ;;
        windows)
            test -f "src/addons/ffmpeg/win64/libgdffmpeg.windows.template_debug.x86_64.dll" 2>/dev/null
            ;;
    esac
}

install_ffmpeg_from_download() {
    echo ""
    echo "=== Downloading EIRTeam.FFmpeg $FFMPEG_VERSION ==="
    TMP_FFMPEG=$(mktemp -d)
    if ! curl -fL -o "$TMP_FFMPEG/$FFMPEG_ZIP" "$FFMPEG_URL"; then
        rm -rf "$TMP_FFMPEG"
        return 1
    fi
    if ! unzip -o "$TMP_FFMPEG/$FFMPEG_ZIP" -d "$TMP_FFMPEG/extract" >/dev/null; then
        rm -rf "$TMP_FFMPEG"
        return 1
    fi

    FFMPEG_SRC=$(find "$TMP_FFMPEG/extract" -name "ffmpeg.gdextension" -exec dirname {} \; | head -1)
    if [ -z "$FFMPEG_SRC" ]; then
        echo "WARNING: Could not find ffmpeg.gdextension in downloaded zip"
        rm -rf "$TMP_FFMPEG"
        return 1
    fi

    for subdir in linux64 win64 macos; do
        if [ -d "$FFMPEG_SRC/$subdir" ]; then
            mkdir -p "src/addons/ffmpeg/$subdir"
            cp -r "$FFMPEG_SRC/$subdir/"* "src/addons/ffmpeg/$subdir/"
            echo "  Installed ffmpeg $subdir"
        fi
    done
    if [ -d "$FFMPEG_SRC/macos" ]; then
        cp -r "$FFMPEG_SRC/macos/"*.framework "src/addons/ffmpeg/macos/" 2>/dev/null || true
    fi

    rm -rf "$TMP_FFMPEG"

    # Verify we actually got binaries for this platform
    if ffmpeg_platform_has_binaries; then
        echo "$FFMPEG_VERSION" > "$FFMPEG_MARKER"
        echo "EIRTeam.FFmpeg $FFMPEG_VERSION installed"
    else
        echo "WARNING: Downloaded FFmpeg has no $PLATFORM binaries"
        return 1
    fi
}

install_ffmpeg_from_source() {
    echo ""
    echo "=== Download failed — building EIRTeam.FFmpeg from source ==="
    if [ -x "scripts/build-ffmpeg.sh" ]; then
        scripts/build-ffmpeg.sh "$PLATFORM"
    else
        echo "ERROR: scripts/build-ffmpeg.sh not found or not executable"
        echo "       FFmpeg addon will not be available."
    fi
}

if [ -f "$FFMPEG_MARKER" ] && [ "$(cat "$FFMPEG_MARKER")" = "$FFMPEG_VERSION" ] && ffmpeg_platform_has_binaries; then
    echo "EIRTeam.FFmpeg $FFMPEG_VERSION already installed"
else
    install_ffmpeg_from_download || install_ffmpeg_from_source
fi

# ── Download godot-sqlite if needed ───────────────────────────────────

SQLITE_VERSION="v4.7"
SQLITE_URL="https://github.com/2shady4u/godot-sqlite/releases/download/${SQLITE_VERSION}/bin.zip"
SQLITE_MARKER="src/addons/godot-sqlite/.sqlite-version"

SQLITE_BINARY="src/addons/godot-sqlite/bin/libgdsqlite.linux.template_debug.x86_64.so"
if [ "$PLATFORM" = macos ]; then
    SQLITE_BINARY="src/addons/godot-sqlite/bin/libgdsqlite.macos.template_debug.framework/libgdsqlite.macos.template_debug"
fi
if [ -f "$SQLITE_MARKER" ] && [ "$(cat "$SQLITE_MARKER")" = "$SQLITE_VERSION" ] && [ -f "$SQLITE_BINARY" ]; then
    echo "godot-sqlite $SQLITE_VERSION already installed"
else
    echo ""
    echo "=== Downloading godot-sqlite $SQLITE_VERSION ==="
    TMP_SQLITE=$(mktemp -d)
    if curl -fL -o "$TMP_SQLITE/bin.zip" "$SQLITE_URL"; then
        unzip -o "$TMP_SQLITE/bin.zip" -d "$TMP_SQLITE/extract" >/dev/null
        SQLITE_BIN="$TMP_SQLITE/extract/bin"
        if [ -d "$SQLITE_BIN" ]; then
            mkdir -p "src/addons/godot-sqlite/bin"
            cp -r "$SQLITE_BIN/"* "src/addons/godot-sqlite/bin/"
            echo "$SQLITE_VERSION" > "$SQLITE_MARKER"
            echo "godot-sqlite $SQLITE_VERSION installed"
        else
            echo "WARNING: Could not find bin/ in downloaded godot-sqlite zip"
        fi
    else
        echo "WARNING: Failed to download godot-sqlite. SQLite addon will not be available."
    fi
    rm -rf "$TMP_SQLITE"
fi

# ── Verify ────────────────────────────────────────────────────────────

python3 scripts/check-editor-ready.py

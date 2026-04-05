#!/usr/bin/env bash
# Build all Minerva GDExtensions (terminal + ghostty-vt shim + godot_wry webview).
# Run from repo root: scripts/build-extensions.sh
#
# Prerequisites installed automatically if missing:
#   - Zig 0.15.2 (downloaded to ~/.local/bin)
#   - SCons (via pip)
#   - Rust/Cargo (must be pre-installed via rustup for godot_wry)
#   - Git submodules (godot-cpp, vendor/ghostty, vendor/godot_wry, vendor/EIRTeam.FFmpeg)
#
# Linux-only prereqs for godot_wry: libgtk-3-dev libwebkit2gtk-4.1-dev

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
echo "SCons $(scons --version 2>&1 | grep -oE 'v[0-9.]+' | head -1) ready"

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
        # Apply Minerva patches to godot_wry before building
        if [ -f "patches/godot_wry-fix-positioning.patch" ]; then
            echo "Applying Minerva patches to godot_wry..."
            cd vendor/godot_wry
            git checkout -- . 2>/dev/null  # Reset to clean upstream first
            git apply ../../patches/godot_wry-fix-positioning.patch
            cd "$OLDPWD"
            echo "Patches applied"
        fi

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
                # WRY.gdextension expects a .framework bundle on macOS
                FW_DIR="$WRY_DST/libgodot_wry.framework"
                mkdir -p "$FW_DIR"
                cp "$WRY_SRC" "$FW_DIR/libgodot_wry"
                echo "godot_wry built: $FW_DIR ($(du -h "$WRY_SRC" | cut -f1))"
            else
                cp "$WRY_SRC" "$WRY_DST"
                echo "godot_wry built: $WRY_DST$(basename "$WRY_SRC") ($(du -h "$WRY_SRC" | cut -f1))"
            fi
        else
            echo "WARNING: godot_wry binary not found at $WRY_SRC"
        fi

        # Reset submodule to clean upstream so it doesn't show as dirty
        cd vendor/godot_wry
        git checkout -- . 2>/dev/null
        cd "$OLDPWD"
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
            test -f "src/addons/ffmpeg/macos/libgdffmpeg.macos.template_debug.framework/libgdffmpeg.macos.template_debug" 2>/dev/null
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

if [ -f "$FFMPEG_MARKER" ] && [ "$(cat "$FFMPEG_MARKER")" = "$FFMPEG_VERSION" ]; then
    echo "EIRTeam.FFmpeg $FFMPEG_VERSION already installed"
else
    install_ffmpeg_from_download || install_ffmpeg_from_source
fi

# ── Download godot-sqlite if needed ───────────────────────────────────

SQLITE_VERSION="v4.7"
SQLITE_URL="https://github.com/2shady4u/godot-sqlite/releases/download/${SQLITE_VERSION}/bin.zip"
SQLITE_MARKER="src/addons/godot-sqlite/.sqlite-version"

if [ -f "$SQLITE_MARKER" ] && [ "$(cat "$SQLITE_MARKER")" = "$SQLITE_VERSION" ]; then
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

echo ""
echo "=== Build complete ==="
echo "Libraries in src/bin/:"
ls -lh src/bin/lib*.so src/bin/lib*.dylib src/bin/*.dll 2>/dev/null || true
echo "FFmpeg addon:"
ls src/addons/ffmpeg/linux64/*.so src/addons/ffmpeg/macos/*.dylib src/addons/ffmpeg/win64/*.dll 2>/dev/null | wc -l | xargs -I{} echo "  {} binary files"
echo "WebView addon:"
ls -lh src/addons/godot_wry/bin/*/libgodot_wry.* src/addons/godot_wry/bin/*/godot_wry.* 2>/dev/null || echo "  (not built)"
echo ""
echo "Open src/project.godot in Godot 4.4+ to run Minerva."

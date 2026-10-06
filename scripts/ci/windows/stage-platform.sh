#!/usr/bin/env bash
GODOT_VERSION="${1:?Godot version is required}"
cd "$(dirname "${BASH_SOURCE[0]}")/../../.."
set -euo pipefail
# RUNNER_TEMP is a Windows path (D:\a\_temp); the Git Bash tools
# here want the POSIX form (GNU tar reads "D:..." as host:path).
tmp=$(cygpath -u "$RUNNER_TEMP")
archive=mcp-schema-helper/minerva-json-schema-helper-windows-x86_64.tar.gz
[ "$(sha256sum "$archive" | cut -d' ' -f1)" = "$(tr -d '\r\n' < "$archive.sha256")" ]
mkdir -p "$tmp/helper" && tar -xzf "$archive" -C "$tmp/helper"
cp "$tmp/helper/minerva-json-schema-helper.exe" src/bin/

curl -fL -o "$tmp/sqlite.zip" https://github.com/2shady4u/godot-sqlite/releases/download/v4.7/bin.zip
unzip -o "$tmp/sqlite.zip" -d "$tmp/sqlite" >/dev/null
mkdir -p src/addons/godot-sqlite/bin && cp -r "$tmp/sqlite/bin/"* src/addons/godot-sqlite/bin/

curl -fL -o "$tmp/ffmpeg.zip" https://github.com/EIRTeam/EIRTeam.FFmpeg/releases/download/autobuild-2025-11-12-13-44/eirteam-ffmpeg-1.1.4.zip
unzip -o "$tmp/ffmpeg.zip" -d "$tmp/ffmpeg" >/dev/null
ffmpeg_src=$(dirname "$(find "$tmp/ffmpeg" -name ffmpeg.gdextension | head -1)")
mkdir -p src/addons/ffmpeg/win64 && cp -r "$ffmpeg_src/win64/"* src/addons/ffmpeg/win64/

# The console build keeps stdout attached, which the runner reads.
godot_zip="Godot_v${GODOT_VERSION}-stable_win64.exe.zip"
curl -fL -o "$tmp/godot.zip" "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}-stable/$godot_zip"
unzip -o "$tmp/godot.zip" -d "$tmp/godot" >/dev/null
echo "GODOT=$tmp/godot/Godot_v${GODOT_VERSION}-stable_win64_console.exe" >> "$GITHUB_ENV"
ls src/bin/

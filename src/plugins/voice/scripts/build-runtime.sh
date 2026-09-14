#!/usr/bin/env bash
# Build one immutable Minerva voice sidecar from pinned PBS and wheel inputs.
set -euo pipefail

if [ "$#" -ne 1 ]; then
  echo "usage: $0 {linux-x86_64|linux-arm64|macos-arm64|macos-amd64|windows-x86_64}" >&2
  exit 64
fi

PLUGIN_DIR="$(cd "$(dirname "$0")/.." && pwd)"
REPO_DIR="$(cd "$PLUGIN_DIR/../../.." && pwd)"
# shellcheck disable=SC1091
. "$PLUGIN_DIR/scripts/runtime-bundle.lock"
TARGET="$1"

case "$TARGET" in
  linux-x86_64)
    PBS_ASSET="x86_64-unknown-linux-gnu"; PLATFORMS="manylinux_2_31_x86_64 manylinux_2_28_x86_64 manylinux_2_17_x86_64 manylinux2014_x86_64"; PYTHON_BIN="bin/python3" ;;
  linux-arm64)
    PBS_ASSET="aarch64-unknown-linux-gnu"; PLATFORMS="manylinux_2_31_aarch64 manylinux_2_28_aarch64 manylinux_2_17_aarch64 manylinux2014_aarch64"; PYTHON_BIN="bin/python3" ;;
  macos-arm64)
    PBS_ASSET="aarch64-apple-darwin"; PLATFORMS="macosx_15_0_arm64 macosx_14_0_arm64 macosx_13_0_arm64 macosx_13_0_universal2 macosx_12_0_arm64 macosx_11_0_arm64"; PYTHON_BIN="bin/python3" ;;
  macos-amd64)
    PBS_ASSET="x86_64-apple-darwin"; PLATFORMS="macosx_15_0_x86_64 macosx_14_0_x86_64 macosx_13_0_x86_64 macosx_13_0_universal2 macosx_12_0_x86_64 macosx_11_0_x86_64 macosx_10_15_x86_64 macosx_10_13_x86_64 macosx_10_9_x86_64"; PYTHON_BIN="bin/python3" ;;
  windows-x86_64)
    PBS_ASSET="x86_64-pc-windows-msvc"; PLATFORMS="win_amd64"; PYTHON_BIN="python.exe" ;;
  *) echo "unsupported target: $TARGET" >&2; exit 64 ;;
esac

hash_file() {
  if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1
  else shasum -a 256 "$1" | cut -d' ' -f1; fi
}

eval "PBS_SHA256=\${PBS_SHA256_$(echo "$TARGET" | tr 'a-z-' 'A-Z_')}"
if [ -z "$PBS_SHA256" ]; then echo "missing PBS sha256 for $TARGET" >&2; exit 65; fi

BUILD_DIR="$PLUGIN_DIR/runtime-build"
CACHE_DIR="$BUILD_DIR/cache"
WHEEL_DIR="$BUILD_DIR/wheels/$TARGET"
STAGE_DIR="$BUILD_DIR/stage/$TARGET"
OUT_DIR="$PLUGIN_DIR/dist"
PBS_FILE="cpython-${CPYTHON}+${PBS_TAG}-${PBS_ASSET}-install_only.tar.gz"
PBS_URL="$PBS_BASE_URL/$PBS_FILE"
mkdir -p "$CACHE_DIR" "$OUT_DIR"
touch "$BUILD_DIR/.gdignore"
touch "$OUT_DIR/.gdignore"
rm -rf "$WHEEL_DIR" "$STAGE_DIR"
mkdir -p "$WHEEL_DIR" "$STAGE_DIR"

if [ ! -f "$CACHE_DIR/$PBS_FILE" ]; then
  curl -fL --retry 3 -o "$CACHE_DIR/$PBS_FILE.tmp" "$PBS_URL"
  mv "$CACHE_DIR/$PBS_FILE.tmp" "$CACHE_DIR/$PBS_FILE"
fi
actual="$(hash_file "$CACHE_DIR/$PBS_FILE")"
if [ "$actual" != "$PBS_SHA256" ]; then
  rm -f "$CACHE_DIR/$PBS_FILE"
  echo "PBS checksum mismatch for $TARGET" >&2
  exit 66
fi
tar -xzf "$CACHE_DIR/$PBS_FILE" -C "$STAGE_DIR" --strip-components=1
touch "$STAGE_DIR/.gdignore"

PY_MM="$(echo "$CPYTHON" | cut -d. -f1,2)"
if [ "$TARGET" = "windows-x86_64" ]; then SITE="$STAGE_DIR/Lib/site-packages"
else SITE="$STAGE_DIR/lib/python${PY_MM}/site-packages"; fi
mkdir -p "$SITE"
HOST_PY="$(command -v "python${PY_MM}" || command -v python3 || command -v python)"
REQUIREMENTS="$PLUGIN_DIR/$REQUIREMENTS_LOCK"
[ -f "$REQUIREMENTS" ] || { echo "missing requirements lock" >&2; exit 65; }
PLATFORM_ARGS=()
for platform in $PLATFORMS; do PLATFORM_ARGS+=(--platform "$platform"); done
# Wheel resolution happens only in CI/build workflows. First launch never
# installs, downloads, or consults the machine's Python environment.
# shellcheck disable=SC2086
"$HOST_PY" -m pip download --only-binary=:all: --no-deps \
  "${PLATFORM_ARGS[@]}" --python-version "$PY_MM" --implementation cp \
  --abi "cp$(echo "$PY_MM" | tr -d .)" --require-hashes \
  -d "$WHEEL_DIR" -r "$REQUIREMENTS"

# Resolve only the explicitly pinned wheel set. This prevents a changed
# transitive resolver result from entering a release unnoticed.
"$HOST_PY" -m pip install --no-index --no-deps --no-compile \
  --find-links "$WHEEL_DIR" --target "$SITE" "${PLATFORM_ARGS[@]}" \
  --python-version "$PY_MM" --implementation cp --abi "cp$(echo "$PY_MM" | tr -d .)" \
  --only-binary=:all: --require-hashes -r "$REQUIREMENTS"
cp -R "$PLUGIN_DIR/worker/minerva_voice_worker" "$SITE/"
# AudioFeatures needs only these packaged openWakeWord resources. Removing the
# unused classifiers keeps the runtime and its model inventory truthful.
find "$SITE/openwakeword/resources/models" -maxdepth 1 -type f \
  ! -name 'melspectrogram.onnx' ! -name 'embedding_model.onnx' \
  ! -name 'silero_vad.onnx' -delete
mkdir -p "$SITE/minerva_voice_worker/models"

MODEL_SOURCE="$REPO_DIR/src/Containers/voice-gateway/app/minerva_wakeword.onnx"
MODEL_DATA_SOURCE="$MODEL_SOURCE.data"
[ "$(hash_file "$MODEL_SOURCE")" = "$MODEL_SHA256" ] || { echo "model checksum mismatch" >&2; exit 66; }
[ "$(hash_file "$MODEL_DATA_SOURCE")" = "$MODEL_DATA_SHA256" ] || { echo "model data checksum mismatch" >&2; exit 66; }
cp "$MODEL_SOURCE" "$MODEL_DATA_SOURCE" "$SITE/minerva_voice_worker/models/"

mkdir -p "$STAGE_DIR/licenses"
cp "$PLUGIN_DIR/licenses/THIRD_PARTY.md" "$STAGE_DIR/licenses/"
echo "$TARGET" > "$STAGE_DIR/target-triple.txt"
cat > "$STAGE_DIR/voice-worker" <<EOF
#!/bin/sh
exec "\$(dirname "\$0")/$PYTHON_BIN" -B -I -m minerva_voice_worker "\$@"
EOF
chmod +x "$STAGE_DIR/voice-worker"
cat > "$STAGE_DIR/voice-worker.cmd" <<'EOF'
@echo off
"%~dp0python.exe" -B -I -m minerva_voice_worker %*
EOF

{
  echo "$PBS_SHA256  $PBS_URL"
  for wheel in "$WHEEL_DIR"/*; do echo "$(hash_file "$wheel")  https://pypi.org/simple/  $(basename "$wheel")"; done
  echo "$MODEL_SHA256  model/minerva_wakeword.onnx"
  echo "$MODEL_DATA_SHA256  model/minerva_wakeword.onnx.data"
} > "$STAGE_DIR/input-artifacts.sha256"

(cd "$STAGE_DIR" && find . -type f ! -name manifest.sha256 -print | LC_ALL=C sort | while read -r file; do
  echo "$(hash_file "$STAGE_DIR/$file")  ${file#./}"
done > manifest.sha256)

tar -czf "$OUT_DIR/minerva-voice-$TARGET.tar.gz" -C "$STAGE_DIR" .
hash_file "$OUT_DIR/minerva-voice-$TARGET.tar.gz" > "$OUT_DIR/minerva-voice-$TARGET.tar.gz.sha256"
echo "built $OUT_DIR/minerva-voice-$TARGET.tar.gz"

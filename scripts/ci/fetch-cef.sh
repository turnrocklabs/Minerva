#!/usr/bin/env bash
# To repin, run a new producer and pack its artifacts unchanged into native-deps.
# Update CEF_PRODUCER_RUN in build.yml, source_sha in verify-cef-inputs.sh and
# the checksum table below.
set -euo pipefail

platform=$1
dest_dir=$2
producer="${CEF_PRODUCER_RUN:?CEF producer run is required}"

case "$producer:$platform" in
  41710864064:linux)
    checksum=ffd689a892a4d10c39737b2ab3e54528bd157a5e1b21df3895bb45e5c11b3891
    ;;
  41710864064:windows)
    checksum=00faab9324e3a457195437ca90e687ce9713e4d696dbf4c3ad02f1dbc6a8cfa5
    ;;
  *)
    echo "::error::Add the CEF checksum pin for producer $producer and platform $platform in $0." >&2
    exit 1
    ;;
esac

archive=$(mktemp)
trap 'rm -f "$archive"' EXIT
url="https://github.com/$GITHUB_REPOSITORY/releases/download/native-deps/godot-cef-$platform-x86_64-$producer.tar.gz"
curl -fL --retry 3 -o "$archive" "$url"
printf '%s  %s\n' "$checksum" "$archive" | sha256sum --check -
mkdir -p "$dest_dir"
tar -xzf "$archive" -C "$dest_dir"

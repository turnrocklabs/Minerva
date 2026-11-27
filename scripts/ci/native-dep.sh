#!/usr/bin/env bash
set -euo pipefail

mode=$1
stem=$2
dir=$3

case "$mode" in
  restore)
    archive=$(mktemp)
    trap 'rm -f "$archive"' EXIT
    url="https://github.com/$GITHUB_REPOSITORY/releases/download/native-deps/$stem.tar.gz"
    if curl -fL --retry 3 -o "$archive" "$url"; then
      mkdir -p "$dir"
      tar -xzpf "$archive" -C "$dir"
      echo "restored=true" >> "$GITHUB_OUTPUT"
    else
      echo "restored=false" >> "$GITHUB_OUTPUT"
    fi
    ;;
  pack)
    out_dir=$4
    mkdir -p "$out_dir"
    tar -czf "$out_dir/$stem.tar.gz" -C "$dir" .
    ;;
  *)
    echo "Usage: $0 restore <asset-stem> <dir> | pack <asset-stem> <dir> <out-dir>" >&2
    exit 2
    ;;
esac

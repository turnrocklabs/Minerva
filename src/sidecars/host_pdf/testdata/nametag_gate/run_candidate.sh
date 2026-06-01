#!/usr/bin/env bash
# Build + run the candidate harness, writing candidate.pdf.
#
# The harness (cmd/gateharness/harness.go) lives in the sidecar's `package main`
# and calls Generate() directly. Generate/Doc/types are in the sidecar root's
# package main alongside main.go — and main.go also defines func main(), which
# would collide. So we assemble a throwaway build dir that links ONLY the core
# source files the harness needs (generate.go, types.go, fonts.go + the embedded
# fonts/ dir) together with harness.go, deliberately omitting main.go/stdout.go.
# `go run .` in that dir then has exactly one main(). The build dir is gitignored.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SIDECAR="$(cd "$HERE/../.." && pwd)"
BUILD="$HERE/.gobuild"

rm -rf "$BUILD"
mkdir -p "$BUILD"

# Link the core files (NOT main.go / stdout.go) + the harness + the fonts dir.
for f in generate.go types.go fonts.go go.mod go.sum; do
  ln -s "$SIDECAR/$f" "$BUILD/$f"
done
ln -s "$SIDECAR/cmd/gateharness/harness.go" "$BUILD/harness.go"
# go:embed will not traverse a symlinked dir, so copy fonts/ in.
cp -R "$SIDECAR/fonts" "$BUILD/fonts"

# Reuse the module cache; build in the linked dir so go:embed resolves fonts/.
# harness.go carries //go:build gateharness so it is invisible to a normal
# `go build/test ./...` of the sidecar (which has no Generate in cmd/gateharness);
# the tag opts it in here, where it's compiled flat alongside the core files.
( cd "$BUILD" && go run -tags gateharness . -- "$HERE/icon.png" "$HERE/candidate.pdf" )

rm -rf "$BUILD"

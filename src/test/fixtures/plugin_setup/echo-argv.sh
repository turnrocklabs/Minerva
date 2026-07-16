#!/usr/bin/env bash
# Fixture F10: writes every argument after the first (an output file path)
# to that file, one per line, so a test can assert argv reached this process
# verbatim -- no shell re-interpretation of spaces/quotes/vars, because the
# executor spawns the binary directly (no shell, no wrapper process).
outfile="$1"
shift
: > "$outfile"
for arg in "$@"; do
	printf '%s\n' "$arg" >> "$outfile"
done

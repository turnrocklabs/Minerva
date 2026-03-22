#!/usr/bin/env bash
# Git smudge filter for SQLite files.
# Converts SQL text from git → binary SQLite in the working directory.
# Also handles legacy binary SQLite content (passes through as-is).
# Usage: git config filter.sqlite3.smudge 'scripts/sqlite-smudge.sh %f'

set -euo pipefail

file="$1"
tmpfile="$(mktemp "${file}.smudge.XXXXXX")"
trap 'rm -f "$tmpfile"' EXIT

# Capture stdin to temp file so we can inspect it
cat > "$tmpfile"

# Check if the content is already a binary SQLite database
if head -c 16 "$tmpfile" | grep -q "SQLite format 3"; then
    # Legacy binary — pass through as-is
    cat "$tmpfile"
else
    # SQL text dump — rebuild into binary SQLite
    tmpdb="$(mktemp "${file}.db.XXXXXX")"
    trap 'rm -f "$tmpfile" "$tmpdb"' EXIT
    sqlite3 "$tmpdb" < "$tmpfile"
    sqlite3 "$tmpdb" "PRAGMA journal_mode=WAL;" >/dev/null 2>&1 || true
    cat "$tmpdb"
fi

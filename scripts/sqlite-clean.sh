#!/usr/bin/env bash
# Git clean filter for SQLite files.
# Converts binary SQLite → deterministic SQL text for git storage.
# Usage: git config filter.sqlite3.clean 'scripts/sqlite-clean.sh %f'
#
# Reads the on-disk file (not stdin) so WAL changes are included.

set -euo pipefail

file="$1"

if [ ! -f "$file" ]; then
    # File doesn't exist yet (new checkout), pass through empty
    cat
    exit 0
fi

# Checkpoint WAL into main db first, then dump as sorted SQL text
sqlite3 "$file" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
sqlite3 "$file" ".dump"

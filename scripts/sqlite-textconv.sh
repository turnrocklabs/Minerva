#!/usr/bin/env bash
# Git diff textconv for SQLite files.
# Usage: git config diff.sqlite3.textconv 'scripts/sqlite-textconv.sh'

file="$1"

if head -c 16 "$file" | grep -q "SQLite format 3"; then
    sqlite3 "$file" ".dump"
else
    # Already text (from the clean filter)
    cat "$file"
fi

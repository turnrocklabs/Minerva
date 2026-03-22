#!/usr/bin/env bash
# Run this once per clone to enable SQLite docket merge support.
# Usage: scripts/setup-git-filters.sh

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

git config filter.sqlite3.clean  'scripts/sqlite-clean.sh %f'
git config filter.sqlite3.smudge 'scripts/sqlite-smudge.sh %f'
git config filter.sqlite3.required true
git config diff.sqlite3.textconv 'scripts/sqlite-textconv.sh'

echo "Git SQLite filters configured. Docket files will now be stored as mergeable SQL text."

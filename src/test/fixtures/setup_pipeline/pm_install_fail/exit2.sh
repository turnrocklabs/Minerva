#!/usr/bin/env bash
# Copied from fixtures/plugin_setup/exit2-with-stderr.sh (kept local so this
# fixture's manifest.json can reference it as "./exit2.sh", resolved against
# the plugin's own data_directory — portable across machines/worktrees).
echo "boom: something went wrong" 1>&2
exit 2

#!/usr/bin/env bash
# No-bleed CI guard (DCR 019e7b6609 P2.3, contract comment 410).
#
# Fails if the core Minerva source re-introduces the file-primitive /
# code-intelligence tools that were extracted to the optional `codetools`
# marketplace plugin. The agent file *tools* belong in the sidecar; only the
# generic platform (PolicyEngine/ActionNormalizer normalization heuristics) may
# mention these names — but core must NOT *register* them or carry the deleted
# CodeTools classes/module.
#
# Usage: scripts/check-no-codetools-bleed.sh   (run from repo root)
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO_ROOT/src/Scripts"
fail=0

note() { echo "  BLEED: $*"; fail=1; }

# 1. The deleted CodeTools class directory must be gone.
if [[ -d "$SRC/Services/CodeTools" ]]; then
	note "src/Scripts/Services/CodeTools/ still exists (must be deleted)"
fi

# 1b. The core sightline_probe editor addon must be gone (P3.4): runtime
#     inspection moved to the codetools plugin (vendored code-probe ships its
#     own probe at worker/vendored/sightline/godot/probe/addons/sightline_probe).
if [[ -d "$REPO_ROOT/src/addons/sightline_probe" ]]; then
	note "src/addons/sightline_probe/ still exists (moved to codetools plugin)"
fi

# 2. The MCP module that registered the primitives must be gone.
if [[ -f "$SRC/Services/MCP/Modules/MCPCodeTools.gd" ]]; then
	note "MCPCodeTools.gd still exists (must be deleted)"
fi

# 3. No core code may instantiate MCPCodeTools.
if grep -rIn --include='*.gd' 'MCPCodeTools' "$SRC" >/dev/null 2>&1; then
	grep -rIn --include='*.gd' 'MCPCodeTools' "$SRC" | grep -v '#' | grep -q . \
		&& note "MCPCodeTools referenced in core (outside comments)"
fi

# 4. No core code may REGISTER the extracted tool names. This targets
#    _register_tool("<name>") specifically — NOT generic normalizer heuristics
#    (ActionNormalizer's `== "minerva_bash"` / `begins_with("minerva_file_")`
#    are deliberately kept as generic platform logic).
for tool in minerva_file_glob minerva_file_grep minerva_bash minerva_cwd \
		minerva_file_read minerva_file_write minerva_file_edit; do
	if grep -rIn --include='*.gd' "_register_tool(\"$tool\"" "$SRC" >/dev/null 2>&1; then
		note "core registers extracted tool '$tool'"
	fi
done

# 5. The CORE MCP server must not register any minerva_codetools_* tool.
if grep -rIn --include='*.gd' '_register_tool("minerva_codetools_' "$SRC" >/dev/null 2>&1; then
	note "core registers a plugin-namespaced minerva_codetools_* tool"
fi

if [[ "$fail" -ne 0 ]]; then
	echo "FAIL: codetools no-bleed guard tripped — see above." >&2
	exit 1
fi
echo "OK: no codetools bleed into core."

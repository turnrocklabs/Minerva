# Pickup — scansort next mission TBD

STATE: `IDLE`

Last updated: 2026-05-18 (post DCR `019e3d67` SHIPPED — File→Close session reset works in-memory)

## What just shipped this session

| Commit | What |
|---|---|
| plugins `167c1fc` | DCR `019e3d67` File→Close session-reset action — minerva_scansort_session_reset MCP tool + session::reset() helper + panel menu wiring (in-memory only; vaults/manifest/library all untouched on disk) |

**Tests:** plugins 307 unit + 5 manifest. **Plugins HEAD:** `167c1fc`. **Minerva HEAD:** `9484f025` (no Minerva-side code change this iter).

### Verification record

| Check | Result |
|---|---|
| R1 regression (single-vault foreground) | 7/7 moved (tax×4, boat×1, drawings×1, utility×1) — baseline green |
| session_reset return shape | `{ok:true, cleared:{vaults:1, dirs:0, sources:1}}` — pre-reset counts, as spec'd |
| session_state post-reset | vaults=[], dirs=[], sources=[] ✓ |
| `.scansort-state.json` post-reset | 2206 B, mtime unchanged ✓ |
| `test.ssort` post-reset | 7585792 B, mtime unchanged ✓ |
| `library.rules.json` post-reset | md5 matches `/tmp/lib_snapshot_iter.json` ✓ |
| 7 source PDFs post-reset | all present (source read-only) ✓ |

## Mission for next session

**None pinned.** Pick the next DCR off the backlog when the user gives direction. Likely candidates from `MEMORY.md`:

- `019e2d82ca72` (P2 model routing) — open bug
- `019e2d8018` (P3 list_models core gap) — open bug
- `019e2cfced` (B3/B4 quality) — open bug
- B6 (Rules Editor dialog retarget) — backlog from path-free DCR `019e2cc988ec` Phase 3a

Ask the user what to pick up before kicking off.

## Cycle policy (carry-forward)

Each iter:
1. Snapshot library: `cp ~/.local/share/scansort/library.rules.json /tmp/lib_snapshot_iter.json`
2. Wipe state: `rm ~/temp/scansort-staging/.scansort-state.json` + any test vaults
3. Implement (sub-agent with worktree isolation, 25-30 turn budget, enumerated file list)
4. `cargo test` — green before continuing
5. **CRITICAL: rebuild + cp binary to entrypoint** (`cp target/release/scansort-plugin scansort-plugin`). See durable hint `019e3ca206867194bfc3a978fc32a96b` — the entrypoint is a manual copy, NOT a symlink. Skipping this means Minerva runs the OLD binary.
6. Restart Minerva, run R1 (baseline regression), then test the new behavior
7. Restore library, commit pickup.md, walk DCR through implementing → reviewing → shipped
8. 30-min cap, 3 fix attempts per bug, ALL bugs in ONE commit

### HITL gotcha — new MCP tools and tool-catalogue staleness

If the DCR adds a NEW MCP tool, Claude can't call it directly post-build — the deferred-tool catalogue is frozen at session start. Symptom: `mcp__minerva__minerva_scansort_<new_tool>` returns "No such tool available". Fix: ask the user to run `/mcp` to reconnect, then `ToolSearch select:<name>` to load the schema. Captured as durable hint `019e3d9c2e85` (claude_code/mcp_new_tools_blocked_by_frozen_catalogue).

## Validated paths

| What | Path | Notes |
|---|---|---|
| Source corpus | `/home/imran/temp/scansort-staging` | 7 PDFs |
| Test vault | `/home/imran/temp/test.ssort` | Created via create_vault; delete at cycle end |
| Library on disk | `~/.local/share/scansort/library.rules.json` | OS XDG dir, NOT under Minerva app_userdata (hint `scansort/library_disk_path`) |
| Library snapshot | `/tmp/lib_snapshot_iter.json` | Write at iter start; restore at iter end |
| Minerva log | `/tmp/minerva_<tag>.log` | nohup target |
| Window ID | `xdotool search --name "Minerva"` | Returns inner WID; export `DISPLAY=:1` first |
| Plugin entrypoint | `~/github/plugins/scansort/scansort-plugin` | Must be `cp`'d from target/release after every build |

## Important session hints (find via nudge_query)

- `scansort/build_binary_install_step` (docket `019e3ca20686...`) — **CRITICAL**: cargo build writes to target/release; manifest entrypoint is `./scansort-plugin` — must cp manually
- `scansort/library_disk_path` (nudge, this session) — library at `~/.local/share/scansort/library.rules.json` not under Minerva
- `scansort/panel_file_menu_location` (nudge) — get_editor_actions ~line 2982, MenuButton ids 0/1/2/3/4/5/7/11/12/13 (id 2 now = "Close" session-reset, no longer "Close Vault")
- `scansort/session_module_layout` (nudge) — session.rs thread-local pattern; reset() helper now EXISTS (added in `019e3d67`)
- `scansort/condition_node_schema` (nudge) — rule conditions JSON shape
- `scansort/phase1_scoring_does_not_extract_fields` (nudge) — historical; B-fallback now runs stages-before-conditions
- `minerva-plugin-mcp/plugin_start_arg_name` (nudge) — `{"id": "..."}` not `{"plugin_id": "..."}`
- `minerva-mcp/close_editor_takes_name` (nudge) — `{"editor_name": "..."}` not `{"index": N}`
- `scansort/session_open_vault_doesnt_create` (nudge) — must create_vault before session_open_vault
- `claude_code/mcp_new_tools_blocked_by_frozen_catalogue` (docket `019e3d9c2e85`) — `/mcp` reconnect needed when DCR adds a new tool
- `claude_code/toolsearch_select_max_results` (nudge) — ToolSearch select: respects max_results, default 5 silently drops extras

## Hard rules (carry-forward)

- Per-file `git add` only. No `git add -A` / `git add .`.
- No `--no-verify`. No `--no-gpg-sign`.
- No `vendor/` touches.
- No `git reset --hard`, no destructive ops without explicit auth.
- No force-push.
- pkill target is `godot`, not `Minerva`.
- Source is read-only — scansort copies to destinations, never alters source.
- Rubric: reliability → durability → cost (S≤100, M 101-1000, L>1000) → debuggability → discoverable (weight last two heavily).

## Cold-start procedure for next session

1. `git -C ~/github/plugins log --oneline -5` — confirm `167c1fc` at tip
2. `git -C ~/github/Minerva log --oneline -3` — confirm latest Minerva HEAD
3. Read this pickup.md
4. Ask user what mission to take on (no pinned DCR)
5. If implementing: per cycle policy → snapshot library → sub-agent dispatch → review → cp binary → restart → R1 + new-feature verification

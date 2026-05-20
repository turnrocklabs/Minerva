# Pickup — scansort panel pipeline

STATE: `SCANSORT_PANEL_WORKING`

Last updated: 2026-05-19 — panel Process All migrated to the path-free `process()` pipeline; end-to-end filing works.

## What shipped this session (2026-05-19)

| Commit (plugins) | What |
|---|---|
| `167c1fc` | DCR `019e3d67` — File→Close session reset (in-memory) |
| `c3a5591` | DCR `019e41a5` — File→Clear Cache (wipes source `.scansort-state.json`) |
| `013d45c` | bug `019e41e1` + DCR `019e4281` — `year` lax-i32 deserializer; `run_rule_engine` library fallback; `copy_to` optional (empty/unresolvable → all open vaults) |
| `4d25b19` | DCR `019e4291` — panel Process All migrated to path-free `minerva_scansort_process` (stages run → real rename values) |

**Plugins HEAD:** `4d25b19` on `main` (pushed). **Tests:** 312 unit + 6 manifest, green.

## Scansort state

Panel Process All works end-to-end: open a vault + source via the panel, Process All → `minerva_scansort_process` classifies, runs the B-fallback rule engine with stages, fans out to all open vaults (empty `copy_to` model). Files land with real `{year}_{issuer}_{doc_type}` names.

## Open items (docket)

- **bug `019e41c0bb36`** — `minerva_scansort_classify_document` with plain `model:"default"` (no model_spec) errors instead of resolving to the chat-panel model. Workaround: set a Settings model override. Not blocking — panel always sends model_spec.
- **bug `019e41e1`** — Process All STDIO timeout. process() is now ONE long MCP call covering all files; the `conn.call_tool` timeout bounds the whole batch. Large cold-start runs (first file loads the model) can still time out. Needs a longer timeout or progress streaming.
- **DCR `019e4291` deferred follow-ups:**
  - Remove dead per-file helpers in `ScansortPanel.gd`: `_process_one_source_file`, `_check_near_dup`, `_show_dedup_disposition`, `_append_audit_rows` (~400 lines, unreferenced after the migration).
  - Interactive near-dup disposition prompt dropped for v1 — process() auto-handles dedup headlessly. Revisit if users want the prompt back.
- **DCR `019e4281` deferred** — Rules Editor `copy_to` field should become a picker sourced from the live vault/dir list (currently free text).

## Key facts (find via nudge_query / docket_hint)

- `scansort/build_binary_install_step` (docket `019e3ca2…`) — **CRITICAL**: cargo writes to `target/release`; entrypoint `./scansort-plugin` is a manual `cp`. Skipping it runs the OLD binary.
- Mid-session binary swap without restarting Minerva: `minerva_plugin_stop` → `cp` → `minerva_plugin_start`.
- `claude_code/mcp_new_tools_blocked_by_frozen_catalogue` (docket `019e3d9c…`) — a NEW MCP tool added mid-session isn't callable until the user runs `/mcp` to reconnect.
- `plugin-substrate/godot_dict_to_rust_serde_int_fix` (docket `019e41e9…`) — GDScript serializes ints as floats; Rust `i32` serde fields need a lax deserializer.
- `plugin-substrate/host_notify_unified_logger` (docket `019e41dd…`) — `host.notify` JSON-RPC notification → toast + Activity:MCP tab.
- `scansort/copy_to_resolves_against_registry_not_session` (nudge) — three distinct destination concepts; see DCR `019e4281`.
- `scansort/library_disk_path` (nudge) — library at `~/.local/share/scansort/library.rules.json`.

## Validated paths

| What | Path |
|---|---|
| Source corpus | `/home/imran/temp/scansort-staging` (7 PDFs) |
| Test vault | `/home/imran/temp/vaults/ui_test.ssort` (delete + recreate for a clean run — vault dedup skips files already filed) |
| Rule library | `~/.local/share/scansort/library.rules.json` |
| Dest registry | `~/.local/share/godot/app_userdata/Minerva/dest_registry.json` |
| Plugin entrypoint | `~/github/plugins/scansort/scansort-plugin` (manual `cp` from `target/release`) |

## Hard rules (carry-forward)

- Per-file `git add` only. No `git add -A` / `git add .`.
- No `--no-verify`. No `--no-gpg-sign`.
- No `vendor/` touches. No committing `src/addons/sightline_probe/` or `project.godot` with that addon enabled.
- No `git reset --hard`, no force-push, no destructive ops without explicit auth.
- pkill target is `godot`, not `Minerva`.
- Source is read-only — scansort copies to destinations, never alters source.
- High PII/HBI risk — never commit fixture PDFs, `.ssort` vaults, audit logs, or `.scansort-state.json`.
- Rubric: reliability → durability → cost → debuggability → discoverable.

## Cold-start procedure for next session

1. `git -C ~/github/plugins log --oneline -5` — confirm `4d25b19` at tip
2. `git -C ~/github/Minerva log --oneline -3`
3. Read this pickup.md
4. Ask the user which open item to take on (dead-code cleanup is the smallest; bug `019e41e1` timeout is the most user-visible).

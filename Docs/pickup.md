# Pickup — scansort panel pipeline

STATE: `SCANSORT_STOP_BUTTON_HITL`

Last updated: 2026-05-19 — Stop button made functional via windowed per-file
`process()` loop; ~540 lines of dead pipeline code removed. **Awaiting HITL.**

## Current task — DCR `019e42e4` (status: reviewing / HITL)

`scansort: functional Stop button via windowed process() loop + dead-code removal`

**Done (autonomous):**
- Rust — `minerva_scansort_process` gained `offset`/`limit` params that window
  the flat source-file list; `process::run()` returns `total_files` (true
  pre-window count). `in_offset_limit_window` helper + 4 unit tests.
- Panel — `_on_process_all_pressed` rewritten as a thin per-file pagination
  loop: one `process()` call per file (`offset=k, limit=1`), checking
  `_process_cancelled` between calls. Stop halts at the next file boundary.
  `_stop_btn` is now enabled during a run; `_on_stop_pressed` wired.
- Dead code removed — `_process_one_source_file`, `_append_audit_rows`,
  `_check_near_dup`, `_show_dedup_disposition`, the two dedup-dialog handlers,
  dead member vars, the stale W10 doc block (544 lines); deleted
  `ui/dedup_disposition_dialog.gd`.
- `cargo test` 316 unit + 6 manifest green. New binary deployed (plugin
  stop/cp/start). `minerva_scansort_process` accepts `offset`/`limit` and
  returns `total_files` — Rust path smoke-verified over MCP.

**HITL test (next — this is the pickup):**
1. Open the Scansort panel (close + reopen it so the new `ScansortPanel.gd`
   loads — panel scripts are re-read on panel open).
2. Open vault `ui_test.ssort` + source `scansort-staging` via the panel.
3. Click **Process All** — confirm files classify + file, status shows
   `Processing N/total…`, end summary reads `Processed N/total — …`.
4. Run again, and **press Stop mid-run** — confirm it halts at the next file
   boundary and the status reads `Stopped after K/total — …`.
5. If the panel fails to load, a GDScript dangling reference slipped through
   the dead-code removal — check the Godot editor error log.

After HITL passes: commit (plugins + Minerva), transition DCR `019e42e4`
→ shipped, resolve bug `019e41e1`.

## What shipped earlier this session (2026-05-19)

| Commit (plugins) | What |
|---|---|
| `167c1fc` | DCR `019e3d67` — File→Close session reset (in-memory) |
| `c3a5591` | DCR `019e41a5` — File→Clear Cache (wipes source `.scansort-state.json`) |
| `013d45c` | bug `019e41e1` groundwork + DCR `019e4281` — `year` lax-i32; `run_rule_engine` library fallback; `copy_to` optional |
| `4d25b19` | DCR `019e4291` — panel Process All migrated to path-free `minerva_scansort_process` |

**Plugins HEAD:** `4d25b19` on `main`. The DCR `019e42e4` changes are
**uncommitted** pending HITL.

## Open items (docket)

- **bug `019e41e1`** — Process All STDIO timeout. **Addressed by DCR
  `019e42e4`**: process() is now called one file at a time, so the connection
  timeout bounds a single file, not the whole batch. Resolve after HITL.
- **bug `019e41c0bb36`** — `minerva_scansort_classify_document` with plain
  `model:"default"` (no model_spec) errors instead of resolving to the
  chat-panel model. Workaround: set a Settings model override. Not blocking —
  the panel always sends model_spec.
- **Dead-code follow-up (separate pass)** — the session-marks sub-cluster is
  also dead: `_processed_keys` / `_low_confidence_keys` /
  `clear_processed_state` / `_push_session_marks_to_provider` in
  `ScansortPanel.gd`, plus `set_session_marks` + the `is_low_conf` display
  branch in `scan_tree_source_provider.gd`. Left for a focused pass because it
  spans the source-tree display path in a second file. Harmless meanwhile
  (operates on permanently-empty dicts).
- **DCR `019e4281` deferred** — Rules Editor `copy_to` field should become a
  picker sourced from the live vault/dir list (currently free text).

## Key facts (find via nudge_query / docket_hint)

- `scansort/build_binary_install_step` (docket `019e3ca2…`) — **CRITICAL**:
  cargo writes to `target/release`; entrypoint `./scansort-plugin` is a manual
  `cp`. Skipping it runs the OLD binary.
- Mid-session binary swap without restarting Minerva: `minerva_plugin_stop`
  → `cp` → `minerva_plugin_start`. Stopping the plugin resets the in-process
  session — the panel must re-open the vault + source afterwards.
- `claude_code/mcp_new_tools_blocked_by_frozen_catalogue` (docket `019e3d9c…`)
  — a NEW MCP tool added mid-session isn't callable until the user runs `/mcp`.
  NOTE: adding *params* to an existing tool does NOT need `/mcp` — the plugin
  handler reads args directly and JSON schema allows extra properties.
- `plugin-substrate/godot_dict_to_rust_serde_int_fix` (docket `019e41e9…`) —
  GDScript serializes ints as floats; Rust deserializers need lax handling.
  Same gotcha applies to `Value::as_u64()` on `0.0` — use an `as_f64` fallback
  (see `lax_usize` in `handle_process`).

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
- No `vendor/` touches. No committing `src/addons/sightline_probe/` or
  `project.godot` with that addon enabled.
- No `git reset --hard`, no force-push, no destructive ops without explicit auth.
- pkill target is `godot`, not `Minerva`.
- Source is read-only — scansort copies to destinations, never alters source.
- High PII/HBI risk — never commit fixture PDFs, `.ssort` vaults, audit logs,
  or `.scansort-state.json`.
- Rubric: reliability → durability → performance → debuggability → cost → discoverable.

## Cold-start procedure for next session

1. `git -C ~/github/plugins log --oneline -5` — confirm `4d25b19` at tip
   (DCR `019e42e4` not yet committed unless HITL already passed).
2. `git -C ~/github/Minerva log --oneline -3`
3. Read this pickup.md.
4. If HITL not yet done: run the HITL test above. If it passed: commit + ship.

# Pickup — Scansort plugin U-series (autonomous run U2–U8 COMPLETE; combined HITL next)

Last updated: 2026-05-14 (end of autonomous U2–U8 run)

## Where I left off

Active workstream: **Scansort plugin DCR — U-series experiment-parity port**.
- Parent DCR: `minerva:019e1cdb451076ae8c344f6e6ec605e1` ("Scansort plugin — functionally-equivalent redesign").
- Gap-analysis bug: `minerva:019e24c57af676bc85e8f76db501e797` (the T7 port dropped the experiment's interaction layer).
- U-series work_item: `minerva:019e24c5d53876098676f4f66b161222` — **in_progress**. Round list + locked design decisions in its description; per-round status in comments 350–358.

**Autonomous run U2→U8 is COMPLETE.** Ran via the work-cycle pattern (Sonnet implementer + cold Opus reviewer + Layer-1 structural gate + per-round WIP commit, both repos, no worktrees — sequential rounds on the branches). All rounds committed + cold-reviewed + Layer-1 green.

**NEXT: combined full-stack HITL** (see below). After HITL passes: **U9 is a DESIGN GATE — stop**, do not auto-implement watch folders. **U10** (docs + delete orphaned files) comes last.

## Commits (pushed? NO — local only, push before switching machines)

| Round | plugins `main` | Minerva `user/imran/experiments/swarm` |
|---|---|---|
| U1 (pre-run) | `33d9f04` | `46365da8` |
| U2 source backend | `52b4843` | `a0e2a7a1` |
| U3 destination backend | `cb8530a` | (plugins-only) |
| U4 2-col layout + chrome buttons | `fb3d5bf` + `bddb5f8` | `fa5e3396` + `477670f9` |
| U5 Process All pipeline | `f31a42b` | `ec7eeeaf` + `4d8f8864` (pickup) |
| U6 manual review + inject-to-chat | `356447e` | `12abd41` |
| U7 vault_and_disk | `f80f21e` | `b9fc1cf` |
| U8 recovery sheet dialog | `d3b6962` | `dcd4a53` |

Current HEADs: plugins `d3b6962`, Minerva `dcd4a53`. **Not yet pushed** — `git push` both before moving machines.
Test baselines: Rust `cargo test --release` **71/0**; panel smoke **225/0**.

## What landed U6–U8

- **U6 — manual review + inject-to-chat** (GDScript-only). `scan_tree.gd` drag-and-drop (`tree_role`, `file_dropped` signal, `DROP_MODE_ON_ITEM`, `_get_drag_data`/`_can_drop_data`/`_drop_data`). Drag-to-classify (source row → vault category folder → extract→dedup→insert with confidence 1.0, NO AI classify). Drag-to-reclassify (vault doc → folder → update_document). Export Marked: vault-tree checkboxes = transitory export marks, "Export Marked to Disk…" File-menu item (id 12). Inject-to-Chat: source-tree checked files pre-extracted on `check_toggled` into `_inject_payload_cache`; `_on_panel_create_note_request` returns it **synchronously** (the host does not await that hook — see nudge `minerva-plugin-platform/create_note_hook_is_synchronous`).
- **U7 — vault_and_disk**. Rust `list_disk_files` (recursive walk of `disk_root`, `Ok(empty)` when unset/missing). `scan_tree_disk_provider.gd` (new). Stacked DestPane: vault tree above disk tree. Process All rebuilt as a **batched-parallel** driver — `_process_one_source_file` fired N-at-a-time per the per-user concurrency setting (1–4), counters in `_run_counters`, batch drained on `process_frame`. Settings dialog: per-vault destination-mode picker (`vault_only`/`disk_only`/`vault_and_disk`) + disk_root field + Browse; per-user concurrency SpinBox. `ScansortSettings` refactored to read-modify-write so `model_override` + `process_concurrency` coexist.
- **U8 — recovery sheet dialog**. Rust `get_project_keys` (read multiple project keys, missing → `""`). `recovery_sheet_dialog.gd` (new): edits `emergency_contact_*` + `extraction_guide` project keys (written via `update_project_key` — its param is `path`, NOT `vault_path`); "Generate Recovery Sheet…" writes a plain-text sheet (vault info, category breakdown, password hint, emergency contact, custom-or-default SQLite-fallback guide). No PDF/QR — text built panel-side, no new Rust deps. "Recovery Sheet…" File-menu item (id 13).

## NEXT: combined full-stack HITL

Full-stack HITL driven **through the panel UI, not raw MCP** (user constraint):
- Test PDFs in `~/Downloads`: 10 PDFs (8 physics/school, 1 `receipt.pdf`, 1 WA-ferries doc).
- Test dir `~/scansort-test/` should be empty + clean before starting.
- The plugin binary is gitignored — rebuild + install before testing (see checklist).

**HITL pass criteria:**
1. Open/create a vault via File menu. Set a source directory (MCP `set_source_dir` or a UI picker) pointing at `~/Downloads`.
2. Source pane lists the PDFs; in-vault files show the `✓` mark.
3. Process All (chrome bar button) runs the batch: files flow source → classified → vault, `✓` marks appear, the summary status line is sane (processed/low-confidence/failed/skipped). Stop button cancels mid-run.
4. Concurrency SpinBox in Settings (1–4) is honoured by Process All.
5. Drag a source row onto a vault category folder → file is filed into that category. Drag a vault doc onto a different category folder → it is reclassified.
6. Check some vault rows, "Export Marked to Disk…" → files land under the configured `disk_root` (set destination to `disk_only`/`vault_and_disk` first via Settings). Disk pane (bottom-right) shows them.
7. Check some source rows, toggle the chrome "inject to chat" button → a text note with the extracted contents reaches the chat.
8. Recovery Sheet… dialog: edit emergency contact + extraction guide, Save; "Generate Recovery Sheet…" writes a readable .txt.

## Cold-pickup checklist

1. `git -C ~/github/Minerva fetch && git checkout user/imran/experiments/swarm && git pull --ff-only`
2. `git -C ~/github/plugins fetch && git checkout main && git pull --ff-only`
3. Rebuild + install the plugin binary (gitignored; source-only in repo):
   ```
   cd ~/github/plugins/scansort && cargo build --release && install -m 0755 target/release/scansort-plugin scansort-plugin
   ```
4. Smoke-check Layer-1:
   ```
   cd ~/github/Minerva
   godot --headless --path src --script test/test_scansort_panel_smoke.gd   # expect 225/0
   cd ~/github/plugins/scansort && cargo test --release                     # expect 71/0
   ```
5. Reload the docket if `minerva.dct` changed underfoot: `docket_project_remove` then `docket_project_add` (the server keeps a stale in-memory copy after a git pull). `docket_get`/`docket_transition` need `project: "minerva"` explicitly — the primary project is `docket`, not `minerva`.
6. Resume at the combined HITL.

## Build / test commands

- Rust build: `cd ~/github/plugins/scansort && cargo build --release`
- Install binary (NOT `cp` — ETXTBSY): `install -m 0755 target/release/scansort-plugin scansort-plugin`
- Rust tests: `cargo test --release` (71/0 after U8)
- Layer-1 panel smoke: `godot --headless --path src --script test/test_scansort_panel_smoke.gd` (225/0 after U8)
- macOS has no `timeout` — run `godot` directly.

## Constraints to carry forward

- All testing goes through MCP tools or the panel UI — do not hand-write rules/vault files.
- Off-tree plugin scripts (`~/github/plugins/`) use `preload()` + base-class typing — no `class_name` for cross-script types. `scan_tree.gd` is the shared component — providers extend `scan_tree_provider.gd` (which `extends RefCounted`, so never `.free()` a provider instance in tests).
- Plugin MCP tool names must be `minerva_<plugin_id>_*`.
- GDScript JSON round-trip turns ints into floats — coerce with `int(...)`.
- Plugin binary rebuild while Minerva runs: `install -m 0755`, not `cp` (ETXTBSY).
- `_on_panel_create_note_request` MUST be synchronous — the host does not await it. Pre-cache async data on a trigger signal. (`_on_panel_inject_toggle_changed` IS fire-and-forget, can be async.)
- `update_project_key`'s param is `path`, not `vault_path`. Other tools use `vault_path`.
- MCP envelope is non-uniform: `extract_text`/`render_pages` return flat `success`; `check_sha256` returns `{found,doc_id}`; `classify_document`/`insert_document`/`get_destination`/`set_destination`/`get_project_keys`/`list_disk_files` return `{ok,...}`.
- Chrome bar (`get_editor_actions`): returned Controls inserted before "Save All", in array order; the editor owns + frees them, so guard member refs with `is_instance_valid`. Chat icons: send = `res://assets/icons/send_icons/send_icon_24_no_bg.png`, stop = `res://assets/icons/stop_icons/stop-sign-24.png`.

## After HITL

- **U9 — watch folders. DESIGN GATE — stop.** Needs a design decision first (daemon-in-Rust vs. panel-poll). Do not auto-implement.
- **U10 — docs + wrap.** Delete orphaned `vault_view.gd` + `edit_details_dialog.gd` (unwired since the U4 layout rewrite).

## Paused workstreams (orthogonal, not picking up)

- Presentation plugin v2 MCP iteration — plan `019df419ce567de0b7699b3be7b6c8b5`.
- CAD Phase B2 — blocked on bug `019dec49988b7091933371908d6bbb00`. NOTE: `~/github/plugins/` has uncommitted CAD changes (CADPanel.gd, Cad_GeometryOverlay.gd, evaluator.py) from 2026-05-11 — untouched by the U-series, left as-is.

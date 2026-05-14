# Pickup — Scansort plugin U-series (autonomous run: U1–U5 done, U6 next)

Last updated: 2026-05-14 (mid autonomous U-series run; compaction point after U5)

## Where I left off

Active workstream: **Scansort plugin DCR — U-series experiment-parity port**.
- Parent DCR: `minerva:019e1cdb451076ae8c344f6e6ec605e1` ("Scansort plugin — functionally-equivalent redesign").
- Gap-analysis bug: `minerva:019e24c57af676bc85e8f76db501e797` (the T7 port dropped the experiment's interaction layer).
- U-series work_item: `minerva:019e24c5d53876098676f4f66b161222` — **in_progress**. Live round list + locked design decisions live in its description; per-round status in its comments (350–355).

**Autonomous run in progress**: U2→U8 via the work-cycle pattern (Sonnet implementer + cold Opus reviewer + Layer-1 structural gate + per-round WIP commit, both repos). No git worktrees — sequential rounds commit directly on the branches. U9 is a design gate (stop). Combined full-stack HITL runs after U8.

**U1–U5 are DONE and committed. U6 is next.**

## Commits (pushed? NO — local only, push before switching machines)

| Round | plugins `main` | Minerva `user/imran/experiments/swarm` |
|---|---|---|
| U1 (pre-run) | `33d9f04` | `46365da8` |
| U2 source backend | `52b4843` | `a0e2a7a1` |
| U3 destination backend | `cb8530a` | (plugins-only) |
| U4 2-col layout + chrome buttons | `fb3d5bf` + `bddb5f8` | `fa5e3396` + `477670f9` |
| U5 Process All pipeline | `f31a42b` | `ec7eeeaf` |

Current HEADs: plugins `f31a42b`, Minerva `ec7eeeaf`. **Not yet pushed** — `git push` both before moving machines.

## What landed U2–U5

- **U2 — source backend.** `src/source.rs` (new): transitory thread_local source-dir state (never persisted) + `set_source_dir`/`get_source_dir`/`list_source_files` MCP tools. `list_source_files` returns `{path,name,size,sha256,in_vault}`. `ui/scan_tree_source_provider.gd` (new).
- **U3 — destination backend.** `src/destination.rs` (new): per-vault destination setting (`vault_only`/`disk_only`/`vault_and_disk`) in the `project` key-value table + `place_on_disk` (templated `{year}`/`{date}` subfolders, `../` sanitised, collision-safe copy). Plugins-only.
- **U4 — panel layout.** `ScansortPanel._build_ui` rewritten: **2-column HBox (SourcePane | DestPane) + status panel as a bottom bar**. Process All / Stop / File menu live in the **editor chrome bar** via `get_editor_actions()` (not in the panel). Chrome buttons use the chat panel's submit/stop icons. (Started as 3-column "Option A"; reworked to 2-column after the visual checkpoint — user feedback.)
- **U5 — Process All pipeline.** `_on_process_all_pressed` batch loop: per source file extract→dedup→classify(text/vision)→`insert_document`. Skips in-vault/processed; one bad file continues, never aborts. `_on_stop_pressed` cancel flag; `clear_processed_state()`. `scan_tree_source_provider` shows a `✓ ` prefix on done files. No disk placement yet (U6/U7).

## NEXT: U6 — manual review + inject-to-chat

From the U-series work_item description (U6 entry) + docket comment 354:
- **Manual review**: drag-to-classify (source row → category), drag-to-reclassify (vault file → folder), mark-for-export (transitory session state, NOT a durable column) + an **Export Marked** button.
- **Inject to Chat** (folded into U6, decided 2026-05-14): a checked-files bulk action — extract the selected source files' contents and feed them to chat via Minerva's plugin inject substrate (`PluginScenePanelHost.invoke_inject_toggle` / the `inject_toggle` chrome action). NOT a parity gap — new scope. Building blocks exist: `scan_tree.get_checked_keys()`, the `extract_text`/`extract_document` MCP tools (T6).
- U6 is the **heaviest remaining round** — drag-and-drop in `scan_tree` + a new bulk action + chat-injection wiring. Read `scan_tree.gd` (esp. `_on_gui_input` / signals), `ScansortPanel.gd`, and how Minerva's `inject_toggle` substrate works (`Editor.gd` ~line 2303, `PluginScenePanelHost.invoke_inject_toggle`).

Then: **U7** vault_and_disk (stacked right pane + DiskProvider + Settings destination-mode picker + concurrency spinbox), **U8** recovery sheet dialog, → **combined HITL**, then **U9** watch-folders (DESIGN GATE — stop), **U10** docs + delete orphaned `vault_view.gd`/`edit_details_dialog.gd`.

## Combined HITL (blocked behind U8)

Full-stack HITL driven **through the panel UI, not raw MCP** (user constraint): 10 test PDFs in `~/Downloads` (8 physics/school, 1 `receipt.pdf`, 1 WA-ferries doc); test dir `~/scansort-test/` empty + clean. Pass = files flow source → classified → vault, ✓ marks appear, Process All summary is sane, drag-reclassify works, Export Marked + Inject-to-Chat work.

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
   godot --headless --path src --script test/test_scansort_panel_smoke.gd   # expect 175/0
   cd ~/github/plugins/scansort && cargo test --release                     # expect 67/0
   ```
5. Reload the docket if `minerva.dct` changed underfoot: `docket_project_remove` then `docket_project_add` (the server keeps a stale in-memory copy after a git pull). `docket_get` needs `project: "minerva"` explicitly — the primary project is `docket`, not `minerva`.
6. Resume at U6.

## Build / test commands

- Rust build: `cd ~/github/plugins/scansort && cargo build --release`
- Install binary (NOT `cp` — ETXTBSY): `install -m 0755 target/release/scansort-plugin scansort-plugin`
- Rust tests: `cargo test --release` (67/0 after U3)
- Layer-1 panel smoke: `godot --headless --path src --script test/test_scansort_panel_smoke.gd` (175/0 after U5)
- macOS has no `timeout` — run `godot` directly.

## Constraints to carry forward

- All testing goes through MCP tools or the panel UI — do not hand-write rules/vault files.
- Off-tree plugin scripts (`~/github/plugins/`) use `preload()` + base-class typing — no `class_name` for cross-script types. `scan_tree.gd` is the shared component — providers extend `scan_tree_provider.gd` (which `extends RefCounted`, so never `.free()` a provider instance in tests).
- Plugin MCP tool names must be `minerva_<plugin_id>_*`.
- GDScript JSON round-trip turns ints into floats — coerce with `int(...)`.
- Plugin binary rebuild while Minerva runs: `install -m 0755`, not `cp` (ETXTBSY).
- Chrome bar (`get_editor_actions`): returned Controls are inserted before "Save All", in array order; the editor owns + frees them, so guard member refs with `is_instance_valid`. Chat icons: send = `res://assets/icons/send_icons/send_icon_24_no_bg.png`, stop = `res://assets/icons/stop_icons/stop-sign-24.png`.
- MCP envelope is non-uniform: `extract_text`/`render_pages` return flat `success`; `check_sha256` returns `{found,doc_id}`; `classify_document`/`insert_document` return `{ok,...}`.

## Paused workstreams (orthogonal, not picking up)

- Presentation plugin v2 MCP iteration — plan `019df419ce567de0b7699b3be7b6c8b5`.
- CAD Phase B2 — blocked on bug `019dec49988b7091933371908d6bbb00`.

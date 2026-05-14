# Pickup — Scansort filing-engine DCR (W1–W10 shipped; next is W11, the combined HITL)

Last updated: 2026-05-14 (after the autonomous W2–W10 run)

## Where I left off

**Active workstream: Scansort filing-engine redesign — DCR `minerva:019e2787d0e178029cd46b93059f7ed9`** ("Scansort filing engine — two-phase rules + multi-destination routing + semantic dedup + audit log"). Status: **approved**, P0.

**W1–W10 are all shipped** (10 work-cycle rounds, Sonnet/Opus implementer + cold Opus reviewer + Layer-1 gate + per-round WIP commit, both repos, no worktrees). **NEXT: W11 — the single combined full-stack HITL.** W11 absorbs the paused U-series HITL (`019e24c5`) — do not run that separately; W11's scope covers re-validating the U-series substrate AND the W-series filing engine together.

## Status of the 12 work_items

| | ID (prefix) | Title | Status |
|---|---|---|---|
| W1 | `019e27b05586` | rule schema v2 + sender→issuer rename | **done** |
| W2 | `019e27b067ec` | Phase 1 classification: facts + per-rule signals | **done** |
| W3 | `019e27b07ca3` | Phase 2 deterministic rule engine | **done** |
| W4 | `019e27b0930a` | destination registry (backend) | **done** |
| W5 | `019e27b0a831` | destination registry UI (stacked sub-trees) | **done** |
| W6 | `019e27b0be91` | copy_to fan-out + per-destination processed-state | **done** |
| W7 | `019e27b0d89a` | three-layer dedup + review-disposition flow | **done** |
| W8 | `019e27b0ebe6` | reprocess + locked/final flag | **done** |
| W9 | `019e27b1007c` | audit log | **done** |
| W10 | `019e27b11549` | Process All integration | **done** |
| W11 | `019e27b12f7c` | combined full-stack HITL | **backlog ← NEXT** |
| W12 | `019e27b13ec0` | docs + cleanup | backlog (after W11) |

## Current HEADs (both pushed)

- Plugins `main`: `6ffd750` (W1–W10, 10 WIP commits on top of U8's `d3b6962`).
- Minerva `user/imran/experiments/swarm`: `619e398c` (5 smoke-test commits for the UI rounds W5/W7/W8/W10 + W9 — W1/W2/W3/W4/W6 were Rust-only).
- Plugin binary rebuilt + installed (`install -m 0755`, 2026-05-14) — has all the W-series MCP tools.

## Test baselines (as of W10)

- Rust `cargo test --release`: **205/0** (was 71/0 at U8 — W1–W9 added 134 tests).
- Panel smoke `godot --headless --path src --script test/test_scansort_panel_smoke.gd`: **326/0** (was 225/0 at U8 — Groups T/U/V/W/X added).

## What W11 (the HITL) must cover

W11 is the **one** human-in-the-loop gate for the whole filing-engine + U-series substrate. Its test plan must exercise, through the real panel UI with the real plugin binary:

- **Destination registry** (W4/W5): add/remove vault + directory destinations; the right column renders N stacked sub-trees.
- **Two-phase Process All** (W2/W3/W6/W10): rules with v2 conditions/exceptions/order/stop_processing; classify → deterministic rule walk → fan-out `copy_to` to multiple destinations; copy-never-move.
- **Dedup** (W7): exact-SHA auto-skip; near-dup (simhash/dhash) flags a disposition prompt — keep both / replace / skip — and NEVER auto-drops. (Logical-identity layer is NOT wired — see gaps below.)
- **Reprocess + locked flag** (W8): per-destination reprocess with confirm; a locked destination refuses reprocess.
- **Audit log** (W9): toggle on, point at an external path, confirm one CSV row per placement.
- **U-series substrate** (U2–U8): source pane, recovery sheet, inject-to-chat, Export Marked still work.

The combined HITL was paused during U-series setup when the user found the single-vault structural gap (tax docs cross years/vaults; CPAs file per client/year). The realistic test: ask the LLM to create rules, point at real PDFs in `~/Downloads`, drive Process All across multiple destinations.

## Known gaps flagged at the W11 HITL handoff (docket comment 360 on W12)

1. **Logical-identity dedup is unreachable.** `dedup::check_logical_identity` (plugin `src/dedup.rs`) is a tested pure function with NO MCP tool and NO caller. The DCR's three-layer dedup is currently **2 layers wired** (simhash + dhash). Safety is unaffected — the only-exact-SHA-auto-skips HARD CONSTRAINT is fully satisfied. W12 should wire it or descope it in the docs.
2. **"replace" disposition is place-alongside only.** W10 maps the dialog's "replace" choice to a normal collision-safe placement + an audit row recording intent — it does NOT supersede/delete the existing file (`place_fanout` has no replace mode). Give it real semantics or document the limitation.
3. **Smoke coverage gaps:** no test for the "replace" disposition path or the no-rule-fired branch in Process All.

## Cold-pickup checklist

1. `git -C ~/github/Minerva fetch && git checkout user/imran/experiments/swarm && git pull --ff-only`
2. `git -C ~/github/plugins fetch && git checkout main && git pull --ff-only`
3. Rebuild + install the plugin binary (gitignored; source-only in repo):
   ```
   cd ~/github/plugins/scansort && cargo build --release && install -m 0755 target/release/scansort-plugin scansort-plugin
   ```
4. Smoke-check Layer-1:
   ```
   cd ~/github/Minerva && godot --headless --path src --script test/test_scansort_panel_smoke.gd   # expect 326/0
   cd ~/github/plugins/scansort && cargo test --release                                            # expect 205/0
   ```
5. Reload the docket if `minerva.dct` changed underfoot: `docket_project_remove` then `docket_project_add`. `docket_get`/`docket_transition` need `project: "minerva"` explicitly.
6. Read DCR `019e2787` + work_item W11 (`019e27b12f7c`). Run the combined HITL.

## How to run implementation

Work-cycle pattern (Sonnet implementer + cold Opus reviewer + Layer-1 structural gate + per-round WIP commit, both repos, no worktrees, sequential rounds). W11 is human-gated — it is NOT a work-cycle round; it is a manual test session with the user. W12 (docs + cleanup) is a work-cycle round AFTER the HITL.

## Build / test commands

- Rust build: `cd ~/github/plugins/scansort && cargo build --release`
- Install binary (NOT `cp` — ETXTBSY): `install -m 0755 target/release/scansort-plugin scansort-plugin`
- Rust tests: `cargo test --release` (205/0 as of W10)
- Layer-1 panel smoke: `godot --headless --path src --script test/test_scansort_panel_smoke.gd` (326/0 as of W10)
- macOS has no `timeout` — run `godot` directly.

## Constraints to carry forward

- All testing goes through MCP tools or the panel UI — do not hand-write rules/vault files.
- Off-tree plugin scripts (`~/github/plugins/`) use `preload()` + base-class typing — no `class_name`. `scan_tree` providers extend `scan_tree_provider.gd` (`extends RefCounted` — never `.free()` a provider).
- Plugin MCP tool names must be `minerva_<plugin_id>_*`.
- GDScript JSON round-trip turns ints into floats — coerce with `int(...)`.
- Plugin binary rebuild while Minerva runs: `install -m 0755`, not `cp` (ETXTBSY).
- `_on_panel_create_note_request` MUST be synchronous — the host does not await it. (`_on_panel_inject_toggle_changed` IS fire-and-forget, can be async.)
- The filing-engine rule schema is v2: rules carry `conditions`/`exceptions` (recursive all/any `ConditionNode` tree), `order`, `stop_processing`, `copy_to` (list of destination ids). The document field is `issuer` (was `sender`); `{sender}` still works as a rename-token alias.
- The destination registry is a host-provided JSON file (`registry_path`); a destination = `{id, kind: vault|directory, path, label, locked}`.
- New W-series MCP tools: `run_rule_engine`, `destination_{add,list,remove}`, `place_fanout`, `scan_directory_hashes`, `check_simhash`, `check_dhash`, `reprocess_destination`, `set_destination_locked`, `audit_append`.

## Paused / orthogonal workstreams (not picking up)

- Presentation plugin v2 MCP iteration — plan `019df419ce567de0b7699b3be7b6c8b5`.
- CAD Phase B2 — blocked on bug `019dec49988b7091933371908d6bbb00`. NOTE: `~/github/plugins/` has uncommitted CAD changes (CADPanel.gd, Cad_GeometryOverlay.gd, evaluator.py) + a `presentation/presentation` binary — untouched by the filing-engine work, left as-is.

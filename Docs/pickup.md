# Pickup — Scansort filing-engine DCR (design done; implementation starts at W1 + W4)

Last updated: 2026-05-14 (after the multi-location design pass + DCR decomposition)

## Where I left off

**Active workstream: Scansort filing-engine redesign — DCR `minerva:019e2787d0e178029cd46b93059f7ed9`** ("Scansort filing engine — two-phase rules + multi-destination routing + semantic dedup + audit log"). Status: **approved**, P0 (docket priority 1).

The U-series (U2–U8) is done and committed, but its **combined HITL is paused** — during HITL setup the user identified a structural gap (scansort is single-vault; real filing crosses vaults — tax docs per year, CPAs per client/year). That triggered the P0 DCR. A full design pass was done with the user on 2026-05-14; the DCR description carries the settled design; it's been decomposed into 12 work_items.

**NEXT: start implementation at W1 + W4** (the two dependency roots — see build order below).

## The DCR design (settled spine — full detail in the DCR description)

1. **Two-phase processing** — Phase 1: LLM extracts facts (`year`, `issuer`, `amount`, `confidence`, …) + scores rule matches. Phase 2: deterministic ordered rule walk does the routing (auditable, replayable).
2. **Rule = category** — a rule bundles a semantic matcher (the LLM-facing instruction — *this defines the category*) + Outlook-style deterministic conditions/exceptions + actions + ordering/`stop_processing`. Extends the existing rule object. Conditions touch only content-derived + file facts, never transport metadata (email etc. = upstream plugins; filesystem is the handoff).
3. **Destinations** — a destination is a single target (vault file OR directory). A registry of them = the panel's right side (N stacked `scan_tree` sub-trees). A rule's `copy_to` action takes a **list** → fan-out (one doc → many destinations, e.g. car-accident → both litigation vaults). Copy, never move.
4. **Processed-state** — a destination is its own source of truth: vault → `check_sha256`; directory → content-hash scan rebuilt at run start (`(path,mtime,size)` cache). No central index. Identity = SHA-256 of contents, never filename.
5. **Reprocess** — directory: clear the folder; vault: explicit reprocess op (delete doc rows) gated by a `locked/final` flag. Default Process All stays additive + dedup-skip.
6. **Three-layer dedup** — exact SHA-256 (auto-skip) / near-dup `simhash`+`dhash` (flag) / logical-identity template-collision (flag). **Only exact auto-skips** — corrected/amended docs are near-identical *replacements*, not dups. Near-dup `simhash`/`dhash` is a parity restoration (experiment had it; T7 port still computes+stores them but dropped the query layer).
7. **Audit log** — append-only, user-specified external path, toggleable, one row per placement (fan-out = N rows), CSV-importable, superseded rows on reprocess. An export, never consulted for dedup decisions.

## The 12 work_items (all `backlog` under the DCR)

| | ID (prefix) | Title | Depends on |
|---|---|---|---|
| W1 | `019e27b05586` | rule schema v2 + sender→issuer rename | — (root) |
| W2 | `019e27b067ec` | Phase 1 classification: facts + per-rule match signals | W1 |
| W3 | `019e27b07ca3` | Phase 2 deterministic rule engine | W1 |
| W4 | `019e27b0930a` | destination registry (backend) | — (root) |
| W5 | `019e27b0a831` | destination registry UI (stacked sub-trees) | W4 |
| W6 | `019e27b0be91` | copy_to fan-out + per-destination processed-state | W4 |
| W7 | `019e27b0d89a` | three-layer dedup + review-disposition flow | W6, W2 |
| W8 | `019e27b0ebe6` | reprocess + locked/final flag | W6 |
| W9 | `019e27b1007c` | audit log | W6, W8 |
| W10 | `019e27b11549` | Process All integration | W2, W3, W5, W6, W7, W9 |
| W11 | `019e27b12f7c` | combined full-stack HITL | W10 |
| W12 | `019e27b13ec0` | docs + cleanup | W10 |

Each work_item description has scope / touches / depends-on / success criteria. W1 (condition grammar), W2 (LLM call shape), W9 (CSV column set) each resolve a deferred design detail inside the round.

**Build order (waves):**
- Wave 1 (parallel roots): **W1, W4**
- Wave 2: W2, W3 (after W1) · W5, W6 (after W4)
- Wave 3: W7 (W6+W2) · W8 (W6) · W9 (W6+W8)
- Wave 4: W10 (integration — pulls it all together)
- Wave 5: W11 (HITL) · W12 (docs/cleanup)

## State of the code (U2–U8 — the substrate this builds on)

U2–U8 committed, cold-reviewed, Layer-1-green. **Not lost** — it's the substrate. Reused largely as-is: U2 source backend, U4 panel shell, U8 recovery sheet, the `scan_tree` component, the extract/classify/insert pipeline tools. Reworked by the DCR: U5 Process All, U6 drag-to-classify/Export Marked, U7 `vault_and_disk` (subsumed by the destination registry).

- Current HEADs: plugins `main` `d3b6962`, Minerva `user/imran/experiments/swarm` `dcd4a53` (+ `584134d2` for the prior pickup.md — about to be superseded by this rewrite).
- **Not yet pushed** — `git push` both before moving machines.
- Test baselines: Rust `cargo test --release` **71/0**; panel smoke **225/0**.

## Cold-pickup checklist

1. `git -C ~/github/Minerva fetch && git checkout user/imran/experiments/swarm && git pull --ff-only`
2. `git -C ~/github/plugins fetch && git checkout main && git pull --ff-only`
3. Rebuild + install the plugin binary (gitignored; source-only in repo):
   ```
   cd ~/github/plugins/scansort && cargo build --release && install -m 0755 target/release/scansort-plugin scansort-plugin
   ```
4. Smoke-check Layer-1:
   ```
   cd ~/github/Minerva && godot --headless --path src --script test/test_scansort_panel_smoke.gd   # expect 225/0
   cd ~/github/plugins/scansort && cargo test --release                                            # expect 71/0
   ```
5. Reload the docket if `minerva.dct` changed underfoot: `docket_project_remove` then `docket_project_add` (the server keeps a stale in-memory copy after a git pull). `docket_get`/`docket_transition`/`docket_create` need `project: "minerva"` explicitly — the primary project is `docket`, not `minerva`.
6. Read DCR `019e2787` (full design) + work_items W1 (`019e27b05586`) and W4 (`019e27b0930a`). Resume implementation there.

## How to run implementation

Use the work-cycle pattern (Sonnet implementer + cold Opus reviewer + Layer-1 structural gate + per-round WIP commit, both repos, no worktrees — sequential rounds commit directly on the branches). Each work_item ≈ one or more work-cycle rounds. W1 and W4 are independent — can run as two sequential rounds back-to-back, or W1 first since W2/W3 both wait on it.

## Build / test commands

- Rust build: `cd ~/github/plugins/scansort && cargo build --release`
- Install binary (NOT `cp` — ETXTBSY): `install -m 0755 target/release/scansort-plugin scansort-plugin`
- Rust tests: `cargo test --release` (71/0 as of U8)
- Layer-1 panel smoke: `godot --headless --path src --script test/test_scansort_panel_smoke.gd` (225/0 as of U8)
- macOS has no `timeout` — run `godot` directly.

## Constraints to carry forward

- All testing goes through MCP tools or the panel UI — do not hand-write rules/vault files.
- Off-tree plugin scripts (`~/github/plugins/`) use `preload()` + base-class typing — no `class_name` for cross-script types. `scan_tree.gd` providers extend `scan_tree_provider.gd` (`extends RefCounted` — never `.free()` a provider instance in tests).
- Plugin MCP tool names must be `minerva_<plugin_id>_*`.
- GDScript JSON round-trip turns ints into floats — coerce with `int(...)`.
- Plugin binary rebuild while Minerva runs: `install -m 0755`, not `cp` (ETXTBSY).
- `_on_panel_create_note_request` MUST be synchronous — the host does not await it. Pre-cache async data on a trigger signal. (`_on_panel_inject_toggle_changed` IS fire-and-forget, can be async.)
- `update_project_key`'s MCP param is `path`, not `vault_path`. Other tools use `vault_path`.
- MCP envelope is non-uniform: `extract_text`/`render_pages` return flat `success`; `check_sha256` returns `{found,doc_id}`; `classify_document`/`insert_document`/`get_destination`/`set_destination`/`get_project_keys`/`list_disk_files` return `{ok,...}`.

## Paused / orthogonal workstreams (not picking up)

- Presentation plugin v2 MCP iteration — plan `019df419ce567de0b7699b3be7b6c8b5`.
- CAD Phase B2 — blocked on bug `019dec49988b7091933371908d6bbb00`. NOTE: `~/github/plugins/` has uncommitted CAD changes (CADPanel.gd, Cad_GeometryOverlay.gd, evaluator.py) from 2026-05-11 — untouched by scansort work, left as-is.

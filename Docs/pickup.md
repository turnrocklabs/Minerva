# Pickup — Scansort filing-engine DCR (W1–W10 + W5b–W5h shipped; W11 combined HITL IN PROGRESS)

Last updated: 2026-05-14 (mid W11 HITL — after the W5b–W5h direct UI fixes)

## Where I left off

**Active workstream: Scansort filing-engine redesign — DCR `minerva:019e2787d0e178029cd46b93059f7ed9`** ("Scansort filing engine — two-phase rules + multi-destination routing + semantic dedup + audit log"). Status: **approved**, P0. Child of parent DCR `019e1cdb` (whose T-series shipped).

**W1–W10 shipped** as autonomous work-cycle rounds. **W11 — the single combined full-stack HITL — is IN PROGRESS.** The user is actively testing the panel; each reported UI issue is fixed DIRECT (no work-cycle) and filed as a W5x follow-up work_item for traceability. W5b–W5h are done. W12 (docs + cleanup) is backlog.

**Work mode:** the W11 HITL fix loop runs DIRECT, not via `/work-cycle` — user's call ("Let's stop using work-cycles and move direct for now"). The loop: user reports a UI issue → diagnose to root cause → fix direct → `cargo test --release` + panel smoke → rebuild binary if Rust changed → commit BOTH repos + push → user retests. Rust changes need a plugin restart; GDScript reads live on panel reload.

## Status of the work_items

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
| W11 | `019e27b12f7c` | combined full-stack HITL | **in_progress** |
| W12 | `019e27b13ec0` | docs + cleanup | backlog (after W11) |

W5b–W5h are HITL-feedback follow-up work_items under the DCR (vault/directory two-pane UI, vault contents render direct from file, kind-aware inline row buttons + real icons, draggable splitter not double-click resize, encrypted-doc open with password, Extract-to-directory dialog, Extract Marked button + per-doc encrypt/decrypt toggle).

## Current HEADs (both pushed)

- Plugins `main`: `ebb9a3c`
- Minerva `user/imran/experiments/swarm`: `92b595f0`
- Plugin binary rebuilt + installed (`install -m 0755`) — has all W-series + W5x MCP tools.

## Test baselines

- Rust `cargo test --release`: **211/0**
- Panel smoke `godot --headless --path src --script test/test_scansort_panel_smoke.gd`: **418/0**

## Settled design decisions (do NOT re-litigate)

- Portability: the `.ssort` vault FILE is the portable unit; the destination registry is machine-local routing scratch. `destinations.rs` keeps absolute paths by design — do NOT add relative-path handling.
- Viewing a vault never depends on the registry — the Vault area renders the open vault directly from its file.
- The vault `documents` table's `encrypt` column is effectively unused; `encryption_iv`/`encryption_tag` presence is the source of truth for "is this doc encrypted".

## Known gaps deferred to W12 (docket comments 360 + 361 on W12)

1. **Logical-identity dedup is unreachable.** `dedup::check_logical_identity` is a tested pure function with NO MCP tool and NO caller — 3-layer dedup is 2-layer wired (simhash + dhash). The only-exact-SHA-auto-skips HARD CONSTRAINT is fully satisfied. Wire it or descope in docs.
2. **"replace" disposition is place-alongside only** — W10 maps "replace" to a collision-safe placement + an audit row recording intent; `place_fanout` has no replace mode. Give it real semantics or document the limitation.
3. **W5 dead code:** the legacy N-section UI code is still live-but-hidden (~150 LOC) + stale test groups T239-T248/V285-V293.

## Cold-pickup checklist

1. `git -C ~/github/Minerva fetch && git checkout user/imran/experiments/swarm && git pull --ff-only`
2. `git -C ~/github/plugins fetch && git checkout main && git pull --ff-only`
3. Rebuild + install the plugin binary (gitignored; source-only in repo):
   ```
   cd ~/github/plugins/scansort && cargo build --release && install -m 0755 target/release/scansort-plugin scansort-plugin
   ```
4. Smoke-check Layer-1:
   ```
   cd ~/github/Minerva && godot --headless --path src --script test/test_scansort_panel_smoke.gd   # expect 418/0
   cd ~/github/plugins/scansort && cargo test --release                                            # expect 211/0
   ```
5. Reload the docket if `minerva.dct` changed underfoot: `docket_project_remove` then `docket_project_add`. `docket_get`/`docket_transition` need `project: "minerva"` explicitly.
6. Read DCR `019e2787` + work_item W11 (`019e27b12f7c`). Continue the combined HITL — wait for the user's next UI feedback, then fix direct.

## Build / test commands

- Rust build: `cd ~/github/plugins/scansort && cargo build --release`
- Install binary (NOT `cp` — ETXTBSY): `install -m 0755 target/release/scansort-plugin scansort-plugin`
- Rust tests: `cargo test --release` (211/0)
- Layer-1 panel smoke: `godot --headless --path src --script test/test_scansort_panel_smoke.gd` (418/0)
- macOS has no `timeout` — run `godot` directly.

## Constraints to carry forward

- All testing goes through MCP tools or the panel UI — do not hand-write rules/vault files.
- Off-tree plugin scripts (`~/github/plugins/`) use `preload()` + base-class typing — no `class_name`. `scan_tree` providers extend `scan_tree_provider.gd` (`extends RefCounted` — never `.free()` a provider).
- Plugin MCP tool names must be `minerva_<plugin_id>_*`.
- GDScript JSON round-trip turns ints into floats — coerce with `int(...)`.
- Plugin binary rebuild while Minerva runs: `install -m 0755`, not `cp` (ETXTBSY).
- `_on_panel_create_note_request` MUST be synchronous — the host does not await it.
- The filing-engine rule schema is v2: rules carry `conditions`/`exceptions` (recursive all/any `ConditionNode` tree), `order`, `stop_processing`, `copy_to` (list of destination ids). The document field is `issuer` (was `sender`); `{sender}` still works as a rename-token alias.
- The destination registry is a host-provided JSON file (`registry_path`); a destination = `{id, kind: vault|directory, path, label, locked}`.
- W-series MCP tools: `run_rule_engine`, `destination_{add,list,remove}`, `place_fanout`, `scan_directory_hashes`, `check_simhash`, `check_dhash`, `reprocess_destination`, `set_destination_locked`, `audit_append`, `set_document_encrypted`.

## Paused / orthogonal workstreams (not picking up)

- Presentation plugin v2 MCP iteration — plan `019df419ce567de0b7699b3be7b6c8b5`.
- CAD Phase B2 — blocked on bug `019dec49988b7091933371908d6bbb00`. `~/github/plugins/` has uncommitted CAD changes — untouched by the filing-engine work, left as-is.

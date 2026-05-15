# Pickup — Path-free agent surface DCR (Phase 3a complete, HITL at B6 next)

Last updated: 2026-05-15 (post-B5+B7)

## Where I left off

**Active workstream: Scansort path-free agent surface — DCR `minerva:019e2cc988ec787fbeeda8e3012ab09f`** ("Scansort path-free agent surface — session model + global rules library"). Status: **proposed**, P2. Sibling of the filing-engine DCR `019e2787`, both under parent scansort-plugin DCR `019e1cdb`.

**Surfaced from** DCR `019e2787` W11 HITL. Attempting "LLM creates rules with no out-of-band paths" surfaced that the entire MCP surface is path-driven and the broker is session-blind — see the new DCR's article for the audit. W11 is now `blocked` by the new DCR.

**Work mode going forward:** mixed.
- **Phase 1 (B1 + B2):** two parallel `/work-cycle` runs, separate worktrees, pre-flight green baselines mandatory.
- **Phase 2 (B3 + B4):** one combined `/work-cycle` (process + manifest are tightly coupled).
- **Phase 3a (B5 + B7):** two parallel `/work-cycle` runs.
- **Phase 3b (B6):** **direct mode** — UI retargeting, user eyeballs.

## Status of DCRs and work items

### Filing-engine DCR `019e2787` (parent — paused at W11)

| | ID (prefix) | Title | Status |
|---|---|---|---|
| W1 | `019e27b05586` | rule schema v2 + sender→issuer rename | done |
| W2 | `019e27b067ec` | Phase 1 classification | done |
| W3 | `019e27b07ca3` | Phase 2 deterministic rule engine | done |
| W4 | `019e27b0930a` | destination registry (backend) | done |
| W5 | `019e27b0a831` | destination registry UI | done |
| W6 | `019e27b0be91` | copy_to fan-out | done |
| W7 | `019e27b0d89a` | three-layer dedup | done |
| W8 | `019e27b0ebe6` | reprocess + locked flag | done |
| W9 | `019e27b1007c` | audit log | done |
| W10 | `019e27b11549` | Process All integration | done |
| W11 | `019e27b12f7c` | combined full-stack HITL | **blocked** (by `019e2cc988ec`) |
| W12 | `019e27b13ec0` | docs + cleanup | backlog (after new DCR ships) |

### Path-free agent surface DCR `019e2cc988ec` (current — starting)

| | ID (prefix) | Title | Status |
|---|---|---|---|
| B1 | `019e2cca04d9` | Session model + state tool (multi-cardinality, label-addressed) | **done** (Phase 1 round 1) |
| B2 | `019e2cca4ba8` | Library at OS app-data + `library_*` CRUD | **done** (Phase 1 round 2) |
| B3 | `019e2ccaa1a9` | Path-free `process()` pipeline | **done** (Phase 2) |
| B4 | `019e2ccadeac` | Source state manifest `.scansort-state.json` | **done** (Phase 2) |
| B5 | `019e2ccb1d94` | Sidecar export/import as portable hatch | **done** (Phase 3a) |
| B6 | `019e2ccb6118` | Retarget Rules Editor dialog at library | backlog (Phase 3b, **HITL — current pickup**) |
| B7 | `019e2ccbbcd6` | Library hot-reload on mtime change | **done** (Phase 3a) |
| — | `019e2cfced` | **Follow-up:** B3/B4 quality (test gaps + minor reporting semantics) | backlog (before HITL go-live) |

## Current HEADs (both pushed)

- Plugins `main`: `27d4d42` — P0 bug fix on top of B5+B7: rename-pattern resolver now supports `{description}`/`{doc_type}`/`{amount}`/`{category}` tokens (DEFAULT_RENAME_PATTERN was emitting literal `{description}` text in filenames). See bug `019e2d6471` — resolved, awaiting HITL verification.
- Minerva `user/imran/experiments/swarm`: see this commit.
- Plugin binary: rebuilt + installed at `~/github/plugins/scansort/scansort-plugin` from `27d4d42`.

## Test baselines

- Rust `cargo test --release` in `~/github/plugins/scansort`: **250/0** (+6 from P0 fix; +5 destination.rs token expansion tests + 1 rule_engine.rs mirror test)
- Panel smoke `godot --headless --path src --script test/test_scansort_panel_smoke.gd`: **433/0** (+15 from B1 Group only; B6 will add panel tests for the new dialog)
- Scansort MCP tool count: **71** (+7 `session_*` + +7 `library_*` + +1 `process` + +2 `library_export_to_sidecar`/`library_import_from_sidecar`; P0 added no new tools, only extended `place_fanout` schema with `doc_type`/`amount` optional args)

Both must be green before any subsequent work-cycle starts.

## Settled design decisions for the new DCR (do NOT re-litigate)

1. **Session is multi-cardinality and label-addressed.** Open vaults, open directories, open sources are each a *set* (≥ 0) of `{label, path}` pairs. LLM-facing tools never see paths — only labels.
2. **Rules live in a single global library** at the OS app-data path, resolved via the Rust `directories` crate (`ProjectDirs::from("", "Minerva", "Scansort").data_dir().join("library.rules.json")`). Plugin refuses to start if HOME/USERPROFILE unset.
3. **`copy_to` references destination labels**, not opaque IDs or paths. Labels are user-chosen and stable across machines. Schema unchanged (`copy_to: [String]`), semantics shift.
4. **Sidecar `<vault-stem>.rules.json` is demoted to portable export-only.** Classifier reads only from the library. Sidecar tools survive as the implementation of `library_export_to_sidecar` / `library_import_from_sidecar`.
5. **Unmatched files are marked source-side** in `<source-dir>/.scansort-state.json`, keyed by sha256. Same manifest tracks moved/conflict/unprocessable outcomes so re-runs skip cleanly.
6. **No rules ship.** Library is empty until user (via Rules Editor dialog or LLM) populates it.
7. **Hot-reload via poll-on-use stat**, not a watcher thread. Three editing surfaces (dialog, LLM, hand-edit) converge on `library.rules.json` without restart.
8. **No per-vault rule overrides in v1.** Sidecar import merges into library by label, last-write-wins.
9. **Broker-level `host.context.*` / `host.app_data.*` capabilities are out of scope.** File separately when needed. Plugin owns the app-data path directly for now.

## Pre-flight gate (every work-cycle, no exceptions)

```bash
git -C ~/github/Minerva fetch && git -C ~/github/Minerva checkout user/imran/experiments/swarm && git -C ~/github/Minerva pull --ff-only
git -C ~/github/plugins fetch && git -C ~/github/plugins checkout main                       && git -C ~/github/plugins pull --ff-only

echo "Minerva base: $(git -C ~/github/Minerva rev-parse HEAD)"
echo "Plugins base: $(git -C ~/github/plugins rev-parse HEAD)"

cd ~/github/Minerva && godot --headless --path src --script test/test_scansort_panel_smoke.gd   # expect 418/0
cd ~/github/plugins/scansort && cargo test --release                                            # expect 211/0
```

If baselines aren't green, the cycle does not start.

Worktree isolation: every parallel cycle uses `git worktree add` so user's main checkout is never touched mid-cycle.

## Post-flight scope-creep gate

```bash
git diff --stat <base>..HEAD         # in BOTH repos
# Every touched file must justify its place vs the work_item's stated scope.
# Out-of-scope changes are reverted or split into a new item.

cargo test --release                 # 211 + N new tests
godot --headless ... panel smoke     # 418 + M new tests
grep -c '"name": "minerva_scansort_' ~/github/plugins/scansort/src/main.rs
# Tool count must match the work_item's "new MCP tools" expectation.
```

## Two-repo discipline

Every cycle:
1. Commit in plugins → `git push origin main`
2. Rebuild binary → `cd ~/github/plugins/scansort && cargo build --release && install -m 0755 target/release/scansort-plugin scansort-plugin` (never `cp` — ETXTBSY)
3. Commit in Minerva → `git push origin user/imran/experiments/swarm`
4. Refresh this pickup doc.

## Build / test commands (quick ref)

- Rust build: `cd ~/github/plugins/scansort && cargo build --release`
- Install binary: `install -m 0755 target/release/scansort-plugin scansort-plugin`
- Rust tests: `cargo test --release` (211/0 today)
- Layer-1 panel smoke: `godot --headless --path src --script test/test_scansort_panel_smoke.gd` (418/0 today)
- macOS has no `timeout` — run `godot` directly.

## Constraints to carry forward

- All testing goes through MCP tools or the panel UI — do not hand-write rules/vault files.
- Off-tree plugin scripts (`~/github/plugins/`) use `preload()` + base-class typing — no `class_name`. `scan_tree` providers extend `scan_tree_provider.gd` (`extends RefCounted` — never `.free()` a provider).
- Plugin MCP tool names must be `minerva_<plugin_id>_*`.
- GDScript JSON round-trip turns ints into floats — coerce with `int(...)`.
- Plugin binary rebuild while Minerva runs: `install -m 0755`, not `cp` (ETXTBSY).
- `_on_panel_create_note_request` MUST be synchronous — the host does not await it.

## Paused / orthogonal workstreams (not picking up)

- Filing-engine DCR `019e2787` W12 (docs + cleanup) — still applicable but blocked behind the new DCR landing.
- Presentation plugin v2 MCP iteration — plan `019df419ce567de0b7699b3be7b6c8b5`.
- CAD Phase B2 — blocked on bug `019dec49988b7091933371908d6bbb00`. `~/github/plugins/` has uncommitted CAD changes — untouched by the current work, left as-is.

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
5. Read DCR `019e2cc988ec` (article has the full design + audit). **B1–B5 + B7 are done**; B6 (Retarget Rules Editor dialog at library; top-level menu) is the **next pickup and is the HITL phase** — direct work-cycle, not autonomous. Before starting B6, consider clearing the B3/B4 quality follow-up `019e2cfced`.

## What works end-to-end after Phase 3a (LLM-callable, path-free)

The LLM can now drive the whole scansort flow with no paths in chat:
- `minerva_scansort_session_state` — see what's open
- `minerva_scansort_library_insert_rule` (+ list/get/update/delete/enable/disable) — define rules referencing destination labels
- `minerva_scansort_process` — run the pipeline; receive a summary `{moved, conflicts, unprocessable, by_rule, by_destination, items}`
- `minerva_scansort_library_export_to_sidecar(vault_label)` — portable export to the vault's sibling `.rules.json`
- `minerva_scansort_library_import_from_sidecar(vault_label)` — bring a sidecar back into the library
- Hand-edits to `<app-data>/Minerva/Scansort/library.rules.json` are picked up automatically (mtime hot-reload)

What's still missing for fully ergonomic UX:
- B6 — Rules Editor dialog retargeted at the library (top-level menu, no vault required to edit rules)
- `019e2cfced` — B3/B4 test gaps + by_rule counting fix + dead `EntryKind::Source` cleanup

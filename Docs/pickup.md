# Pickup — Scansort plugin: rules-file separation done, U-series in progress

Last updated: 2026-05-14 (laptop, end of session — U1 committed, U2 next)

## Where I left off

Active workstream: **Scansort plugin DCR — experiment→plugin parity port**
(`minerva:019e1cdb451076ae8c344f6e6ec605e1`, "Scansort plugin — functionally-equivalent redesign").

Three things moved this session. (1) and (2) are **done and committed**; (3) is **in progress**.

### (1) Rules-file separation (R1–R6) — DONE, committed, NOT yet HITL-tested

Rules moved out of the `.ssort` vault into an external plaintext JSON file: sibling
`<vault-stem>.rules.json` first, then a user-level library fallback. The vault keeps a
per-document `rule_snapshot` blob (+ `snapshot_hash`) so it stays self-describing. Vault
schema bumped **1.0.0 → 1.1.0** with auto-migration on `open_vault`
(`schema::migrate` + `rules_file::migrate_embedded_to_sibling`).

### (2) F&F polish — DONE, committed

- Dropped the chrome model picker; model override now lives in the **Settings dialog**
  (per-plugin, user-level, single model preference — "always a multimodal model").
- All plugin dialogs honor Minerva's UI scale (`ui_scale.gd`).
- Fixed 14 real debugger warnings at root cause (lambda-capture bugs in `CapabilityBroker.gd`).

### (3) U-series — cuteFTP experiment-parity port — IN PROGRESS (U1 done)

Gap analysis found the T7 port captured the **data layer** faithfully but dropped the
**interaction layer** (source pane, Process button, per-file actions). The U-series restores it.
**U1 is committed**; U2–U10 + the full-stack HITL remain.

## Commits (pushed; pull on the other machine)

| Repo | Branch | Notes |
|---|---|---|
| `~/github/plugins/scansort` | `main` | HEAD `33d9f04` — U1 scan_tree component. R1-R6 + F&F below it. |
| `~/github/Minerva` | `user/imran/experiments/swarm` | HEAD has U1 test (`46365da8`, Group N N135-N153) + this session's `.uid` WIP commit. |

Plugin commit trail: `4c450c4` rules_file module · `44e8d98` schema 1.1.0 · `edcdb09` classify
reads file · `5f7f08a` R4 MCP rules_path tools · `e530315` R5 migration · `240a473`/`777b12a`
R6 rules editor UI · `2c23994` drop chrome model picker · `7f61c60`/`762d65f` Settings dialog ·
`c362562` UI scale · `33d9f04` U1 scan_tree.

Minerva commit trail: `343cfc0` ChatPane.get_active_model_spec · `092d1b9` lambda-capture fix ·
`1bf4696` test path portability · `46365da8` U1 Group N tests.

## NEXT: U2 — source backend

From nudge `scansort-T7-continuation/round-sequence` and `session-state`:

> Add MCP tools `set_source_dir(path, recursive)` / `get_source_dir()` / `list_source_files()`
> to `~/github/plugins/scansort/src/main.rs`. Source state = **transitory** plugin-process
> memory (module-level state struct), never persisted. `list_source_files` returns supported
> files under the source dir (recursive optional), each `{path, name, size, sha256, in_vault}`
> where `in_vault` cross-references the vault's `fingerprints`/`sha256`. Then build
> `scan_tree_source_provider.gd` (extends `scan_tree_provider.gd`) calling `list_source_files`.
> Rust unit tests + smoke-test additions. Commit U2 both repos.

Remaining rounds (Tier-1): U3 destination backend · U4 panel layout rewrite (3-column Option A) ·
U5 Process All pipeline · U6 manual review (drag/mark/export) · U7 vault_and_disk stacked view +
Settings destination picker + concurrency control · U8 recovery sheet dialog · U9 watch folders
(design-first) · U10 docs + delete orphaned `vault_view.gd`/`edit_details_dialog.gd`.

## HITL — still pending (blocked behind U-series)

Panel-driven HITL of the full stack: 10 test PDFs in `~/Downloads` (8 physics/school, 1
`receipt.pdf`, 1 WA-ferries doc); test dir `~/scansort-test/` is empty + clean. **Drive through
the panel UI, not raw MCP** (user constraint). Sightline should confirm 0 new warnings.

Open question: HITL the rules-file work against the *current* pane before the U-series tears it
out, or one combined HITL after U10. Leaning combined-after.

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
   godot --headless --path src --script test/test_scansort_panel_smoke.gd      # expect 160/0
   ```
   Rust: `cd ~/github/plugins/scansort && cargo test --release`                # expect 45/0
5. Resume at U2 (above).

## Build / test commands

- Rust build: `cd ~/github/plugins/scansort && cargo build --release`
- Install binary (NOT `cp` — ETXTBSY): `install -m 0755 target/release/scansort-plugin scansort-plugin`
- Rust tests: `cargo test --release` (45/0)
- Layer-1 panel smoke: `godot --headless --path src --script test/test_scansort_panel_smoke.gd` (160/0)
- macOS has no `timeout` command — run `godot` directly.
- Pick up GD changes: user restarts Minerva (F5 stop+start). Pick up Rust binary: install + restart
  scansort plugin via `minerva_plugin_restart`.

## Constraints to carry forward

- All testing goes through MCP tools or the panel UI — **do not hand-write rules/vault files** to
  side-step how Minerva works.
- Off-tree plugin scripts (`~/github/plugins/`) use `preload()` + base-class typing — no `class_name`
  for cross-script types. Off-tree `class_name` (where used) must start with `<canonical_prefix>_`.
- Plugin MCP tool names must be `minerva_<plugin_id>_*`.
- GDScript JSON round-trip turns ints into floats; coerce with `int(...)`.
- GDScript `func()` lambdas capture primitives BY VALUE — use a Dictionary for mutable shared state.
- Plugin binary rebuild while Minerva runs: `install -m 0755`, not `cp` (ETXTBSY).

## Locked design decisions (U-series)

See nudge `scansort-T7-continuation/design-decisions-locked` for the full list. Highlights:
source dir is transitory; destination is a per-vault setting (`vault_only`/`disk_only`/
`vault_and_disk`); `vault_and_disk` is curated, not mirrored; export mark and processed mark are
transitory session state; ONE unified `scan_tree` component for all three panes; no per-doc detail
panel (`vault_view.gd` gets deleted); Process All is a panel-orchestrated GDScript loop, not a Rust
tool; concurrency control (1–4 parallel) lives in the Settings dialog.

## Nudge state

Component `scansort-T7-continuation` — keys: `session-state`, `round-sequence`,
`build-test-commands`, `docket-and-prior-work`, `design-decisions-locked`. Query before
re-discovering.

## Session housekeeping done

- Sightline probe reverted (`--cleanup`): `src/project.godot` restored, `src/addons/sightline_probe/`
  and `src/.sightline/` removed.
- Untracked `.uid` files in `src/test/` committed (Godot tracks `.uid` — 606 already in the repo).

## Paused workstreams (orthogonal, not picking up)

- Presentation plugin v2 MCP iteration — plan `019df419ce567de0b7699b3be7b6c8b5`.
- CAD Phase B2 — blocked on bug `019dec49988b7091933371908d6bbb00`.

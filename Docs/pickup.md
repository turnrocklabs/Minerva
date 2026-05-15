# Pickup — Path-free agent surface DCR (Phase 3a complete; HITL stuck on Claude Code MCP catalogue staleness)

Last updated: 2026-05-15 (end of session, HITL paused mid-test)

## TL;DR for cold pickup

- **DCR `019e2cc988ec`** ("Scansort path-free agent surface") — **6 of 7 children done.** B1, B2, B3, B4, B5, B7 shipped + P0 token-expansion fix (`019e2d6471`) shipped. **B6 (Rules Editor dialog retarget) is backlog and is the HITL phase.**
- **First end-to-end HITL test attempted today and BLOCKED** by a Claude Code MCP-client bug: the deferred-tool catalogue doesn't refresh on `/mcp` reconnect after a plugin manifest change. **The next instance must verify ToolSearch sees the new tools FIRST** — see "Cold-start prerequisite" below.
- **6 test PDFs staged at `~/temp/scansort-staging/`** waiting for the test to resume.
- **User has `~/temp/vaults/test.ssort` vault** (panel state was reset when plugin reinstalled; user will need to re-open the panel + vault before testing).
- **Model for classifier: `gemma4:e4b`** via the "core" provider. NOT in `minerva_list_models` output (filed bug `019e2d8018`).

## Where I left off

The user wanted to validate the path-free pipeline end-to-end: insert a tax rule via MCP, register a source via session, call `process()`, see PDFs land in the vault under the `tax` category with names like `imran_w-2_2024.pdf`.

Sequence reached:
1. Staged 6 PDFs into `~/temp/scansort-staging/` (4 tax positives, 2 negatives — Beneteau, PSEBill).
2. Tried to call `session_state()` to read the open-vault label.
3. **Claude Code's ToolSearch could not find the new tools** even though Minerva had them registered. `/mcp` reconnect did not refresh the client-side deferred-tool catalogue.
4. User attempted a Claude Code "restart" but the catalogue stayed stale — the `/mcp` slash command alone re-establishes the connection without re-handshaking the tool list. **The Claude Code CLI binary must be fully exited and re-launched** (or the user is on a build that doesn't refresh tools on /mcp — separate question).

## Cold-start prerequisite — DO THIS FIRST

Before attempting any new tool call:

```
# In Claude Code, try:
ToolSearch query="select:mcp__minerva__minerva_scansort_session_state" max_results=1
```

Two outcomes:
- **Returns the tool schema** — catalogue is healthy, proceed to "HITL test plan" below.
- **"No matching deferred tools found"** — catalogue is stale, ALL the new tools are invisible. Halt. Either:
  - Ask user to fully exit + relaunch the Claude Code CLI binary (NOT just `/mcp`).
  - Or proceed with manual panel-driven workaround (see "Fallbacks" below).

## Phase status

| | ID | Title | Status |
|---|---|---|---|
| B1 | `019e2cca04d9` | Session model + state tool | **done** |
| B2 | `019e2cca4ba8` | Library at OS app-data + `library_*` CRUD | **done** |
| B3 | `019e2ccaa1a9` | Path-free `process()` pipeline | **done** |
| B4 | `019e2ccadeac` | Source state manifest `.scansort-state.json` | **done** |
| B5 | `019e2ccb1d94` | Sidecar export/import as portable hatch | **done** |
| B6 | `019e2ccb6118` | Retarget Rules Editor dialog at library | backlog — **HITL phase, next pickup after smoke** |
| B7 | `019e2ccbbcd6` | Library hot-reload on mtime change | **done** |
| Q  | `019e2cfced`   | B3/B4 quality follow-up (test gaps + reporting semantics) | backlog (before HITL go-live) |

### Filing-engine DCR `019e2787` (paused)
- W1–W10 + W5b–W5h done. **W11 (HITL) blocked** by `019e2cc988ec`. W12 backlog.

### Open bugs filed this session

| ID | Pri | Title | Status |
|---|---|---|---|
| `019e2d6471` | P0 | rename_pattern resolver missing `{description}/{doc_type}/{amount}/{category}` tokens | **resolved** in commit `27d4d42`. Awaits HITL verification → `verified` |
| `019e2d82ca72` | P2 | `process()` / classifier can't pin to a different model than chat default | new |
| `019e2d801895` | P3 | `minerva_list_models` omits the "core" provider's catalogue | new |

## Current HEADs (both pushed)

- Plugins `main`: **`e228dd7`** — `manifest.json` updated to register all 17 new B1+ tools. P0 fix at `27d4d42` underneath.
- Minerva `user/imran/experiments/swarm`: see this commit.
- Plugin binary: at `~/github/plugins/scansort/scansort-plugin` built from `e228dd7`. **Plugin is INSTALLED + RUNNING in Minerva** (uptime grows from 21:31:41 today's reinstall; will reset on Minerva restart).

## Test baselines

- Rust `cargo test --release` in `~/github/plugins/scansort`: **250/0** (+13 B1 + +1 B2 + +18 B3+B4 + +6 P0)
- Panel smoke `godot --headless --path src --script test/test_scansort_panel_smoke.gd`: **433/0** (+15 B1 Group only; B6 will add panel tests)
- Scansort MCP tool count in main.rs: **71** (+17 from B1-B7, no new tools in P0)
- Scansort tools in `manifest.json`: **52** (was 35 pre-B1; the 17-vs-19 delta is intentional — we did NOT add the W-series tools like `set_source_dir`, `destination_add`, etc. to the manifest in this DCR; those remain panel-internal)

## HITL test plan (ready to resume)

### Pre-conditions
- Staging: `~/temp/scansort-staging/` (6 PDFs, see "Staged files" below)
- Vault: `~/temp/vaults/test.ssort` (user creates / re-opens via panel)
- Panel must be open and vault opened — this auto-registers it in the plugin session via B1's wiring.

### Steps (path-free, via Claude Code MCP)

1. `minerva_scansort_session_state()` — confirm vault label (should be `test` from `test.ssort`'s stem) and confirm staging source isn't yet registered. Panel auto-registers vault on open; source must be added by us.

2. `minerva_scansort_set_source_dir(path: "/home/imran/temp/scansort-staging", recursive: true)` — set the plugin's source-dir global (B3's `list_source_files_for_path` may or may not use this; safer to set).

3. `minerva_scansort_session_open_source(label: "scansort-staging", path: "/home/imran/temp/scansort-staging")` — register source in session.

4. `minerva_scansort_library_insert_rule(...)` with the tax rule:

```json
{
  "label":                "tax",
  "name":                 "Tax documents",
  "instruction":          "Tax-related documents including W-2s, 1099s, tax returns, IRS correspondence, property tax statements, and receipts for deductible expenses.",
  "signals":              ["W-2","1099","tax return","IRS","adjusted gross income","taxable income","withholding","deduction","Schedule C","Form 1040","property tax","estimated tax","EIN","SSN"],
  "subfolder":            "tax",
  "rename_pattern":       "imran_{doc_type}_{year}",
  "confidence_threshold": 0.5,
  "stop_processing":      true,
  "order":                100,
  "enabled":              true,
  "encrypt":              false,
  "is_default":           false,
  "copy_to":              ["test"]
}
```
(`copy_to` must match the actual vault label from step 1 — confirm before inserting.)

5. `minerva_scansort_library_list_rules()` — verify the rule is in the library and enabled.

6. `minerva_scansort_session_state()` — verify both vault and source are present.

7. **Important**: Per bug `019e2d82ca72`, `process()` uses whatever model is the host default for `host.providers.chat`. The user wants **`gemma4:e4b`** (core provider). **Before calling process(), confirm Minerva's chat default model is set to gemma4:e4b** via the AISettings or chat UI. If a different default is in place, the classifier runs on the wrong model and the test result is moot.

8. `minerva_scansort_process()` — run. This is slow (one LLM call per file via host.providers.chat). For 6 PDFs at ~2-5 sec each, expect 15-30 sec.

### Expected outcome

```jsonc
{
  ok: true,
  summary: { moved: 4, conflicts: 0, unprocessable: 2, skipped_already_processed: 0 },
  by_rule:        { "tax": 4 },
  by_destination: { "test": 4 },
  items: [
    // 4 moved entries: msft_w2 → imran_w-2_2024.pdf (or similar — depends on what gemma extracts as doc_type),
    //                  MorganStanley + Consolidated 1099 → imran_1099_2023.pdf collisions handled,
    //                  0624PEIM 1040 → imran_1040_2024.pdf
    // 2 unprocessable: Beneteau 373 2004 → no_rule_match,
    //                  PSEBill → no_rule_match
  ]
}
```

Verify in the panel: opening the vault should show 4 documents under category "tax" with display_name renamed per pattern.

Manifest at `~/temp/scansort-staging/.scansort-state.json` should have 6 entries (4 moved, 2 unprocessable).

### Things that could go wrong (and how to react)

1. **`copy_to` label mismatch** — if `session_state` returns `test.ssort` instead of `test`, update the rule's `copy_to`. The B1 wiring is `path.get_file().get_basename()` which strips `.ssort`, so `test` is expected. Worth checking.
2. **`gemma4:e4b` scores everything at 0.0** — the score is per-rule; with one rule the LLM should write something ≥0.5 for tax PDFs. If everything fires at 0.0, the prompt isn't being followed (model too small for the scoring schema). Fix: lower threshold to 0.3 or 0.0; rerun. If still no fires, swap to `gemini-3.1-flash-lite-preview` (cheaper API but reliable JSON).
3. **`doc_type` includes punctuation** — e.g. `"W-2 (wage statement)"` lands in filename as `imran_W-2 (wage statement)_2024.pdf`. The current sanitiser only rejects path separators + traversal; spaces and parens pass through. This is a UX wart, not a P0. Note for follow-up — token-value normalization could be a B8-class enhancement.
4. **Empty `extract_text` on a scanned PDF** — classifier scores all rules at 0.0 → unprocessable. Real for OCR-poor PDFs. None of the 6 staged PDFs should hit this (all are digital-text).
5. **The Claude Code tool catalogue is still stale after restart** — the path-free flow can't proceed. Use the panel UI to open the panel + vault, but DO NOT use the Rules Editor dialog (it targets the old sidecar which B5 demoted; the classifier won't see those rules). Best bet: keep restarting Claude Code or wait for the bug fix.

## Staged files

```
~/temp/scansort-staging/
├── 0624PEIM 1040, Il-1040, and M1 Tax Returns client copy 2024.pdf   (tax — positive)
├── 2023-Imran-1478-Consolidated-Form-1099.pdf                         (tax — positive)
├── 2023-MorganStanley-MSFT-Bonus.pdf                                  (tax — positive)
├── Beneteau 373 2004.pdf                                              (boat — negative; should not fire)
├── msft_w2.pdf                                                        (tax — positive, W-2)
└── PSEBill.pdf                                                        (utility — negative; should not fire)
```

## Hard-won gotchas discovered today (read before doing anything plugin-related)

1. **`manifest.json` is the source of truth for plugin MCP tools** — see [[plugin-manifest-is-source-of-truth-for-tools]] memory entry. Adding handlers to `main.rs` is necessary but NOT sufficient. The `tools` array in `manifest.json` must list every new tool by name + description, or Minerva's MCP server won't expose it. This caught B1-B5+B7 — the implementer prompts didn't include "update manifest.json" as a step. Fixed in commit `e228dd7` by adding the 17 new entries. **Update the work-cycle skill brief template to require manifest.json updates in the same commit.**

2. **`minerva_plugin_reload` doesn't refresh the MCP client's tool catalogue** — see [[mcp-plugin-reload-doesnt-refresh-tools]]. After a binary rebuild + reload, the new tools aren't visible to Claude Code until `/mcp` reconnect *at minimum* — and possibly until a full CLI restart (still confirming). The deferred-tool catalogue appears to be cached at session-start time.

3. **Plugin remove + install is needed to refresh a cached manifest** — `plugin_reload` restarts the subprocess but Minerva's *manifest cache* (the entry in its plugins table) is set at install time. Manifest changes require `plugin_remove(id)` + `plugin_install(manifest_path)` + `plugin_start(id)`. This is how we got the 17 new tools to register today.

4. **Claude Code CLI deferred-tool catalogue staleness is unresolved** — the user did a `/mcp` reconnect (and possibly a Claude Code restart, unclear) and the new tools still didn't appear in ToolSearch. Minerva-side `plugin_inspect` confirmed all 52 tools are registered. The bug is on the Claude Code side and is **the only thing blocking the HITL test today**. Worth filing as a Claude Code bug with repro: 1) start Claude Code CLI, 2) connect to Minerva with a plugin advertising N tools, 3) remove+reinstall the plugin with N+M tools, 4) `/mcp`, 5) the M new tools are not in ToolSearch.

5. **classifier no longer reads sidecar** — B5 demoted `<vault-stem>.rules.json` to "portable export hatch only." `classify_document` reads only from `library.rules.json` at the OS app-data path. The legacy `insert_rule(rules_path=...)` MCP tool still works for writing to a sidecar — but the rule won't be visible to the classifier. The library is the only source. This breaks Option-2 fallback paths until B6 lands.

6. **`directories` crate sandboxes app-data oddly** — under `~/.local/share/minerva/scansort/library.rules.json` on Linux. If the user clears their app data, the library is gone. Worth noting in B6 documentation.

7. **`{description}` token capped at 60 chars** — by design (P0 fix). `chars().take(60)` not `[..60]` byte slice (would panic on multi-byte boundary). Empty values fall back to `"unknown"` for all 7 tokens including `{year}`, `{date}`.

## Cold-pickup checklist

1. `git -C ~/github/Minerva fetch && git checkout user/imran/experiments/swarm && git pull --ff-only`
2. `git -C ~/github/plugins fetch && git checkout main && git pull --ff-only`
3. Verify plugin binary fresh:
   ```
   cd ~/github/plugins/scansort && cargo build --release && install -m 0755 target/release/scansort-plugin scansort-plugin
   ```
4. Smoke-check Layer-1:
   ```
   cd ~/github/Minerva && godot --headless --path src --script test/test_scansort_panel_smoke.gd   # expect 433/0
   cd ~/github/plugins/scansort && cargo test --release                                            # expect 250/0
   ```
5. **Verify Claude Code tool catalogue is healthy** (CRITICAL):
   ```
   ToolSearch query="select:mcp__minerva__minerva_scansort_session_state" max_results=1
   ```
   If empty, ask user to fully restart Claude Code CLI before proceeding.

6. Verify Minerva plugin state:
   - User: confirm Minerva is running, panel is open, vault `~/temp/vaults/test.ssort` is loaded
   - Agent: `minerva_plugin_inspect id="scansort"` — confirm 52 tools, plugin RUNNING

7. Decide next step:
   - **HITL smoke** (recommended first): run the test plan above against the 6 staged PDFs. Verify P0 fix end-to-end, validate classifier behavior on real docs.
   - **B3/B4 quality follow-up** (`019e2cfced`): clear test theater + by_rule counting fix + dead variant cleanup. Small work-cycle.
   - **B6 (UI retarget)**: HITL phase — direct mode, GDScript dialog work. Move `rules_editor_dialog.gd` from path-driven CRUD to `library_*` calls. Add "Rules Library..." top-level menu item.

## Settled design decisions (do NOT re-litigate)

1. Session is multi-cardinality, label-addressed. LLM never sees paths.
2. Rules live in a global library at `<OS-app-data>/Minerva/Scansort/library.rules.json` via `directories` crate.
3. `copy_to` carries user-chosen destination labels, not opaque IDs or paths.
4. Sidecar `<vault-stem>.rules.json` is portable export-only. Classifier reads only the library.
5. Unmatched files mark in `<source-dir>/.scansort-state.json`. Re-runs skip cleanly.
6. No rules ship — library starts empty.
7. Hot-reload via poll-on-use stat. No watcher thread.
8. No per-vault rule overrides in v1.
9. `{description}` capped at 60 chars via `chars().take(60)` (multi-byte safe).
10. Empty token values fall back to literal `"unknown"` (uniform across all 7 tokens).
11. **No per-rule or per-process classifier-model override yet** — open bug `019e2d82ca72`. Workaround: set Minerva's chat default to `gemma4:e4b` before calling process().

## Build / test commands (quick ref)

- Rust build: `cd ~/github/plugins/scansort && cargo build --release`
- Install binary: `install -m 0755 target/release/scansort-plugin scansort-plugin` (NEVER `cp` — ETXTBSY)
- Rust tests: `cargo test --release` (250/0 today)
- Panel smoke: `godot --headless --path src --script test/test_scansort_panel_smoke.gd` (433/0 today)
- Plugin reinstall (after manifest change):
  ```
  # via Claude Code MCP:
  minerva_plugin_remove id=scansort
  minerva_plugin_install manifest_path=/home/imran/github/plugins/scansort/manifest.json
  minerva_plugin_start id=scansort
  ```
- macOS has no `timeout` — run `godot` directly.

## Constraints to carry forward

- All testing goes through MCP tools or the panel UI — do not hand-write rules/vault files.
- Off-tree plugin GDScript: no `class_name`, use `preload()` + base-class typing.
- Plugin MCP tool names must be `minerva_<plugin_id>_*`.
- GDScript JSON round-trip turns ints into floats — coerce with `int(...)`.
- Plugin binary rebuild while Minerva runs: `install -m 0755`, not `cp`.
- **Any new MCP tool added to `main.rs` MUST also be added to `manifest.json` `tools` array** (the manifest is the gate, not main.rs).
- **Restart Claude Code CLI fully** (not just `/mcp`) after a plugin manifest change to refresh the deferred-tool catalogue.
- `_on_panel_create_note_request` MUST be synchronous.

## Paused / orthogonal workstreams

- Filing-engine DCR `019e2787` W12 (docs + cleanup) — still applicable post-DCR.
- Presentation plugin v2 MCP iteration — plan `019df419ce567de0b7699b3be7b6c8b5`.
- CAD Phase B2 — blocked. `~/github/plugins/cad/` has uncommitted CAD changes — left as-is.

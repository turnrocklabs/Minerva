# Pickup — scansort rule schema redesign (DCR 019e33bfa10c) — autonomous implementation

STATE: IN_PROGRESS_CHUNK_3

Last updated: 2026-05-16

---

## STATE marker (READ THIS FIRST)

The `STATE:` line above is the goal-completion predicate. Haiku reads it every turn to decide whether the active `/goal` is satisfied. Valid values:

| State | Meaning |
|---|---|
| `PLAN_READY` | Plan written. No `/goal` set yet. No work started. |
| `IN_PROGRESS_CHUNK_1` … `IN_PROGRESS_CHUNK_6` | Phase 1 autonomous run in flight on the named chunk. |
| `AWAITING_HITL` | Chunks 1–6 done. Phase 1 goal satisfied. User HITL pending. |
| `IN_PROGRESS_CHUNK_7` | Phase 2 autonomous run in flight (post-HITL cleanup). |
| `SHIPPED` | All work done. Phase 2 goal satisfied. DCR transitioned to shipped. |

**Update this marker at every chunk boundary.** Edit the top-of-file `STATE:` line in the same commit that advances the chunk.

---

## Cold-start procedure (zero-context resume)

If you're reading this with no conversation history, execute in this exact order:

1. `git -C ~/github/Minerva pull --ff-only` (branch: `user/imran/experiments/swarm`)
2. `git -C ~/github/plugins pull --ff-only` (branch: `main`)
3. Read this file in full (you're here).
4. Read DCR description: `mcp__docket__docket_query` with `{"conditions":[{"field":"id","op":"eq","value":"019e33bfa10c753dbc467c38468268cd"}]}` and `detail: "full"`.
5. Identify current chunk from the STATE marker. Read every work_item in that chunk's "Work items" column (use `docket_query` with `parent` filter on the DCR id).
6. Resume execution from the chunk's "What's left in this chunk" sub-section.

If the STATE is `PLAN_READY` and a `/goal` is already active, start at Chunk 1.

---

## The plan — quick reference table

| Chunk | Work items | Mode | Approx wall-time | Exit checkpoint |
|---|---|---|---|---|
| 1 | W1 + W5 | Direct (sequential) | ~1.5 h | `cargo test` green; legacy library round-trips through migration |
| 2 | W2 | Direct | ~2-3 h | `cargo test` green; stage-folding + filter-failure both tested |
| 3 | W3, W11, W12 | Parallel sub-agents in worktrees, Opus reviewers | ~1 h wall | All 3 merged; Layer-1 green |
| 4 | W4 + W8 | Parallel sub-agents in worktrees, Opus reviewers | ~1.5 h wall | Both merged; dryrun_one callable end-to-end |
| 5 | W6 | Direct | ~1.5 h | Pane visible, toggle works, panel smoke ≥ 433/0 |
| 6 | W7 | Direct | ~3-4 h | All menu items wired, dry-run result dialog functional |
| **HITL** | — | **User** | user time | Pane validated end-to-end; any bugs filed as follow-up work_items |
| 7 | W9 + W10 | Direct | ~2-3 h | Skill loads in focused chat; old UI deleted; no regressions |
| **Final HITL** | — | **User** | user time | Focused chat with skill authors a rule; mark DCR shipped |

---

## Per-chunk detail

### Chunk 1 — Schema + migration (direct)

**Work items:** W1 (`019e33ce48c8`), W5 (`019e33ce9ff1`)

**Why locked together:** W1 breaks legacy library files on load. W5 fixes that. Land in one PR (or two PRs merged together) so main is never in a broken state for users with rules on disk.

**Branch:** `work-item/W1-W5-schema-migration`

**Files expected:** `~/github/plugins/scansort/src/rules.rs`, `~/github/plugins/scansort/src/types.rs` (if Stage/Slot live there), new `~/github/plugins/scansort/src/migrate.rs`, related tests.

**Exit checkpoint:**
- `cargo test --release` green (≥ 258 + new tests)
- A legacy rules.json with `signals` + `subtypes` + `{date}_{sender}_{description}` template round-trips through migration to the new schema, written back to disk
- Reloading post-migration is a no-op (idempotent)
- pickup.md updated with commit SHAs; STATE flipped to `IN_PROGRESS_CHUNK_2`

### Chunk 2 — Engine adaptation (direct)

**Work items:** W2 (`019e33ce5f18`)

**Branch:** `work-item/W2-engine-adaptation`

**Files expected:** `~/github/plugins/scansort/src/classifier.rs`, `~/github/plugins/scansort/src/rule_engine.rs`, `~/github/plugins/scansort/src/process.rs`.

**Exit checkpoint:**
- `cargo test --release` green
- Tax rule processes end-to-end with single-stage
- Lawyer rule (2-stage with filter on stage 1) drops irrelevant docs and processes survivors
- Stage-folding verified: 2 stages, no `keep_when`, issues 1 LLM call
- STATE → `IN_PROGRESS_CHUNK_3`

### Chunk 3 — Parallel mechanical (sub-agents)

**Work items:** W3 (`019e33ce6e24`), W11 (`019e33cf1e33`), W12 (`019e33cf2787`)

**Mode:** Spawn 3 sub-agents in parallel using the `Agent` tool with `isolation: "worktree"`. Each agent gets the docket description as its brief verbatim. Opus reviewer agent for each PR.

**Branches:** `work-item/W3-library-reorder-rules`, `work-item/W11-deprecate-path-tools`, `work-item/W12-edit-details-dropdown-switch`

**Per sub-agent prompt template:**
> "Implement work item [W#] under DCR 019e33bf. Acceptance criteria are in your docket description (id [019e33ce...]). Hard rules: no `git add -A`, no `--no-verify`, no touches to `vendor/`. Before every commit run `git diff --cached --stat` and explain each file against the work item's 'Files' section — refuse to commit if anything is unexpected. After your changes: cargo test green (Rust items) or panel smoke green (GD items). Report commit SHA(s) and final test count back."

**Per-PR reviewer prompt template (Opus):**
> "Review PR for work item [W#] against acceptance criteria in docket [id]. Reject if: (a) any files outside stated 'Files' section, (b) acceptance criteria bypassed, (c) scope crept beyond the docket. If reject, list specifics. If accept, list commit SHAs."

**Exit checkpoint:**
- All 3 PRs merged on main
- `cargo test --release` green
- STATE → `IN_PROGRESS_CHUNK_4`

### Chunk 4 — Parallel mechanical, second batch (sub-agents)

**Work items:** W4 (`019e33ce855a`), W8 (`019e33cedae8`)

**Mode:** 2 parallel sub-agents in worktrees, Opus reviewers. Same prompts as Chunk 3.

**Branches:** `work-item/W4-dryrun-one`, `work-item/W8-paste-json-dialog`

**Exit checkpoint:**
- Both PRs merged
- `dryrun_one` callable via MCP; returns documented shape on tax fixture
- Paste-JSON dialog opens, saves a new rule via `library_insert_rule`
- STATE → `IN_PROGRESS_CHUNK_5`

### Chunk 5 — Rules pane skeleton (direct)

**Work items:** W6 (`019e33ceb5ca`)

**Branch:** `work-item/W6-rules-pane-skeleton`

**Files expected:** `~/github/plugins/scansort/ui/ScansortPanel.gd` (new section), possibly new `~/github/plugins/scansort/ui/rules_pane.gd`.

**Exit checkpoint:**
- Pane visible in panel; lists library rules via `library_list_rules`
- Enable/disable toggle persists across panel reopen
- Fired-count shows integer when trace log readable; `—` otherwise
- Panel smoke ≥ 433/0
- STATE → `IN_PROGRESS_CHUNK_6`

### Chunk 6 — Row menu (direct, integrates everything)

**Work items:** W7 (`019e33cec9a2`)

**Branch:** `work-item/W7-row-menu`

**Files expected:** `~/github/plugins/scansort/ui/rules_pane.gd` (or panel extension), new `~/github/plugins/scansort/ui/dryrun_result_dialog.gd`.

**Exit checkpoint:**
- All 6 menu items wired: Test on…, Move up, Move down, View JSON, Edit JSON, Duplicate, Delete
- Dry-run result dialog shows per-stage trace
- Move up/down persists order
- Delete confirms before destructive action
- Panel smoke green
- **STATE → `AWAITING_HITL`**
- Comment added to DCR 019e33bf summarizing what shipped in chunks 1–6 (commit SHAs per work item, any deviations from plan)
- Phase 1 goal satisfied here; autonomous run stops

### HITL (user)

**Checklist:**
- Open Minerva → Scansort panel → Rules section
- Verify all library rules listed with correct enable state, subfolder preview, fired-counts
- Click a rule's `[⋮]` → Test on… → pick a sample PDF → confirm result panel shows score + per-stage trace + resolved subfolder/filename
- Move a rule up, reopen panel, verify order persisted
- Duplicate a rule, verify `_copy` suffix on label
- Open File menu — note the 4 vault-sidecar entries are still present (deleted in Chunk 7)
- File any bugs as work_items under DCR 019e33bf with title `Bug: <description>` and dependency `blocks` → W10 if a fix must land before cleanup, otherwise `follow_up`
- When satisfied: set Phase 2 `/goal` (text in §"/goal text" below), compact, resume

### Chunk 7 — Skill content + cleanup (direct)

**Work items:** W9 (`019e33cef75d`), W10 (`019e33cf0e9f`)

**Order:** W9 first (skill content lands and is testable), then W10 (delete old UI).

**Branches:** `work-item/W9-skill-content`, `work-item/W10-delete-old-ui`

**Files expected:**
- W9: `~/github/plugins/scansort/manifest.json` (add `skills` array with the rule-authoring skill, ~3-5 KB). No code.
- W10: `~/github/plugins/scansort/ui/ScansortPanel.gd` (delete 4 File-menu entries + handlers), `~/github/plugins/scansort/ui/rules_editor_dialog.gd` (delete entirely).

**Exit checkpoint:**
- Skill discoverable in focused-chat skill list when plugin loaded
- `grep -r 'rules_editor_dialog' ~/github/plugins ~/github/Minerva` returns zero hits
- File menu shows none of: "Vault Rules Editor", "Library Rules Editor", "Create Vault-Specific Rules", "Use Library Rules"
- Panel smoke ≥ 433/0
- All 12 work_items transitioned to `done`
- DCR 019e33bf transitioned to `shipped`
- **STATE → `SHIPPED`**
- Phase 2 goal satisfied; run stops

### Final HITL (user)

**Checklist:**
- Open focused chat in Minerva
- Add "Scansort rule authoring" skill to the focused-chat skill list
- Describe a use case (e.g., "I want to sort my tax docs by year and form type")
- Confirm skill walks you through, generates JSON, calls `library_insert_rule`
- New rule appears in rules pane
- Test it on a sample PDF via row menu → Test on…
- If clean: thank the agent, close the chat
- If issues: file follow-up bugs

---

## Hard rules (every commit, every chunk)

These are non-negotiable. The agent rejects its own commit if any rule is violated.

1. **No `git add -A` or `git add .`.** Per-file adds only.
2. **No `--no-verify`.** Hooks always run. If a hook fails, fix the underlying cause; do not bypass.
3. **No `--no-gpg-sign` or `-c commit.gpgsign=false`.**
4. **No `vendor/` touches.** Submodules (`vendor/EIRTeam.FFmpeg`, `vendor/godot_cef`) are not in scope for any work item. If staged, unstage.
5. **No `git reset --hard`, no destructive operations** without explicit user authorization.
6. **No force-push.** Ever.
7. **Pre-commit diff-stat enumerate-and-explain.** Before every commit: run `git diff --cached --stat`, then list each file and explain it against the work item's "Files" section. Refuse to commit if any file is unexpected.
8. **Layer-1 must be green before chunk transitions.** Rust changes: `cargo build --release && cargo test --release`. GD changes: panel smoke harness ≥ 433/0. Cross-cutting changes: both.
9. **Branch per work item.** Convention: `work-item/<W#>-<slug>`. Branch off the chunk's starting commit, not random WIP.
10. **Commit message refs the work_item ID** in the format `[W#] <title>` and includes docket short-id in the body.
11. **No scope creep.** Anything beyond the work item's stated acceptance criteria is a new work_item, filed under DCR 019e33bf. Do not silently expand.
12. **No editing this file (`Docs/pickup.md`) mid-chunk** except for STATE marker + `What's done / What's next` updates at chunk boundaries.

---

## Decisions not to relitigate

These are settled. Do not re-open during implementation. If something seems wrong, surface to the user — do not silently re-decide.

| Decision | Source-of-truth |
|---|---|
| Model A (per-rule pipelines, multi-rule walk preserved) over Model B | DCR 019e33bf description, §"Background" rubric scoring |
| Container name `stages` (not `pipeline` or `steps`) | DCR 019e33bf §"Design choices" table |
| Filter grammar: minimal (`==`, `!=`, `in [...]`) only | DCR 019e33bf §"Design choices" |
| Single-stage rules always wrapped in `stages: [{...}]` (no flat shortcut) | DCR 019e33bf §"Design choices" |
| Slot-name collisions across stages rejected at insert | DCR 019e33bf §"Design choices" |
| Cross-stage prompt templating disallowed in v1 | DCR 019e33bf §"Scope: OUT" |
| Default `on_filter` = leave doc in source (not quarantine, not delete) | DCR 019e33bf §"Design choices" |
| No built-in tokens — every template token comes from a `classify` slot | DCR 019e33bf §"Design choices" |
| `signals` and `subtypes` removed from schema | DCR 019e33bf §"Migration & deletions" |
| Phase 1 (rule scoring) preserved as cheap pre-filter | DCR 019e33bf §"Background" + rubric |
| Trace log is JSONL, persona-stripped, primary log (CSV is downstream projection) | DCR 019e33a2 description, full |
| UI label "Processing Log" (not "Audit Log") | DCR 019e33a2 §"Persona strip" |
| Authoring via focused-chat skill (not panel form), works for any in-Minerva LLM | DCR 019e33bf §"Authoring model" |
| One global rules library; no per-vault sidecars in UI | DCR 019e33bf §"Background" + §"Migration" |
| Path-driven rule MCP tools deprecated (W11), library_* tools are canonical | DCR 019e33bf §"Migration & deletions" |
| Per-rule classify-slot repetition accepted in v1 (skill carries copy-paste templates) | DCR 019e33bf §"Scope: OUT" |
| Reorder UX: up/down arrows in row menu, no drag-and-drop in v1 | DCR 019e33bf §"Rules pane UI" |
| Big HITL after Chunk 6 (W7 lands), small HITL after Chunk 7 | This file §"Per-chunk detail" |

---

## Stop conditions (surface to user mid-chunk)

The agent stops autonomous execution and pings the user when:

1. Any test fails after 3 fix attempts on the same test
2. An acceptance criterion cannot be met without scope creep
3. A work item's design surfaces a surprise (e.g., a buried dependency on another item not yet landed)
4. Time-box exceeded by 2× the wall-time estimate in §"The plan" (per chunk, cumulative)
5. Anything ambiguous in a docket description — do not guess
6. Build is broken on main and bisect can't identify a single-commit cause within 15 min
7. A user-authored file (under `~/github/Minerva/Docs/`, `~/github/plugins/scansort/README.md`) would need editing — surface, don't edit
8. Trace log DCR 019e33a2 phase 1+2 not yet landed by the time Chunk 4 starts (W4 dryrun_one depends on pre-placement trace events). If unlanded: surface; either land it inline or proceed with graceful fallback in dryrun_one.

---

## What's done / What's next

**Done:**
- Chunk 1: W1 + W5 — `work-item/W1-W5-schema-migration` @ `2477359` (plugins). New schema (stages/classify/keep_when) + library migration on load. 271 tests passing.
- Chunk 2: W2 — `work-item/W2-engine-adaptation` @ `2b576e2` (plugins). New `stage_walker.rs` (LLM caller trait + walk + folding + filter grammar); `rule_engine::run_with_stages` + slot template resolver; `process::CapabilityLlmCaller` adapter wired into runtime. 291 tests passing.

**Next:**
- Chunk 3: W3 + W11 + W12 — parallel sub-agents in worktrees, Opus reviewers. `library_reorder_rules` MCP tool, deprecate path-driven tools, edit_details dropdown switch.

---

## /goal text

### Phase 1 — run before Chunk 1

Copy-paste into Claude Code:

```
/goal Complete chunks 1-6 from /Users/ipeerbhai/github/Minerva/Docs/pickup.md for scansort rule schema redesign (DCR 019e33bfa10c). Each chunk's exit checkpoint in §"Per-chunk detail" must be met before proceeding to the next. After chunk 6 lands and panel smoke is green (≥433/0), update the STATE marker line in pickup.md from any IN_PROGRESS_CHUNK_N value to exactly "STATE: AWAITING_HITL" (the line beginning with STATE:, near the top of the file), add a comment on docket 019e33bfa10c summarizing what shipped (commit SHAs per work item, any deviations from plan), and stop. Goal is satisfied when pickup.md contains a line that exactly matches "STATE: AWAITING_HITL" and no line matching "STATE: IN_PROGRESS_CHUNK_". All hard rules in §"Hard rules" must hold for every commit. Stop after 350 total turns regardless of completion. Surface to user immediately on any of the conditions in §"Stop conditions".
```

### Phase 2 — run after HITL

```
/goal Complete chunk 7 from /Users/ipeerbhai/github/Minerva/Docs/pickup.md for scansort rule schema redesign (DCR 019e33bfa10c): W9 (skill content) and W10 (delete old UI). Each item's acceptance criteria must be met. After cleanup commits land and panel smoke stays green (≥433/0), update the STATE marker line in pickup.md to exactly "STATE: SHIPPED" (the line beginning with STATE:, near the top of the file), transition DCR 019e33bfa10c to shipped status, and stop. Goal is satisfied when pickup.md contains a line that exactly matches "STATE: SHIPPED". All hard rules in §"Hard rules" must hold. Stop after 100 total turns regardless of completion. Surface immediately on any failure pattern that can't be self-resolved in 3 attempts.
```

---

## Reference

### Docket IDs (short prefixes)

| ID | Title |
|---|---|
| `019e2787` | DCR — Scansort filing engine (parent, architectural spine) |
| `019e33a2` | DCR — Processing log (trace-first, persona-stripped) |
| `019e33bf` | DCR — Rule schema redesign (this implementation's target) |
| `019e2cc9` | DCR — Path-free (superseded by 019e33bf) |
| `019e33ce48c8` | W1 — Rule schema types |
| `019e33ce5f18` | W2 — Engine adaptation |
| `019e33ce6e24` | W3 — `library_reorder_rules` MCP tool |
| `019e33ce855a` | W4 — `dryrun_one` MCP tool |
| `019e33ce9ff1` | W5 — Schema migration |
| `019e33ceb5ca` | W6 — Rules pane skeleton |
| `019e33cec9a2` | W7 — Row menu |
| `019e33cedae8` | W8 — Paste-JSON dialog |
| `019e33cef75d` | W9 — Skill content |
| `019e33cf0e9f` | W10 — Delete old UI |
| `019e33cf1e33` | W11 — Deprecate path-driven tools |
| `019e33cf2787` | W12 — edit_details_dialog dropdown switch |

### Repos and branches

- `~/github/Minerva` on `user/imran/experiments/swarm`
- `~/github/plugins` on `main`

### Build / test commands (Quick reference)

- Rust: `cd ~/github/plugins/scansort && cargo build --release && cargo test --release`
- Plugin binary install: `cd ~/github/plugins/scansort && install -m 0755 target/release/scansort-plugin scansort-plugin`
- Panel smoke: `cd ~/github/Minerva && godot --headless --path src --script test/test_scansort_panel_smoke.gd`

### Cross-DCR dependency note

DCR 019e33a2 (trace log) phases 1+2 are a soft prerequisite for W4 (dryrun_one pre-placement events) and W6 (fired-count). Both have documented graceful-fallback paths. If 019e33a2 is unlanded when Chunk 4 begins, see Stop condition #8.

### Paused / orthogonal workstreams (not in scope here)

- Filing-engine DCR `019e2787` W12 (docs + cleanup) — separate from this implementation
- `019e2d8018` — `minerva_list_models` omits core provider — separate
- `019e2cfced` — B3/B4 quality follow-up — separate
- Medical-PDF process() hang bug (filed during B8 iter2) — separate; if encountered during dry-run testing, surface and file follow-up; do not investigate inline

### Carry-forward constraints

- 5-min model-chat cold-start ceiling: timeouts beyond that = bug, not warmup
- After ~5 identical-args MCP tool failures, broker BLOCKS the tool. Don't poll-retry — fix root cause or change args.
- Plugin must be explicitly started post-MCP-initialize: `mcp.call("minerva_plugin_start", {"id": "scansort"})`. Install/load is not enough.

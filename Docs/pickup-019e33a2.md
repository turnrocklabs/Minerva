# Pickup — Scansort processing log (DCR 019e33a2) — autonomous implementation

STATE: PLAN_READY

Last updated: 2026-05-17

---

## STATE marker (READ THIS FIRST)

The `STATE:` line above is the goal-completion predicate. Haiku reads it every turn to decide whether the active `/goal` is satisfied. Valid values:

| State | Meaning |
|---|---|
| `PLAN_READY` | Plan written. No `/goal` set yet. No work started. |
| `IN_PROGRESS_CHUNK_1` … `IN_PROGRESS_CHUNK_3` | Phase 1 autonomous run in flight on the named chunk. |
| `AWAITING_HITL` | Chunks 1–3 done. Phase 1 goal satisfied. User HITL pending (live panel + LLM background sanity). |
| `SHIPPED` | DCR 019e33a2 transitioned to shipped; all W1–W4 work_items done. |

**Update this marker at every chunk boundary.** Edit the top-of-file `STATE:` line in the same commit that advances the chunk.

---

## Cold-start procedure (zero-context resume)

If you're reading this with no conversation history, execute in this exact order:

1. `git -C ~/github/Minerva pull --ff-only` (branch: `user/imran/experiments/swarm`)
2. `git -C ~/github/plugins pull --ff-only` (branch: `main`)
3. Read this file in full (you're here).
4. Read DCR description: `mcp__docket__docket_query` with `{"conditions":[{"field":"id","op":"eq","value":"019e33a2ab2e7581bf0bdcbf5ddf0aeb"}]}` and `detail: "full"`.
5. Read the design comment (latest) on the DCR — captures the MCP interface decision.
6. Identify current chunk from the STATE marker. Read every work_item in that chunk's "Work items" column (`docket_query` with `parent` filter on the DCR id).
7. Resume execution from the chunk's "What's left in this chunk" sub-section.

If STATE is `PLAN_READY` and a `/goal` is already active, start at Chunk 1.

---

## The plan — quick reference table

| Chunk | Work items | Mode | Approx wall-time | Exit checkpoint |
|---|---|---|---|---|
| 1 | W1 (`019e389ffd43`) | Direct (sequential) | ~1.5 h | `cargo test` green; old audit.rs gone; new `minerva_scansort_trace_append` callable; settings auto-migration tested |
| 2 | W2 (`019e38a034e7`) | Direct | ~2 h | `cargo test` green; process() emits full trace; `dryrun_one` emits with `mode:"dryrun"`; ProcessResult carries `run_id` |
| 3 | W3 + W4 | Parallel sub-agents in worktrees, Opus reviewers | ~1 h wall | Both merged; panel smoke green; manual: panel live-updates during a run; LLM-mode trace_query returns events |
| **HITL** | — | **User** | user time | Live panel observed during a real Process All; LLM-mode background invocation observed via trace_tail without any panel; both scenarios produce identical trace stream |
| FINAL | — | autonomous | minutes | All four work_items transitioned to `done`; DCR 019e33a2 transitioned to `shipped`; STATE → SHIPPED |

---

## Verification matrix — what a human checks for each STATE

A `/goal` line on its own says little. Use this to spot-check the agent's claimed STATE from the outside, in any terminal, in seconds. Every cell is something you can `git`/`cargo`/`docket_query` directly.

| STATE | Branch/commit state | Files on disk | Test counts | Docket state | Smoke-test ritual |
|---|---|---|---|---|---|
| **PLAN_READY** | `Minerva` main has `Docs/pickup-019e33a2.md`; no `work-item/W*-*` branches on `plugins`. | Pickup file present. | Baseline (no new tests). | DCR 019e33a2 = `designing`; W1–W4 all `backlog`. | n/a |
| **IN_PROGRESS_CHUNK_1** | `plugins` has branch `work-item/W1-trace-infrastructure`, not yet merged. | WIP `trace.rs`; `audit.rs` still on main. | n/a (WIP) | W1 = `in_progress`. | n/a |
| **IN_PROGRESS_CHUNK_2** (W1 done) | `plugins` main HEAD has commit `[trace-W1] …`; W1 branch gone or fast-forwarded. | `scansort/src/trace.rs` EXISTS; `scansort/src/audit.rs` GONE; settings keys renamed. | `cargo test --release` ≥ 291 + new trace round-trip tests, all green; `minerva_scansort_trace_append` registered, `minerva_scansort_audit_append` no longer registered. | W1 = `done`; W2 = `in_progress`. | Call `minerva_scansort_trace_append` with a tiny event payload → returns ok; tail the configured JSONL file → see the event. |
| **IN_PROGRESS_CHUNK_3** (W2 done) | `plugins` main HEAD has commit `[trace-W2] …`. | `scansort/src/trace.rs` has a `Tracer` struct with all event-emit methods; `process.rs` constructs Tracer in `run` and `dryrun_one`. | `cargo test --release` green incl. new W2 integration tests; ProcessResult JSON now contains a `run_id` ULID. | W2 = `done`; W3 + W4 both `in_progress`. | Run `--hitl` against a tiny fixture; capture `result.run_id`; tail the trace JSONL → see `run_started`, `doc_seen × N`, `rule_evaluated`, `placement` or `doc_unprocessable`, `run_completed`; counts in `run_completed` match `result.summary`. |
| **AWAITING_HITL** (W3 + W4 done) | `plugins` main HEAD has commits `[trace-W3] …` and `[trace-W4] …`. | `scansort/ui/trace_tail.gd` EXISTS; `scansort/ui/ScansortPanel.gd` references it; `scansort/src/main.rs` registers 3 new tools `trace_query`, `trace_list_runs`, `trace_tail`. | `cargo test --release` green incl. W4 tool tests; panel smoke ≥ baseline. | W3 = `done`; W4 = `done`; DCR 019e33a2 = `implementing`. | (a) Open Scansort panel → trigger Process All → watch the bottom status bar tick `Processing X (k/N)…` and the rules-pane fired-counts increment; (b) close the panel → trigger a second Process All via MCP → no UI changes, trace file gets a new run; (c) call `minerva_scansort_trace_list_runs` → see both runs; `minerva_scansort_trace_query {run_id}` → see full event stream for either run. |
| **SHIPPED** | (no new code commits required beyond `AWAITING_HITL`) | Same as `AWAITING_HITL`. | Same as `AWAITING_HITL`. | All W1–W4 = `done`; DCR 019e33a2 = `shipped`. | n/a — already validated during HITL. |

### One-liner spot checks

Copy-paste verifications you can run in any terminal:

```bash
# Current STATE line (should match the marker at the top of this file)
grep '^STATE:' ~/github/Minerva/Docs/pickup-019e33a2.md

# W-item statuses (should track the matrix row)
for id in 019e389ffd43 019e38a034e7 019e38a06dd5 019e38a09ed1; do
  echo "=== $id ==="
  # via docket MCP if available; otherwise via gh/jq or the docket UI
done

# DCR status
# mcp__docket__docket_get id=019e33a2 → look at status field

# audit.rs absence (post-W1)
test -f ~/github/plugins/scansort/src/audit.rs && echo "FAIL: audit.rs still present" || echo "ok: audit.rs gone"

# trace.rs presence (post-W1)
test -f ~/github/plugins/scansort/src/trace.rs && echo "ok" || echo "FAIL: trace.rs missing"

# trace_tail.gd presence (post-W3)
test -f ~/github/plugins/scansort/ui/trace_tail.gd && echo "ok" || echo "FAIL: trace_tail.gd missing"

# New MCP tools registered (post-W4) — search the plugin's tool registration
grep -E 'minerva_scansort_(trace_append|trace_query|trace_list_runs|trace_tail)' \
  ~/github/plugins/scansort/src/main.rs | sort -u

# Tests green
cd ~/github/plugins/scansort && cargo test --release 2>&1 | tail -3
```

If any row of the matrix doesn't line up with the agent's claimed STATE, the agent has cheated/skipped — surface immediately and read the per-chunk detail below.

---

## Per-chunk detail

### Chunk 1 — Trace infrastructure (direct)

**Work item:** W1 (`019e389ffd43`)

**Branch:** `work-item/W1-trace-infrastructure`

**Files expected:** `~/github/plugins/scansort/src/trace.rs` (new), `~/github/plugins/scansort/src/main.rs` (modified — register new tool, remove old), `~/github/plugins/scansort/src/audit.rs` (DELETED), settings-bearing GDScript file(s) under `~/github/plugins/scansort/ui/` (rename `audit_log_*` → `trace_log_*`, label rename).

**Exit checkpoint:**
- `cargo test --release` green (≥ 291 + new trace round-trip + concurrent-append tests)
- `audit.rs` file gone; `minerva_scansort_audit_append` no longer registered
- Settings auto-migration: pre-existing `audit_log_path` on a `.csv` → `trace_log_path` on `.jsonl` alongside, `.csv` untouched, one-time info toast surfaces
- Panel smoke ≥ baseline
- STATE → `IN_PROGRESS_CHUNK_2`
- Commit message: `[trace-W1] scansort: trace infrastructure — JSONL writer + minerva_scansort_trace_append + settings rename + audit.rs removal`

### Chunk 2 — Engine instrumentation (direct)

**Work item:** W2 (`019e38a034e7`)

**Branch:** `work-item/W2-engine-instrumentation`

**Files expected:** `~/github/plugins/scansort/src/trace.rs` (add Tracer struct), `~/github/plugins/scansort/src/process.rs` (Tracer wiring in `run` + `dryrun_one`), `~/github/plugins/scansort/src/main.rs::handle_process` (thread trace path from settings; return run_id).

**Exit checkpoint:**
- `cargo test --release` green; new integration test asserts event ordering on a small fixture
- `process()` writes a complete trace per the parent DCR §Reframe vocabulary
- `dryrun_one` emits the same shape with `mode: "dryrun"` in `run_started`
- `ProcessResult.run_id` populated; matches the trace
- `run_completed` summary matches `ProcessResult` summary
- STATE → `IN_PROGRESS_CHUNK_3`
- Commit message: `[trace-W2] scansort: engine instrumentation — Tracer abstraction emits run/doc/rule events from process()`

### Chunk 3 — Parallel (W3 + W4) — sub-agents in worktrees

**Work items:** W3 (`019e38a06dd5`), W4 (`019e38a09ed1`)

**Mode:** Spawn 2 sub-agents in parallel via the `Agent` tool with `isolation: "worktree"`. Each gets the docket description as its brief verbatim. Opus reviewer for each PR.

**Branches:** `work-item/W3-panel-binding`, `work-item/W4-trace-mcp-tools`

**Per sub-agent prompt template:**
> Implement work item [W#] under DCR 019e33a2 (Scansort processing log — trace-first). Acceptance criteria are in your docket description (id [019e38a0...]). Hard rules: no `git add -A`, no `--no-verify`, no touches to `vendor/`. Before every commit run `git diff --cached --stat` and explain each file against the work item's "Files" section — refuse to commit if anything is unexpected. After your changes: cargo test green (W4) or panel smoke green (W3). Report commit SHA(s) and final test count back.

**Per-PR reviewer prompt template (Opus):**
> Review PR for work item [W#] under DCR 019e33a2 against acceptance criteria in docket [id]. Reject if: (a) any files outside stated "Files" section, (b) acceptance criteria bypassed, (c) scope crept beyond the docket. The big invariants: (i) panel must not auto-open during process() — silent background workflow preserved, (ii) trace event vocabulary matches the parent DCR §Reframe verbatim — no new fields, no missing ones, (iii) MCP tool inputSchema matches the W4 description exactly. If reject, list specifics. If accept, list commit SHAs.

**Exit checkpoint:**
- Both PRs merged on main
- `cargo test --release` green
- Panel smoke green
- **STATE → `AWAITING_HITL`**
- Comment added to DCR 019e33a2 summarizing what shipped (commit SHAs per work_item, any deviations from plan)
- Phase 1 goal satisfied; autonomous run stops

### HITL (user)

**Checklist:**
- Open Minerva → Scansort panel → set source dir + destination → click Process All → confirm live status-bar updates (Processing X (k/N), Last: X → rule, Run done summary), rules pane fired-count populates
- Close the panel → trigger another Process All via MCP from a chat (or harness) → confirm no panel state changes, trace file gets written, scansort-smoke harness still passes
- From a chat or external MCP caller: invoke `minerva_scansort_trace_list_runs` → see both runs; `minerva_scansort_trace_query {run_id}` → see full event stream; `minerva_scansort_trace_tail` against an in-flight third run → see events stream in
- Either workflow surfaces identical trace stream (UI and LLM converge)
- File any bugs as work_items under DCR 019e33a2 (or 019e33bf if cross-cutting) with title `Bug: <description>`
- When satisfied: transition the four W-items to `done`, transition DCR 019e33a2 to `shipped`, set STATE → `SHIPPED`

### Final autonomous tick

After HITL approval, agent transitions DCR + work_items and updates STATE. Trivial — typically a single turn.

---

## Hard rules (every commit, every chunk)

These are non-negotiable. The agent rejects its own commit if any rule is violated.

1. **No `git add -A` or `git add .`.** Per-file adds only.
2. **No `--no-verify`.** Hooks always run. If a hook fails, fix the underlying cause; do not bypass.
3. **No `--no-gpg-sign` or `-c commit.gpgsign=false`.**
4. **No `vendor/` touches.** Submodules (`vendor/EIRTeam.FFmpeg`, `vendor/godot_cef`) are not in scope for any work_item. If staged, unstage.
5. **No `git reset --hard`, no destructive operations** without explicit user authorization.
6. **No force-push.** Ever.
7. **Pre-commit diff-stat enumerate-and-explain.** Before every commit: run `git diff --cached --stat`, then list each file and explain it against the work_item's "Files" section. Refuse to commit if any file is unexpected.
8. **Layer-1 must be green before chunk transitions.** Rust changes: `cargo build --release && cargo test --release`. GD changes: panel smoke harness ≥ baseline (currently 433/0 on Linux desktop; macOS has 1 pre-existing reprocess symlink-escape failure that does NOT count as a regression). Cross-cutting: both.
9. **Branch per work_item.** Convention: `work-item/<W#>-<slug>`. Branch off the chunk's starting commit, not random WIP.
10. **Commit message refs the work_item ID** in the format `[trace-W#] <title>` and includes docket short-id in the body.
11. **No scope creep.** Anything beyond the work_item's stated acceptance criteria is a new work_item, filed under DCR 019e33a2. Do not silently expand.
12. **No editing this file (`Docs/pickup-019e33a2.md`) mid-chunk** except for STATE marker + `What's done / What's next` updates at chunk boundaries.

---

## Decisions not to relitigate

These are settled. Do not re-open during implementation. If something seems wrong, surface to the user — do not silently re-decide.

| Decision | Source-of-truth |
|---|---|
| Trace is the canonical observability surface (UI + LLM both subscribe; no mode flag) | DCR 019e33a2 design comment (2026-05-17) |
| `process()` stays SYNC; adds `run_id` to result | DCR 019e33a2 design comment, W2 acceptance |
| Trace events fire to dual sink: JSONL on disk + Godot signal in-process | DCR 019e33a2 design comment |
| Event vocabulary is fixed by parent DCR §Reframe — `run_started`, `doc_seen`, `rule_evaluated`, `template_resolved`, `placement`, `doc_unprocessable`, `error`, `run_completed` | DCR 019e33a2 description |
| Pipeline events (`stage_executed`, `doc_filtered`) RESERVED in shape, NOT emitted in this DCR | DCR 019e33a2 §Implementation phases ¶3 |
| `audit.rs` is REMOVED in W1 (not parallel-maintained) | DCR 019e33a2 §Migration |
| Settings auto-migration preserves user's `.csv` untouched; writes `.jsonl` alongside | DCR 019e33a2 §Migration |
| Panel never auto-opens during process(); background workflow preserved | DCR 019e33a2 design comment, W3 acceptance |
| W3 (panel) and W4 (MCP tools) are parallel subscribers — no ordering dependency between them | DCR 019e33a2 W3+W4 |
| CSV export tool is a SEPARATE follow-up DCR (not bundled here) | DCR 019e33a2 §Implementation phases ¶4 |

---

## Stop conditions (surface to user mid-chunk)

The agent stops autonomous execution and pings the user when:

1. Any test fails after 3 fix attempts on the same test
2. An acceptance criterion cannot be met without scope creep
3. A work_item's design surfaces a surprise (e.g., audit.rs has callers we didn't know about)
4. Time-box exceeded by 2× the wall-time estimate (per chunk, cumulative)
5. Anything ambiguous in a docket description — do not guess
6. Build is broken on main and bisect can't identify a single-commit cause within 15 min
7. A user-authored file (under `~/github/Minerva/Docs/`, `~/github/plugins/scansort/README.md`) would need editing — surface, don't edit
8. The DCR 019e33bf pipeline work appears to be landing in parallel and would conflict with W2's Tracer placement — surface, coordinate, don't merge blindly

---

## What's done / What's next

**Done:**
- DCR 019e33a2 decomposed into W1–W4 (filed 2026-05-17 in HITL session, mac laptop). Linked: W2 blocks-by W1; W3 blocks-by W2; W4 blocks-by W2.
- DCR transitioned proposed → approved → designing.
- This pickup file landed.

**Next:**
- Phase 1 `/goal` (text in §"/goal text" below) drives Chunks 1–3 to `AWAITING_HITL`.

---

## /goal text

### Phase 1 — run now

Copy-paste into Claude Code:

```
/goal Complete chunks 1-3 from /Users/ipeerbhai/github/Minerva/Docs/pickup-019e33a2.md for scansort processing-log DCR 019e33a2. Each chunk's exit checkpoint in §"Per-chunk detail" must be met before proceeding to the next. After chunk 3 lands and panel smoke is green plus cargo tests green, update the STATE marker line in pickup-019e33a2.md from any IN_PROGRESS_CHUNK_N value to exactly "STATE: AWAITING_HITL" (the line beginning with STATE:, near the top of the file), add a comment on docket 019e33a2 summarizing what shipped (commit SHAs per work_item, any deviations from plan), and stop. Goal is satisfied when pickup-019e33a2.md contains a line that exactly matches "STATE: AWAITING_HITL" and no line matching "STATE: IN_PROGRESS_CHUNK_". All hard rules in §"Hard rules" must hold for every commit. Stop after 200 total turns regardless of completion. Surface to user immediately on any of the conditions in §"Stop conditions".
```

### Final tick — run after HITL

```
/goal Wrap DCR 019e33a2 (scansort processing log). Transition all four W-items (019e389ffd43, 019e38a034e7, 019e38a06dd5, 019e38a09ed1) to "done". Transition DCR 019e33a2 to "shipped". Update STATE marker in pickup-019e33a2.md to exactly "STATE: SHIPPED". Goal is satisfied when STATE line matches "STATE: SHIPPED" and the DCR shows status=shipped via docket_query. Stop after 20 total turns.
```

---

## Reference

### Docket IDs (short prefixes)

| ID | Title |
|---|---|
| `019e33a2` | DCR — Scansort processing log (this implementation's target) |
| `019e2787` | DCR — Scansort filing engine (parent; §7 audit-log design superseded by this DCR) |
| `019e33bf` | DCR — Rule schema redesign (sibling DCR; pickup.md is its plan) |
| `019e24c5` | U-series — panel chrome that W3 binds into |
| `019e389ffd43` | W1 — trace infrastructure |
| `019e38a034e7` | W2 — engine instrumentation |
| `019e38a06dd5` | W3 — panel binding |
| `019e38a09ed1` | W4 — LLM-facing MCP query tools |

### Repos and branches

- `~/github/Minerva` on `user/imran/experiments/swarm`
- `~/github/plugins` on `main`

### Build / test commands (quick reference)

- Rust: `cd ~/github/plugins/scansort && cargo build --release && cargo test --release`
- Plugin binary install: `cd ~/github/plugins/scansort && install -m 0755 target/release/scansort-plugin scansort-plugin`
- Panel smoke: `cd ~/github/Minerva && godot --headless --path src --script test/test_scansort_panel_smoke.gd`

### Carry-forward constraints

- 5-min model-chat cold-start ceiling: timeouts beyond that = bug, not warmup.
- After ~5 identical-args MCP tool failures, broker BLOCKS the tool. Don't poll-retry — fix root cause or change args.
- Plugin must be explicitly started post-MCP-initialize: `mcp.call("minerva_plugin_start", {"id": "scansort"})`. Install/load is not enough.
- macOS-only `reprocess::tests::reprocess_directory_resolves_symlink_before_safety_check` is pre-existing — do not count it as a regression on darwin.
- Sibling DCR 019e33bf's pickup.md still has `STATE: AWAITING_HITL`. This DCR's work touches `process()` and `dryrun_one`, both of which are 019e33bf phase-1 surfaces. If 019e33bf's pickup-driven HITL produces a new work_item that lands in those files in parallel, COORDINATE — surface rather than merge blindly (stop condition #8).

### Carry-forward context from 2026-05-17 HITL session

- Minerva broker fix (commit `e9696765`): plugin-supplied images now route through `chi.InjectedNotes` so `CoreProvider.Format` actually delivers them. Prerequisite for any trace event that involves image-bearing chat calls (W2 doesn't emit image data in trace events directly — but image classifications now work end-to-end, which means trace events for those classifications are meaningful).
- Plugin commit `82f515f`: vision pipeline fixes (broker-shape messages, minimal generic prompt, PNG resampler at 256×256). These changes touched `classifier.rs`, `stage_walker.rs`, `render.rs`, `rules.rs` — overlapping with W2's `process.rs` edits. W2 builds on top of these — no conflict expected since W2 only adds the Tracer wiring.
- Test status post-2026-05-17: `cargo test --release` 291/1 (1 pre-existing macOS reprocess symlink-escape failure — not a regression).

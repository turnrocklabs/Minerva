# Pickup

STATE: `PLUGINS MERGED TO MAIN · MINERVA STAYS ON SWARM BRANCH`

Last updated 2026-05-26. Two DCRs and three pri-1/2 bugs landed today
across two remora cycles. Plugins repo is on main. Minerva stays on
`user/imran/experiments/swarm` per user direction.

---

## 0. ONE-LINE SUMMARY ON RESUME

- **Plugins**: `main` at `d25883a` — DCR `019e5068f584` (vault-lifecycle)
  + DCR `019e564809a9` (scansort agent-UX, 3 cycles) + 2 remora landings
  all shipped. 33 commits forward of the prior main `bd2251ef`.
- **Minerva**: `user/imran/experiments/swarm` at `85602b65` — ChatPane
  freed-node-guard fix + the panel-loop e2e test. Not merged to main per
  user direction; stays on the swarm branch.
- **All 4 remora bugs**: closed (verified via HITL 2026-05-26).

---

## 1. WHERE EVERYTHING LIVES (post-merge)

```
~/github/plugins
  main            → d25883a fix: scansort handle_process_run offset advancement
  dcr/scansort-agent-visibility  → same commit (merged-from branch, kept locally)

~/github/Minerva
  user/imran/experiments/swarm   → 85602b65 test: add panel-loop e2e
  main           → unmerged; stays this way per user direction
```

Submodule pointer drift on `vendor/godot_cef` + `vendor/godot_wry` is
pre-existing; do not touch.

---

## 2. WHAT SHIPPED TODAY (across the two remora cycles)

### Remora-1 (2026-05-24/25): visibility + chat exception
- Bug `019e5bc8dae47584a1f9b9fcb9868173` (PRI-0, Minerva) — ChatPane
  zombie coroutine using freed `model_msg_node` after stop+redispatch.
  Fix: static helper `_are_ui_args_valid` + guards on
  `update_ui_after_response` / `_no_signal` + inline guard in
  `execute_hcp_chat`. Test: `test_chatpane_freed_node_guard.gd` 7/0.
  Minerva commit `32de4409`.
- Bug `019e5bc927417448b09ef38f21db0b40` (scansort) — `b.errors[]` not
  populated. Fix: end-of-run loop pushes `result.items` non-success
  entries. Plugins `81ce583`.
- Bug `019e5bc946807b0db2dcfab842670782` (scansort) — audit log silent
  on failure. Fix: `audit::AuditRow` per failure when audit_enabled.
  Plugins `81ce583`.
- Shared regression: `process_pipeline_v2.rs::bug_019e5bc927_and_5bc946_failure_visibility`.

### Remora-2 (2026-05-26): offset advancement + filter
- Bug `019e6269890f7de48fdb689a0e99d9bd` (PRI-1, scansort) —
  `handle_process_run` hard-coded `offset=0`; panel limit=1 loop walked
  file[0] N times. Regression-revival of `019e5802d5d8` at the
  offset-advancement layer. Fix: new accessor
  `process::current_batch_files_done()` returns `b.files_done()`; used
  in `handle_process_run` instead of literal 0. Filter blocks also
  fixed to exclude `"moved"` (success status, not failure).
- Regression tests:
  - Cargo: `process_pipeline_v2.rs::bug_offset_advancement_panel_loop_pattern`
    (3 distinct-content PDFs, asserts DISTINCT rel_paths in errors[]).
  - Functional: `test_scansort_panel_loop_e2e.gd` — sibling to
    `test_scansort_filing_e2e.gd`, drives cycle-3 `process_plan +
    process_run(limit=1, no offset)` pipeline.
- Plugins commit `d25883a`; Minerva commit `85602b65`.

### HITL verification (2026-05-26)
User-driven run on 7-PDF source through the panel button:
- Pre-fix: `placed:1, errored:6, errors:[7 same rel_path]`
- Post-fix: `placed:7, errored:0, errors:[]`. Vault doc_count climbed
  1 → 7 across the runs.

---

## 3. TEST GATE (final)

- Cargo bin: **387/0** (release)
- Wire tests, all green:
  - `mcp_wire_numeric_args` 1/1
  - `session_describe` 1/1
  - `dryrun_session` 1/1
  - `library_path_isolation` 1/1
  - `vault_label` 1/1
  - `manifest_validation` 6/0
  - `process_pipeline_v2` **7/0** (added 2 regression tests this week)
- Functional suite (`scripts/run-functional-tests.sh --all`): **6/0**
  (scansort_filing_e2e + scansort_panel_loop_e2e + cad + presentation
  + 2 hermetic — new panel-loop test SKIPs cleanly without
  model-chat).
- Minerva headless ChatPane regression: **7/0**

Binary deployed: `install -m 755 target/release/scansort-plugin ./scansort-plugin`
in `~/github/plugins/scansort/`.

---

## 4. DOCKET CLOSE-OUT

| Item | Type | Final state | Notes |
|---|---|---|---|
| `019e5bc8dae47584a1f9b9fcb9868173` | bug | closed | Chat exception, pri-0 |
| `019e5bc927417448b09ef38f21db0b40` | bug | closed | errors[] propagation |
| `019e5bc946807b0db2dcfab842670782` | bug | closed | audit-on-failure |
| `019e6269890f7de48fdb689a0e99d9bd` | bug | closed | offset advancement |

**Heads up about DCR `019e564809a9` + `019e5068f584`**: these were
tracked via memory + the in-session task list, NOT formally filed as
docket items (audited 2026-05-26 — DCR ID lookup returned "not found"
across all projects). The work is verifiably shipped via the git log on
main; docket-only audits will miss the multi-cycle history. Session
nudge `docket-process/memory-vs-docket-tracking-gap` captures this for
future policy decisions.

---

## 5. STILL-PENDING FOLLOW-UPS (under the same scansort area)

These were filed yesterday + today as deferred items. None are
blocking; pick up in any order.

From the prior cycle-3 backlog:
- `019e566ea3eb` — manifest/tools-list codegen
- `019e5671eea7` — tool_err coverage for session_describe + dryrun_session
- `019e56720a92` — `tail_rows` O(file_size)
- `019e57749bcb` — T7 obs (a) state_changed subscription
- `019e5774c543` — T7 obs (b) vault unlock cross-surface
- `019e566e5fa5` — extend lax_* helpers
- `019e58319f75` — delete legacy `process::snapshot_json`
- `019e5831ae93` — `ProcessPlan::empty(scope)` helper
- `019e5834a2b7` — panel Stop surface cancel failure
- `019e5834b518` — process_plan negative-path test coverage
- `019e5834ce3f` — process_run O(N²) over iterations

From today's reviewer notes (DRY F1/F2/F3, deferred):
- Task #135 — factor `is_failure` into `ProcessItem::is_failure()` (2 sites in process.rs now duplicate the match)
- Task #136 — extract `scansort_e2e_common.gd` (the two functional tests duplicate ~250 lines of plumbing)
- Task #137 — `tests/common::open_source_and_plan` helper (the 2 panel-loop cargo tests duplicate ~30 lines)

The above are caveats only when a 3rd similar consumer surfaces.

---

## 6. WHAT TO DO NEXT SESSION

No active scansort work. Suggested entry points if you come back to
this area:
- Knock off any of the §5 follow-ups (each is small + well-scoped).
- Look at the docket-vs-memory tracking gap noted above — decide
  whether multi-cycle DCRs should always be explicitly filed up front.
- The Minerva swarm branch hosts the ChatPane fix + a build.yml CI
  pipeline thread from the laptop — those are likely targets for the
  next merge-to-main cycle once you're ready.

---

## 7. HARD RULES (unchanged)

- Per-file `git add` only — never `-A` or `.`. No `--no-verify`. No
  `vendor/` touches.
- scansort source documents are READ-ONLY at runtime.
- No force-push, no `git reset --hard`, no push without an explicit
  user ask.
- Never `cp` over a mapped binary — use `install -m 755` (atomic).
- pkill target is `godot`, not `Minerva`.
- Co-author trailer: `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`.
- Use MCP for state probes, not filesystem reads.

---

## 8. MEMORY LANDMARKS

- `MEMORY.md` Active Work line — should be retired or pointed at
  whatever you take up next.
- `project_active_scansort_agent_visibility_dcr.md` — terminal state
  reached; the DCR shipped to main today. Memory file kept for
  reference but no longer "active."
- Durable docket hints from this work-cycle stack:
  - `019e57af4a8e` — spawned-binary `#[cfg(test)]` override invisible
  - `019e5b67e03b` — per-call→per-batch accumulators (+= not =)
  - `019e5b680716` — scansort-mcp stdio blocks read-only tools mid-run
- Session nudges (this stack — promote any that recur):
  - `scansort-testing/distinct-content-per-test-file`
  - `scansort-process-pipeline/handle-process-run-offset-zero-bug`
  - `docket-process/memory-vs-docket-tracking-gap`

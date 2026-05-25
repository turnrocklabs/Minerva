# Pickup

STATE: `REMORA CYCLE CODE-COMPLETE — 3 BUG FIXES + 1 REGRESSION TEST EACH, AWAITING HITL`

Last updated 2026-05-25. Resume from this state on any device.

---

## 0. ONE-LINE SUMMARY ON RESUME

DCR `019e564809a9` cycles 1-3 shipped previously. The remora cycle filed
yesterday is now code-complete: 1 pri-0 Minerva chat fix + 2 scansort
visibility fixes, each with a Layer-2 regression test pinning the bug ID.
All gates green. Awaiting user HITL on the chat repro + a live scansort
re-run with audit.

---

## 1. WHERE EVERYTHING LIVES

- **Plugins repo:** `~/github/plugins` on `dcr/scansort-agent-visibility`
  HEAD `81ce583` (remora commit) on top of `370763b` (cycle-3 close) —
  25 commits ahead of base `50b4571` (predecessor DCR's HEAD).
- **Minerva repo:** `~/github/Minerva` on `user/imran/experiments/swarm`
  HEAD `32de4409` (remora commit) on top of `c205a215` (laptop CI work) /
  `8e5225c7` (EOD handoff).
- Submodule pointer drift on `vendor/godot_cef` + `vendor/godot_wry` is
  pre-existing; do not touch (per CLAUDE.md).

Verify:
```
cd ~/github/plugins
git log --oneline -2          # → 81ce583 fix: scansort…  then 370763b…
git status --porcelain        # → clean

cd ~/github/Minerva
git log --oneline -2          # → 32de4409 fix: ChatPane…  then c205a215…
git status --porcelain        # → only vendor/ submodule drift
```

---

## 2. WHAT THE REMORA CYCLE SHIPPED

### A. Bug `019e5bc8dae47584a1f9b9fcb9868173` — ChatPane zombie coroutine (PRI-0)
File: `~/github/Minerva/src/Scripts/UI/Views/ChatPane.gd`
Commit: Minerva `32de4409`.

Fix (rubric Opt 2 — 23/28):
- New static helper `_are_ui_args_valid(user_history_item, user_msg_node,
  model_msg_node)` centralizes the `is_instance_valid` check.
- Guards added at the top of `update_ui_after_response` and
  `update_ui_after_response_no_signal` so any zombie call returns with a
  `push_warning` instead of crashing.
- Inline guard after the await in `execute_hcp_chat` (HCP path touches
  `model_msg_node` directly before the function call).
- 4 call sites total covered (1530 regenerate, 1548 execute_hcp_chat,
  1672 execute_regular_chat else, 1662 execute_regular_chat tool-calls,
  2138 worker path) — all flow through the guarded functions.

Regression: `src/test/test_chatpane_freed_node_guard.gd` — 7/7 PASS.
Headless: `godot --headless --path src --script test/test_chatpane_freed_node_guard.gd`.

### B. Bug `019e5bc927417448b09ef38f21db0b40` — process_run b.errors[] not populated
File: `~/github/plugins/scansort/src/process.rs`
Commit: plugins `81ce583`.

Fix: end-of-process::run, iterate `result.items` inside the existing
`with_controller` block, push BatchError{rel_path, message} into
`b.errors` for every non-success disposition. Counter bump stays as-is;
only the error array gains entries.

Regression: `process_pipeline_v2.rs::bug_019e5bc927_and_5bc946_failure_visibility`
— 3 distinct-content PDFs, all classify-fail, asserts
`errors[].len()==3` with non-empty messages.

### C. Bug `019e5bc946807b0db2dcfab842670782` — audit log silent on failure
File: `~/github/plugins/scansort/src/process.rs`
Commit: plugins `81ce583`.

Fix: before the with_controller block at run-end, when
`audit_enabled && !audit_path.is_empty()`, iterate `result.items`,
build an `audit::AuditRow` per non-success entry (source_filename =
`"label/rel_path"` since ProcessItem doesn't carry abs_path;
sha256/destination columns left empty for early-fail paths), append_rows.
Non-fatal on audit failure (same handling as the success path).

Same regression test covers this — asserts `audit_tail` returns 3 rows
with non-empty detail + non-"placed" disposition.

---

## 3. TEST GATE (all green at 2026-05-25)

- **Cargo bin (release):** 387/0
- **Wire tests:**
  - mcp_wire_numeric_args 1/1
  - session_describe 1/1
  - dryrun_session 1/1
  - library_path_isolation 1/1
  - vault_label 1/1
  - manifest_validation 6/0
  - process_pipeline_v2 **6/0** (was 5, +1 from remora regression)
- **Functional suite:** 5/0 via `scripts/run-functional-tests.sh --all`
  (scansort + cad + presentation + 2 hermetic)
- **Minerva headless:** test_chatpane_freed_node_guard 7/0

Binary deployed: `install -m 755 target/release/scansort-plugin ./scansort-plugin`
inside `~/github/plugins/scansort/`.

---

## 4. WHAT THE USER MUST DO TO HITL-ACCEPT

### Step 1 — chat-fix HITL (pri-0)
Launch Minerva. In any chat tab:
1. Dispatch a chat message.
2. Before the response arrives, click Stop.
3. Dispatch another message in the same tab.
4. Confirm: no `SCRIPT ERROR: Invalid type ... previously freed` in the
   log. If the freed-node path fires the guard, expect a
   `push_warning("[ChatPane] late response dropped — UI node freed (bug 019e5bc8…)")`
   instead.

### Step 2 — scansort visibility HITL
1. `/mcp` reconnect so the new plugin binary is in use.
2. Open a vault, load some PDFs, hit Start (or via MCP:
   `process_plan(scope={kind:"all_sources"}) → process_run(batch_id, audit_enabled=true, audit_path=<some path>)`).
3. If any file fails, run `process_status` — `errors[]` should now carry
   per-file reasons.
4. `audit_tail(log_path=<same path>)` should return rows for the failed
   files too, not just successes.

### Step 3 — accept + transition
On acceptance:
- `019e5bc8…` (chat) → resolved → verified → closed
- `019e5bc927…` (errors[]) → resolved → verified → closed
- `019e5bc946…` (audit) → resolved → verified → closed
- Cycle-3 cards under DCR `019e564809a9` → shipped (if not already)
- DCR `019e564809a9` itself → shipped (if HITL on the original cycle-3
  also accepted)
- Predecessor DCR `019e5068f584` → shipped (still pending user-driven
  merge)

---

## 5. OPEN FOLLOW-UP WORK ITEMS UNDER DCR `019e564809a9`

Unchanged — these queue behind the remora HITL.

- `019e566ea3eb` — manifest/tools-list codegen
- `019e5671eea7` — tool_err coverage for session_describe + dryrun_session
- `019e56720a92` — tail_rows O(file_size)
- `019e57749bcb` — T7 obs (a) state_changed subscription
- `019e5774c543` — T7 obs (b) vault unlock cross-surface
- `019e566e5fa5` — extend lax_* helpers
- `019e58319f75` — delete legacy `process::snapshot_json`
- `019e5831ae93` — `ProcessPlan::empty(scope)` helper
- `019e5834a2b7` — panel Stop surface cancel failure
- `019e5834b518` — process_plan negative-path test coverage
- `019e5834ce3f` — process_run O(N²) over iterations

Potential follow-up from the remora work:
- ProcessItem could carry `abs_path` + `sha256` so the audit-on-failure
  rows match the success rows in shape (cleaner). Filed as nudge
  `scansort-testing/distinct-content-per-test-file` for the testing
  gotcha that fell out of the regression-test build.

---

## 6. HARD RULES (unchanged)

- Per-file `git add` only — never `-A` or `.`. No `--no-verify`. No
  `vendor/` touches.
- scansort source documents are READ-ONLY at runtime. Code on this
  branch is fair game.
- No force-push, no `git reset --hard`, no push without an explicit user
  ask. (Today's push of the remora work is the explicit ask in the
  pickup.md §4 plan that the user just executed.)
- Never `cp` over a mapped binary — use `install -m 755` (atomic).
- pkill target is `godot`, not `Minerva`.
- Co-author trailer: `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`.
- Use MCP for state probes, not filesystem reads (production agents have
  no shell).

---

## 7. MEMORY LANDMARKS

- `MEMORY.md` Active Work line still points at this DCR — update on
  HITL accept.
- `project_active_scansort_agent_visibility_dcr.md` — full per-cycle
  status + the remora aftermath (see file).
- Durable docket hints (cross-session):
  - `019e57af4a8e` — spawned-binary `#[cfg(test)]` override invisible
  - `019e5b67e03b` — rust-refactor per-call→per-batch accumulators
  - `019e5b680716` — scansort-mcp stdio blocks read-only tools
- Session nudges (this run):
  - `scansort-testing/distinct-content-per-test-file` — same-content
    files share sha256 and trip the should_skip path; use per-file salt
    in regression tests where every file must hit the same disposition.

---

## 8. ONE-LINE INCANTATION TO PICK UP TOMORROW

If user accepts: nothing — close out the cards, merge to main.
If user rejects: read this file, look at the offending repro, file a
follow-up bug under DCR `019e564809a9`, repeat the remora pattern.

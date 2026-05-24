# Pickup

STATE: `DCR 019e564809a9 HITL IN-FLIGHT · 3 NEW BUGS FILED · REMORA CHAT FIX PLANNED`

Last updated 2026-05-24 (end of day). Resuming on a different device tomorrow.
This file is the runbook on resume — **do not trust a compaction summary for
specifics; this file + the docket bug tree are ground truth.**

---

## 0. ONE-LINE SUMMARY ON RESUME

DCR `019e564809a9` shipped 3 cycles. Today's HITL surfaced an **LLM backend
maintenance outage** that masked the scansort failure modes, **but also
exposed real visibility-gap bugs** (filed) AND **a pri-0 chat exception**
(filed). All three are remora to the scansort branch — fixes piggyback,
tracking stays separate via docket bug IDs below.

---

## 1. WHERE EVERYTHING LIVES

- **Plugins repo:** `~/github/plugins` on branch `dcr/scansort-agent-visibility`,
  HEAD at the same SHA you left it — 24 commits ahead of base
  `50b4571` (predecessor DCR `019e5068f584`'s HEAD). Pushed to `origin`
  (set as upstream end-of-day on 2026-05-24).
- **Minerva repo:** `~/github/Minerva` on branch
  `user/imran/experiments/swarm`. Synced with origin end-of-day. Submodule
  pointer drift on `vendor/godot_cef` + `vendor/godot_wry` is pre-existing;
  do not touch (per CLAUDE.md).

To verify on the laptop:
```
cd ~/github/plugins
git branch --show-current        # → dcr/scansort-agent-visibility
git status --porcelain           # → clean
git log --oneline -1             # → matches the SHA in the push log

cd ~/github/Minerva
git branch --show-current        # → user/imran/experiments/swarm
git status --porcelain           # → only the vendor/ submodule drift,
                                 #   plus possibly pickup.md if you edit
```

---

## 2. WHAT HAPPENED TODAY (HITL session, 2026-05-24)

Order of events:

1. **HITL test 1 of Cycle 3** — user loaded 7 PDFs + a fresh vault `test-4`,
   hit Start in the scansort panel.
2. **Result:** `placed:1, errored:6, skipped:0` in ~1 minute. Only 1 file
   classified.
3. **Diagnostic via MCP** showed `errors[]` was empty despite `errored:6` —
   no per-file reasons surfaced.
4. **Re-run with audit log** (`audit_enabled=true`, custom path): `placed:0,
   errored:7` in **~600 ms** (way too fast for any LLM call). Audit file
   was NEVER created — confirming no per-file audit row was written for
   failed files either.
5. **Root cause of the symptom** — **LLM backend was in a maintenance
   window** (extended longer than expected). Run 1 caught partial
   availability; Run 2 hit dead air.
6. **Independent pri-0 finding** — during HITL the user hit a chat
   exception: `ChatPane.gd:1672` called `update_ui_after_response` with
   `model_msg_node` that had been queue_free'd. Repro: dispatch chat →
   hang → click Stop → dispatch another chat in same tab.

---

## 3. THE 3 NEW DOCKET BUGS (all filed 2026-05-24)

### A. **`019e5bc8dae47584a1f9b9fcb9868173`** — ChatPane zombie coroutine (PRI-0)

Project: Minerva. Type: bug. Status: new. Severity 2.

`_on_audio_stop_1_pressed` (ChatPane.gd:3523-3529) queue_free's loading
`MessageMarkdown` nodes, but the awaiting coroutine in
`execute_regular_chat` (ChatPane.gd:1640) keeps a stale reference and
resumes at line 1672 → exception. Same shape at line 1530 (regenerate)
and line 2138 (worker chat).

**Author left an acknowledging comment** at ChatPane.gd:3538-3539 ("zombie
coroutine ... will never reach the agent_chat_finished emit") — they
handled the signal but not the freed-UI-node race.

**Fix plan (rubric Opt 2 — 23/28):** early-guard
`update_ui_after_response` + `update_ui_after_response_no_signal` with
`is_instance_valid`; add cancelled-id bail after the await in
`execute_regular_chat` / regenerate / worker-chat (4 call sites total).
Plus headless regression test that creates a model_msg_node, frees it,
then drives `update_ui_after_response` and asserts no crash + history
unchanged.

**Branching (rubric):** Opt 2 + Branch B chosen (piggyback on
`dcr/scansort-agent-visibility`) per explicit user instruction —
"Keep this fix as a remora in the current work."

### B. **`019e5bc927417448b09ef38f21db0b40`** — process_run b.errors[] not populated (P2)

Project: scansort. Severity 3.

`process::run` bumps `b.errored` in bulk at run-end
(`process.rs:1321-1323`) but never propagates `result.items[]` per-file
reason strings into `b.errors[]`. `record_file_disposition` (the function
that DOES push to b.errors) is only called from the back-compat
`finish_run` path + tests.

**Fix:** after the per-file loop, iterate `result.items` and call
`record_file_disposition` (or push directly to b.errors) for every
non-success entry, preserving the reason text. Add a Layer-2 wire test
asserting `errors.len() == errored` when classify fails.

### C. **`019e5bc946807b0db2dcfab842670782`** — audit log silent on failure (P2)

Project: scansort. Severity 3.

When all files in a run error before reaching fan_out (extract_error,
classify_error, empty LLM response, etc.), the audit CSV file is never
created — the audit-append step only runs after successful placement.
A run with `totals.placed=0` produces no diagnostic CSV.

**Fix:** write an audit row for every disposition
(`placed | skipped | unprocessable | conflict | error`), not just
success. Add a wire test that runs with all-fail inputs and confirms
audit_tail returns rows.

---

## 4. RESUME WORK PLAN

Pick up in this order on the laptop:

### Step 1 — confirm scansort actually works post-outage

Now that LLM backend is up, re-run the scansort pipeline via MCP to
confirm the placed-count matches the batch size:

```
minerva_scansort_process_plan(scope={kind:"all_sources"})
minerva_scansort_process_run(batch_id=<from plan>, audit_enabled=true,
                             audit_path=<pick a temp path>)
minerva_scansort_process_status()
minerva_scansort_audit_tail(log_path=<same path>, limit=50)
```

Expected: `placed` matches the file count. If yes → today's symptom
WAS the outage, and we can confidently move to fixes. If no → there's a
real bug under the outage; investigate before doing remora.

### Step 2 — implement the chat-exception remora (PRI-0)

Bug `019e5bc8dae47584a1f9b9fcb9868173`. Files to edit (all in
`~/github/Minerva/src/Scripts/UI/Views/ChatPane.gd`):

- Line 850 (`update_ui_after_response`) — add `is_instance_valid` guards
  at top: if `model_msg_node` or `user_msg_node` is freed, log a
  `push_warning("[ChatPane] late response dropped — UI node freed")`
  and return without touching nodes/history.
- Line 888 (`update_ui_after_response_no_signal`) — same guards.
- Line 1640 (`execute_regular_chat`), after the await — check
  `SingletonObject.cancelled_history_ids.has(history.HistoryId)` and bail
  before touching anything.
- Line 1354 (regenerate) — same cancelled-id check after await.
- Line 2138 (worker chat) — same cancelled-id check after await.

**Test:** add a new headless test under `src/test/` (use existing test
patterns from `test_mcp_stdio_concurrency.gd` etc as a template). Drive:
create ChatHistory + VBox; create model_msg_node; queue_free it +
`await get_tree().process_frame`; call `update_ui_after_response` with
the freed node + a mock bot_response; assert no exception + history
length unchanged.

### Step 3 — implement the 2 scansort visibility fixes

Both fixes live in `~/github/plugins/scansort/src/process.rs`. Small.
After fix, rebuild + redeploy:

```
cd ~/github/plugins/scansort
cargo build --release
install -m 755 target/release/scansort-plugin ./scansort-plugin
```

Then add cargo wire tests (in `tests/`) for both:
- one that runs with an injected fake `host.providers.chat` that always
  errors, asserts `b.errors.len() == eligible_count` with reasons matching
- one that runs the same scenario with `audit_enabled=true`, asserts the
  CSV exists with one row per file

### Step 4 — green gate + HITL

Same gate as Cycle 3:
- `cargo test --release` (lib + manifest_validation + every wire test)
- `scripts/run-functional-tests.sh --all`
- Targeted headless on the new ChatPane regression test
- Restart Minerva, re-run the chat-exception repro, confirm no crash
- Re-run scansort with audit, confirm `errors[]` populated + audit CSV
  has rows for failures

### Step 5 — WIP commits per file, then HITL

Per-file `git add` only. Three commits:
1. ChatPane remora (Minerva repo)
2. scansort errors[] propagation (plugins repo)
3. scansort audit-on-error (plugins repo)

Co-author trailer required. Push both repos. Hand back to user for HITL.

---

## 5. WHAT'S ALREADY DONE (do NOT redo)

- DCR `019e564809a9` cycles 1-3 are shipped on the plugins branch.
- 387/0 cargo lib tests; 6 wire tests; functional 5/0 — all green at
  cycle-3 close.
- Process pipeline redesign (Option C — plan + run + cancel + status)
  is live; the 3 new MCP tools (`process_plan`, `process_run`,
  `process_cancel`) are wired through manifest + dispatch + main +
  panel.
- The G8 SCANSORT_LIBRARY_PATH safety contract is in place. Tests that
  spawn the plugin binary use `common::spawn_plugin_with_isolated_library`.

---

## 6. OPEN FOLLOW-UP WORK ITEMS UNDER DCR `019e564809a9`

(Unchanged from pre-handoff — these are queued for after the remora cycle.)

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

The 2 new scansort visibility bugs (`019e5bc927...` and `019e5bc946...`)
are higher priority than these — fix in Step 3 above before tackling the
backlog.

---

## 7. HARD RULES (unchanged)

- Per-file `git add` only — never `-A` or `.`. No `--no-verify`. No
  `vendor/` touches.
- scansort source documents are READ-ONLY at runtime. Code on this
  branch is fair game.
- No force-push, no `git reset --hard`, no push without an explicit user
  ask.
- Never `cp` over a mapped binary — use `install -m 755` (atomic).
- pkill target is `godot`, not `Minerva`.
- Co-author trailer: `Co-Authored-By: Claude Opus 4.7 <noreply@anthropic.com>`.
- Use MCP for state probes, not filesystem reads (production agents
  have no shell).

---

## 8. MEMORY LANDMARKS

- `MEMORY.md` Active Work line still points at this DCR — update it
  after the remora cycle lands.
- `project_active_scansort_agent_visibility_dcr.md` describes per-cycle
  status — needs an "Aftermath" section once the 3 new bugs are
  resolved.
- Durable lesson hints saved from prior cycles (still relevant):
  - nudge `rust-serde-json/nan-inf-refused-at-encoder`
  - nudge `scansort-mcp/stdio-blocks-read-only-tools-too`
  - nudge `rust-refactor/per-call-to-per-batch-state-must-add-not-overwrite`
  - docket hint `019e57af4a8e` — spawned-binary `#[cfg(test)]`
    override invisible to the spawned process

---

## 9. DOCKET STATE TO TRANSITION ON COMPLETION

After the remora cycle is green + HITL-accepted:

- `019e5bc8dae47584a1f9b9fcb9868173` (chat exception) → resolved → verified → closed
- `019e5bc927417448b09ef38f21db0b40` (errors[]) → resolved → verified → closed
- `019e5bc946807b0db2dcfab842670782` (audit-on-error) → resolved → verified → closed
- Cycle-3 cards under DCR `019e564809a9` → shipped (if not already)
- DCR `019e564809a9` itself → shipped (if HITL also accepts the original cycle-3)
- Predecessor DCR `019e5068f584` → shipped (still pending user-driven merge)

---
name: work-cycle
description: Drive a multi-round work cycle on Minerva tasks with sub-agents (parallel implementers + Opus reviewers), automated Layer-1 verification incl. a non-mocked functional-test floor, smart-batched WIP commits, and explicit stop conditions for human-in-the-loop tests. Supports campaign mode — an outer goal loop over a DCR subtree with HITL deferred to one consolidated register-burn session. Use when starting a new round of focused implementation work — typically after a planning conversation or when picking up a docket task. Default scope is one DCR-grandchild task or a small group of sibling tasks; campaign mode takes a DCR/parent id.
---

## When to use

Invoke `/work-cycle` when:
- You have a docket task ID (or several) ready to implement.
- You want a structured loop with parallel sub-agents, fresh-context reviewers, automated test gates, and clean WIP checkpoints.
- You want explicit stop-condition declarations up front so you know when to be at the keyboard vs. let me run.

Do not invoke for:
- Open-ended planning conversations (those are pre-cycle; use plain conversation or `/Plan`).
- One-off file edits (just edit the file).
- Multi-DCR phase work with many human gates — break that into per-DCR cycles first.

## Inputs

The user provides one of:
- **Docket task IDs**: `/work-cycle 019dc604... 019dc555...`
- **Scope description**: `/work-cycle hello plugin annotation smoke test`
- **Plan reference**: `/work-cycle plan:annotations-smoke` (if plan saved earlier in conversation)

Optional flags (see `Docs/process/work-cycle.md` for full list):

- `--opus-only` / `--sonnet-only` — force implementer model
- `--cap=N` — Layer-1 iteration cap
- `--no-review` — skip review (mechanical work only)
- `--no-stop` — suppress 3a/3b stops (unattended runs)

## Workflow

### Step 0 — SCOPE (orchestrator does this; outputs a plan to the user)

1. Read the docket task(s) referenced by the input. If freeform scope, identify the matching task(s) by tag/title; if none exists, file one before proceeding.
2. Decompose into independent units. A unit is one sub-agent's work — small enough that it can be specified concretely in 5-10 sentences.
3. Identify dependencies. Units in the same round must be independent; sequential dependencies are separate rounds.
4. Pick a model per unit (see "Model selection" under Conventions). Defaults: implementer = Sonnet, reviewer = Opus; reviewer = Fable for pattern-establishing rounds; mechanical units = Haiku.
5. **Write the scope fence**: an explicit path allowlist (files/dirs this round may touch) derived from the work item. The fence goes verbatim into every implementer prompt and into the round plan. Out-of-fence discoveries follow **file, don't fix**: create a docket item immediately, never an inline fix.
6. Declare the stop condition (3a / 3b / 3c / 3d / 3e). Announce it to the user.
7. Transition each task in the docket: `backlog → open → in_progress`.
8. Output a plan summary to the user:
   ```
   /work-cycle plan
     Tasks: <ids and titles>
     Repos/branches: <repo: branch, per repo touched>
     Scope fence: <path allowlist>
     Units this round: <N>
     Models: <unit:model list>
     Stop condition: <3a/3b/3c/3d/3e — what triggers it>
     Expected: <what to expect at end of round>
   ```
   Do NOT wait for user confirmation unless the plan looks risky (3e potential, large scope, or pattern-establishing first round).

### Step 0.5 — PREFLIGHT (hard gate; fail-stop, never improvise past it)

Run for EVERY repo the round touches (a round may span Minerva + minerva-plugins):

1. **Branch check**: `git branch --show-current` matches the round's declared branch. Standing policy: Minerva → `development`, minerva-plugins → `main`. Wrong branch = STOP and report; do not switch branches silently.
2. **Cleanliness check**: `git status --porcelain` empty except the standing allowlist (vendor submodule pointer drift: `vendor/EIRTeam.FFmpeg`, `vendor/godot_cef`; docket cache churn: `Docs/minerva.dct`). Any other dirty path = STOP — it's either someone's WIP (report it) or a prior round's leak (diagnose it).
3. **Freshness check (behind upstream)**: `git fetch`, then `git rev-list HEAD..@{u} --count`. Non-zero means another machine pushed since this checkout last pulled — a round started here produces conflicts and reviews against a stale base. If the tree is clean, `git pull --ff-only` and continue; if the pull cannot fast-forward (diverged), STOP and report. Never start a round knowingly behind upstream.
4. **Base check**: local branch is not ahead of its upstream with unexpected commits (`git log @{u}..HEAD --oneline`). Unexplained commits ahead = STOP and report.
5. **Pin the base**: record `git rev-parse HEAD` per repo as a comment on each in-scope docket item at the `in_progress` transition. All reviews and audits this round are against `base..HEAD` — reviewers never review pre-existing code as if it were new.

### Step 1 — WORK

For each unit in this round, in parallel where independent:

1. Spawn an Implementer sub-agent (`Agent`) with:
   - Model = unit's selected model
   - Subagent type = `general-purpose` (or `Plan` if first-of-pattern)
   - Prompt = self-contained brief: goal, files to touch, existing patterns to follow, tests to add, success criteria
   - **Scope fence verbatim**, with the rule: anything needed outside the fence → report it back as a finding (orchestrator files it in docket); do NOT fix inline.
   - **Reuse scan (blocking, first deliverable)**: before writing code, read the reference implementations named in the work item (most items name them: e.g. `CadAnnotationHost.gd`, `internal/bridge`, `test_cad_plugin_smoke.gd`) and state per major piece: reuse / extend / copy-with-justification. New code that duplicates an existing asset without this declaration is a review reject.
   - Isolation: do NOT use the Agent tool's built-in worktree isolation — it bases on origin/<default-branch> (Minerva: `main`, ~1yr behind `development`; the plugin system doesn't exist there). Create worktrees manually pinned to the round base (`git worktree add -b wc/<round-unit> ~/github/minerva-worktrees/<name> <base-sha>`), pass the absolute path in the prompt, and make the agent's first act `git rev-parse HEAD` == pinned base (fail-stop on mismatch). Remove worktrees after merge-back.

2. When implementer returns, spawn a Reviewer sub-agent:
   - Model = Opus (default) / Fable (pattern-establishing rounds — first-of-kind code that later rounds will copy)
   - Subagent type = `general-purpose`
   - Prompt = "Review the diff `base..HEAD` (base SHA: <pinned>). Verify: <unit's success criteria>. **Score against the rubric, in order: durability → DRY → reliability → well-factored → readability → cost.** DRY trigger: any block >~30 lines substantially duplicating code elsewhere in this repo or a sibling plugin → must_fix (extract or justify in writing). **Scope audit**: list any changed file outside this fence: <fence>; out-of-fence files = must_fix. Look for: <known gotchas from work-cycle.md anti-patterns + repo-specific gotchas saved in nudge>. Verdict: approve / approve_with_notes / must_fix / reject."
   - Reviewer has NO context from the implementer's prompt or memory of this conversation.

3. Reconcile review verdict:
   - **approve / approve_with_notes**: proceed.
   - **must_fix (orchestrator can resolve)**: apply fix locally; re-verify with Layer-1.
   - **must_fix (judgment-dependent)**: STOP cycle, escalate to user (stop condition 3e).
   - **reject**: re-spawn implementer with reviewer feedback as additional context. If second rejection on same unit, escalate model (Sonnet→Opus) per the escalation rule. If still rejected, stop and escalate to user.

### Step 2 — VERIFY-LAYER-1

1. Run targeted test suite headless. For Minerva platform work:
   ```
   timeout 60 godot --headless --path src --script test/<relevant_test>.gd
   ```
   Pick test files that exercise the touched modules. Do not run the full suite unless the change is cross-cutting.

2. **Functional floor (non-mocked)**: any round that touches a runtime surface must end with at least one REAL functional test green — boot the actual stack headless (real SingletonObject / real installer / real subprocess / real files on disk) and drive one happy path end-to-end at the integration boundary. Unit tests supplement this; they never substitute for it (Phase 1B: 330 green unit tests missed 6 wiring bugs). Mocks are allowed only where the real dependency is inherently unavailable or non-deterministic (live LLM calls, paid APIs, user dialogs) — and then fake at the OUTERMOST process boundary (e.g. a fake `host.providers.chat` provider, a fake tool executable), never by stubbing internal seams. Rounds with no runtime surface (docs, fixtures) are exempt — say so explicitly in the round report rather than silently skipping.

3. Tally `PASS:` / `FAIL:` lines. Green = no FAIL lines.

4. If red:
   - Identify failing test by name.
   - If failure is in test fixture (not implementation), fix locally.
   - If failure is in implementation, re-spawn implementer with the failing assertion as context.
   - Cap at `--cap=N` retries (default 3) on the same problem. Past cap, escalate (3d).

### Step 3 — WIP COMMIT

1. **Diffstat audit (scope-creep gate)**: `git diff --stat <base>..HEAD` (working tree included) vs the scope fence. Any out-of-fence file → resolve as must_fix (revert it or get explicit user approval) BEFORE staging. Never commit out-of-fence changes silently.
2. Stage files explicitly by name (never `git add -A` or `.`).
3. Compose commit message:
   - Subject ≤ 70 chars, prefixed `WIP: ` when round is part of an unfinished phase.
   - Body lists each unit's deliverable and test counts, plus the docket item ID(s).
   - Co-author trailer naming the session's current model, e.g. `Co-Authored-By: Claude <noreply@anthropic.com>`.
4. Use HEREDOC for the commit message.
5. After commit, run `git status` to verify clean, then push to the round's declared branch (Minerva → `development`, minerva-plugins → `main`).

### Step 4 — DOCKET TRANSITION (conditional)

- If stop condition for this round was **3c** (phase boundary, auto-verified):
  - For each task in scope, transition `in_progress → done` with resolution note citing commit SHA + test counts.
- Otherwise:
  - Leave tasks `in_progress` until step 5 confirms.

### Step 5 — STOP CONDITION FIRES

1. Present to the user:
   - WIP commit SHA.
   - What changed (one sentence per unit).
   - **Test plan** for the human:
     - For 3a (UI): list visual checks with expected appearance.
     - For 3b (plugin): list interactions with expected behavior.
     - For 3c (auto): just announce completion + next-round options.
   - Standing-by message.

2. On user confirmation:
   - For each task: `in_progress → done` with resolution note citing what was tested + commit SHA.
   - If there are more rounds in the same scope, ask whether to start the next round.

3. On user reporting failure:
   - Tasks stay `in_progress`.
   - Treat the failure report as the scope input for a follow-up round (loop back to step 0).

### Step 6 — RUN-AGAIN DECISION

If stop condition was **3c** (auto-verified) and there are more rounds queued in the same multi-round phase:
- Loop directly back to step 0 with the next round's scope.
- No human pause needed.

If stop condition was **3a / 3b**:
- Wait for user. Do not loop autonomously.

## Campaign mode (goal loop)

Invocation: `/work-cycle campaign <dcr-or-parent-id> [--max-rounds=N] [--defer-hitl=<register.md>]`

Campaign mode wraps steps 0-6 in an outer loop that drives a docket subtree to a goal instead of running one declared round. Per-round discipline (preflight, fence, cold review, Layer-1, WIP commit) is unchanged — the loop only decides *what the next round is* and *when to stop*. Proven shape: the PCB migration autonomy plan (DCR 019dc140, 17 iterations to a single consolidated HITL).

### Loop body (each iteration)

1. **Re-read the live subtree** (`docket_query` children/grandchildren of the goal item — the docket is the loop state, not conversation memory). Build the candidate set: leaf items that are `backlog`/`open`, unblocked (no `blocks` link from an undone item), and not human-gated.
2. **Select the next round**: highest-priority independent candidates that fit one round (default 1-2 units; dependencies = later iterations).
3. Run steps 0-6 on the selection.
4. **Checkpoint**: append a campaign comment to the goal item — iteration number, items transitioned, commit SHAs, register entries added, candidate set remaining. This makes the campaign resumable across compaction or a new session: re-invoking campaign mode on the same goal id picks up from docket state.

### Adoption rule (campaign-level scope fence)

Rounds file out-of-fence discoveries; campaigns must not auto-adopt them. A newly-filed item joins the candidate set ONLY if it **blocks** a goal-subtree item (link it `blocks` explicitly). Everything else is file-only — it waits for a human to promote it. "The loop found more work" is the campaign-scale version of "while I'm here."

### HITL deferral (`--defer-hitl`)

With the flag, 3a/3b stops do not halt the loop: append the manual test to the named register file instead (entry MUST name the automated proxy that stands in for the human check — no proxy, no deferral; build the probe first) and continue. The campaign's exit report presents the whole register as ONE consolidated acceptance session. Without the flag, 3a/3b halts the loop (default behavior).

### Termination (all explicit; first to fire wins)

| Condition | Result |
|---|---|
| Goal predicate: every subtree item done, HITL-deferred, or human-blocked | SUCCESS — exit report + register test plan |
| 3d (Layer-1 cap) or 3e (judgment must_fix) | HALT — these are never deferrable; a human is the point |
| Preflight failure | HALT — fail-stop, never improvise past it |
| Two consecutive no-progress iterations (zero items transitioned) | HALT — dry loop; report why candidates are stuck |
| `--max-rounds` reached (default 12) | HALT — checkpoint + remaining-work summary |

### Exit report

Goal item gets a final checkpoint comment: iterations run, items done vs remaining, commits per repo, test counts, and — if deferring — the register rendered as an ordered human test plan with expected results (the single HITL session).

## Conventions

### Sub-agent prompts

Every sub-agent prompt must be self-contained — the agent has no memory of this conversation. Include:
- Goal in 1-2 sentences.
- Concrete files to touch (paths).
- Existing patterns to follow (with file:line references).
- Acceptance criteria as a numbered list.
- Test files to update or add — including the round's non-mocked functional test (which real stack to boot, which happy path to drive; see Layer-1 functional floor).
- For reviewers: also list known gotchas from `nudge` hints under `minerva-plugin-platform`, `minerva-testing`, etc.
- Brevity instruction: "Report in under 200 words" for review agents; "Concise summary at end" for implementers.

### Model selection

Leverage is asymmetric: reviewers are where the fence/DRY/rubric gates live and they only read diffs — put the strongest model there.

| Role | Model | Notes |
|---|---|---|
| Reviewer | Opus (default); **Fable** for pattern-establishing rounds | First-of-kind code gets copied by every later round; the review that blesses it deserves the top model |
| Implementer | Sonnet (default), parallelizable | Escalate to Opus for design-heavy units (forensic spikes, shared API surfaces, host/substrate integration) |
| Mechanical units | Haiku | Renames, fixture generation, migration boilerplate, golden-file plumbing |
| Spikes / walking skeletons | Sonnet, often inline (no fan-out) | Investigative value is the reasoning trail, not parallel throughput |

### Model overrides

Recognized in scope text:
- `task-title @opus` — force Opus for that unit's implementer
- `task-title @sonnet` — force Sonnet
- `task-title @haiku` — force Haiku
- `task-title @no-review` — skip reviewer for that unit

Recognized as flags:
- `--opus-only` / `--sonnet-only` — apply to all units
- `--no-review` — skip reviewers globally
- `--cap=N` — Layer-1 iteration cap
- `--no-stop` — suppress 3a/3b (unattended)

### Memory and hints

Before spawning a reviewer, check `nudge` for hints under relevant components:
- `minerva-plugin-platform` — plugin/scene-panel gotchas
- `minerva-testing` — test fixture and isolation gotchas
- `minerva-singleton` — SingletonObject quirks
- `minerva-plugin-platform` — recent regression-class entries

Pass relevant hints into the reviewer prompt as "things to specifically check for."

After the round, save any new gotcha discovered as a nudge hint under the appropriate component. The post-tool-use hook will remind you; act on it.

## Anti-patterns

These come from past Phase 1B rounds and are cheaper to avoid than to discover again:

1. **Skipping step 0.** Spawning sub-agents without a plan leaks money and time when the decomposition is wrong. Plan first, even if the plan is short.
2. **Sharing reviewer context with implementer.** Defeats the entire purpose of the second pair of eyes. The reviewer must start cold.
3. **Marking docket `done` at WIP-time when manual test is the gate.** State is terminal — wait for the verdict.
4. **Big-batch WIP commits across multiple rounds.** Smart-batched per round, not per phase. Replay-ability matters.
5. **Surprise stops mid-round.** Other than 3d/3e, stops should be declared at step 0.
6. **Letting Sonnet retry past the cap.** Two must-fix rounds on the same unit → escalate to Opus.
7. **`git add .` or `git add -A`.** Stage by name; binaries/secrets sneak in otherwise.
8. **Testing the wrong thing in Layer-1.** Pick targeted suites, not the whole repo. The full suite is for Layer-2 (phase boundary).
9. **Skipping preflight.** Rounds that start on the wrong branch or a dirty tree produce unreviewable diffs and contaminated commits. The gate is fail-stop: report and wait, never improvise past it.
10. **Fixing out-of-fence discoveries inline.** Scope creep enters as "while I'm here." File it in docket, don't fix it. The diffstat audit will catch it anyway — cheaper to not write it.
11. **Writing code before the reuse scan.** Duplicated substrate/bridge/test code is the main DRY failure. Read the named references first; declare reuse/extend/copy before implementing.
12. **Campaign auto-adoption.** A goal loop that pulls every filed discovery into its candidate set is scope creep at campaign scale. Only explicitly-linked blockers join; everything else waits for a human.
13. **Green unit wall, no functional proof.** A round that ends with only unit tests green has verified its own assumptions, not the wiring (Phase 1B: 330/0 units, 6 wiring bugs). The functional floor is part of Layer-1, not an optional extra; mocking internal seams to make it "pass" defeats it.

## Reference

- Full spec, rationale, and examples: `Docs/process/work-cycle.md`
- Model selection rationale: `Docs/process/work-cycle.md#model-selection`
- Stop condition table: `Docs/process/work-cycle.md#stop-conditions`

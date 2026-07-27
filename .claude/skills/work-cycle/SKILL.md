---
name: work-cycle
description: Drive a multi-round work cycle on Minerva tasks with sub-agents (parallel implementers + Opus reviewers), automated Layer-1 verification incl. a non-mocked functional-test floor, smart-batched WIP commits, and explicit stop conditions for human-in-the-loop tests. Runs ONE round. For campaigns — deciding which round is next, whether to continue, and what the record says — see the `orchestrator` skill. Use when starting a round of focused implementation work, typically after planning or when picking up a tracked task.
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
- Deciding *what* to work on, or managing the tracker / knowledge record — that is the `orchestrator` skill. This skill runs a round someone has already chosen.

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
6. **Premise re-validation** (different oracle from the four checks above — those read repo STATE, this reads the work item's CLAIMS): check every factual assertion in the item description against the repo at the pinned SHA. File:line citations, function behaviour, measured numbers. A tracked item is authored at the moment of peak ignorance and consumed later at the moment of peak consequence, and nobody ever goes back to correct it. Measured stale premises in 2 of 3 consecutive rounds. Not fail-stop: correct the item (comment the correction, do not silently edit history) and continue. **Numbers are the sharpest trap — always ask HOW a number was measured, not just what it was.** A figure produced by an oracle that shares the defect's blind spot looks exactly like ground truth (round C2d: "62 of 3403" was measured with a predicate blind to the very geometry it was counting).

### Step 0.6 — TEST PLAN (advisory; skip only for rounds that add no tests)

Two passes, both cheap, both BEFORE any test is authored. This is the only point in the pipeline that can PREVENT a bad test; every other test gate detects one after the tokens are spent.

1. **Test plan.** For each unit, choose one of three verdicts and NAME THE ORACLE:
   - **TEST** — an independent oracle exists (or can be sourced). Write it.
   - **TIP** — no independent oracle, and a miss is recoverable. Instrument and judge from what actually happened. Say who analyses the run and when.
   - **NEITHER** — spike/exploratory; the knowledge is the deliverable. Say so explicitly in the round report rather than silently skipping.

   Decide with the 2x2 on (independent oracle available?) x (is a miss recoverable?):

   | | Miss recoverable | Miss unrecoverable |
   |---|---|---|
   | **Oracle exists** | TEST, keep it cheap | TEST, hard gate |
   | **No oracle** | **TIP** | **Go MANUFACTURE an oracle — never fake one** |

   That bottom-right cell is the one that matters. The correct move is external ground truth (precedent: pinning rotation correctness by matching pads *by number* against KiCad's own X2 records). The INCORRECT move — and the one that feels natural — is to reach for the nearest production predicate and let the code grade itself.

   **RULE: if you cannot name an independent oracle, do not write the test.** It will be blind by construction. Source an oracle or TIP it.

2. **Test-plan adversary** (cold agent, no context from the plan's author). One question: *"Of these proposed tests, which give the most real feature coverage at the lowest cost?"* Two axes only — **parsimony** and **coverage**. Its output is a list of tests to CUT and gaps to fill. It advises; the orchestrator adjudicates.

### Step 0.75 — BRIEF REVIEW (cold; skip for trivial or purely mechanical rounds)

Send the brief **verbatim** to a cold Opus agent, with the work item and base SHA and no context from its author. Read-only; it must not edit the repo. Target under ~5 minutes.

It checks six things — these are observed failure modes, not a generic checklist:
- **(a) Factual claims.** Are the brief's file:line facts, signatures and measured outputs true at this SHA?
- **(b) Prescribed mechanism.** Where the brief says "implement THIS approach", name the assumption it rests on and check it holds.
- **(c) Fence sufficiency.** Enumerate every file the work plausibly needs. Under-fencing costs a mid-round round-trip and did so in 4 of 5 consecutive rounds.
- **(d) Acceptance reachability.** Is the exit condition observable — and **can the proposed oracle actually fail?**
- **(e) Asserted traps.** Are the brief's warnings real, and is a real one missing?
- **(f) Fail-closed safety.** Could anything prescribed yield a false clean, a silent default, or approximated output?

Verdict: proceed / revise. **It ADVISES; the orchestrator adjudicates** — the brief reviewer has no more claim on truth than the brief's author.

**This must NOT suppress implementer pushback.** An implementer refusing an instruction *with a reason* has been right every time it has happened and remains the last line of defence. Step 0.75 is additive: it catches cheap errors earlier so the implementer's judgement is spent on the hard ones.

### Step 1 — WORK

For each unit in this round, in parallel where independent:

1. Spawn an Implementer sub-agent (`Agent`) with:
   - Model = unit's selected model
   - Subagent type = `general-purpose` (or `Plan` if first-of-pattern)
   - Prompt = self-contained brief: goal, files to touch, existing patterns to follow, tests to add, success criteria
   - **Scope fence verbatim**, with the rule: anything needed outside the fence → report it back as a finding (orchestrator files it in docket); do NOT fix inline.
   - **Reuse scan (blocking, first deliverable)**: before writing code, read the reference implementations named in the work item (most items name them: e.g. `CadAnnotationHost.gd`, `internal/bridge`, `test_cad_plugin_smoke.gd`) and state per major piece: reuse / extend / copy-with-justification. New code that duplicates an existing asset without this declaration is a review reject.
   - **Mutation proof (required deliverable, FULL *and* HALF)**: before reporting, delete the change under test → the new tests must FAIL. Then WEAKEN it — remove half the condition, check one branch instead of both — and the new tests must STILL FAIL. Report both counts. **A test that survives the half-mutation is not a pin**, and it is the failure mode that looks most like success: it is well-named, asserts on the right thing, and dies under full removal. Measured: an implementer explicitly warned about vacuous tests, working on a round whose subject *was* a blind oracle, still authored one that passed under one half-mutation direction.
   - **Refusal right (say this verbatim in every brief)**: "If any instruction in this brief is wrong, refuse it and say why. Do not implement something you believe is incorrect because the brief said so." This is structurally unenforceable — you cannot compel disagreement — so it must be stated explicitly and must never be punished.
   - Isolation: do NOT use the Agent tool's built-in worktree isolation — it bases on origin/<default-branch> (Minerva: `main`, ~1yr behind `development`; the plugin system doesn't exist there). Create worktrees manually pinned to the round base (`git worktree add -b wc/<round-unit> ~/github/minerva-worktrees/<name> <base-sha>`), pass the absolute path in the prompt, and make the agent's first act `git rev-parse HEAD` == pinned base (fail-stop on mismatch). Remove worktrees after merge-back.

2. When implementer returns, spawn a Reviewer sub-agent:
   - Model = Opus (default) / Fable (pattern-establishing rounds — first-of-kind code that later rounds will copy)
   - Subagent type = `general-purpose`
   - Prompt = "Review the diff `base..HEAD` (base SHA: <pinned>). Verify: <unit's success criteria>. **Score against the rubric, in order: durability → DRY → reliability → well-factored → readability → cost.** DRY trigger: any block >~30 lines substantially duplicating code elsewhere in this repo or a sibling plugin → must_fix (extract or justify in writing). **Scope audit**: list any changed file outside this fence: <fence>; out-of-fence files = must_fix. Look for: <anti-patterns below + hints retrieved at step 0.5 via docket_hint_query>. Verdict: approve / approve_with_notes / must_fix / reject."
   - Reviewer has NO context from the implementer's prompt or memory of this conversation.

3. Reconcile review verdict:
   - **approve / approve_with_notes**: proceed.
   - **must_fix (orchestrator can resolve)**: apply fix locally; re-verify with Layer-1.
   - **must_fix (judgment-dependent)**: STOP cycle, escalate to user (stop condition 3e).
   - **reject**: re-spawn implementer with reviewer feedback as additional context. If second rejection on same unit, escalate model (Sonnet→Opus) per the escalation rule. If still rejected, stop and escalate to user.

### Step 2 — VERIFY-LAYER-1

**Step 2.0 — TEXT + TEST ADVERSARY (runs BEFORE the suite; cheapest gate first).**

> **SERIALIZE THIS AFTER THE STEP-1 COLD REVIEW. Do not run the two concurrently.** Both are cold agents pointed at the same diff, so in parallel they duplicate the expensive part — re-running the same mutation matrix, the same fuzz, the same reproductions — and converge on the same headline finding. Measured: ~169k tokens across two agents for heavily overlapping work. Run the reviewer first, then hand this station a short digest of what the reviewer already established with "do not re-verify these; find what they missed." Independent convergence IS real evidence, but it is a very expensive way to buy a second opinion; when you want it, spawn one cheap targeted verifier on the specific claim instead of doubling a full pass.

Prose is the only artifact with no gate — nobody runs a comment, so a false claim stays green forever. It is the joint-most-frequent defect class, and it now matters more than it used to because agents read a docstring with the same weight as the code beneath it and cannot smell staleness.

- **Mechanical pre-pass** (decidable, no judgment): does every symbol, test name, caller and `file:line` cited in prose actually resolve? A claimed caller relationship is a static call-graph query. Then grep the diff for modal claims — *never, always, cannot happen, guaranteed, by construction* — and surface them. Load-bearing claims cluster in those few sentences.
- **Judged pass** (cold agent, changed hunks only — not the whole tree): Are the comments correct? Are the test docstrings correct? **Are the tests useful and correct?** A test whose assertion passes while its docstring justifies it with a false claim is worse than no docstring: it answers "is X covered?" wrongly, in green.

Findings here are must_fix before the suite runs, because fixing prose is cheap and re-running the suite is not.

**Step 2.1 — the suite.**

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

5. **Green here is necessary and never sufficient.** A severity-1 fail-open has shipped green through 1296 tests, `go vet`, `go test`, the gd suite and all five CI jobs. Treat a green suite as "no known regression", never as evidence of correctness.

**Step 2.2 — CODE ADVERSARY** (cold agent; must run AFTER the suite is green — you cannot mutation-test a red suite).

One question: *"What can I break here that nothing notices?"* Tools are mutants and fuzz, not reading. **Fuzz geometry and parsing code specifically** — fuzzing found a real defect after three separate rounds of careful reading over the same file missed it. Survivors are the finding; triage each as (a) real gap → write a test, (b) equivalent mutant → harmless, note it, (c) deliberately untested → document why.

> RUBRIC PENDING. This station's grading rubric is not yet written (a code adversary judges *attacks*, which is a different question from the test rubric's axes). Until it exists, run the station and report survivors without scoring them.

### Step 3 — WIP COMMIT

1. **Diffstat audit (scope-creep gate)**: `git diff --stat <base>..HEAD` (working tree included) vs the scope fence. Any out-of-fence file → resolve as must_fix (revert it or get explicit user approval) BEFORE staging. Never commit out-of-fence changes silently.
2. Stage files explicitly by name (never `git add -A` or `.`).
3. Compose commit message:
   - Subject ≤ 70 chars, prefixed `WIP: ` when round is part of an unfinished phase.
   - Body lists each unit's deliverable and test counts, plus the docket item ID(s).
   - Co-author trailer naming the session's current model, e.g. `Co-Authored-By: Claude <noreply@anthropic.com>`.
4. **Commit-message check (pre-commit is the ONLY possible gate — a pushed message is immutable).** Verify against the diff and the tracker: does the message describe what actually changed? Do the cited item IDs exist and are they in a plausible state? Do quoted test counts match what the suite printed? Our commit bodies assert a lot of fact into a permanent record, and unlike a comment they can never be corrected in place.
5. Use HEREDOC for the commit message.
6. After commit, run `git status` to verify clean, then push to the round's declared branch (Minerva → `development`, minerva-plugins → `main`).
7. **CI, where CI exists.** Minerva and the plugins monorepo have it; other work has none. Absence of CI is not a skipped gate — it moves that weight onto the review and adversary stations above, and the round report should say so rather than implying a check ran.

### Step 4 — CLOSE-OUT + PROVENANCE (conditional)

- If stop condition for this round was **3c** (phase boundary, auto-verified):
  - For each task in scope, transition `in_progress → done` with resolution note citing commit SHA + test counts.
- Otherwise:
  - Leave tasks `in_progress` until step 5 confirms.
- **Provenance on every number written into a durable record.** Stamp HOW a figure was measured, not just what it was — `"62 of 3403 (measured via _segment_clear)"`, not `"62 of 3403"`. A number without its oracle looks like ground truth and gets consumed as a premise by later rounds; that exact omission cost a round. Applies to any durable record — tracker item, commit body, or saved hint — not only Docket. Not all work is tracked in a docket; where it is not, the commit body is the durable record and the same rule applies to it.

- **What to WRITE at close-out is owned by the `orchestrator` skill.** The completion comment is a PM register — shipped SHA, gates with numbers, what it unblocks, decisions and who may veto, filed-not-fixed, what needs the owner — not a narrative. The technical account belongs in the commit message, which step 3#4 already gates.
- **Close-out has no reviewer.** Every station above fires before the commit; everything written after it is ungated. Before writing a factual claim here, open the file behind it.

### Step 5 — STOP CONDITION FIRES

0. **Audible notification (owner-requested, 2026-07-16)**: when all prescribed
   tasks in the cycle are done — i.e. the moment the cycle becomes ready for
   the human (typically a 3a/3b HITL stop, or the final round of a serial
   plan reaching its human gate) — play a beep BEFORE composing the report:
   `paplay /usr/share/sounds/freedesktop/stereo/complete.oga` (fallback:
   `aplay` or `spd-say "work cycle complete"`; if Minerva is running, prefer
   `minerva_speak` with a one-line summary). Never let a failed beep block
   the report — fire-and-forget. Intermediate 3c auto-verified rounds that
   chain into another round do NOT beep; only the stop that hands control
   to the human does.

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

### Step 5.5 — DEBRIEF: TIP ANALYSIS (post-HITL; only for units the test plan marked TIP)

A unit routed to **TIP** at step 0.6 has no test standing behind it. Its gate is here, and it fires AFTER the human gate, not before: run the instrumented path, then analyse what the run actually produced.

- The analysis must be **scheduled and owned**, not aspirational. "We'll TIP it" without a named analyst and a trigger degrades into ship-and-hope, which is strictly worse than the test we chose not to write.
- **Instrumentation is production code and inherits the prose defect class.** A trace line asserting `resolved footprint=X` can be exactly as false as a comment saying so — and it is worse, because under TIP we are trusting it *instead of* a test. Review instrumentation as hard as the code it observes, and ask it the same question: is this reporting what happened, or what its author believed happens?
- Where the correctness question is **perceptual** (does this label overlap? is this legible?), the human is the oracle and a rating prompt is the cheapest way to capture it. Any automated proxy for a perceptual check is a golden image, which fails re-bless resistance: it goes red, someone re-blesses it, and the defect rides back in.

> INFRASTRUCTURE PENDING. TIP is not yet buildable — see discussion `019fa00980ef` (packaged logging system + separate reader). Until it lands, "TIP" is not a legal verdict at step 0.6; route those units to *manufacture an oracle* or to HITL instead.

### Step 6 — RUN-AGAIN DECISION

If stop condition was **3c** (auto-verified) and there are more rounds queued in the same multi-round phase:
- Loop directly back to step 0 with the next round's scope.
- No human pause needed.

If stop condition was **3a / 3b**:
- Wait for user. Do not loop autonomously.

## Campaigns

Campaign mode lives in the `orchestrator` skill, which owns the loop body, the adoption rule, termination conditions, HITL deferral and the exit report. This skill runs each round the campaign selects; the discipline below is unchanged whether a round was chosen by a human or by a campaign loop.

## Conventions

### Sub-agent prompts

Every prompt is self-contained — the agent has no memory of this conversation.

**State constraints. Point at facts.**

- A **constraint** is yours to set and cannot be wrong the way a number can: the fence, decisions already taken, process bans, the acceptance *shape*, "assert by identity not count", "mutate FULL and HALF". These earn their length.
- A **fact** is measurable, so name where it lives instead of restating it. Write *"read the floor from `_V1_MANUFACTURING_FLOOR`"*, never *"the floor is 0.127"*. Cite **symbol names, never file:line** — line numbers measure stale within a round.
- Prescribe the **invariant**, not the edit. "Make the code and the docs agree across both dimensions" finds every site; "add the predicate here" finds one.

Include:
- Goal in 1–2 sentences.
- The fence, verbatim, with the file-don't-fix rule.
- Symbols to read for existing patterns, in the order they should be read.
- Acceptance as a numbered list — including the criterion that defeats the lazy implementation (see `orchestrator`, "Acceptance criteria").
- Which tests to add, including the round's non-mocked functional test.
- Relevant hints retrieved at step 0.5, as "things to specifically check for."
- The refusal right, verbatim (step 1).
- Brevity: "under 200 words" for reviewers; "concise summary at end" for implementers.
- For every fix cycle and every adversary: a **digest of what earlier stations already established**, with *"do not re-verify these; find what they missed."*
- For a long-running job: **report the terminal event, not progress.** Each progress ping re-invokes the orchestrator for a full turn and carries no decision.

**Say when the brief may be wrong.** Add: *"If something I state as fact is wrong when you measure it, say so — that is a success, not an embarrassment."* The agents that surface a bad brief are the ones told it is welcome.

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

The `orchestrator` skill owns the stores and the protocol. This skill owns **when the search happens in a round** and **how its results reach an agent**.

**At step 0.5 (pre-flight), before the brief is written:**

```
docket_hint_query(project=<project>, component=<area this round touches>)
```

`docket_hint_*` is the DURABLE store. `nudge` does not survive a reboot — use it only for state that should not outlive the session.

- **Scope by component.** An unscoped or tag-only query times out.
- A retrieved hint is **a claim, not a fact**. It gets the same treatment step 0.5#6 gives the work item's premises: verify before relying on it. Hints go stale exactly like tracker items.

**Into every sub-agent brief** — implementer and reviewer alike — pass the relevant hints as "things to specifically check for." An implementer that knows the trap does not fall into it.

**After the round**, write back what cost real time to learn, including *how it was measured*. The post-tool-use hook will remind you; act on it while the context is fresh.

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
14. **Using the code under test as its own oracle.** The natural oracle for "did we emit something illegal?" is the project's own predicate — and that predicate can share the exact blind spot as the defect being hunted, so the measurement looks like ground truth and is not. An oracle must be built from a DIFFERENT representation than the code it judges. For a defect expressed in cells, assert in cells; do not ask whether a sampled chord passed.
15. **Full-only mutation.** A test that dies under full removal can still pass when the guard is half-removed — checking one branch instead of both. Half-mutate every round, in each direction. This is the vacuous test that looks most like a good one.
16. **Grading tests by reading them.** Test value is a property of the test-plus-code system — does it fail when the code is wrong — and that is measurable, not inferable from the text. A reading-based grader inherits reading's blind spots, which is the failure being fixed. Measure with mutants; reserve judgment for what cannot be measured (oracle independence, re-bless resistance, intent legibility).
17. **Treating a golden as a pin.** Goldens detect CHANGE, not correctness: when one goes red the cheap response is to re-bless it, and the defect rides back in. They are not worthless — they are miscategorised. Never count a re-blessable failure as protection.
18. **Prose with no gate.** Comments, docstrings, commit messages and tracker records are now inputs to an executing system — agents read them with the weight of code and cannot smell staleness. They were advisory when only humans read them, and nothing re-classified them when that changed. Every claim in prose has a cheap oracle (the code, the diff, the repo at a SHA); the defect is that nobody consults it.
19. **Writing a test with no independent oracle.** If you cannot name one, the test is blind by construction and will pass while the behaviour is wrong. Source external ground truth, or route the unit to TIP — do not write the test and call it covered.
20. **Asserting in a brief what the agent could measure.** A supplied fact — a floor value, a symbol name, a baseline — is one the agent would have read correctly had the brief pointed instead of stated. The first-order cost is being wrong; the second-order cost is larger, because a brief dense with asserted facts teaches the agent to trust the brief over the repo, which is precisely the verification you are paying it for. Constraints are yours to state; facts are theirs to measure.

## Reference

- Full spec, rationale, and examples: `Docs/process/work-cycle.md`
- Model selection rationale: `Docs/process/work-cycle.md#model-selection`
- Stop condition table: `Docs/process/work-cycle.md#stop-conditions`

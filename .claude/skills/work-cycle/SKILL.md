---
name: work-cycle
description: Drive a work cycle on Minerva tasks with sub-agents — implementer plus one cold reviewer per unit, cheap per-unit gates, and smart-batched WIP commits. Runs ONE round inside an epoch; the expensive judged stations and test authoring run at the epoch boundary, not per round. For epochs, campaigns, and what the record says — see the `orchestrator` skill. Use when starting a round of focused implementation work, typically after planning or when picking up a tracked task.
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
- `--cap=N` — per-unit gate retry cap
- `--no-review` — skip review (mechanical work only)
- `--no-stop` — suppress 3a/3b stops (unattended runs)

## Where this sits

A **round** runs inside an **epoch** — a batch of rounds sharing one verification boundary. `orchestrator` owns epoch composition, the six-epoch NTE, the risk tiers and the cadence table. This skill runs one round and then stops.

Two consequences shape everything below:

- **Only the cheap gates run per round.** Compile, vet, lint, and the existing targeted tests for the modules this round touched. Seconds, not agent-hours, so failure attribution stays with the round that caused it.
- **The expensive stations run at the epoch boundary**, over the accumulated diff: test authoring, the full suite, the text+test adversary, the code adversary, and any human bless. See "Epoch boundary" below. Do not run them per round.

**Tests are authored at the boundary, not before the code.** The exception is a regression test for a bug, which is written with its fix — it has a known failure mode, so it has a real oracle by construction.

## Workflow

### Step 0 — SCOPE (orchestrator does this; outputs a plan to the user)

1. Read the docket task(s) and nudge hint(s) referenced by the input. If freeform scope, identify the matching task(s) by tag/title; if none exists, file one before proceeding.
2. Decompose into independent units. A unit is one sub-agent's work — small enough that it can be specified concretely in 5-10 sentences.
3. Identify dependencies. Units in the same round must be independent; sequential dependencies are separate rounds.
4. Pick a model per unit (see "Model selection" under Conventions). Defaults: implementer = Sonnet, reviewer = Opus; reviewer = Fable for pattern-establishing rounds; mechanical units = Haiku.
5. **Write the scope fence**: an explicit path allowlist (files/dirs this round may touch) derived from the work item. The fence goes verbatim into every implementer prompt and into the round plan.
   Out-of-fence discoveries follow **file, don't fix**: create a docket item immediately, never an inline fix.
   **But a fence can be wrong, and the answer to a wrong fence is to widen it deliberately, not to work around it.** When a file outside the fence must change for the requested work to be CORRECT — as opposed to merely adjacent, or convenient — the agent stops and asks, naming the file and why the work is incorrect without it. You widen the fence explicitly and record it in the round plan. What is banned is the silent edit, not the conversation.
6. Declare the stop condition (3a / 3b / 3c / 3d / 3e). Announce it to the user.
7. Move each task to its in-flight state. **The chain differs by type** — `work_item` runs backlog → open → in_progress, `bug` runs new → triaged → active, `chore` runs open → in_progress. There is no shortcut and no universal path; read the item's type and walk its own chain.
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

### Step 0.6 — NAME THE ORACLE (cheap; do not author the test here)

Tests are authored at the epoch boundary. What this round owes the boundary is **the oracle**: for each unit, one line saying what independent thing would show the unit wrong.

- An oracle must be a **different representation** from the code it judges. The natural choice — the project's own predicate — can share the exact blind spot as the defect, so the measurement looks like ground truth and is not.
- **If you cannot name one, say so now.** That unit's boundary test would be blind by construction. Either source external ground truth, or route it to a human check and record which.
- Where the question is **perceptual** (does this overlap, is this legible), the human is the oracle. Say so; do not manufacture an automated proxy, which becomes a re-blessable golden.

Carry these lines to the boundary. They are what the test author works from.

### Step 0.75 — BRIEF REVIEW (runs at epoch planning, once, over the epoch's whole brief-set)

**This station has moved out of the per-round path.** One cold Opus pass reviews all of an epoch's briefs together, before any of them is dispatched. It is the only station that *prevents* work rather than detecting defects in work, so it must run early or not at all — never at the boundary.

Read-only, no context from the briefs' author, with the work items and base SHA. It checks six things:
- **(a) Factual claims.** Are the briefs' cited symbols, signatures and outputs true at this SHA?
- **(b) Prescribed mechanism.** Where a brief says "implement THIS approach", name the assumption it rests on and check it holds.
- **(c) Fence sufficiency.** Enumerate every file each unit plausibly needs. Under-fencing is the most frequent defect in briefs.
- **(d) Acceptance reachability.** Is each exit condition observable — and **can the named oracle actually fail?**
- **(e) Asserted traps.** Are the stated warnings real, and is a real one missing?
- **(f) Fail-closed safety.** Could anything prescribed yield a false clean, a silent default, or approximated output?

Verdict per brief: proceed / revise. **It ADVISES; the orchestrator adjudicates** — the brief reviewer has no more claim on truth than the brief's author.

**This must NOT suppress implementer pushback.** An implementer refusing an instruction *with a reason* remains the last line of defence. This station is additive: it catches cheap errors earlier so the implementer's judgement is spent on the hard ones.

### Step 1 — WORK

For each unit in this round, in parallel where independent:

1. Spawn an Implementer sub-agent (`Agent`) with:
   - Model = unit's selected model
   - Subagent type = `general-purpose` (or `Plan` if first-of-pattern)
   - Prompt = self-contained brief: goal, files to touch, existing patterns to follow, tests to add, success criteria
   - **Scope fence verbatim**, with the rule: anything needed outside the fence → report it back as a finding (orchestrator files it in docket); do NOT fix inline.
   - **Reuse scan (blocking, first deliverable)**: before writing code, read the reference implementations named in the work item (most items name them: e.g. `CadAnnotationHost.gd`, `internal/bridge`, `test_cad_plugin_smoke.gd`) and state per major piece: reuse / extend / copy-with-justification. New code that duplicates an existing asset without this declaration is a review reject.
   - **Tests: default tier writes none.** The boundary authors them. Two exceptions, both of which the brief must state explicitly:
     - a **regression test for a bug**, written with its fix — it has a known failure mode, so it has a real oracle by construction;
     - a **careful-tier unit** (silent *and* expensive to repair late), which authors its test with the code, because deferring the pin is exactly what makes that class expensive.
   - **Mutation proof — careful-tier units and regression tests only, FULL *and* HALF**: before reporting, delete the change under test → the new test must FAIL. Then WEAKEN it — remove half the condition, check one branch instead of both — and it must STILL FAIL. Report both counts. **A test that survives the half-mutation is not a pin**, and it is the failure mode that looks most like success: well-named, asserting on the right thing, and dying under full removal.
   - **Refusal right (say this verbatim in every brief)**: "If any instruction in this brief is wrong, refuse it and say why. Do not implement something you believe is incorrect because the brief said so." This is structurally unenforceable — you cannot compel disagreement — so it must be stated explicitly and must never be punished.
   - **No worktrees in a campaign.** Units work in the main tree and are isolated by FENCE, which is what the fence is for. A worktree earns its cost when the work is EXPERIMENTAL — spiking a feature, or comparing two approaches side by side — not when several units are advancing one agreed design. Never use the Agent tool's built-in worktree isolation either: it bases on origin/<default-branch>, which for Minerva is a year behind `development`.

2. When implementer returns, spawn a Reviewer sub-agent:
   - Model = Opus (default) / Fable (pattern-establishing rounds — first-of-kind code that later rounds will copy)
   - Subagent type = `general-purpose`
   - Prompt = "Review the change against base SHA <pinned>. If the work is uncommitted, that is `git diff <base>` plus `git status --porcelain` for new files — not `base..HEAD`, which would show you nothing.
     **Does it do what the item asked?** Score correctness and goal-fit FIRST; a change can be durable, DRY and well-factored while solving the wrong problem, and no later station asks this question.
     **Then the rubric, in order: durability → reliability → DRY → well-factored → parsimony → readability → cost.**
     DRY: substantial duplicated logic → must_fix (extract, or justify in writing). Use judgement on size rather than a line count, and note that duplication ACROSS plugin boundaries is often the correct ownership call rather than a defect — say which you think it is.
     **Scope audit**: list any changed path outside this fence: <fence>; out-of-fence = must_fix.
     Look for: <anti-patterns below + hints named at step 0.5>. Verdict: approve / approve_with_notes / must_fix / reject."
   - Reviewer has NO context from the implementer's prompt or memory of this conversation.

3. Reconcile review verdict:
   - **approve**: proceed.
   - **approve_with_notes**: proceed, but **disposition every note** — accepted and applied, rejected with a reason, or filed. A note that is neither is a finding you silently dropped.
   - **must_fix (orchestrator can resolve)**: apply the fix, then **send the resolution back to a cold reviewer**. The reviewer that raised it has not seen the fix, and a fix applied by the adjudicator is the one change in the round nobody independent has looked at. The re-review is narrow: the finding and its resolution, not the whole diff.
   - **must_fix (judgment-dependent)**: STOP cycle, escalate to user (stop condition 3e).
   - **reject**: re-spawn implementer with reviewer feedback as additional context. If second rejection on same unit, escalate model (Sonnet→Opus) per the escalation rule. If still rejected, stop and escalate to user.

### Step 2 — PER-UNIT GATE (cheap only; seconds, not agent-hours)

Everything expensive moved to the epoch boundary. What runs here exists to keep **failure attribution** with the round that caused it, which is the one thing batching cannot give back.

Run, for each language the round touched: compile, vet, lint, and the **existing** targeted tests for the touched modules. Nothing else.

**Do not run the full suite here**, and do not run either adversary. Both are boundary stations.

For Minerva platform work a targeted run looks like:

```
timeout 60 godot --headless --path src --script test/<relevant_test>.gd
```

Tally `PASS:` / `FAIL:` lines. Green = no FAIL lines.

If red:

- Identify the failing test by name.
- If the failure is in a test fixture rather than the implementation, fix it locally.
- If it is in the implementation, re-spawn the implementer with the failing assertion as context.
- Cap at `--cap=N` retries (default 3) on the same problem. Past the cap, escalate (3d).

**Green here is necessary and nowhere near sufficient — and be precise about why.** These are the tests that existed BEFORE this round, so they can only tell you the round did not break something old. **They know nothing about the behaviour this round added**, which stays unverified until the boundary authors its tests. Green means "no known regression in the modules touched", and it is a category error to report it as evidence the unit works.

State that plainly in the round report. A severity-1 fail-open has shipped green through the whole gate stack.

### Step 3 — WIP COMMIT

1. **Scope audit (scope-creep gate)** — TWO commands, because one is not enough:
   - `git status --porcelain` — the only thing that shows UNTRACKED files. A new file outside the fence is invisible to any diff.
   - `git diff --stat <base>` — note the SINGLE ref, not `<base>..HEAD`. The two-dot form compares commit to commit and silently excludes everything still in the working tree, which for an uncommitted round is the entire change.
   Any out-of-fence path → resolve as must_fix (revert it, or get explicit approval) BEFORE staging. Never commit out-of-fence changes silently.
2. Stage files explicitly by name (never `git add -A` or `.`).
3. Compose commit message:
   - Subject ≤ 70 chars, prefixed `WIP: ` when round is part of an unfinished phase.
   - Body lists each unit's deliverable and test counts, plus the docket item ID(s).
   - Co-author trailer naming the session's current model, e.g. `Co-Authored-By: Claude <noreply@anthropic.com>`.
4. **Commit-message check (pre-commit is the ONLY possible gate — a pushed message is immutable).** Verify against the diff and the tracker: does the message describe what actually changed? Do the cited item IDs exist and are they in a plausible state? Do quoted test counts match what the suite printed? Our commit bodies assert a lot of fact into a permanent record, and unlike a comment they can never be corrected in place.
5. Use HEREDOC for the commit message.
6. After commit, run `git status` to verify clean, then push to the round's declared branch (Minerva → `development`, minerva-plugins → `main`).
7. **CI, where CI exists — WAIT FOR IT.** Minerva and the plugins monorepo have it. Do not treat the push as the end of the round: poll until every job for that SHA reaches a terminal state, and report the conclusions. **A red job is a round failure**, handled like any other red gate, not a note in the report.
   Where there is no CI, say so in the round report. Its absence is not a skipped gate — it shifts that weight onto the review and adversary stations, and the report should state that rather than implying a check ran.

### Step 4 — CLOSE-OUT + PROVENANCE (conditional)

- If stop condition for this round was **3c** (phase boundary, auto-verified):
  - For each task in scope, transition `in_progress → done` with resolution note citing commit SHA + test counts.
- Otherwise:
  - Leave tasks `in_progress` until step 5 confirms.
- **Provenance on every number written into a durable record.** Stamp HOW a figure was measured, not just what it was — `"62 of 3403 (measured via _segment_clear)"`, not `"62 of 3403"`. A number without its oracle looks like ground truth and gets consumed as a premise by later rounds; that exact omission cost a round. Applies to any durable record — tracker item, commit body, or saved hint — not only Docket. Not all work is tracked in a docket; where it is not, the commit body is the durable record and the same rule applies to it.

- **What to WRITE at close-out is owned by the `orchestrator` skill.** The completion comment is a PM register — shipped SHA, gates with numbers, what it unblocks, decisions and who may veto, filed-not-fixed, what needs the owner — not a narrative. The technical account belongs in the commit message, which step 3#4 already gates.
- **Close-out has no reviewer.** Every station above fires before the commit; everything written after it is ungated. Before writing a factual claim here, open the file behind it.

### Step 5 — STOP CONDITION FIRES

0. **Audible notification (owner-requested)**: when all prescribed
   tasks in the cycle are done, play a beep BEFORE composing the report:
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

### Step 6 — RUN-AGAIN DECISION

If stop condition was **3c** (auto-verified) and there are more rounds queued in the same multi-round phase:
- Loop directly back to step 0 with the next round's scope.
- No human pause needed.

If stop condition was **3a / 3b**:
- Wait for user. Do not loop autonomously.

## Epoch boundary

Runs ONCE over the epoch's accumulated diff, after its last round has committed. `orchestrator` decides what the epoch contained; this is how the boundary is run.

### 1. Author the tests

Now, not before — with every implementation visible, and working from the oracle lines each round recorded at step 0.6.

**Few and wide.** Prefer one test that drives a real path end to end over many that verify their own assumptions. Mocks only where the real dependency is inherently unavailable or non-deterministic (live LLM calls, paid APIs, user dialogs), and then faked at the OUTERMOST process boundary — never by stubbing internal seams.

**Functional floor:** an epoch that touched a runtime surface ends with at least one REAL functional test green — real stack booted, one happy path driven at the integration boundary. An epoch with no runtime surface is exempt; say so in the report rather than skipping silently.

**Do not write a test whose oracle you could not name.** It will be blind by construction. Route that unit to the human register instead.

**Every test authored here is mutation-proven before the boundary closes.** This is the compensating control for writing tests after the code, and it is not optional. A test written against an implementation that already exists is shaped by that implementation and will agree with it — including where the implementation is wrong. Break what each new test claims to pin, confirm it goes red, restore. Half-mutate as well as fully: a test that dies under full removal can still pass when the condition is half-removed.

### 2. Full suite

Everything, not the targeted subset. Record the numbers.

### 3. Text + test adversary

**Serialize after the boundary review; never concurrent with it.** Two cold agents on one diff duplicate the expensive part and converge on the same headline finding. Hand this station a digest of what earlier stations established, with *"do not re-verify these; find what they missed."*

Prose is the only artifact with no gate — nobody runs a comment, so a false claim stays green forever, and agents read a docstring with the same weight as the code beneath it.

- **Mechanical pre-pass** (decidable, no judgment): does every symbol, test name, caller and path cited in changed prose resolve? Then grep the diff for modal claims — *never, always, cannot happen, guaranteed, by construction* — and surface each. Load-bearing claims cluster there.
- **Judged pass** (changed hunks only): are the comments correct, are the test docstrings correct, and **are the newly authored tests useful and correct?**

### 4. Code adversary

One question: *"What can I break here that nothing notices?"* Tools are mutants and fuzz, not reading — the reading stations already ran, and they find a different defect class. Fuzz geometry and parsing code specifically.

Survivors are the finding. Triage each as (a) real gap → write the test, (b) equivalent mutant → harmless, say why, (c) deliberately untested → say what would justify that.

**Verify the harness before believing a result.** Plant a mutation that MUST fail and confirm it does. A harness that reports "caught" for a mutation it never applied is worse than no harness.

### 5. Human bless, where the eye is the oracle

Anything checkable by looking — rendered output, layout, legibility — gets one human pass at the boundary rather than an automated proxy. Walk each artifact against stated intent, and ask the two questions a rendering cannot answer on its own: **what should be present that isn't**, and **what is not visible at all**.

### 6. Convergence count

Aggregate the per-unit counts: subtree items closed, and new items filed that *block* a subtree item. Report both. If filed-blocking meets or exceeds closed for two consecutive epochs, stop and report instead of opening the next one.

### Splitting the boundary review

When the accumulated diff exceeds what one reviewer reads well, split the review **by dimension** — one pass for correctness, one for prose and test power — rather than splitting the epoch.

## Campaigns

Campaign mode lives in the `orchestrator` skill, which owns the loop body, epoch composition, the adoption rule, termination conditions, HITL deferral and the exit report. This skill runs each round the campaign selects; the discipline here is unchanged whether a round was chosen by a human or by a campaign loop.

## Conventions

### Sub-agent prompts

Every prompt is self-contained — the agent has no memory of this conversation.

**State constraints. Point at facts.**

- A **constraint** is yours to set and cannot be wrong the way a number can: the fence, decisions already taken, process bans, the acceptance *shape*, "assert by identity not count", "mutate FULL and HALF". These earn their length.
- A **fact** is measurable, so name where it lives instead of restating it. Write *"read the floor from `_V1_MANUFACTURING_FLOOR`"*, never *"the floor is 0.127"*. Cite **symbol names, never file:line** — line numbers go stale within a round.
  **Treat this as a hard rule, not a preference, and check the brief against it before sending.** Sweep your draft for any sentence stating a value, a signature, a file location or a count, and convert each into a pointer. Every measurable thing you assert is a thing you can be wrong about while sounding authoritative — and the agent will believe you over the repo, which is the opposite of what you are paying it for.
- Prescribe the **invariant**, not the edit. "Make the code and the docs agree across both dimensions" finds every site; "add the predicate here" finds one.

Include:
- Goal in 1–2 sentences.
- The fence, verbatim, with the file-don't-fix rule.
- Symbols to read for existing patterns, in the order they should be read.
- Acceptance as a numbered list — including the criterion that defeats the lazy implementation (see `orchestrator`, "Acceptance criteria").
- Whether this unit writes a test at all — default tier does not; careful-tier and regression units do, and the brief must say which.
- Relevant hints retrieved at step 0.5, as "things to specifically check for."
- The refusal right, verbatim (step 1).
- **Where the full report goes, and what comes back.** Every station writes its complete output to nudge under `<epoch>/<unit>.<station>` and returns you a short summary — verdict, findings, numbers, refusals. The report is not for your context.
- For every fix cycle and every adversary: **the nudge key of what earlier stations established**, with *"read it, then find what they missed. Do not repeat their whole pass — but DO check any premise your own work rests on."* Name the key; never paste a digest you wrote by hand, which costs tokens and drifts from what was established.
  The distinction matters: telling an agent not to re-verify anything turns a mistaken upstream report into inherited truth. An implementer once found a station's central claim was wrong precisely because it checked instead of accepting. Duplicated effort is the cheap failure; inherited error is the expensive one.
- Brevity: "under 200 words" for reviewers; "concise summary at end" for implementers.
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
- `--cap=N` — per-unit gate retry cap
- `--no-stop` — suppress 3a/3b (unattended)

### Memory and hints

The `orchestrator` skill owns the stores and the protocol. This skill owns **when the search happens in a round** and **how its results reach an agent**.

**At step 0.5 (pre-flight), before the brief is written:**

```
docket_hint_query(project=<project>, component=<area this round touches>, detail="lean")
```

`docket_hint_*` is the DURABLE store; `nudge` is the in-flight one. Reach for `docket_context(tags=[…])` when orienting in an unfamiliar area — one curated briefing beats several full queries.

- **Scope by component.** An unscoped or tag-only query times out.
- **Lean first.** Pull a full body only for the hint you are about to act on; a component can hold a lot of long hints.
- A retrieved hint is **a claim, not a fact**. It gets the same treatment step 0.5#6 gives the work item's premises: verify before relying on it. Hints go stale exactly like tracker items.

**Into every sub-agent brief** — implementer and reviewer alike — name the relevant hints as "things to specifically check for," and let the agent read them. An implementer that knows the trap does not fall into it.

**As each unit closes**, write its findings to the tracker rather than accumulating them for the boundary. Then a handoff or a compaction at any point loses nothing. Write back what cost real time to learn, including *how it was measured*; the post-tool-use hook will remind you, and the moment to act on it is while the context is fresh.

## Anti-patterns

These come from past Phase 1B rounds and are cheaper to avoid than to discover again:

1. **Skipping step 0.** Spawning sub-agents without a plan leaks money and time when the decomposition is wrong. Plan first, even if the plan is short.
2. **Sharing reviewer context with implementer.** Defeats the entire purpose of the second pair of eyes. The reviewer must start cold.
3. **Marking docket `done` at WIP-time when manual test is the gate.** State is terminal — wait for the verdict.
4. **Big-batch WIP commits across multiple rounds.** Smart-batched per round, not per phase. Replay-ability matters.
5. **Surprise stops mid-round.** Other than 3d/3e, stops should be declared at step 0.
6. **Letting Sonnet retry past the cap.** Two must-fix rounds on the same unit → escalate to Opus.
7. **`git add .` or `git add -A`.** Stage by name; binaries/secrets sneak in otherwise.
8. **Running boundary stations per round.** The full suite and both adversaries are epoch-boundary gates. Running them every round is the cost this design exists to remove, and it buys nothing a targeted run does not already give.
9. **Skipping preflight.** Rounds that start on the wrong branch or a dirty tree produce unreviewable diffs and contaminated commits. The gate is fail-stop: report and wait, never improvise past it.
10. **Fixing out-of-fence discoveries inline.** Scope creep enters as "while I'm here." File it in docket, don't fix it. The diffstat audit will catch it anyway — cheaper to not write it.
11. **Writing code before the reuse scan.** Duplicated substrate/bridge/test code is the main DRY failure. Read the named references first; declare reuse/extend/copy before implementing.
12. **Campaign auto-adoption.** A goal loop that pulls every filed discovery into its candidate set is scope creep at campaign scale. Only explicitly-linked blockers join; everything else waits for a human.
13. **Green unit wall, no functional proof.** An epoch that ends with only unit tests green has verified its own assumptions, not the wiring. The functional floor is part of the boundary, not an optional extra; mocking internal seams to make it "pass" defeats it.
14. **Using the code under test as its own oracle.** The natural oracle for "did we emit something illegal?" is the project's own predicate — and that predicate can share the exact blind spot as the defect being hunted, so the measurement looks like ground truth and is not. An oracle must be built from a DIFFERENT representation than the code it judges. For a defect expressed in cells, assert in cells; do not ask whether a sampled chord passed.
15. **Full-only mutation.** A test that dies under full removal can still pass when the guard is half-removed — checking one branch instead of both. Wherever the mutation proof applies, half-mutate in each direction. This is the vacuous test that looks most like a good one.
16. **Grading tests by reading them.** Test value is a property of the test-plus-code system — does it fail when the code is wrong — and that is measurable, not inferable from the text. A reading-based grader inherits reading's blind spots, which is the failure being fixed. Measure with mutants; reserve judgment for what cannot be measured (oracle independence, re-bless resistance, intent legibility).
17. **Treating a golden as a pin.** Goldens detect CHANGE, not correctness: when one goes red the cheap response is to re-bless it, and the defect rides back in. They are not worthless — they are miscategorised. Never count a re-blessable failure as protection.
18. **Prose with no gate.** Comments, docstrings, commit messages and tracker records are now inputs to an executing system — agents read them with the weight of code and cannot smell staleness. They were advisory when only humans read them, and nothing re-classified them when that changed. Every claim in prose has a cheap oracle (the code, the diff, the repo at a SHA); the defect is that nobody consults it.
19. **Writing a test with no independent oracle.** If you cannot name one, the test is blind by construction and will pass while the behaviour is wrong. Source external ground truth, or route the unit to the human register — do not write the test and call it covered.
20. **Asserting in a brief what the agent could measure.** A supplied fact — a floor value, a symbol name, a baseline — is one the agent would have read correctly had the brief pointed instead of stated. The first-order cost is being wrong; the second-order cost is larger, because a brief dense with asserted facts teaches the agent to trust the brief over the repo, which is precisely the verification you are paying it for. Constraints are yours to state; facts are theirs to measure.
21. **Deferring a careful-tier pin to the boundary.** The tier exists because a silent defect gets more expensive once other units build on it. Deferring its test is the one deferral this design does not buy back.
22. **Believing a mutation result without checking the harness.** Plant a mutation that must fail and confirm it does. A rig that reports success while measuring nothing fails in the reassuring direction, and that is the direction nobody investigates.
23. **Letting an epoch's diff grow past what a reviewer reads well, then reviewing it anyway.** Split the boundary review by dimension. A review that silently degrades is indistinguishable from one that passed.
24. **Taking an agent's full report into your own context.** It belongs in nudge, keyed for whoever needs it next; you take the summary. This is the difference between an epoch that fits and one that does not.
25. **Writing a scratch file for a single-use intermediate result.** That is nudge with no query interface and cleanup you will forget.

## Reference

**This file is the source of truth.** `Docs/process/work-cycle.md` predates the epoch model and disagrees with it — on flag names, on when functional tests run, on reviewer models — so treat it as history, not instruction. Where the two differ, this file wins. Do not cite it to an agent.

Stop conditions: 3a UI-visual HITL · 3b plugin-behaviour HITL · 3c auto-verified, chains to the next round · 3d retry cap reached · 3e judgement-dependent must_fix, escalate to the owner.

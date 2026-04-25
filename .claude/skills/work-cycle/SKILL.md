---
name: work-cycle
description: Drive a multi-round work cycle on Minerva tasks with sub-agents (parallel implementers + Opus reviewers), automated Layer-1 verification, smart-batched WIP commits, and explicit stop conditions for human-in-the-loop tests. Use when starting a new round of focused implementation work — typically after a planning conversation or when picking up a docket task. Default scope is one DCR-grandchild task or a small group of sibling tasks.
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
4. Pick a model per unit using `Docs/process/work-cycle.md` "Model Selection". Defaults: implementer = Sonnet, reviewer = Opus, planner = Opus.
5. Declare the stop condition (3a / 3b / 3c / 3d / 3e). Announce it to the user.
6. Transition each task in the docket: `backlog → open → in_progress`.
7. Output a plan summary to the user:
   ```
   /work-cycle plan
     Tasks: <ids and titles>
     Units this round: <N>
     Models: <unit:model list>
     Stop condition: <3a/3b/3c/3d/3e — what triggers it>
     Expected: <what to expect at end of round>
   ```
   Do NOT wait for user confirmation unless the plan looks risky (3e potential, large scope, or pattern-establishing first round).

### Step 1 — WORK

For each unit in this round, in parallel where independent:

1. Spawn an Implementer sub-agent (`Agent`) with:
   - Model = unit's selected model
   - Subagent type = `general-purpose` (or `Plan` if first-of-pattern)
   - Prompt = self-contained brief: goal, files to touch, existing patterns to follow, tests to add, success criteria
   - Isolation: default unless the unit is large

2. When implementer returns, spawn a Reviewer sub-agent:
   - Model = Opus (always)
   - Subagent type = `general-purpose`
   - Prompt = "Review the implementation at <commit/files>. Verify: <unit's success criteria>. Look for: <known gotchas from work-cycle.md anti-patterns + repo-specific gotchas saved in nudge>. Verdict: approve / approve_with_notes / must_fix / reject."
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

2. Tally `PASS:` / `FAIL:` lines. Green = no FAIL lines.

3. If red:
   - Identify failing test by name.
   - If failure is in test fixture (not implementation), fix locally.
   - If failure is in implementation, re-spawn implementer with the failing assertion as context.
   - Cap at `--cap=N` retries (default 3) on the same problem. Past cap, escalate (3d).

### Step 3 — WIP COMMIT

1. Stage files explicitly by name (never `git add -A` or `.`).
2. Compose commit message:
   - Subject ≤ 70 chars, prefixed `WIP: ` when round is part of an unfinished phase.
   - Body lists each unit's deliverable and test counts.
   - Co-author trailer: `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.
3. Use HEREDOC for the commit message.
4. After commit, run `git status` to verify clean.

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

## Conventions

### Sub-agent prompts

Every sub-agent prompt must be self-contained — the agent has no memory of this conversation. Include:
- Goal in 1-2 sentences.
- Concrete files to touch (paths).
- Existing patterns to follow (with file:line references).
- Acceptance criteria as a numbered list.
- Test files to update or add.
- For reviewers: also list known gotchas from `nudge` hints under `minerva-plugin-platform`, `minerva-testing`, etc.
- Brevity instruction: "Report in under 200 words" for review agents; "Concise summary at end" for implementers.

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

## Reference

- Full spec, rationale, and examples: `Docs/process/work-cycle.md`
- Model selection rationale: `Docs/process/work-cycle.md#model-selection`
- Stop condition table: `Docs/process/work-cycle.md#stop-conditions`

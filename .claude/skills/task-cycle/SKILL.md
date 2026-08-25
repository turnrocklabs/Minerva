---
name: task-cycle
description: Run sequential goal-only tasks as one local batch: one base, one task, one commit; review and test after all tasks land.
---

# task-cycle

Run tasks sequentially from one local base. Each task produces exactly one
commit. Review the completed batch once, then run a deliberately scoped test
set. Do not push until the batch closes.

## Invariants

- No parallel tasks, integration branches, or worktrees.
- One task base → one task → one commit.
- Tests are authored but not run during implementation.
- Static checks may run before committing.
- Out-of-scope discoveries are filed, not fixed.
- Nothing is pushed until review and scoped execution finish.
- The full suite is deferred to its scheduled run.
- Comments should be salient.
- Reviews should be at batch end, not item-by-item.


## Terminology and shared controls

### Terms

- **Dispatch base** — the commit at the start of the batch. The batch review
  and scoped execution compare against this commit.
- **Task base** — the commit immediately before a task begins.
- **Batch** — all dispatched tasks, from the dispatch base through the final
  task commit.
- **Goal-only brief** — a brief containing the desired outcome and constraints,
  but no implementation instructions or unverified repository facts.
- **Oracle** — an independent observation that could show the implementation is
  wrong. If no independent oracle exists, do not write the test.
- **Static gates** — compilation, type checking, linting, formatting, and
  equivalent checks that do not execute the test suite.
- **Scoped execution set** — the named tests that validate the changes and
  cover plausible regressions in touched modules and their direct callers.
- **Cold review** — review performed without the implementer's explanation or
  prior discussion as context.
- **Deferred suite** — the full test suite, run separately on schedule.

### Pre-flight

Before dispatch, verify:

- the intended branch is checked out;
- the working tree contains no unrelated changes;
- the repository and branch are fresh enough for the work;
- the tracker item, acceptance criteria, and requested outcome are still valid;
- the exact `HEAD` SHA is recorded.

Stop if any check fails. Do not improvise past pre-flight.

### Shared controls

Before committing:

- inspect `git status --porcelain`;
- inspect `git diff --stat <task-base>`;
- stage paths by name;
- verify the commit message;
- confirm that exactly one commit represents the task.

Record relevant SHAs, scopes, and measured numbers wherever the workflow reports
them.

## Before dispatch

Pin the dispatch base:

```text
git rev-parse HEAD
```

Prepare one dispatch table per task:

```text
/task-cycle dispatch
  Task          <item id> — <title>
  Goal          <one-line goal, verbatim as the brief will state it>
  Base          <task base SHA>  (repository, branch)
  Implementer   Opus
  Adversary     Fable
  Tests         authored / none — oracle: <what would show this wrong>
  Constraints   <constraints in the brief>
  Not in scope  <what this task deliberately does not touch>
  Cross-provider yes / no
  Deferred      full suite: <last scheduled run> or OVERDUE
```

If the deferred suite is overdue, say so explicitly.

Wait for owner approval before spawning any agent. The owner must confirm:

1. the goal is the desired outcome; and
2. the stated oracle could genuinely fail if the task were wrong.

Any goal change requires a new dispatch table and renewed approval.

## Per-task procedure

Repeat these steps in dispatch order.

### 1. Write the brief

The brief contains only the goal and constraints. Do not prescribe mechanism or
state repository facts for the implementer.

Include this sentence verbatim:

> If something I state as fact is wrong when you measure it, say so — that is a success, not an embarrassment.

The brief must also state:

- out-of-scope discoveries follow file-don't-fix;
- tests must be authored but not run;
- the implementer may refuse an instruction believed to be wrong and must
  explain why.

### 2. Implement and author tests

Spawn the implementer. The implementer chooses the mechanism, implements the
goal, and authors the smallest useful test delta.

For every test, identify the oracle before writing it. Prefer few, wide tests
over many narrow tests. Use real paths where possible; mock only inherently
unavailable or nondeterministic outer dependencies.

### 3. Run static gates only

Run compilation, linting, formatting, type checks, and equivalent static gates.

Do not execute tests.

### 4. Audit and commit

Audit the task against its task base. Stage only intended paths and create one
local commit. Do not push.

Pin the new `HEAD`; it becomes the next task's base.

## After all tasks land

### 5. Review the batch

Give the cold adversary the diff from the dispatch base through the current
`HEAD`, along with:

```text
git status --porcelain
```

Do not provide implementer explanations or prior discussion. Tell the reviewer
that tests have not been run.

Review the batch as one body of work. Judge:

- goal fit;
- correctness, durability, reliability, factoring, readability, and cost;
- test width, minimality, oracle independence, and falsifying power;
- comment quality;
- scope.

Every comment must describe mechanism or a non-obvious code constraint. Comments
must not contain dates, requesters, ticket IDs, review history, or project
rationale.

The reviewer must answer these policy questions with yes/no and a reason:

1. Is every comment salient?
2. Is this the smallest test delta that can validate the change?
3. Is the code parsimonious?
4. Is the code readable by someone outside the conversation?
5. Is every changed path within scope?

Keep the review under 300 words unless the diff must be split by dimension.
Never split it by task.

### 6. Resolve findings

Allowed dispositions:

- **approve** — proceed;
- **approve_with_notes** — disposition every note as applied, rejected with a
  reason, or filed;
- **must_fix, resolvable** — fix and obtain a cold re-review of the finding and
  resolution;
- **must_fix, judgement-dependent** — stop and escalate to the owner;
- **reject** — return the work to the responsible implementer with the review as
  context. A second rejection escalates to the owner.

Fold each fix into the commit of the task that caused it. If attribution to one
task is impossible, create a clearly named batch-review fix commit.

### 7. Scope and execute tests

Before running anything, name:

1. tests that validate the changes; and
2. tests covering plausible regressions in touched modules and their direct
   callers.

Record the set and its justification. Run only that set.

A failure returns to the responsible task with the failing assertion as context.
Retry the same failure at most three times, then escalate.

Do not run the full suite.

### 8. Optional cross-provider review

After the batch review has closed, run at most one secondary review from a
different provider. Spend it where the definition of correctness is uncertain.
Small tasks may be excluded; record which tasks were excluded and why.

### 9. Push and report

Push only after review and scoped execution finish.

Report only what the scoped run established, for example:

> The batch's tests pass and no regression was found in the named touched
> modules and direct callers.

Do not claim the work is fully verified until the deferred full suite has run.

Record the deferred suite's status. It should run roughly weekly, or more often
during heavy change, against CI build outputs. Record its date, SHA range, and
results. Attribute failures by bisecting the covered range.

Finally, emit a one-line audible completion signal.
Notification failure must not block the report.
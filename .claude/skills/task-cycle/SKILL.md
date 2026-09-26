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
- Codex runs serially after Fable's rounds close, as the final check.
- Owner rulings on the campaign anchor minerva:01a0dc2bf96e bind every batch:
  static gates, syntax checks and exploratory experiments are always allowed,
  test execution only at step 7 (#2183); at most three fix rounds per review
  boundary (#2184's approved tables); no finding is dropped — it is resolved,
  placed on an owning task, or filed with a blast-radius priority (#2191, scale
  #2192).
- Every stage leaves its Docket work record (see Work records).


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

**Records.** Reads the objective and each task (status, DONE WHEN, open
`deferred:` comments) and every attempt under them. An attempt left
`in_progress` or `blocked` by an earlier session is reconciled first. The
pinned `HEAD` becomes the first attempt's `base:` tag.

### Shared controls

Before committing:

- inspect `git status --porcelain`;
- inspect `git diff --stat <task-base>`;
- stage paths by name;
- verify the commit message;
- confirm that exactly one commit represents the task.

Record relevant SHAs, scopes, and measured numbers wherever the workflow reports
them.

### Work records

The batch lives in Docket as W1 work records. The template — record kinds,
field and tag grammar, protected fields, who the caller is — is KB
docket:01a0dc3549bc (key `work-records/template-v1`); read it there, it is not
restated here. Each stage below ends with a **Records** line saying what it
reads and writes. The shape:

- the batch is one `wr:objective`; each dispatched task is one `wr:task` under
  it; each dispatch of one actor in one role is one `wr:attempt` under its task
  (a retry is a new attempt, linked `follow_up` from the old one);
- evidence — commands, measured numbers, SHAs — is a comment on the attempt,
  authored by the actor's principal; results go in `resolution`, never only in
  chat;
- `docket_update` replaces the whole tag list, so a tag value is changed by
  rewriting the list without the old value.

A resuming orchestrator rebuilds state from these records alone: the
objective's tasks, their `requires:` / `integrated:` / `review:` / `test:` /
`deferred:` tags, and any attempt still `in_progress` or `blocked`. An
interrupted attempt is reconciled against its evidence and `head:` before a
retry, so completed side effects (commits, pushes) are not repeated.

Docket builds differ. The records need only create, update, transition, comment
and link, which every build has. Claims (`docket_claim` / `docket_release` /
`docket_reassign` with a `holder`), `if_revision` on update and transition,
`docket_append`, `docket_authorized` and `docket_subscribe` /
`docket_changes_since` / `docket_ack` need a current Docket build; an older
running server has none of them. Without claims, holding is declared by
`assigned_to` alone and nothing refuses a stale write.

How to file and word tracker items, and close-out, belong to the
`orchestrator` skill; this skill only says which record each of its stages
touches.

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

**Records.** The batch's objective is the existing plan item tagged
`wr:objective`, or a new one. Each table row is a `wr:task` under it: Goal,
Not in scope and Constraints become its description's GOAL / NON-GOALS /
TRAPS, the DONE WHEN states the oracle, and the Tests row becomes `test:not-run`
(plan NONE) or `test:planned`. The tables themselves and the owner's approval,
in the owner's words, are comments on the objective.

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

**Records.** The brief is the description of a new `wr:attempt` under the task:
`role:implementer`, the actor's principal in `assigned_to`, `base:` = the task
base, plus what the attempt is authorized to do and its test plan. The task
moves to `in_progress` (and is claimed, where the build has claims); the
attempt moves to `open` when spawned.

### 2. Implement and author tests

Spawn the implementer. The implementer chooses the mechanism, implements the
goal, and authors the smallest useful test delta.

For every test, identify the oracle before writing it. Prefer few, wide tests
over many narrow tests. Use real paths where possible; mock only inherently
unavailable or nondeterministic outer dependencies.

**Records.** The attempt is `in_progress`. The implementer's measurements and
refusals are evidence comments on it; each out-of-scope discovery is its own
filed item, linked `surfaced` from the task. A refusal ends the attempt with
`result:refused`.

### 3. Run static gates only

Run compilation, linting, formatting, type checks, and equivalent static gates.

Do not execute tests.

**Records.** Gate commands and their results are an evidence comment on the
attempt.

### 4. Audit and commit

Audit the task against its task base. Stage only intended paths and create one
local commit. Do not push.

Pin the new `HEAD`; it becomes the next task's base.

**Records.** The audit (`git status --porcelain`, `git diff --stat`) is an
evidence comment. The attempt gets `head:` = the commit, `result:completed`
and a one-line `resolution`, and moves to `done`. The task gets
`requires:<repo>@<branch>@<sha>` for the commit and `review:requested`; it
stays `in_progress` — acceptance is decided later, not here.

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

**Records.** One `role:reviewer` attempt for the batch, parented to the
objective (the review spans tasks), with `base:` = the reviewed `HEAD`; the
verdict and policy answers are its evidence. Each finding is a comment on the
task it belongs to, and that task moves to `review:findings-open`.

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

**Records.** A disposition is the finding comment accepted or rejected, with
the reason as a reply (reject records no reason of its own). A fix is a new
implementer attempt under the owning task with `base:` = the current `HEAD`. A
fold rewrites every later commit, so each affected task's `requires:` moves to
its new SHA. A finding left unresolved becomes a filed item linked `surfaced`
from the task. When every finding on a task is disposed, it moves to
`review:accepted` — a fact, not a gate.

### 7. Scope and execute tests

Before running anything, name:

1. tests that validate the changes; and
2. tests covering plausible regressions in touched modules and their direct
   callers.

Record the set and its justification. Run only that set.

A failure returns to the responsible task with the failing assertion as context.
Retry the same failure at most three times, then escalate.

Do not run the full suite.

**Records.** The named set and its justification are a comment on each task it
covers, which moves to `test:planned`; the owner's approval is a comment on the
objective. The run is a `role:tester` attempt whose evidence is the command and
its result; each task then carries `test:passed` or `test:failed`. A failure
returns as a new implementer attempt with the failing assertion in its brief.

### 8. Cross-provider final check (Codex)

Codex is the final double-check of code Claude believes is finally good. It
runs SERIALLY, only after every Fable find/fix round has closed and every
must_fix is folded in — never in parallel with the batch review, and never on
a diff that still has open findings. Feed it the diff on stdin (it cannot use
its sandbox on this host); tell it not to run commands.

Disposition its findings the same way as step 6. A must_fix from Codex goes
back through one Fable-judged fix round, then Codex re-checks the fold; a
second Codex must_fix escalates to the owner. Small batches may skip Codex;
record that they were skipped and why.

**Records.** As step 5: a second `role:reviewer` attempt with its own actor;
a skip is a comment on the objective.

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

**Records.** The push is a `role:integrator` attempt; its evidence is the
remote ref after the push. Each task gets `integrated:<repo>@<branch>@<sha>`
per commit landed; every required branch is integrated only when each
`requires:` tag has an `integrated:` tag with the same repo, branch and SHA.
Validation that did not run — the deferred suite, a human check — is a
`deferred:<what>` tag plus one open comment naming what, why and who owns it.
The task's holder then records `outcome:accepted` (or rejected / abandoned /
superseded) with a `resolution` and moves it to `done`.
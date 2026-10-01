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
- Tests are authored but never run by the implementer. The configured tester
  runs a test group's named set when the group's last task commits, and the
  union of every group on the exact final `HEAD` before the push.
- Static checks may run before committing.
- Out-of-scope discoveries are filed, not fixed.
- Nothing is pushed until review and the final scoped run on the final `HEAD`
  finish.
- The full suite is deferred to its scheduled run.
- Comments should be salient.
- Reviews are at batch end, not item-by-item, unless a test group is declared a
  review boundary on the dispatch table because later groups depend on a
  contract it changes. Review fixes are separate commits, never folds.
- The cross-provider reviewer runs serially after the batch review's rounds
  close, as the final check.
- Who fills each role, how many reviewers and fix rounds each boundary gets,
  and which stages run come from the configuration record (see
  Configuration). This skill names no provider or model.
- A gated stage — review, test execution, push — runs only when a standing
  authorization covers it (see Authority). A missing one stops the batch; it is
  never skipped silently.
- Static gates, syntax checks and experiments that answer a design question
  are always allowed. Experiments that stand in for tests — probe scripts and
  mutation checks written to gain confidence in one's own change — are not:
  the tester's group runs and the final run on a named set the owner approved
  are where confidence comes from.
- Fix rounds per review boundary are capped by the configuration record's
  `rounds` value; when the cap is reached the owner is asked.
- No finding is dropped: each is resolved, placed on an owning task, or filed
  with a priority set by its blast radius.
- Every stage leaves its Docket work record (see Work records).
- The stage transitions may be run by a workflow script, but only on the
  owner's explicit words, and judgement points — dispositions, filing, the
  push — stay with the orchestrator (see Consider a workflow).


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

### Pre-flight (preconditions)

Before dispatch, verify:

- the intended branch is checked out;
- the working tree contains no unrelated changes;
- the repository and branch are fresh enough for the work;
- the tracker item, acceptance criteria, and requested outcome are still valid;
- exactly one configuration record is found, and it is valid (below);
- the exact `HEAD` SHA is recorded.

Stop if any check fails. Do not improvise past pre-flight.

**Records.** Reads the objective and each task (status, DONE WHEN, open
`deferred:` comments) and every attempt under them, and the configuration
record. An attempt left `in_progress` or `blocked` by an earlier session is
reconciled first. The pinned `HEAD` becomes the first attempt's `base:` tag.

#### Configuration

The process is configured by a record, not by editing this skill or host code.
It is a `kb` item tagged `process-config` whose `key` is
`process-config/task-cycle`. An objective tagged `config:<item id>` uses that
item. Otherwise find it with `docket_query` for that type, tag and key in the
objective's project, then, if none is there, in project minerva. Its `article`
holds one fenced JSON object:

```json
{
  "schema": "task-cycle/v1",
  "roles": {
    "implementer":    {"provider": "<p>", "model": "<m>"},
    "reviewer":       {"provider": "<p>", "model": "<m>"},
    "cross_reviewer": {"provider": "<p>", "model": "<m>", "notes": "<text>"},
    "tester":         {"provider": "<p>", "model": "<m>"},
    "integrator":     {"provider": "<p>", "model": "<m>", "principal": "<id>"}
  },
  "stages":    {"batch_review": true, "cross_provider": true,
                "testex": true, "push": true},
  "reviewers": {"batch_review": 1, "cross_provider": 1},
  "rounds":    {"batch_review": 3, "cross_provider": 1, "testex": 3},
  "queue":     {"serial": true},
  "budgets":   {"implementer_tool_calls": 30, "reviewer_tool_calls": 20}
}
```

- `roles.<role>` — who fills the role. `provider` is the harness that runs it
  and `model` the model that harness is told to use; both are opaque strings
  passed to that harness. Optional `principal` is the actor's principal id
  (template section 5), default the orchestrator's own; optional `notes` is
  dispatch advice for that provider (how to feed it input, what it cannot do),
  read by the orchestrator and not pasted into the brief. The attempt role tags
  are `role:implementer`, `role:reviewer` (reviewer and cross_reviewer),
  `role:tester` and `role:integrator`.
- `stages.<stage>` — whether steps 5, 8, 7 and 9 run. A stage turned off is
  recorded where the step says, never dropped silently.
- `reviewers.<stage>` — independent cold reviewers per review boundary, each
  its own attempt.
- `rounds.<stage>` — fix rounds allowed at that boundary before the owner is
  asked; for `testex`, retries of one failure.
- `queue.serial` — tasks dispatch one at a time, the next only after the
  previous commit. This template implements only `true`; `false` is refused.
- `budgets.<role>_tool_calls` — optional; the tool-call allowance stated in an
  implementer's or reviewer's brief (defaults 30 and 20). Verification is
  testex's job: an implementer that cannot run tests will otherwise build its
  own harness from probe scripts and mutation checks, and a reviewer will do
  the same, which has cost more than the testex round it replaces. When the
  allowance is reached the agent stops and reports what it has, listing what
  the first test run should settle.

Every key is required except `principal`, `notes` and `budgets`. Validate the whole
object before dispatch. A key not listed here (for example a per-task review
switch), a missing key, a wrong type, a count below 1,
`serial: false`, or a cross reviewer with the reviewer's provider while
`cross_provider` is on stops pre-flight with a message naming the key path and
what was wrong. Changing a
role's provider or model in the record changes the next attempt dispatched
for that role; nothing else needs editing.

#### Authority

Review (steps 5 and 8), test execution (step 7) and push (step 9) need a
standing authorization (W1 T3): an active `policy` item tagged
`authorization`, `action:<class>`, `scope:*` and `granted-by:*`, grantee in
`directed_to`. The action classes are `review`, `execute-tests` and `push`.

Immediately before each gated stage, and again as a preview on the dispatch
table, ask:

```text
docket_authorized(actor="role:<role tag>", action=<class>, id=<objective>, project=<p>)
docket_authorized(actor=<role's principal>,  action=<class>, id=<objective>, project=<p>)
```

Either `authorized: true` suffices; cite the matching record id in the
attempt's brief. If both are false, STOP the batch: comment on the objective
`MISSING AUTHORIZATION: action:<class> for role:<role> or <principal>,
scopes checked <scopes_checked>` and ask the owner. Only a person grants one;
the orchestrator never creates or widens an authorization. Assignment is not
authority, and authority does not claim an item.

A Docket server without `docket_authorized` answers the same question with
`docket_query`: `type` policy, `status` active, tags `authorization` and
`action:<class>`, `directed_to` equal to the actor; keep records whose scope
tag is `scope:project:<p>`, `scope:item:<full id>` of the objective or an
ancestor, or `scope:tag:<t>` for a tag the objective carries.

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
  Config        <config item id>, updated <updated_at>
  Roles         <role>: <provider>/<model> [<principal>]  — one line per role
  Review        batch <reviewers>×, ≤<rounds> rounds; cross-provider <reviewers>×,
                ≤<rounds> rounds; testex ≤<rounds> retries
  Stages        batch_review on/off; cross_provider on/off; testex on/off;
                push on/off   (queue serial)
  Authority     review <record id or MISSING>; execute-tests <…>; push <…>
  Execution     orchestrator-stepped | workflow (needs the owner's explicit words)
  Test group    <group> = {<tasks>} → <classes> after <last task> commits
  Tests         authored / none — oracle: <what would show this wrong>
  Constraints   <constraints in the brief>
  Not in scope  <what this task deliberately does not touch>
  Deferred      full suite: <last scheduled run> or OVERDUE
```

The Config through Authority rows are the effective configuration, read from
the record at pre-flight, not typed from memory. If the deferred suite is
overdue, or an enabled stage's authorization is MISSING, say so explicitly.

Wait for owner approval before spawning any agent. The owner must confirm:

1. the goal is the desired outcome; and
2. the stated oracle could genuinely fail if the task were wrong.

Any goal change requires a new dispatch table and renewed approval.

### Test groups

Within a batch, tasks belong to test groups. A group names its tasks, its
scoped test set (the classes that validate those tasks plus touched modules
and direct callers) and its trigger: the group runs once the last of its tasks
has committed. A task alone is a group of one, tested right after its gate;
related tasks that share a primitive are one group tested once, so one run
also covers their interaction. The orchestrator proposes the groups on the
dispatch table and the owner approves or redraws them with the goals.

Signals for proposing a group: two tasks whose planned test sets share a
class; a dependency or `follow_up` link between tasks; tasks touching the
same module or persisted contract (from the scout's map on a large repository).
Without a signal each task is its own group; when the owner has called tasks
related, they are one.

Grouping is early feedback, not the gate: the final scoped run (step 7) covers
the union of every group on the exact final `HEAD`, so a group drawn too wide
delays feedback and one drawn too narrow defers an interaction to that run —
neither affects correctness. A group boundary may also be a review boundary
when a later group depends on a contract the earlier one changes
(`review: per-group`); the default is one review at batch end.

**Records.** Each task carries `test-group:<name>`. A group run is a
`role:tester` attempt naming its tasks and classes; its result sets
`test:passed` or `test:failed` on each task in the group. The trigger is a
fact a workflow runner can evaluate: every task tagged with the group has a
`head:`.

### Consider a workflow

The stage transitions below are mechanical: implement → static gate → commit
→ cold review → bounded fix rounds → cross review → scoped tests → bounded
retries. Stepped by the orchestrator, each arrow is a turn that waits for a
notification, re-reads the whole conversation and writes the next brief; on
a small change those gaps have cost about a third of the process time. A
workflow script can run the arrows and return only at the judgement points.

When the batch is small or medium and the chain is the standard one, ask the
owner on the dispatch table whether to run it as a workflow. A workflow runs
only on the owner's explicit words in reply (for example "run it as a
workflow"); approval of the table alone is not that, and the orchestrator
never assumes it.

A workflow run keeps the invariants above: tasks strictly serial, one commit
per task, the configured roles and round caps, static gates before commits,
no test run before step 7. It may spawn and chain the implementer, gate,
reviewer, fixer, cross-reviewer and tester agents, and must STOP and return to
the orchestrator at: a `must_fix` the reviewer flags as judgement-dependent,
a `reject`, a round cap reached, anything that needs filing, and before the
push — the orchestrator dispositions, files, writes the records and pushes.
Reviewer agents therefore return findings in a shape that carries that flag.
Evidence the agents gather goes into the records as in an orchestrator-stepped
run, written either by the agents themselves or by the orchestrator once at
close-out.

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
- tests must be authored but not run, and not stood in for: static gates only,
  no probe scripts or mutation checks to gain confidence in the change — a
  scoped run follows review and is where confidence comes from. An experiment
  that answers a design question (how does this path behave today?) is fine;
- the tool-call allowance from `budgets.implementer_tool_calls`; at the
  allowance the implementer stops and reports what it has;
- the report ends with "What the first test run should settle", one line per
  thing the implementer could not verify;
- the implementer may refuse an instruction believed to be wrong and must
  explain why.

**Records.** The brief is the description of a new `wr:attempt` under the task:
`role:implementer`, the role's principal in `assigned_to`, `base:` = the task
base, `provider:<provider>/<model>` from the configuration, plus what the
attempt is authorized to do and its test plan. Every attempt carries the
`provider:` tag, because local principals cannot tell two providers on one
machine apart (template section 5). The task
moves to `in_progress` (and is claimed, where the build has claims); the
attempt moves to `open` when spawned.

### 2. Implement and author tests

Spawn the configured implementer through its provider. The implementer chooses
the mechanism, implements the goal, and authors the smallest useful test delta.

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

If this commit completes a test group, the configured tester runs that group's
classes now (`execute-tests` authority checked first; the implementer never
runs them). A failure returns to the owning task as a new implementer attempt
with the failing assertion, and the group re-runs; retries are capped by
`rounds.testex`. Reviewers at step 5 are given the group results, so they
spend their attention on what a test cannot see.

**Records.** The audit (`git status --porcelain`, `git diff --stat`) is an
evidence comment. The attempt gets `head:` = the commit, `result:completed`
and a one-line `resolution`, and moves to `done`. The task gets
`requires:<repo>@<branch>@<sha>` for the commit and `review:requested`; it
stays `in_progress` — acceptance is decided later, not here.

## After all tasks land

### 5. Review the batch

Runs when `stages.batch_review` is on; check `review` authority first. Give
each of the `reviewers.batch_review` configured cold reviewers the diff from
the dispatch base through the current `HEAD`, along with:

```text
git status --porcelain
```

Do not provide implementer explanations or prior discussion. Tell the reviewer
that tests have not been run, that it reviews by reading (static checks
allowed, no probe scripts or mutation checks — anything only a run can decide
goes under "what the first test run should settle"), and its tool-call
allowance from `budgets.reviewer_tool_calls`. Ask it to mark each `must_fix`
as resolvable or judgement-dependent, so a workflow run knows where to stop.

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

**Records.** One `role:reviewer` attempt per reviewer, parented to the
objective (the review spans tasks), with `base:` = the reviewed `HEAD`; the
verdict and policy answers are its evidence. Each finding is a comment on the
task it belongs to, and that task moves to `review:findings-open`. A stage
turned off in the configuration is a comment on the objective naming the
config item, and each task keeps `review:requested`.

### 6. Resolve findings

Allowed dispositions:

- **approve** — proceed;
- **approve_with_notes** — disposition every note as applied, rejected with a
  reason, or filed;
- **must_fix, resolvable** — fix and obtain a cold re-review of the finding and
  resolution; after `rounds.batch_review` rounds, escalate to the owner;
- **must_fix, judgement-dependent** — stop and escalate to the owner;
- **reject** — return the work to the responsible implementer with the review as
  context. A second rejection escalates to the owner.

Each fix round is its own commit on top of the current `HEAD`, named for the
review that asked for it (`review: …`). Fixes are not folded into the task
commit: a fold rewrites every later SHA and invalidates the `head:` and
`requires:` evidence already recorded, while a separate commit keeps the
history of what the review changed readable.

**Records.** A disposition is the finding comment accepted or rejected, with
the reason as a reply (reject records no reason of its own). A fix is a new
implementer attempt under the owning task with `base:` = the current `HEAD`
and `head:` = the fix commit; the owning task's `requires:` moves to that
commit. A finding left unresolved becomes a filed item linked `surfaced`
from the task. When every finding on a task is disposed, it moves to
`review:accepted` — a fact, not a gate.

### 7. Scope and execute tests

Before running anything, name:

1. tests that validate the changes; and
2. tests covering plausible regressions in touched modules and their direct
   callers.

Record the set and its justification. Runs when `stages.testex` is on; check
`execute-tests` authority, then the configured tester runs only that set.

This is the gate the push depends on, and it is evaluated against the exact
final `HEAD`: the union of every test group's set runs once more after the last
review fix commit, whatever the group runs showed earlier. Any later code
change invalidates it; push eligibility is never inferred from the fact that
tests and reviews both happened at some point.

A failure returns to the responsible task with the failing assertion as context.
Retry the same failure at most `rounds.testex` times, then escalate.

Do not run the full suite.

**Records.** The named set and its justification are a comment on each task it
covers, which moves to `test:planned`; the owner's approval is a comment on the
objective. The run is a `role:tester` attempt whose evidence is the command and
its result; each task then carries `test:passed` or `test:failed`. A failure
returns as a new implementer attempt with the failing assertion in its brief.
With the stage off, each task carries `test:not-run` and `deferred:scoped-tests`
naming the config item.

### 8. Cross-provider final check

The configured cross reviewer — a different provider from the batch reviewer —
is the final double-check of code the batch review believes is finally good.
It runs when `stages.cross_provider` is on, after `review` authority is
checked, SERIALLY: only after every batch-review find/fix round has closed and
every must_fix is fixed and committed — never in parallel with the batch review, and
never on a diff that still has open findings. Follow the role's `notes` for how
to feed it the diff.

Disposition its findings the same way as step 6. A must_fix goes back through a
fix round judged by the batch reviewer, then the cross reviewer re-checks the
fix commit; past `rounds.cross_provider` rounds, escalate to the owner. A small batch
may skip the stage by saying so, with the reason, on its dispatch table.

**Records.** As step 5: one `role:reviewer` attempt per cross reviewer, with
its own actor and `provider:` tag; a stage turned off or skipped is a comment
on the objective.

### 9. Push and report

Push only after review and scoped execution finish. Runs when `stages.push` is
on; check `push` authority, then the configured integrator pushes.

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
superseded) with a `resolution` and moves it to `done`. With the push stage
off, each task carries `deferred:push` instead of `integrated:`.
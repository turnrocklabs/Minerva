---
name: evidence-cycle
description: Implement an approved Docket batch with serial writers, independent review, scoped tests, and evidence required before push.
---

# Evidence cycle

Use this skill to take approved Docket work through implementation, review,
testing, and an authorized push. Release when the run's authority and settings
include it. This replaces `task-cycle` and `work-cycle` for new batches.

The **manifest** is the approved execution plan. The **candidate** is the commit
being considered for push. Decisions use the owner's authoritative ten-axis
rubric, Docket item `minerva:01a0b15a3cad7827bbc821e1b9d29b21` (read it through
Docket; with only a browser, fetch
https://raw.githubusercontent.com/turnrocklabs/Minerva/development/Docs/minerva.dct
and search for the id — the file is too large for GitHub to render); freeze
its contents with the plan.

## The cycle at a glance

| Phase | Responsible | Result needed to continue |
|---|---|---|
| Prepare | Orchestrator; owner where required | Complete, approved manifest and available execution controls |
| Implement | One writer, tasks in series | Focused checks during iteration; exact-SHA static PASS starts review and the final named run |
| Review | Independent reviewers; orchestrator | Review runs alongside final tests; every finding gets a decision |
| Repair | Serial fixer; required reviewers | Repaired candidate passes checks and has required review coverage |
| Accept | Orchestrator; authorized integrator | Writer's exact-SHA PASS job, pack spot-check and reviews support push; CI is recorded |

The writer (implementer or fixer) executes the profile's gates and tests in its
approved isolation. The orchestrator owns decisions, spot-checks and recovery.
Read-only review and planning may run in parallel; code-changing agents stay
serial. A separate command executor is an exception for a runner capability
gap, recorded before dispatch; it does not remove the writer's check obligations.

## Rules that apply throughout

- Generate briefs and commands from the manifest and profile. Keep code
  changes within the approved goals and non-goals.
- Writers author useful tests, run focused affected targets while iterating,
  and run the full named set once on the immutable final SHA. Use the approved
  profile commands, not substitute probe or mutation harnesses.
- Ask questions before dependent work, then wait for actual answers before a
  dependent commit. A timeout is not an answer; return incomplete if needed.
- Initial reviews are independent: every configured reviewer gets the same
  candidate and context, without implementer explanations or prior reviews.
  Keep all configured reviewers during the pilot.
- Give each task one implementation commit. Count handed-off preserved commits
  toward the cap. Pre-handoff corrections may amend the writer's own unhanded
  commit; never rewrite commits already delivered, reviewed or integrated.
  Later repairs are separate `review:` commits. Keep temporary feedback SHAs
  and job receipts visible, marked superseded when replaced.
- Record command and review results against their actual commit. Older group
  results are useful feedback, not proof that the final candidate passes.
- At an attempt's tool-call or time allowance, return **incomplete** with
  remaining uncertainties. The orchestrator may dispatch a bounded follow-up
  within the configured round limits. Reaching a round limit ends the batch
  incomplete; it never counts as approval.
- Write a durable start checkpoint before a consequential action and its
  completion afterward. Verify exclusive execution before dispatching work.
  [Runner details](references/runner.md) define these requirements.
- Keep dossiers compact: SHA, job IDs, short report and actual usage ledger.
  No source tars or source hash indexes. Retain approved input contents and
  hashes for reproducibility; those are distinct from the source dossier.
- Secret-handling fixtures emit only exception class, line number and a fixed
  stage label. Never emit payloads or secret representations; do not introduce
  a broad secret-logging framework.

## Batch size and scope

Ceremony — preparation, review rounds, acceptance and release — costs about
the same per batch whatever the batch contains, and reviewers stop converging
after about three rounds. So size is decided per batch, by rule:

- **Fill to the ceiling.** Ceremony is paid once per batch whatever it holds,
  and writer time is a small fraction of it (batch 4: 7 of 48 minutes), so
  there is no time floor. Intake keeps adding ready items until the next one
  would breach the ceiling; a batch is never run for one small item while
  ready items wait.
- **Ceiling.** One release, one shared-primitive seam, and a diff a cold
  reviewer can cover in three rounds — the profile's `batch` limits on commits
  and changed lines. Above it, split before admission.
- **Size tag.** Every task carries `size:S`, `size:M` or `size:L`. An `L` is
  never dispatched whole: splitting it into children that each have an oracle
  is itself a task. Estimates are poor, so each task records estimate against
  actual (commits, files, minutes); the profile's ceremony and size limits are
  revised from actuals, not from opinion.
- **Readiness.** A task is ready when it has a DONE WHEN, an oracle, a size
  tag, no blocker and no other claim. Intake takes ready items in priority
  order up to the ceiling. An unready item goes to shaping — write the
  oracle, split the `L` — which is dispatchable work, not a reason to stop.
  A project with an active `policy` tagged `intake:parked` is skipped
  entirely; with `intake:parked-before:<date>`, its items not updated since
  that date are skipped. Only the owner archives a park.
- **Declared touch-set.** Each manifest task names the paths it expects to
  change. The commit audit compares `git diff --stat` against that list; a path
  outside it is a finding — filed, or justified in one line in the attempt's
  evidence. "It felt related" is how scope arrives disguised as discovery.

## Decisions, approval, and authority

Default to autonomous decisions within already-approved goals. Read the
configured autonomy mode; an explicit owner instruction overrides skill
defaults. Autonomy does not grant permission to review, run tests, push, or
release.

In autonomous mode, measure the relevant facts, compare options using all ten
rubric axes, and record the decisive axis, chosen default, and what would
disprove it. The owner may veto that default. Ask the owner when:

1. The choice changes what the product is.
2. Options differ in user-visible behavior and evidence does not settle the choice.
3. No option can safely proceed under the established facts and constraints.

In attended mode, unresolved judgment goes to the owner. Cheap, reversible
decisions need a concise record, not a separate decision package.

Before review, test execution, or push, check the role and principal with
`docket_authorized`. Either matching authorization suffices. A missing
authorization stops that action. Only a person grants or widens authority.
Reuse existing approval and authority within their scope.

Workflow execution needs the owner's explicit words for the batch or
objective. Suggest it for a standard batch; record authorization once and
reuse it for batches it covers. Release runs only when authorized and enabled
by the selected mode. A changed goal reopens plan approval.

## 1. Prepare

**Responsible:** orchestrator; optional read-only scout; owner where required.
**Inputs:** objective, tasks, process config, project profile, rubric.

1. Resolve the repo key to a local path. Check the intended branch, clean tree,
   freshness against origin, and green CI on the base. Confirm the items and
   acceptance criteria are still valid; pin the base commit.
2. Load and validate exactly one config and profile. Read
   [schemas](references/schemas.md) when preparing these records.
3. Gather missing facts before freezing the plan. Use a read-only scout when
   the profile's size threshold or missing test map warrants it. Discovery
   must already be within approved scope; obtain bounded discovery approval
   only if it is not. The scout supplies navigation and test pointers.
4. Build the manifest: goals, non-goals, oracles, sizes, touch-sets, task
   order, test groups, affected contracts, reviewers, budgets, and execution
   mode. Check the batch against the ceiling and record the check.
   Distinguish tasks that must precede others from tasks useful to test
   together.
5. Freeze the actual config, profile, and rubric contents with hashes. Retain
   those contents so another session can retrieve them.
6. In owner-approval mode, present the completed plan and wait. In
   ratified-items mode, verify recorded owner approval of every goal and
   acceptance criterion, record the derived plan as a default, and proceed.
   Merely existing in Docket does not make an item approved.
7. Verify the selected runner's capabilities and exclusive execution. Use
   [runner details](references/runner.md) for a Workflow run or recovery.

Test groups are early-feedback boundaries. Shared classes, modules, or links
suggest grouping; they do not prove interaction coverage. Name the interaction
scenario where it matters. A group may also require review before dependent
tasks proceed; record that boundary explicitly.

**Exit:** the complete manifest is approved under the selected mode, retained
inputs are retrievable, and required execution controls are available.
Missing facts or failed preconditions stop preparation with a precise reason.

## 2. Implement and check

**Responsible:** one implementer for the whole batch, working the tasks in
manifest order, including gates and tests.
**Inputs:** manifest, current task base, one generated batch brief.

1. Give a fresh implementer the batch: every task's goal, oracle, verified
   pointers, constraints, non-goals, forbidden resources, and the budget for
   the batch. It carries context between related tasks but still makes one
   commit per task and commits each before starting the next. A new
   implementer is dispatched only for a different batch or after this one
   returns incomplete. Include:
   > If something I state as fact is wrong when you measure it, say so — that is a success, not an embarrassment.
2. The implementer writes code and the smallest useful broad tests. It reports
   out-of-scope discoveries without fixing them, and may refuse an instruction
   with a reason. End its report with **What the reviewer should settle**.
3. Check intended paths and generated files against the task's touch-set;
   commit the task and run the profile's static gates on that exact SHA in
   the prescribed isolation. Record actual commits, files and
   minutes beside the estimate. A gate failure returns to bounded repair;
   a path outside the touch-set is a finding for Review and decide.
4. When every task in a group has a completed implementation attempt and a
   verified commit reachable from the batch head, the writer executes its
   named tests with the profile's isolation. Focused affected targets also
   run during iteration; feedback receipts retain their actual SHA. When the
   group completes the final candidate, use step 6 for the full named set
   rather than running that same final set twice.
5. A failing group blocks further implementation. An assertion goes to a fixer
   with the exact failure. Other failures are classified before deciding
   whether to retry the command or change code. Recheck gates after any repair.
6. At final static PASS, immediately post the immutable candidate SHA and gate
   job ID. Start independent review before waiting for the final runtime run;
   mark runtime in progress. Run the full named target set once at this SHA
   and hand off its PASS job ID and targets when complete. A changed SHA
   explicitly supersedes the pointer and requires new gates, tests and review
   coverage. The early pointer grants neither runtime PASS nor acceptance.

Command failure handling and retry limits are in
[runner details](references/runner.md). File discoveries as separate items.

**Exit:** all tasks are committed and their group tests pass. Results identify
the actual tested commits; final handoff names the exact-SHA PASS job and
targets. An incomplete or refused attempt remains visible. An explicitly
approved static-only task records that scope and runs no runtime classes.

## 3. Review and decide

**Responsible:** all configured reviewers; orchestrator for finding decisions.
**Inputs:** static-PASS candidate, diff, available results, profile contracts.

1. Start review from the writer's static-PASS pointer while its final named
   run proceeds. State earlier tested SHAs and current runtime status; add
   the final job receipt when it finishes. Never imply an in-progress run passed.
2. Give reviewers the same compact context: goal, diff, affected contracts,
   test results, known gaps, and navigation pointers. Include callers and
   contract text for a diff-only reviewer; allow targeted source requests.
3. Reviewers read independently and return structured findings. They challenge
   test selection and oracle independence, and identify what only execution
   can settle. They consume gate results rather than run mutating checks.
4. Decide each finding: **accept fix**, **reject with reason**, or **defer to a
   filed item**. Resolve duplicate findings without losing attribution.
   Disputed factual claims get a targeted read-only check.

Use the [review receipt format](references/schemas.md#review-receipt).
Apply the decision rules above to rejected designs and unresolved judgment.

While pack N is under review, plan pack N+1 read-only. Resolve pointers,
oracles and scope without code changes or dependent dispatch; one code writer
remains serial and the next pack still needs its approved manifest.

**Exit:** every finding has a decision. Accepted fixes still require repair;
they are not yet recorded as applied, and review acceptance remains pending.

## 4. Repair and validate

**Responsible:** serial fixer, including checks; required reviewers.
**Inputs:** accepted findings and the current candidate.

1. Give a fresh fixer the findings, relevant code, and acceptance condition
   for each. Resume the implementer only for a design-level change.
2. Apply accepted fixes in one pass where practical; split conflicting repairs.
   Create separate repair commits and record which findings they address.
3. Run focused affected targets while repairing. At exact-SHA static PASS,
   post the replacement pointer and start required repair reviews alongside
   the final named run. Every required reviewer covers the new candidate
   according to its configured initial, delta and final review schedule.
4. Widen review when repairs alter contracts, expand scope, or leave uncertainty.
   New findings return to Review and decide, within the configured round caps.

Record **applied** only when a repair exists. Record `review:accepted` only
when required review covers that repair and all findings are resolved or
explicitly deferred. [Record details](references/records.md) define the mapping.

**Exit:** repairs pass their checks and every required reviewer covers the
current candidate. If no code changed, initial approval already supplies coverage.

## 5. Accept, push, and close

**Responsible:** orchestrator for acceptance; authorized integrator for push.
**Inputs:** candidate, complete evidence, current authority.

Use the writer's passing job at the exact candidate as acceptance evidence;
verify its named targets and environment rather than cold-rerunning every job.
The orchestrator cold spot-checks one handoff per pack in the approved isolation.
A SHA-only audit does not replace that run. Any spot-check failure reverts the
pack to cold reruns: classify, fix and revalidate through Repair and validate.
Never accept using older evidence. Any code change requires updated gates,
review coverage and a final named run at the replacement SHA.

**A commit may be pushed only when:**

- Required gates and the final named targets pass at this commit, with the
  writer's job ID recorded; the pack's cold spot-check passes. An approved
  static-only task requires its named gates instead of runtime targets.
- Every required reviewer covers the code through the latest repair.
- Every finding is applied and validated, rejected with a reason, or explicitly
  deferred to a filed item.
- Required authorizations are active.
- Evidence identifies the commit, approved manifest, frozen inputs, and
  execution environment. Missing evidence names exactly what must be redone.

Scan the exact outgoing commit range for secrets, push under authority, and
watch CI for that commit. A code fix after red CI returns through repair,
review, final checks, and readiness before another push. Release according to
the profile only when authorized; never move a release tag.

**Exit:** record the remote integration result, CI status, release result if
requested, remaining human checks, and outcome. Do not mark unreleased work as
released. Measure velocity as GO-to-push lead time and pre- versus post-handoff
defects, not lines per hour. Distinguish the early review pointer from the final
runtime-PASS acceptance handoff. Record actual usage and propose profile changes;
do not silently apply them. Emit one completion line; notification failure
does not block reporting.

## Supporting details

- [Schemas](references/schemas.md): read when creating or validating a config,
  profile, manifest, or structured agent result.
- [Records](references/records.md): read when writing evidence, recording
  outcomes, exporting artifacts, or rebuilding state.
- [Runner](references/runner.md): read before Workflow execution or recovery.

`orchestrator` selects work and owns campaign-level acceptance and ceilings.
`decider` supplies a decision package when an escalation needs one. This guide
defines batch execution without requiring the earlier cycle skills.

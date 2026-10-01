---
name: evidence-cycle
description: Implement an approved Docket batch with serial writers, independent review, scoped tests, and evidence required before push.
---

# Evidence cycle

Use this skill to take approved Docket work through implementation, review,
testing, and an authorized push. Release when the run's authority and settings
include it. This replaces `task-cycle` and `work-cycle` for new batches.

The **manifest** is the approved execution plan. The **candidate** is the commit
being considered for push. Decisions use the owner's authoritative nine-axis
rubric, Docket item `minerva:01a0b15a3cad7827bbc821e1b9d29b21` (read it through
Docket; with only a browser, fetch
https://raw.githubusercontent.com/turnrocklabs/Minerva/development/Docs/minerva.dct
and search for the id — the file is too large for GitHub to render); freeze
its contents with the plan.

## The cycle at a glance

| Phase | Responsible | Result needed to continue |
|---|---|---|
| Prepare | Orchestrator; owner where required | Complete, approved manifest and available execution controls |
| Implement | Serial implementers; command executor | Task commits and passing group tests |
| Review | Independent reviewers; orchestrator | A decision for every finding |
| Repair | Serial fixer; executor; reviewers | Checks pass and required reviewers cover the repaired code |
| Accept | Executor; authorized integrator | Final evidence matches the candidate; push and CI are recorded |

The executor runs commands. Agents implement and exercise judgment. The
orchestrator owns decisions and recovery. Read-only reviewers may run in
parallel; code-changing agents never do.

## Rules that apply throughout

- Generate briefs and commands from the manifest and profile. Keep code
  changes within the approved goals and non-goals.
- Implementers author tests but never execute them or build substitute probe
  or mutation harnesses. Design-question experiments are allowed.
- Initial reviews are independent: every configured reviewer gets the same
  candidate and context, without implementer explanations or prior reviews.
  Keep all configured reviewers during the pilot.
- Give each task one implementation commit. Repairs are separate
  `review:` commits; never fold or rewrite commits named by evidence.
- Record command and review results against their actual commit. Older group
  results are useful feedback, not proof that the final candidate passes.
- At an attempt's tool-call or time allowance, return **incomplete** with
  remaining uncertainties. The orchestrator may dispatch a bounded follow-up
  within the configured round limits. Reaching a round limit ends the batch
  incomplete; it never counts as approval.
- Write a durable start checkpoint before a consequential action and its
  completion afterward. Verify exclusive execution before dispatching work.
  [Runner details](references/runner.md) define these requirements.

## Decisions, approval, and authority

Default to autonomous decisions within already-approved goals. Read the
configured autonomy mode; an explicit owner instruction overrides skill
defaults. Autonomy does not grant permission to review, run tests, push, or
release.

In autonomous mode, measure the relevant facts, compare options using all nine
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
4. Build the manifest: goals, non-goals, oracles, task order, test groups,
   affected contracts, reviewers, budgets, and execution mode. Distinguish
   tasks that must precede others from tasks useful to test together.
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

**Responsible:** one implementer at a time; executor for gates and tests.
**Inputs:** manifest, current task base, generated task brief.

1. Give a fresh implementer the goal, oracle, verified pointers, constraints,
   non-goals, forbidden resources, and budget. Include:
   > If something I state as fact is wrong when you measure it, say so — that is a success, not an embarrassment.
2. The implementer writes code and the smallest useful broad tests. It reports
   out-of-scope discoveries without fixing them, and may refuse an instruction
   with a reason. End its report with **What the first run should settle**.
3. Run the profile's static gates in the prescribed scratch environment.
   Check intended paths and generated files; commit the task and record its
   commit. A gate failure returns to a bounded repair attempt.
4. When every task in a group has a completed implementation attempt and a
   verified commit reachable from the batch head, execute its named tests with
   the profile's isolation.
5. A failing group blocks further implementation. An assertion goes to a fixer
   with the exact failure. Other failures are classified before deciding
   whether to retry the command or change code. Recheck gates after any repair.

Command failure handling and retry limits are in
[runner details](references/runner.md). File discoveries as separate items.

**Exit:** all tasks are committed and their group tests pass. Results identify
the actual tested commits; an incomplete or refused attempt remains visible.

## 3. Review and decide

**Responsible:** all configured reviewers; orchestrator for finding decisions.
**Inputs:** frozen review candidate, diff, test results, profile contracts.

1. Freeze the current head. Run the test union now, or state which earlier
   commits were tested and what remains unverified at this head.
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

**Exit:** every finding has a decision. Accepted fixes still require repair;
they are not yet recorded as applied, and review acceptance remains pending.

## 4. Repair and validate

**Responsible:** serial fixer; executor; required reviewers.
**Inputs:** accepted findings and the current candidate.

1. Give a fresh fixer the findings, relevant code, and acceptance condition
   for each. Resume the implementer only for a design-level change.
2. Apply accepted fixes in one pass where practical; split conflicting repairs.
   Create separate repair commits and record which findings they address.
3. Rerun relevant gates and affected test groups. Every required reviewer checks
   the changes from its last reviewed commit to the new candidate.
4. Widen review when repairs alter contracts, expand scope, or leave uncertainty.
   New findings return to Review and decide, within the configured round caps.

Record **applied** only when a repair exists. Record `review:accepted` only
when required review covers that repair and all findings are resolved or
explicitly deferred. [Record details](references/records.md) define the mapping.

**Exit:** repairs pass their checks and every required reviewer covers the
current candidate. If no code changed, initial approval already supplies coverage.

## 5. Accept, push, and close

**Responsible:** executor; authorized integrator; orchestrator for close-out.
**Inputs:** candidate, complete evidence, current authority.

Run every required gate and the final test union on the exact candidate.
A failure returns to Repair and validate; any subsequent code change requires
updated gates, review coverage, and final tests.

**A commit may be pushed only when:**

- Required gates and the final scoped tests pass at this commit.
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
released. Record metrics and propose profile changes; do not silently apply
them. Emit one completion line; notification failure does not block reporting.

## Supporting details

- [Schemas](references/schemas.md): read when creating or validating a config,
  profile, manifest, or structured agent result.
- [Records](references/records.md): read when writing evidence, recording
  outcomes, exporting artifacts, or rebuilding state.
- [Runner](references/runner.md): read before Workflow execution or recovery.

`orchestrator` selects work and owns campaign-level acceptance and ceilings.
`decider` supplies a decision package when an escalation needs one. This guide
defines batch execution without requiring the earlier cycle skills.

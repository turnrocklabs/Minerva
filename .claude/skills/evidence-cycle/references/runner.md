# Runner execution and recovery

Read before using Workflow mode or resuming interrupted work. These are
requirements for an adapter, not claims that a particular tool implements them.

## Pilot and later runners

The first pilot uses Claude Code's Workflow tool where its available
capabilities support this guide. Confirm the real tool interface, command
execution, structured results, records access, and recovery before dispatch.
If commands need a fixed-command agent, use the configured gate role.

The next candidate is a small standalone CLI that reads the exported manifest,
executes gates/tests, records evidence through Docket, and checks readiness.
State whether agent dispatch and finding decisions still belong to the
orchestrating harness. A CLI command executor is not automatically the whole
autonomous orchestrator.

Bundling the worker and run controls with Docket is a later, measured step.
Do not expand the pilot into that product build.

## Choosing execution mode

Suggest Workflow mode for a standard single-repository batch with serial
writers, explicit groups, and known review requirements. Record the reason and
reuse the owner's explicit authorization for the objective or batch.

Use orchestrator-stepped mode when a group outcome may change later goals.
The manifest and evidence requirements are identical in either mode.
Capability gaps are reported explicitly; never simulate a green command or
computed readiness with a model's assertion.

## Execution phases

Expose the main guide's five phases: Prepare, Implement, Review, Repair, Accept.
Keep mechanical commands inside their phase so they do not each require an
orchestrator turn.

Workflow may use two runs separated by a decision checkpoint:

1. Writer implements and runs focused targets, commits and gates the exact SHA,
   posts the static-PASS pointer, then runs the full named set while independent
   reviews proceed. Return separate review-pointer and final PASS receipts.
2. From finding decisions: serial repair and focused checks, replacement
   static-PASS pointer, required review alongside the final named run, pack
   cold spot-check and readiness. Return evidence for authorized push.

The checkpoint belongs to the orchestrator; the configured autonomy mode
determines whether the owner is needed. It is not necessarily a human pause.
New findings loop through the same decision and repair rules.

Post the SHA and gate job immediately at static PASS, with runtime in progress
until its final job finishes. A replacement SHA explicitly supersedes earlier
pointers and receipts. Preserve those receipts as feedback; never treat them
as proof for the replacement. Read-only planning for pack N+1 may proceed
while N is under review, without dispatching a second code writer.

The writer runs gates and tests by default. A fixed-command role handles an
explicit runner capability gap only within recorded authority and isolation.
Ask questions, then wait for answers before dependent commits. Neither a
timeout nor an unanswered notification supplies approval or missing facts.

Every agent returns a defined result shape. Parse that structure, not free-text
reports. All required reviewers use independent read-only execution; writers
remain serial. Respect both total dispatch allowance and runtime concurrency
limits. Do not run another agent merely to summarize a structured result.

## Commands, failures, and limits

Generate command invocations from the approved profile. Use its isolation,
timeouts, forbidden resources, and environment identity. Gate audit checks
structure; goal fit and semantic scope remain review judgments.

Record failures as:

| Class | Next action |
|---|---|
| `assertion` | Give a fixer the exact assertion and relevant context |
| `timeout` | Check whether the command remained alive and diagnose before retry |
| `missing_dependency` | Identify the missing capability; do not change product code blindly |
| `invocation` | Correct a known invocation problem within approved procedure |
| `unknown` | Preserve output and obtain diagnosis |

A known operational failure may receive one mechanical retry after its cause
is understood and no prior process remains active. Otherwise stop or diagnose.
An unknown error is not automatically an assertion failure. Repairs return
through gates, affected tests, review, and final checks.

Count group repairs, repair-review rounds, and final-test repairs against their
separate config limits; all agent dispatches count toward `max_agents`.
Attempt allowances yield incomplete results. Batch round/dispatch limits stop
the batch incomplete and record remaining work. Autonomous mode does not
remove those limits.

Acceptance uses the writer's exact-SHA PASS job and named targets. The
orchestrator cold-runs one handoff per pack; if it fails, revert that pack to
cold reruns, classify the failure, fix and revalidate. Older evidence cannot
support acceptance. The spot-check is an execution check, not just a SHA audit.
An approved static-only task records its exception and executes no runtime
classes; the spot-check covers its required gates.

## Records access

An adapter capable of calling Docket writes start/completion checkpoints
directly. Otherwise an identified orchestrator or fixed-command agent writes
them before and after each consequential action. Specify that responsibility
before dispatch. Never assume the Workflow script has or lacks MCP access
without checking the actual tool.

Store command outputs as artifacts with structured evidence. Session caches
may accelerate pickup but cannot replace durable records.

The handoff dossier contains SHA, job IDs, a short report and actual usage;
omit source tars and source hash indexes. Approved input contents and hashes
remain required for reproducibility. Count handed-off preserved commits against
the cap; amend only the writer's own unhanded commit. Never rewrite delivered,
reviewed or integrated commits, and mark replaced feedback receipts superseded.
Measure GO-to-push lead time and defects before and after final handoff; the
early review pointer remains a separate event. Secret-handling fixtures report
only exception class, line number and fixed stage label, never secret payloads
or representations. No broad logging framework is needed.

## Exclusive execution

Acquire exclusive ownership for the run and repository before any writer or
consequential command. The adapter must identify a verified atomic mechanism,
held for the execution lifetime, with explicit release and stale-owner recovery.
It must refuse a competing executor. Record its owner in Docket.

An `executor:<run-id>` tag is an informational mirror. A check followed by a
tag write, a declared holder, or a task claim does not prove execution
exclusivity over processes and Git operations.

If the adapter cannot provide exclusive acquisition, report the missing
capability and stop automatic execution. This document does not implement a
lock. Reconcile evidence before replacing a stale owner; never clear it solely
because a session is absent.

## Recovery checks

Exercise these boundaries during the pilot:

- Commit succeeds but completion recording fails.
- Review completes but its returned result is lost.
- Push succeeds but acknowledgment is lost.
- UI closes, server disconnects, or a child command dies.

For each case, identify the real repo/remote/process state before retrying.
Stop starting consequential actions while evidence cannot be recorded.
Do not spawn a duplicate child or push blindly from an absent completion.
Recompute missing evidence using [record rules](records.md#rebuilding-state).

For readiness, mechanically check results at the candidate SHA, each required
reviewer's coverage, finding completion, current authority, frozen inputs, and
environment identity. Produce a list of missing or failed checks. Readiness is
never a verdict requested from an LLM.

# Work Cycle

Reproducible process for shipping multi-round work in Minerva with sub-agents,
review agents, and minimal human-in-the-loop time.

## Purpose

Phase 1B (10 rounds, 330+ platform tests, hello-world MVP) was driven by an
ad-hoc version of this loop. Codifying it removes "what's the next round?"
friction, declares stop conditions up front, and standardizes who reviews what
on which model.

The slash command form is `/work-cycle` (see `.claude/skills/work-cycle/`). This
doc is the canonical reference; the skill is the executor.

## Glossary

| Term | Meaning |
|---|---|
| **Round** | One full pass of the loop (steps 0-5) producing one WIP commit. |
| **Unit** | A piece of work small enough for one sub-agent. Multiple units run in parallel within a round when independent. |
| **Implementer** | A sub-agent that writes code. |
| **Reviewer** | A separate sub-agent (fresh context, no implementation prompt) that audits the implementer's output. |
| **Orchestrator** | The Claude instance running this conversation — Opus 4.7 by default. Decomposes scope, reconciles must-fix, runs the loop. |
| **Stop condition** | A declared point at which the orchestrator must hand off to the human. |
| **WIP** | Work-in-progress commit at the end of each round. Smart-batched (one per round, not one per unit). |

## The Loop

```
0. SCOPE
   ├─ Read tasks from docket (or freeform user ask)
   ├─ Decompose into independent units
   ├─ Identify dependencies between units
   ├─ Pick model per unit (see Model Selection)
   ├─ Declare stop condition for this round (see Stop Conditions)
   ├─ Transition each task: backlog → open → in_progress
   └─ Announce plan to user: "N units, models X/Y/Z, will pause when Q"

1. WORK (parallel where possible)
   For each unit:
     ├─ Spawn Implementer sub-agent
     ├─ Spawn Reviewer sub-agent (Opus, fresh context)
     ├─ Reconcile must-fix locally if I can
     └─ Escalate to user ONLY if must-fix is judgment-dependent

2. VERIFY-LAYER-1 (automated, no human)
   ├─ Run targeted test suite headless (Godot --headless --script test/...)
   ├─ Parse-check / type-check
   ├─ Red → fix → re-verify (capped at N=3 iterations on same problem)
   └─ Green → step 3

3. WIP COMMIT
   ├─ Smart-batch: one commit per round, not one per unit
   ├─ Co-Authored-By: Claude Opus 4.7 (1M context)
   └─ Commit message lists what each unit shipped + test counts

4. DOCKET TRANSITION (conditional)
   If stop condition is "auto-verified" (3c only):
     ├─ Transition each task: in_progress → done
     └─ Resolution note cites commit SHA + test counts
   Else:
     └─ Leave in_progress; advance to step 5

5. STOP CONDITION FIRES
   ├─ Present to user: WIP SHA, what to test, expected behavior
   ├─ User confirms → in_progress → done with resolution note
   ├─ User reports failure → stay in_progress, fold into next round's scope
   └─ For automated stop conditions, no user pause needed; loop directly to 0
```

## Stop Conditions

The orchestrator MUST stop and hand off to the human when any of these fire:

| ID | Condition | Why |
|---|---|---|
| **3a** | Round produces UI change | Visual confirmation needed; auto-tests can't verify pixels. |
| **3b** | Round produces plugin / runtime behavior | Live Minerva session needed; can't simulate headless. |
| **3c** | All planned units of this scope complete (phase boundary) | Clean checkpoint to declare a phase done. |
| **3d** | Hit iteration cap on the same problem | Runaway protection. Default cap = 3 within the same round. |
| **3e** | Must-fix from reviewer requires user judgment | E.g. trade-off between two valid designs. |

Stop condition is **declared in step 0 and announced to the user**. Surprise
stops mid-round (other than 3d/3e, which are unavoidable) are a bug in step 0
decomposition.

For purely backend / infra / test-only rounds, stop condition is **3c only** —
the round runs end-to-end without human input.

## Model Selection

| Role | Default | Rationale |
|---|---|---|
| Plan / Decompose (step 0) | **Opus** | High-stakes; bad decomposition wastes the whole cycle. |
| Reviewer (every implementation) | **Opus, fresh context** | Reviewer needs to catch what the implementer rationalized. |
| Implementer — design-critical / first-of-kind | **Opus** | New patterns, cross-cutting refactors, security-sensitive code. |
| Implementer — routine (follows existing pattern) | **Sonnet** | Adding a tool to a registered group, writing tests, migrating to a sibling's shape. |
| Implementer — mechanical | **Haiku** | File moves, doc-comment edits, find-replace refactors with no judgment. |
| Long-context refactor (>200k tokens) | **Opus 1M** | Only Opus has the 1M variant. |

### Heuristics

- **Sibling pattern in the codebase to follow?** Yes → Sonnet. No → Opus.
- **Success depends on a judgment call?** Yes → Opus.
- **Mostly typing?** Haiku.
- **Hard to verify automatically?** Opus — review is a weaker safety net here.
- **First round of a new pattern?** Opus. Subsequent rounds copying the pattern → Sonnet.

### Escalation rules

- Sonnet implementation fails review with must-fix **twice** on the same unit → retry on Opus.
- Reviewer keeps catching the same class of bug across rounds (e.g. async-await issues) → upgrade implementer model for next round.
- Plan changes mid-round (unexpected dependency surfaces) → kick decision back to orchestrator before spawning more agents.

### Always-Opus

- The **orchestrator** (this conversation).
- All **reviewers**.
- The **planner** in step 0.

## Docket Transition Rules

| Phase | State change |
|---|---|
| Step 0 SCOPE | each task: `backlog → open → in_progress` |
| Step 4, stop = 3c (auto-verified) | each task: `in_progress → done` with resolution note citing commit SHA + test counts |
| Step 5, user confirms | each task: `in_progress → done` with resolution note citing what was tested + commit SHA |
| Step 5, user reports failure | task stays `in_progress`; orchestrator folds feedback into next round's scope |

`done` is terminal in the work_item state machine. If a task marked `done` later
shows a real-world bug, file a new bug item rather than reopening — the original
implementation is shipped.

## WIP Commit Conventions

- One commit per round.
- Commit subject: short capitalized phrase, prefix `WIP: ` when unfinished phase.
- Body lists each unit's deliverable and test counts.
- Include `Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>`.
- Pass commit message via HEREDOC to preserve formatting.

Example:

```
WIP: Plugin authoring contract + full state round-trip (Phase 1B R9+R10)

Round 9 — platform: capabilities opt-in + install-time validation
  - PluginDefinition: capabilities field, allowed-value parser, ...
  - PluginDB.install: runs validate_capabilities ...

Round 10 — hello plugin migration: full state round-trip
  - manifest.json: declares capabilities ...

Test status: 330/330 platform + 24/24 capability assertions pass.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
```

## Configuration / Overrides

Per-cycle (passed to `/work-cycle`):

| Flag | Effect |
|---|---|
| `--opus-only` | Force every implementer to Opus |
| `--sonnet-only` | Force every implementer to Sonnet (review still Opus) |
| `--no-stop` | Suppress 3a/3b stop conditions (use only when explicitly running unattended) |
| `--cap=N` | Override Layer-1 iteration cap |
| `--review=off` | Skip reviewer agents (only for trivial mechanical work) |

Per-unit, in the scope description:

- Append `@opus`, `@sonnet`, or `@haiku` next to a unit title to force that unit's model.
- Append `@no-review` to skip review for that unit (e.g. doc-only changes).

Default override block (top of this doc):

```yaml
# work-cycle defaults
implementer_default: sonnet
reviewer: opus
planner: opus
layer1_iteration_cap: 3
```

Edit this block to change the project-wide defaults.

## Examples

### Example 1: Pure-backend round (auto-verified, no stop)

User: "Run /work-cycle on the per-kind AnnotationAuthorTool tasks"

Orchestrator step 0:
- Reads task `019dc604535c7352ad726a2f31ecf83f`.
- Decomposes into 8 units (one per built-in 2D kind).
- Picks Sonnet for each (sibling pattern: arrow author tool establishes shape, others copy).
- Declares stop condition: **3c, auto-verified**.
- Announces: "8 units, all Sonnet, no human pause until done."

Then works steps 1-4 without further input. Each unit's review approves; tests
green; WIP committed; 8 tasks → done. User sees a single completion message.

### Example 2: UI-touching round (manual test required)

User: "Run /work-cycle on the hello plugin annotation smoke test"

Orchestrator step 0:
- Decomposes into 3 units: panel surface (canvas + toolbar), AnnotationHost subclass, save/load wiring.
- Picks Opus for unit 1 (new pattern), Sonnet for units 2-3 (copying from unit 1).
- Declares stop condition: **3b, live Minerva run** (visual + plugin behavior).
- Announces: "3 units, Opus + Sonnet × 2, will pause for you to manually test the live panel."

Steps 1-3 run; WIP committed at step 4; orchestrator pauses at step 5 with a
test checklist. User runs the test; reports back; orchestrator either marks
done or folds feedback into the next round.

## Anti-patterns to avoid

- **Marking docket `done` at WIP-time when there's a manual-test gate.** The
  state machine is terminal; once done, you can't re-open. Wait for the verdict.
- **Big-bang sub-agent spawning without a plan.** Always step 0 first. The
  orchestrator is Opus for a reason — use that judgment up front.
- **Sharing context with reviewer.** Independence is the entire point of review.
- **Letting Sonnet keep retrying past the cap.** If two must-fix rounds on the
  same unit, escalate to Opus. Don't fight the model.
- **Forgetting to announce the stop condition.** The user shouldn't be guessing
  whether to stay at the keyboard.

## Living document

When the loop reveals a friction point we haven't captured here, edit this file
and the skill in the same round. Rules of thumb:

- New stop condition discovered → add to the table.
- New escalation pattern → add to Model Selection.
- New override needed → add a flag to Configuration.

The skill at `.claude/skills/work-cycle/SKILL.md` references this doc for the
why; itself contains the operational steps.

## Changelog

### 2026-07-15 — campaign mode, functional floor, freshness gate

Four additions landed in SKILL.md (operational steps live there; this is the why):

- **Preflight freshness check**: `git fetch` + behind-count before every round;
  ff-only pull when clean, STOP on divergence. Motivated by the multi-machine
  workflow — a round started behind upstream reviews against a stale base and
  produces conflicting pushes (2026-07-15 session opened on repos 29k lines behind).
- **Campaign mode (goal loop)**: outer loop over a DCR subtree — re-read live
  docket each iteration, run rounds until goal predicate / cap / dry-loop / hard
  stop. Docket is the loop state (checkpoint comment per iteration), so campaigns
  survive compaction and session restarts. `--defer-hitl=<register.md>` converts
  3a/3b stops into register entries (each must name its automated proxy) for ONE
  consolidated acceptance session. Adoption rule: filed discoveries join the
  candidate set only when explicitly linked as blockers. Formalizes the PCB
  migration autonomy plan (DCR 019dc140, 17 iterations → single HITL).
- **Functional floor in Layer-1**: every round touching a runtime surface ends
  with ≥1 non-mocked functional test green — boot the real stack headless, drive
  one happy path at the integration boundary. Fake only at the outermost process
  boundary (fake provider, fake tool executable) when the real dependency is
  inherently unavailable. Motivated by Phase 1B: 330/0 unit tests, 6 wiring bugs.
- **New anti-patterns**: campaign auto-adoption (scope creep at loop scale);
  green-unit-wall-no-functional-proof.

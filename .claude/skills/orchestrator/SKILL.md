---
name: orchestrator
description: Manage a body of work — decide what gets worked on next, what success looks like, and what the durable record says. Owns the tracker as a decision record, the knowledge stores (durable docket hints vs volatile nudge), acceptance-criteria authoring, decisions and escalation, campaign sequencing, and close-out. Pairs with work-cycle, which runs one round.
---

## Scope

This skill covers **what** gets built and **what "done" means**. It does not run the round — work-cycle does.

Concretely, it covers five things:

1. **Selection** — which work happens next, and what is deferred.
2. **Acceptance** — what success looks like, written so it cannot be faked.
3. **The record** — what the tracker says, so a future session can act without this conversation.
4. **Knowledge** — what gets remembered, where, and when it is read back.
5. **Escalation** — which calls are yours and which belong to the owner.

## Terms

| Term | Means |
|---|---|
| **Docket** | The tracker (`docket_*` tools). Items, comments, states, links. The durable record of decisions. |
| **Round** | One unit of dispatched work — one pass through work-cycle. |
| **Campaign** | An optional mode: driving a Docket subtree to a goal across many rounds. **Not a prerequisite.** Orchestration applies to a single round just as much; a campaign only adds the outer loop and its termination rules. |
| **Register** | An ordered list of deferred human checks, burned down in one session. |

## Placement rule

**work-cycle answers "how do I run this round." orchestrator answers "what is the goal of the round, and what does success look like, approximately."**

Anything that fits neither description belongs here — selection, acceptance and the record are this skill's, and the residue lands with them.

**One rule lives in exactly one skill.** If a rule seems to belong in both, put it in one and have the other point at it. Duplicated instructions drift apart as each is edited, and a reader following the stale copy has no way to tell which is current.

## When to use

- Choosing what to work on next, or deciding to defer something.
- Writing acceptance criteria.
- Any write to the tracker: filing, commenting, transitioning, closing out.
- Making a decision that constrains later work.
- Deciding whether to escalate instead of deciding.
- Starting or resuming a campaign.

Not for the mechanics of running a round — spawning, fencing, reviewing, mutating, committing. That is work-cycle.

## 1. Knowledge stores

| Store | Lifetime | Holds |
|---|---|---|
| **docket hints** (`docket_hint_set/get/query`) | **Durable** — file-backed, git-tracked | Anything a future session needs: resume anchors, process rules, area gotchas, measurement traps |
| **nudge** (`nudge_set_hint/get_hint`) | **Until reboot** | In-flight state only: a path true for this session, a number true mid-round |

**Before writing, ask: would losing this at reboot cost anything?** If yes, it is a docket hint. Resume anchors and process rules are always durable.

**If the tracker is unavailable**, durable state goes to a file in the repo (`Docs/pickup.md` or equivalent) and is committed. A store that is down is not a reason to hold state in conversation memory, which does not survive compaction.

### Reading

| When | Query |
|---|---|
| Campaign or session pickup | `docket_hint_get(component=<campaign>, key="state")` |
| Round pre-flight, before the brief is written | `docket_hint_query(project=…, component=<area>)` |
| Before briefing any sub-agent | pass the relevant hints into the brief |
| On any surprise | query before diagnosing |

Pre-flight is the highest-value moment: a hint records something that has already gone wrong in that area, and pre-flight is while it is still cheap to act on.

**Scope every query by component.** Unscoped and tag-only queries time out.

**A retrieved hint is a claim, not a fact.** Hints go stale like any written record — verify before relying on one, the same way work-cycle re-validates a work item's premises.

### Writing

Write a hint when a fact cost real time to establish and would cost it again.

- Record **how it was measured**, not only what was found. A number without its oracle gets inherited as ground truth.
- State the **blast radius** — "true of this worker" and "true of any Python mutation testing" get read differently.
- Do not write what the code already says. A hint earns its place by being something the code cannot tell you.

## 2. The tracker

### Do

- **File the moment something is found**, out of fence or out of scope. Filing is cheap; rediscovery is not.
- **Open the file before writing a claim about it.** Applies to every symbol name, path, number and behaviour.
- **Treat sub-agent reports as evidence, not record.** Verify before a claim from one enters the tracker.
- **Stamp how any number was measured**, in the same sentence as the number.
- **Cite symbol names**, not `file:line` — line numbers go stale within a round.
- **Point instead of restating.** A reference to a commit or hint cannot drift; a copied number can.
- **Link blockers explicitly** (`blocks`), because selection reads links, not prose.

### Don't

- Don't narrate process in an item. What a reviewer found, and in which pass, changes nobody's next action.
- Don't restate what the commit message already says. Two records of one change diverge.
- Don't put lessons in items — they belong in hints.
- Don't paraphrase an owner's decision. Record the words.
- Don't mark an item done while a human check is still the gate.

### The test

**Would a future reader take a different action because this sentence exists?** If not, cut it.

### Template — bug or work item

```
WHAT IS WRONG (one sentence, no history)
WHERE          symbol names + module; how it was measured
CONSEQUENCE    what breaks, for whom, and whether it is silent or loud
ACCEPTANCE     the observable that proves it fixed; the criterion a lazy fix fails
TRAPS          what will mislead whoever picks this up
LINKS          blocks / blocked-by
```

### Template — completion comment

```
SHIPPED        what, at which SHA
GATES          suite / sweep / CI, with numbers
UNBLOCKS       what can now proceed
DECISIONS      what was decided, what it constrains, who may veto
FILED          items filed and not fixed
NEEDS OWNER    anything awaiting a human
```

Target ~150 words. The technical account belongs in the commit message; the lessons belong in hints.

### Routing

| Content | Home |
|---|---|
| Constraints for an agent | the brief (work-cycle) |
| A decision and what it constrains | tracker comment |
| A lesson or trap | docket hint |
| Technical narrative of a change | commit message |
| Detail someone must act on | tracker item body |

## 3. Close-out

Every gate in work-cycle fires **before** the commit. Everything written after it — comments, filed items, hints, the anchor — is ungated, so it is where unverified claims survive.

At close-out:

- Open the file behind each factual claim before writing it. This is the whole gate, and it is cheap because the register is short.
- Prefer pointing over restating.
- Stamp the oracle on any number.

## 4. Decisions

Decide deliberately, and record the decision where its constraint will be read.

**Score options on the 7-axis rubric** — reliability, durability, performance, debuggability, cost, discoverable, user-visible. Record the winning total and the **decisive axis**, which is usually one axis rather than the sum.

**Score against measurement, not plausibility.** Before scoring an axis, ask what you would have to open to know — then open it. An axis scored on reasoning about how code probably behaves is the most likely source of a wrong decision, because the score looks identical either way.

**Loud failure beats silent failure.** When options tie, prefer the one that fails visibly.

**Say who may veto.** A decision you made is a default; a decision the owner ratified is a ruling. Record which.

**Escalate instead of deciding when:**
- the choice changes what the product *is*, not how it is built;
- options differ in user-visible behaviour and no measurement separates them;
- proceeding under either assumption would be unsafe.

Otherwise decide, state the assumption, and continue.

## 5. Acceptance criteria

You author acceptance; work-cycle enforces it. A criterion satisfiable without doing the work is worse than none, because it reads as coverage.

**Write the lazy implementation first.** Describe the smallest change that satisfies the draft criteria while leaving the feature broken. Then add the criterion that defeats it. Do this before the criteria are final — it is the cheapest place to catch a hollow gate.

**Prefer an outcome that changes over a structure that exists.** "The data is present" passes for the lazy version; "the result differs because of it" does not.

**Name the discriminating fixture.** A single-element fixture catches a dropped value but not a misassigned one. Identical duplicates catch a dropped value but not a mispaired one.

## 6. Campaigns

Optional mode: drive a tracker subtree to a goal across rounds.

### Loop

1. **Re-read the live subtree.** The tracker is the loop state; conversation memory does not survive compaction.
2. **Build the candidate set** — leaf items open, unblocked, not human-gated.
3. **Select** the highest-priority independent candidates that fit one round.
4. Hand off to work-cycle.
5. **Checkpoint** on the goal item in the completion-comment format.

### Adoption

**A newly filed item joins the candidate set only if it explicitly blocks a subtree item.** Link it. Everything else waits for a human. A loop that adopts what it finds is scope creep at campaign scale.

### Splitting

Split a round when shipping it would leave the feature's *use* costing the user something the round does not also fix. Sequence the fix first, so the tree never passes through a state where adopting the feature is a downgrade.

### Termination — first to fire wins

| Condition | Result |
|---|---|
| Every subtree item done, deferred, or human-blocked | SUCCESS — exit report + register |
| Judgment-dependent must_fix, or retry cap | HALT — a human is the point |
| Pre-flight failure | HALT |
| Two consecutive no-progress iterations | HALT — report why candidates are stuck |
| Max rounds reached | HALT — checkpoint + remaining work |

### Deferral

Human-gated stops may append to a register instead of halting. **An entry must name the automated proxy standing in for the human check** — no proxy, no deferral; build the probe first. The exit report presents the register as one acceptance session.

## Anti-patterns

1. **Durable knowledge in the volatile store.** Ask what a reboot would cost.
2. **Writing hints nothing ever reads.** A store only pays off if the read points are honoured.
3. **Filing a claim you have not verified against the file** — especially one from a sub-agent report.
4. **A completion comment that narrates instead of deciding.**
5. **Restating in the tracker what the commit already says.**
6. **Scoring a rubric axis on plausibility** instead of opening what would settle it.
7. **Paraphrasing an owner's decision.**
8. **Auto-adopting filed discoveries into a campaign.**
9. **Acceptance criteria a lazy implementation satisfies.**
10. **Treating close-out as done.** It is ungated, and unverified claims survive there.
11. **A number without its oracle.** It is inherited as ground truth by whoever reads it next.

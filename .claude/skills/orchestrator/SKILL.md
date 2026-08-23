---
name: orchestrator
description: Manage a body of work — decide what gets worked on next, what success looks like, and what the durable record says. Owns the tracker as a decision record, the knowledge stores (durable docket hints vs volatile nudge), acceptance-criteria authoring, decisions and escalation, campaign sequencing, and close-out. Pairs with work-cycle, which runs one round.
---

## Scope

This skill covers **what** gets built and **what "done" means**. It does not run the round — work-cycle does.

Concretely, it covers six things:

1. **Selection** — which work happens next, and what is deferred.
2. **Acceptance** — what success looks like, written so it cannot be faked.
3. **The record** — what the tracker says, so a future session can act without this conversation.
4. **Knowledge** — what gets remembered, where, and when it is read back.
5. **Escalation** — which calls are yours and which belong to the owner.
6. **Batching** — how rounds group into epochs, and what verification each boundary carries.

## Terms

| Term | Means |
|---|---|
| **Docket** | The tracker (`docket_*` tools). Items, comments, states, links. The durable record of decisions. |
| **Unit** | One implementer's work — one brief, one fence. |
| **Round** | One pass through work-cycle: one or more independent units, ending in a commit. |
| **Epoch** | A batch of rounds sharing one verification boundary. **At most six per codebase.** |
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
| **nudge** (`nudge_set_hint/get_hint/query`) | **Until reboot** | In-flight state: agent reports, per-unit findings, running counts — everything an epoch accumulates before its boundary writes the durable record |

**Before writing, ask: would losing this at reboot cost anything?** If yes, it is a docket hint. Resume anchors and process rules are always durable.

**If the tracker is unavailable**, durable state goes to a file in the repo (`Docs/pickup.md` or equivalent) and is committed. A store that is down is not a reason to hold state in conversation memory, which does not survive compaction.

**Do not invent a third store.** Scratch files for single-use intermediate results are the store you already have, minus the query interface, plus cleanup you will forget. Use nudge.

### Nudge as the agent channel

An agent's full output goes to nudge; only a short summary comes back to you.

- Key it `<epoch-or-round>/<unit>.<station>` so a component-scoped query returns the whole epoch at its boundary.
- **A downstream agent reads the upstream entry ITSELF.** Name the key in its brief instead of pasting a digest. A digest you write by hand costs tokens and is a paraphrase, and paraphrases drift from what was actually established.
- At the boundary, `nudge_query(component=<epoch>)` collects everything for the close-out. Once the durable record is written the entries are disposable — that is the lifetime nudge exists for.
- **Name the read point or do not write.** A store nothing reads is worse than a file: invisible rather than merely untidy.

### Your own context holds DECISIONS, not evidence

The same rule that stops you asserting unverified facts also stops your context filling: anything you read only in order to summarise should have been read by an agent. Read what you will **adjudicate**.

- Query `detail: "lean"` by default; fetch a full body only for the item you are about to act on.
- `docket_context(tags=[…])` returns a curated area briefing — insights, open bugs, recent RCAs, questions — in one call. Prefer it over assembling the same picture from several full queries.
- `docket_saved_query` cans the lean forms so the cheap query is the default rather than something you have to remember.
- Write each unit's **findings and decisions** to the tracker as that unit closes, not accumulated for the boundary. Nudge is volatile, so anything that would have to be re-derived after a reboot belongs in docket the moment it is known. What legitimately stays in nudge is the raw report — recoverable by re-running an agent, expensive but not lost. Say "a reboot costs a re-run, not a decision", never "costs nothing".

### Reading

| When | Query |
|---|---|
| Campaign or session pickup | `docket_hint_get(component=<campaign>, key="state")` |
| Orienting in an unfamiliar area | `docket_context(tags=[…])` — one call, not several |
| Round pre-flight, before the brief is written | `docket_hint_query(project=…, component=<area>, detail="lean")` |
| What is waiting on the owner | `docket_query(type="question", status != "answered")` |
| What human checks are pending | `docket_query(type="test", status="ready")` |
| Before briefing any sub-agent | name the hint or nudge key in the brief; let the agent read it |
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
| An agent's full report, mid-epoch | nudge, keyed for the next agent to read |

### Item type

The tracker has more types than `bug` and `work_item`, and each carries fields the generic types do not. Filing into the wrong type means writing structured content as prose and losing the state chain.

| What you are recording | Type | Why not a bug or a comment |
|---|---|---|
| A defect | `bug` | — |
| A unit of work | `work_item` / `chore` | — |
| A causal investigation | **`rca`** | Has `why_chain`, `contributing_factors`, `corrected`, `surprise`, and a detected → root_caused → verified chain. A causal chain written as a comment loses all of it. |
| A deferred human check | **`test`** | Has `test_setup`, `test_steps`, `expected_result` and a draft → ready → passing chain. The acceptance session becomes `docket_query(type=test, status=ready)` instead of a bullet list someone maintains by hand. |
| An open owner decision | **`question`** | asked → answered. Makes the owner's inbox a query rather than prose buried in a close-out. |
| An observation about how the system behaves | **`insight`** | Distinct from a hint: a hint is an actionable fact, an insight is something true about the system that shapes later judgment. |
| Reference material worth keeping | **`kb`** | — |

**`policy` is RESERVED. Do not use it for owner rulings.** In Minerva a policy is a runtime enforcement object with event triggers — "when cobrowser reaches this domain, load that kb article." Filing a ruling as a policy puts a document where an enforcement rule belongs. Owner rulings stay as decisions in tracker comments and in the campaign anchor.

**Link with the relation that is true**: `blocks`, `caused_by`, `follow_up`, `duplicates`, `surfaced`. Selection reads links, not prose.

## 3. Close-out

**The cheap gates fire before a round's commit; the expensive stations fire at the epoch boundary, after several rounds have already pushed.** So a round's commit message — which is immutable — is written before the stations that could contradict it have run.

Two consequences, both load-bearing:

- **Claim no more in a commit body than the round's own gates established.** "No regression in the modules touched" is what a per-round green means; "verified", "proven", "guaranteed" are boundary words. An overclaim in a commit body cannot be corrected, only annotated later in the tracker.
- **A round's items do not go terminal on the round's evidence alone.** Mark them done when the boundary has run. If a boundary finding is NEW work — a coverage gap, a follow-up — file it and the round stays done. If a boundary finding shows the round's own acceptance was never met, REOPEN it; that is not a new item.

Everything written after the last gate — comments, filed items, hints, the anchor — is ungated, and it is where unverified claims survive.

At close-out:

- Open the file behind each factual claim before writing it. This is the whole gate, and it is cheap because the register is short.
- Prefer pointing over restating.
- Stamp the oracle on any number.

## 4. Decisions

Decide deliberately, and record the decision where its constraint will be read.

**When the facts the choice rests on are not established, use the `decider` skill** and bring back a package. This section owns how a decision is RECORDED and when to escalate; `decider` owns how one is PRODUCED when the premises are still open. Do not score options here on facts you have not checked — a rubric formalizes the comparison, not the premises, and the arithmetic will launder an unverified claim into a recommendation.

**Score options on the 7-axis rubric** — reliability, durability, performance, debuggability, cost, discoverable, user-visible. Record the winning total and the **decisive axis**, which is usually one axis rather than the sum.

**Score against measurement, not plausibility.** Before scoring an axis, ask what you would have to open to know — then open it. An axis scored on reasoning about how code probably behaves is the most likely source of a wrong decision, because the score looks identical either way.

**Loud failure beats silent failure.** When options tie, prefer the one that fails visibly.

**"No current caller" is a measurement; "dead" is a prediction.** A caller census tells you what reaches a symbol *today*. It cannot tell you whether a consumer is coming — and in a part-built system the honest default is that one is, because anything whose consumer is sequenced into an unbuilt phase looks exactly like dead code. A deliberate move toward smaller, more numerous tests widens that blind spot further.

So: report the census as **no current production caller**, never as "dead" or "safe to delete". Deletion needs a *positive* argument — superseded by a named replacement, or ruled out by a recorded decision — and the absence of callers is not one. Test-only is not dead: fixture loaders and harnesses are infrastructure, and deleting them costs the suites that depend on them.

Scope such work by **is it worth building now or later**, never by **is it reachable now**. The cost of deleting something a later phase wants is rebuilding it carrying whatever bug you declined to fix.

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

## 6. Epochs

An **epoch** is a batch of rounds sharing one verification boundary. The expensive judged stations run once per epoch instead of once per round; the cheap mechanical gates still run every round.

### The NTE

**A body of work gets at most SIX epochs from inception to completion.** A ceiling, not a target — most work should use fewer.

"Body of work" means the campaign, DCR or goal you are driving — something with a definable done. It is NOT the repository, which for a living codebase never completes and would make the ceiling meaningless. A new campaign starts a new count.

**Err large.** When a split is arguable, take the larger epoch. The pull is always toward smaller ones, because each feels safer in isolation, and the more common waste is paying a full verification pass for a fraction of the work.

### Composition

- **Units inside an epoch should not build on each other.** Where they must, order them explicitly and accept that a defect found at the boundary unwinds everything downstream of it.
- **A change to the measurement rig goes first, or alone.** Anything that moves, renames or regenerates the tests other work is judged by must be verified before the work it will judge.
- **Give each epoch a one-sentence purpose.** If you cannot say what it is for in one sentence, the grouping is arbitrary and the boundary review will be too.
- **Size by the reviewer, not the writer.** The binding constraint is the largest diff a cold reviewer reads without quality falling off. Where an epoch exceeds it, split the boundary review **by dimension** — one pass for correctness, one for prose and test power — rather than splitting the epoch.

### Risk tier

Two tiers. The criterion is **silent and expensive**, not any particular subsystem.

- **Default** — failure is loud, or cheap to repair late. No mutation proof; tests authored at the boundary.
- **Careful** — a defect would be silent *and* expensive to repair once other work sits on top of it. Keep the per-unit mutation proof here.

**Name the careful-tier modules explicitly in the campaign anchor, and keep the list short.** An unwritten tier expands until it means everything.

### Cadence

| Runs | What |
|---|---|
| Every unit | compile / vet / lint, plus the existing targeted tests for the touched modules; mutation proof if the unit is careful-tier |
| Every epoch | author this epoch's tests; full suite; text+test adversary; code adversary; human bless for anything checkable by eye; convergence count |
| Every few epochs, or at a phase boundary | mutation sweep |
| At acceptance | the deferred-human register; cross-provider review |

### Cross-provider review

A same-family reviewer shares blind spots with the implementer; a different provider does not. That review is scarce — budget **one to three per product**. Spend it where **the definition of correctness changes** — what a golden certifies, what a parity assertion means, what a schema promises — and once at final acceptance. Never on an ordinary feature round.

### Convergence, and the debt beside it

Batched verification hides drift, so measure two things at every boundary. They look alike and are not, and conflating them is what made the earlier item-counting metric useless.

**THE GATE — distance to the goal.** How many of the campaign's acceptance checks pass, sampled at each boundary. The level says whether you are done; the slope says whether you are getting there. Nothing else is the convergence metric: counting items closed against items filed is a proxy that any change in task granularity can move without any change in reality.

**If the passing count has not risen across two consecutive boundaries, stop and report** rather than opening the next epoch. Either the work is not reaching the goal, or the checks are measuring the wrong thing — both need a human.

**THE INSTRUMENT — debt.** Items filed and left unfixed, reported at every boundary as a trend. A campaign can approach its goal monotonically while leaving a large residue behind: every check goes green, the goal is genuinely met, and distance-to-goal is silent about what it cost. That silence is what this number is for.

**Debt is REPORTED and NEVER GATED**, and the reason is not squeamishness. Any metric that counts filed items against you reduces *filing*, not debt — and filing is how a discovery survives a compaction, a handoff, or the end of a session. Penalising it is the worst incentive available here. Report the number, let a human read the trend, and never let it halt anything on its own.

Together they give four readings worth telling apart: closing with flat debt is healthy; closing with rising debt is shipping on credit; stalled with flat debt means something external blocks you; stalled with rising debt is where a campaign should have stopped a while ago.

## 7. Campaigns

Optional mode: drive a tracker subtree to a goal across rounds. Campaigns have explicit goal state -- a product to be built, a feature to ship, a problem to solve. Those goals may have sub-goals -- libraries to build, ux stories to implement, pre-conditions to the problem, etc. When defining a campaign, make sure it composes to the goal state.

### The goal, before the first round

Write three things on the goal item before any round starts. Without them a campaign can only measure its own queue, and an empty queue is not a met goal.

1. **The goal** — what is true when this is done, stated as an outcome rather than a list of work.
2. **The non-goals** — what this campaign deliberately does not do. Non-goals are what stop scope arriving disguised as discovery.
3. **The acceptance checks** — the goal and each sub-goal decomposed into things that can be OBSERVED to pass or fail. File each as a `test` item linked to the goal it serves, status `ready`. Automated where possible; a human check is legitimate, and a perceptual one is expected to stay human.

**Write the checks so a lazy campaign fails them.** Same discipline as section 5: describe the smallest set of work that would let you claim the goal while leaving it unmet, then add the check that catches it.

A check may be revised when the goal genuinely changes — record why, on the goal item. Silently loosening one to make a campaign pass is the failure this mechanism exists to prevent.

### Loop

1. **Re-read the live subtree.** The tracker is the loop state; conversation memory does not survive compaction.
2. **Build the candidate set** — leaf items open, unblocked, not human-gated.
3. **Lay the candidates into epochs** before starting any of them, honouring the NTE and the composition rules in section 6. Give each epoch its one-sentence purpose and name its careful-tier units.
4. **Select** the highest-priority independent candidates that fit one round inside the current epoch.
5. Hand off to work-cycle.
6. **Checkpoint** on the goal item in the completion-comment format, and record the convergence counts at every epoch boundary.

### Adoption

**A newly filed item joins the candidate set if and only if it prevents a named acceptance check from passing.** Link it to that check. Everything else waits for a human.

This is mechanical, not a judgement call, and that is the point — "it feels related to the goal" is how a loop adopts what it finds, which is scope creep at campaign scale. If you cannot name the check an item blocks, it does not block.

### Splitting

Split a round when shipping it would leave the feature's *use* costing the user something the round does not also fix. Sequence the fix first, so the tree never passes through a state where adopting the feature is a downgrade.

### Termination — first to fire wins

| Condition | Result |
|---|---|
| **Every acceptance check passes** | SUCCESS — exit report; the owner declares it, not you |
| Every subtree item done but a check still fails | HALT — the work breakdown was deficient, not the goal. Report which check and why nothing addressed it |
| Judgment-dependent must_fix, or retry cap | HALT — a human is the point |
| Pre-flight failure | HALT |
| Two consecutive no-progress iterations | HALT — report why candidates are stuck |
| Passing-check count flat across two consecutive boundaries | HALT — not converging, or the checks measure the wrong thing |
| Sixth epoch closed with work remaining | HALT — the NTE is a ceiling; re-plan rather than opening a seventh |
| Max rounds reached | HALT — checkpoint + remaining work |

**An empty queue is not success.** It is necessary and nowhere near sufficient: a deficient breakdown reaches 100% with the goal unmet, which is exactly the failure the checks exist to catch. Success is a property of the checks; the queue is bookkeeping.

### Deferral

Human-gated stops may defer instead of halting. **File each deferred check as a `test` item** — `test_setup`, `test_steps`, `expected_result`, status `ready` — never as a bullet in a prose register, which someone then has to maintain by hand and which goes stale silently.

**An entry must name the automated proxy standing in for the human check** — no proxy, no deferral; build the probe first. Record the proxy in the item, so a reader can tell what is genuinely covered from what is merely deferred.

**PERCEPTUAL checks are the exception, and they are exempt.** Does this label overlap, is this legible, does this render correctly — for those the human IS the oracle, and the only available proxy is a golden image, which fails re-bless resistance: it goes red, someone blesses it, and the defect rides back in. Defer a perceptual check with `test_setup`, `test_steps` and `expected_result` written for a human, and the proxy field recording "none — perceptual" rather than a probe that would manufacture false comfort.

The acceptance session is then `docket_query(type="test", status="ready")`, and each check transitions as it is run.

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
12. **Erring small on an epoch.** Every argument for splitting sounds prudent in isolation. Splitting buys a full verification pass for a fraction of the work; when the call is close, take the larger epoch.
13. **An unwritten careful tier.** If the list of silent-and-expensive modules lives in someone's head, it silently expands to everything and the batching saves nothing.
14. **Spending the cross-provider review on an ordinary round.** It is budgeted per product, not per epoch. Save it for where the definition of correctness changes, and for acceptance.
15. **Opening the next epoch without the convergence counts.** The counts are the only instrument that can show batching is hiding drift, and they are worthless collected retrospectively.
16. **Reading an agent's full report into your own context.** It goes to nudge; you take the summary. Reading it yourself is how the orchestrator runs out of room before the reviewer does.
17. **Hand-writing a digest into a downstream brief.** Name the nudge key and let the agent read the original. Your paraphrase costs tokens and drifts from what was established.
18. **Filing structured content as prose.** A causal chain in a comment instead of an `rca`, a human check as a bullet instead of a `test`, an owner decision buried in a close-out instead of a `question`. The fields and the state chains exist; prose loses both.
19. **Everything as `bug` or `work_item`.** Those are the defaults, not the whole vocabulary. Ask what type has the fields you are about to write by hand.
20. **Pulling full bodies to decide what to read.** Query lean, then fetch the one you will act on.
21. **Declaring success on an empty queue.** A deficient breakdown reaches 100% with the goal unmet. Success is a property of the acceptance checks; the queue is bookkeeping.
22. **Loosening a check so a campaign can pass.** A check may change when the GOAL changes, recorded and reasoned. Changing it because it is failing is falsifying the only instrument you have.
23. **Gating on debt.** Report it, never halt on it. A metric that counts filed items against you suppresses filing, and filing is how a discovery survives the session that found it.
24. **Starting a campaign without its checks.** They are cheapest to write before the work argues for its own definition of done, and they are what makes "blocks" mechanical rather than a judgement call.
25. **Proposing a deletion from a caller census.** "Nothing calls it" is a fact about today and an assumption about the future. In a part-built product the consumer is usually sequenced, not absent — and test-only means infrastructure, not dead.
26. **Adding too much detail.** The orchestrator is a manager, not a researcher or an implementer. Do not state how the code works or make claims against existing functionality — point at the symbol and let whoever acts on it measure. It is too easy to conflate features and capabilities at this level, creating rework. Focus on the goal state and the success metrics.

    This governs **what you write**: tracker items, goals, acceptance criteria, decisions. The same taxonomy applied to **sub-agent briefs** — constraint, fact, mechanism, and which of the three may appear — lives in `work-cycle` under Conventions → Sub-agent prompts, and in `task-cycle` section 2 for goal-only briefs. One rule, one home: read it there rather than re-deriving it here.
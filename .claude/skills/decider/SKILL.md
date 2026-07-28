---
name: decider
description: Turn a decision request into a decision package when the choice rests on facts that are not yet established. Validates the problem, establishes load-bearing claims from code, generates options including doing nothing, scores them on the rubric, and hands over a package with a named falsifier. Use when someone asks "which approach", "show me options", or "how should we fix X" and answering honestly requires facts you do not have. Produces the package; never makes the call.
---

## When to use

- A choice has to be made and the facts it rests on are not established.
- Someone asks for options, or for a recommendation, on anything that will be **ratified and built on**.
- The orchestrator hits an escalation trigger and owes the owner something better than a question.

## When NOT to use

**Cheap, reversible decisions.** If being wrong costs a re-run, decide and move. This skill is for decisions where the cost is not the mistake but everything constructed on top of it before anyone notices.

Applying it to a small call is not caution, it is ceremony, and ceremony teaches everyone to route around the process.

## The failure it prevents

**A rubric formalizes the comparison, not the premises.** Seven axes and a total look measured. If a score rests on an unchecked claim, the arithmetic launders that claim into a recommendation, and the numbers make the output look better grounded than its inputs.

So: the claims come first, and every score has to trace to one.

## Stages

The middle three are a LOOP, not a sequence. You cannot know which facts matter until you have sketched the options, and you cannot score the options until the facts are in.

### 0 — Validate the problem

A request presupposes a problem. "Which fix for X" assumes X exists, is described correctly, and is still true.

Establish that first, from code, before generating anything. Legitimate outcomes here:

- the problem is real as stated — proceed;
- the problem is real but is not what was stated — restate it and say so;
- **the problem was already solved** — stop, and say what solved it;
- the problem cannot be confirmed — say what would confirm it, and stop.

Stopping at stage 0 is a success. It is the cheapest place this skill can pay for itself.

### 1 — Sketch options, to discover which facts matter

Rough out the candidates without scoring them. The point is not the options yet — it is that each one **exposes the claim it depends on**. An option that needs a cheap inner loop tells you "where does this run?" is a load-bearing question.

Generate the null option here too, not as an afterthought. See below.

### 2 — Establish the load-bearing claims, from code

For each claim an option depends on, record **where it was measured**: a symbol and its file, a command and its output, a SHA.

**Prose is never a source.** A claim taken from a docstring, a code comment, a tracker item, a hint, a commit message, or another agent's report is UNVERIFIED — however authoritative it sounds, and including when you wrote it yourself — until it has been re-derived from code.

**A measurement carries its age.** Cite the SHA or round it was taken at. When the tree has moved past it, it is stale until re-run. A number whose conditions have changed is not evidence, and it is most dangerous when it is precise.

A claim you cannot tag is **marked**, not quietly used.

Delegate this reading. It is exactly the work a sub-agent should do and return as findings.

### 3 — Reshape

Facts kill options and change their costs. Do this deliberately: walk each option against what you just learned and ask whether it still makes sense.

**If nothing changed at this stage, the research was aimed at the wrong claims.** Go back to stage 1 and find what actually separates the candidates.

### 4 — Score

The 7-axis rubric lives in `orchestrator` §4 — reliability, durability, performance, debuggability, cost, discoverable, user-visible. Name the **decisive axis**, which is usually one axis rather than the sum.

**A score that rests on an unverified claim is inadmissible.** Mark the option, present it, and do not recommend it.

### 5 — Package and hand over

**This skill never makes the call.** It produces the package; a human decides. Record the decision where its constraint will be read — that part belongs to `orchestrator`.

## The package

```
PROBLEM      what is wrong, verified — or how the stated problem was wrong
CLAIMS       each load-bearing fact, with where it was measured; unverified ones marked
OPTIONS      the candidates, INCLUDING doing nothing
SCORES       7 axes, with the decisive axis named
RECOMMEND    one option — or "no recommendation", and why
FALSIFIER    what fact, if different, changes the answer
OPEN         what is still unmeasured, and why that is tolerable
```

## Constraints

**Score doing nothing.** Deferring, or leaving a thing broken on purpose, is a real option with real costs, and an analysis that omits it is arguing for action rather than informing a choice. Sometimes "this stays broken this cycle, honestly" is correct.

**Name the falsifier.** Every recommendation states the one fact that would change it. A recommendation with no falsifier is a preference wearing a rubric.

**Recommend at most one option.** Ranking everything is a way of not deciding while appearing to.

**Say what you did not check.** The OPEN line is not a disclaimer, it is scope: it tells the decider how far the analysis reaches.

## Anti-patterns

1. **Scoring before checking.** The arithmetic is the last step, not the first. Numbers produced over unverified premises are worse than no numbers, because they invite ratification.
2. **Citing prose as evidence.** A docstring can be as wrong as a comment, a tracker item, or a report — and a well-written one is the most persuasive wrong thing available.
3. **Inheriting a measurement without its age.** Precision does not confer freshness.
4. **Omitting the null option**, which quietly converts an analysis into an argument for change.
5. **Skipping stage 0** because the problem "obviously" exists. That is the assumption the whole skill exists to test, and the cheapest one to be wrong about.
6. **Researching before sketching.** Without candidates you cannot tell a load-bearing fact from an interesting one, and you will verify the wrong things thoroughly.
7. **Making the call.** Producing a package and then deciding from it is how an escalation becomes a rubber stamp.
8. **Using this for a decision that costs a re-run.** Ceremony on cheap choices trains everyone to route around the process.

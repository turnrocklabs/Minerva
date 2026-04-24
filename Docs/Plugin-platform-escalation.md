# Plugin Platform — Escalation

**Status:** Active  **Date:** 2026-04-24

Stop autonomous work and surface the issue to the user when any of these hold. Otherwise proceed per `Plugin-platform-policy.md`.

## Interrupt conditions

1. **Spec contradicts itself or thought paper.** Do not guess intent.
2. **Scope creep proposal.** Task would touch files outside its owned scope. File a follow-up; don't expand.
3. **Cross-cutting change affecting >2 DCRs.**
4. **Security / legal concern.** Licenses (LGPL/GPL), data exfiltration paths, credential handling, process privilege.
5. **Spec and implementation diverge materially.** Codebase clearly expects something other than the design doc says.
6. **Stuck.** Same failure 3 iterations in a row. No infinite retry loops.
7. **Integration failure spanning >1 task's owned files.**
8. **Policy silent + decision non-reversible.** If `Plugin-platform-policy.md` has no default AND the choice is hard to undo.
9. **New dependency.** Any new library, service, binary requires user approval.
10. **Breaking change to Minerva core** outside plugin/platform directories owned by the current task.
11. **Sub-agent budget exhausted.**

## NOT interrupt conditions

- Implementing a locked-in design within task scope.
- Choosing between internally-equivalent code patterns.
- Routine refactors inside task-owned files.
- Writing tests.
- Adding comments when non-obvious WHY needs capturing.
- Updating documentation within task scope.
- Running builds and tests.
- Writing to the decisions journal (filing comments on docket items).

## Surfacing mechanism

- Sub-agent → coordinating agent: concise summary + options + recommendation. Don't return raw work product alongside.
- Coordinating agent → user: tight summary: what blocked, alternatives, recommendation. Do not dump raw sub-agent output.

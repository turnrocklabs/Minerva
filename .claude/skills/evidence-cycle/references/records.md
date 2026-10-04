# Docket records and evidence

Use these mappings when recording or resuming a run. Docket owns its project
files; mutate them through its tools.

The W1 contract is `docket:01a0dc3549bc7433a6b18e5db948fc8b`
(`work-records/template-v1`). It defines objective, task, and attempt records.
Use its pinned lifecycle and claim rules; do not invent statuses.

## Record map

| Record | Where it lives | What it proves |
|---|---|---|
| Objective | `wr:objective` item | Approved scope, manifest reference, decisions, batch outcome |
| Manifest | `kb` tagged `manifest`, under objective | Frozen execution plan and input identities |
| Task | `wr:task` under objective | Goal, acceptance, required commits, review/test/integration facts |
| Attempt | `wr:attempt` for each actor dispatch | Work started, work ended, and evidence for its actual input/output |
| Review receipt | Reviewer attempt evidence | Code reviewed, findings, verdict, and coverage |
| Decision | Objective or owning finding comment | Chosen action, rationale, and owner ruling or vetoable default |
| Metrics | Objective close-out and `evidence-cycle/metrics` KB | Measured stage costs and process outcomes |

Create recoverable plans and checkpoints with `storage: durable` explicitly:
`wr:attempt` items otherwise default to ephemeral on some builds. Progress
pings and temporary output may be ephemeral; they are not recovery evidence.
Task-specific attempts belong under the task. Batch review/test/integration
attempts belong under the objective and name all covered tasks.

## Start and completion checkpoints

Before a consequential action, record its identity, actor, manifest, input
commit, intended command or operation, and scope. Afterward record actual
output, command result, evidence references, and output commit if known.

A retry is a new attempt linked `follow_up` from the previous attempt. A
completed attempt does not by itself accept a task. Interrupted attempts stay
awaiting reconciliation; do not repeat their side effects from an absent
completion record alone.

Use declared principals consistently. Assignment, claims, comments, and tags
are coordination records, not proof of authenticated identity or a lock over
Git/process side effects.

## Tags and task facts

Use full commit SHAs and the W1 repo-key grammar:

- Attempt input: `base:<repo>@<sha>`.
- Attempt output: `head:<repo>@<sha>`.
- Task commit to integrate: `requires:<repo>@<branch>@<sha>`.
- Verified integrated commit: `integrated:<repo>@<branch>@<sha>`.
- Group membership: `test-group:<name>`, derived from the manifest.
- Review state: `review:requested`, `review:findings-open`, then
  `review:accepted` after required review covers the accepted code.
- Test state: `test:not-run|planned|passed|failed`, with actual SHA and command
  in evidence. A task tag alone never satisfies readiness.
- Release fact: `released:<release-tag>`, only after the release exists.

Replace obsolete tag values while preserving unrelated tags. Respect claims
and use revision checks on writes where supported.

Repairs update the owning task's `requires:` to the commit that includes its
accepted fix. After push, verify the remote contains each exact required commit
and write matching `integrated:` facts. Rebased or squashed substitutes do not
satisfy the original commit requirement without an explicit reconciliation.

## Finding decisions and completion

| Event | Record |
|---|---|
| Decision to fix | Reply `accept fix`, with rationale; finding stays open |
| Decision not to fix | Reply with reason and reject the finding |
| Decision to defer | File a scoped item with priority, link it, record the accepted deferral |
| Repair committed | Record `applied` and its commit on the finding |
| Repair validated and reviewed | Accept the finding; update review facts |

Do not record a repair as applied merely because it was selected. Deferring
a required fix needs the decision rules; it cannot bypass an acceptance
criterion. Retain both reviewer attributions when merging duplicate findings.

## Review coverage

For each required reviewer, retain an initial full receipt and every repair
receipt. A repair receipt names the previous reviewed commit and the new one;
the chain must end at the push candidate under the same approved manifest.
A widened full receipt may establish a new coverage starting point.

Confirm matching reviewer identities, manifest revision/hash, commit ancestry,
and completed finding decisions. A new commit with no covering receipt leaves
review incomplete. Changed approved inputs require a new manifest and updated
evidence. No initial review means a repair-only receipt is insufficient.

## Artifacts and frozen inputs

Keep full command logs outside `.dct`; evidence stores their location, hash,
command, result, commit, and environment identity. Preserve artifacts required
for recovery through close-out and the project's retention period.

Retain the exact approved config, profile, and rubric contents in the manifest
or an attached/retained approved-inputs artifact. A source revision and hash
alone do not make old content available. The export carries source identities
and retained contents; it is generated, never a separately edited plan.

Moving a run between machines includes required artifacts and a mapping of
repo keys to local paths. Verify hashes after transfer. A missing log or frozen
input is a stated evidence gap; a hash cannot replace its contents.

## Decisions and metrics

Use the authoritative rubric frozen with the run. Record all ten axes:
Determinism, Reliability, Durability, Performance, Debuggability, LLM Ergonomics,
DRY, Cost, Discoverable, User-visible. Include measured facts, the decisive
axis, chosen default, and its falsifier. Preserve owner wording for a ruling.

At close-out, record one stage table with elapsed minutes, actor, tool calls,
input/cached/output tokens where reported, retries, findings and consequential
findings per reviewer, product/test diff size, orchestration wait, CI time, and
release time. Mark estimates and cumulative reports; do not double-count them.
Reference that batch row from the metrics KB and record measured reasons for
adopted optimizations. Read earlier rows during preparation.

Resolve tasks only when the agreed outcome is met. Record release separately
when requested; otherwise record integration and remaining checks without a
false `released:` tag. Human checks need a durable item naming expected
result, owner, and any automated proxy or explicitly perceptual gap.

## Rebuilding state

Read the manifest and frozen inputs, current repo head, attempts, receipts,
findings, artifacts, and remote facts. Reconcile incomplete operations first.
Then list missing evidence for the candidate and return to the relevant phase.
An empty work queue or completed attempt is not acceptance evidence.

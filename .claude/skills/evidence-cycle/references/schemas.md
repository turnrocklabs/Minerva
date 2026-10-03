# Evidence-cycle schemas

Use these shapes when preparing records or validating agent results. Examples
show the required structure; replace illustrative values before running work.
Store one fenced JSON object in each config, profile, and manifest article.

## Process config

Find the `kb` tagged `process-config` with key
`process-config/evidence-cycle`. First use the objective's `config:<id>`;
otherwise search its project, then `minerva`. Multiple matches are an error.

```json
{
  "schema": "evidence-cycle/v1",
  "roles": {
    "scout": {"provider": "<provider>", "model": "<model>"},
    "implementer": {"provider": "<provider>", "model": "<model>"},
    "reviewers": [
      {"name": "behavior", "provider": "<provider>", "model": "<model>", "access": "repo", "emphasis": "behavior and integration", "notes": ""},
      {"name": "contracts", "provider": "<provider>", "model": "<model>", "access": "diff", "emphasis": "persistence, concurrency, and test oracles", "notes": ""}
    ],
    "fixer": {"provider": "<provider>", "model": "<model>"},
    "gate": {"provider": "<provider>", "model": "<model>"},
    "integrator": {"provider": "<provider>", "model": "<model>", "principal": "<principal>"}
  },
  "rounds": {"group_retries": 3, "repair_review": 2, "final_retries": 3},
  "budgets": {"implementer_tool_calls": 60, "reviewer_tool_calls": 20, "implementer_minutes": 30},
  "autonomy": {
    "manifest_approval": "ratified-items",
    "judgement": "escalate-on-triggers-only",
    "release": "on-ci-green"
  },
  "runner": {"workflow": true, "max_agents": 12}
}
```

| Field | Meaning |
|---|---|
| `roles` | Harness and model for each role; never infer them from memory |
| `reviewers` | All listed reviewers are required during the pilot; emphasis does not prohibit other findings |
| `access` | `repo` allows independent navigation; `diff` requires supplied source and targeted requests |
| `gate` | Fixed-command agent used only when the runner cannot execute commands directly |
| `rounds` | Hard batch limits for group repairs, repair review rounds, and final-test repairs |
| `budgets` | Per-attempt allowances; the implementer attempt covers a whole batch, so its allowance scales with the task count; exhaustion returns incomplete under the main guide's rules |
| `max_agents` | Total agent dispatch allowance for this batch, including retries; parallel calls also respect runtime capacity |
| `workflow` | Permit suggesting Workflow mode; explicit owner authorization is still required |

Autonomy values:

- `manifest_approval`: `owner` presents the complete manifest for approval;
  `ratified-items` requires recorded owner approval of goals and acceptance.
- `judgement`: `always-ask` requests owner decisions; otherwise use
  `escalate-on-triggers-only` as defined in the main guide.
- `release`: `owner` waits for a release instruction; `on-ci-green` performs
  an already-authorized release once that candidate's CI passes.

Omitted `autonomy` uses the autonomous values in the example; it does not grant
authority. Other required fields must be explicit. Document an attended-mode
exception in the config article. Validate types, allowed enum values, unique
reviewer names, and positive limits; name the offending field on refusal.

## Project profile

Find exactly one `kb` with key `process-profile/<project>`. Resolve its repo
key locally. The profile holds reusable repository procedures, not machine
paths or transient findings.

```json
{
  "schema": "evidence-cycle/profile-v1",
  "repo": {"key": "<remote-host/owner/repo>", "branch": "<branch>"},
  "gates": [
    {"name": "import", "cmd": "<profile command>"},
    {"name": "parse", "cmd": "<profile command accepting {file}>"}
  ],
  "tests": {
    "one_class": "<profile command accepting {class}>",
    "isolation": "<required environment and directories>",
    "timeout_s": 900,
    "map": {"<module>": ["<test target>"]},
    "impact_cmd": ""
  },
  "forbidden": ["<live service, port, or user data>"],
  "contracts": ["<format, API, transaction, or sensitive path>"],
  "environment": {"identity_cmd": "<command reporting relevant toolchain and dependency identity>"},
  "ci": {"workflow": "<workflow name>", "full_suite_on_push": true},
  "release": {"tag_pattern": "<tag pattern>", "workflow": "<workflow name>", "install": "<procedure>"},
  "scale": {"scout_above_files": 400, "god_file_lines": 1500},
  "batch": {"ceremony_minutes": 40, "size_minutes": {"S": 2, "M": 8, "L": 25},
            "repair_round_minutes": 7, "max_commits": 6, "max_changed_lines": 600},
  "quirks": ["<repository-specific fact needed to resume>"]
}
```

`batch` holds the measured numbers behind the ceiling in the main guide:
`ceremony_minutes` is go-to-push minus writer time from the last runs,
`size_minutes` the expected implementer *writer* minutes per size tag,
`repair_round_minutes` the cost of one review-repair round, and the two
limits bound one reviewable batch. There is no time floor; the numbers exist
to forecast the batch and to compare estimate with actual. Revise them from
recorded actuals at close-out, as a proposed profile revision.

`classes` and `one_class` retain the pilot field names but identify the
project's named test targets; they need not be language-level classes. Use
platform-specific command entries where needed and resolve them before
approval. Do not interpolate untrusted text into shell commands; use argument
lists or explicit quoting supported by the runner.

Record missing commands or isolation as missing capabilities. Capture relevant
environment identity for results; if `environment` is absent in an existing
profile, propose its definition during preparation before approving the run.
Profile changes learned during execution are proposals for a new revision.

## Manifest

A `kb` tagged `manifest`, under the objective. It captures the effective plan
and frozen inputs. Source identities and budgets are derived from validated
records; approved run-specific overrides are explicit.

```json
{
  "schema": "evidence-cycle/manifest-v1",
  "base": "<full commit SHA>",
  "repo": "<remote-host/owner/repo>",
  "branch": "<branch>",
  "profile": "<item>@<revision>",
  "config": "<item>@<revision>",
  "rubric": "<item>@<revision>",
  "frozen": {
    "profile_sha256": "<sha256>",
    "config_sha256": "<sha256>",
    "rubric_sha256": "<sha256>",
    "artifact": "<retained approved-inputs artifact>",
    "artifact_sha256": "<sha256>"
  },
  "execution": "workflow",
  "tasks": [
    {
      "id": "<task id>",
      "goal": "<approved goal>",
      "oracle": "<independent observation that could fail>",
      "size": "S",
      "touch_set": ["<path or directory the task is expected to change>"],
      "constraints": [],
      "non_goals": [],
      "contracts": [],
      "pointers": [],
      "must_precede": [],
      "test_together": []
    }
  ],
  "groups": [
    {"name": "G1", "tasks": ["<task id>"], "classes": ["<test target>"], "review_boundary": false}
  ],
  "review": {"reviewers": ["behavior", "contracts"], "widen_on_contract": true},
  "budgets": {"implementer_tool_calls": 60, "reviewer_tool_calls": 20, "implementer_minutes": 30}
}
```

- `execution` is `workflow` or `orchestrator-stepped`.
- `size` is the task item's `size:` tag; a manifest never carries an `L`.
  `touch_set` is what the commit audit compares the diff against; an empty
  list is refused.
- Task array order is execution order. `must_precede` lists tasks that this
  task must precede; reject missing references or a contradictory order.
- Each task belongs to one named group. Membership comes from the approved
  manifest, not mutable tags. Reject unknown tasks, duplicate names, or missing
  targets. When no useful automated oracle exists, record the gap explicitly;
  approval must state the alternative evidence and deferred human check.
- A review-boundary group must finish its required review before dependent
  implementation proceeds. Use orchestrator-stepped mode if its outcome may
  change later goals.
- `review.reviewers` matches the configured reviewers. During the pilot,
  `widen_on_contract` must be true; it cannot silently reduce reviewer count.
- After discovery, freeze the plan before dispatch. Pointers are navigation;
  they never dictate a mechanism.

Retain the exact approved profile/config/rubric article contents and their
source identities in the approved-inputs artifact or directly in the manifest.
An export includes those retained contents, not only hashes. Use SHA-256 over
the exact retained UTF-8 article bytes; hash the exact saved manifest JSON
bytes separately and record that hash on the objective. Keep hash metadata
outside the bytes it hashes. Never reconstruct an old input from its latest
record. See [artifact rules](records.md#artifacts-and-frozen-inputs).

## Review receipt

Require a structured result from every reviewer. This example is an initial
review; a repair review identifies its previous reviewed commit.

```json
{
  "reviewer": "behavior",
  "reviewed_sha": "<commit>",
  "previous_reviewed_sha": null,
  "manifest_rev": "<item>@<revision>",
  "manifest_sha256": "<sha256>",
  "coverage": "full",
  "verdict": "must_fix",
  "findings": [
    {
      "id": "behavior-1",
      "location": "<file:line>",
      "class": "must_fix",
      "judgement": "resolvable",
      "scenario": "<trigger and observable consequence>",
      "confidence": "<supported confidence>",
      "evidence": "<source or result supporting the finding>"
    }
  ],
  "policy_answers": {
    "salient_comments": "<yes/no and reason>",
    "smallest_test_delta": "<yes/no and reason>",
    "parsimonious": "<yes/no and reason>",
    "readable_outside_context": "<yes/no and reason>",
    "within_scope": "<yes/no and reason>"
  },
  "execution_gaps": []
}
```

Verdicts: `approve`, `approve_with_notes`, `must_fix`, `reject`, or
`incomplete`. Finding classes: `must_fix` or `note`; judgment:
`resolvable` or `judgement_dependent`. For repair coverage, set
`coverage: repair` and `previous_reviewed_sha` to the prior receipt's commit.
For widened review, use `coverage: full`. Incomplete visibility belongs in
the gaps, not in an invented defect or implied approval.

Other agent results identify role, manifest, input/output commit, result,
evidence references, discoveries, and remaining uncertainties. A command
result also records command, environment, exit status, timeout, log identity,
and failure classification. Missing or malformed results are incomplete.

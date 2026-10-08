---
name: author-minerva-skill
description: Author or update skills shipped in src/Data/master.dct through a staged Docket project, then verify the three-way bootstrap merge in isolation.
---

# Author a shipped Minerva skill

Use for new or updated skills that ship in `src/Data/master.dct`. Runtime-only
user skills belong to the user's Docket project and are a different scope.
Read the repository instructions and tracked task before making changes.

## How delivery works

Minerva's `DocketHost` sends the shipped master to the Docket plugin's
`bootstrap_project`. Docket owns the three-way merge of the new shipment,
the stored shipped baseline and the user's current content. Untouched copies
update; customized copies are preserved and reported as conflicts. Seen IDs
are retained in `ever_shipped`, so a user's deletion is not resurrected.
Removing an ID from a shipment does not remove its existing user copy: fix
bad shipped content forward. There is no shipped-hash invalidation step.

## Author through the owning API

1. Establish the approved title, description, preconditions, outcome, steps,
   tags and tool dependencies. Reuse existing decisions; ask only for genuinely
   missing requirements. Markdown headings are valid in the steps text.
2. Pin the repository revision. Copy its `src/Data/master.dct` to a new scratch
   directory outside Git. Keep an untouched before-copy for the diff and tests.
   Do not use an experiment snapshot containing probe items.
3. Call `docket_project_list`, then `docket_project_add(path=<staged file>,
   create=false)`. The shipped file's project name is lowercase `master`;
   uppercase `Master` is a different project. If `master` is already loaded
   from another path, stop rather than mutating or closing that user's project.
4. New item: `docket_create(project="master", type="skill", source="master",
   title=..., description=..., preconditions=..., outcome=..., steps=...,
   tags=[...], tool_deps=[...])`. Use the returned ID; transition its draft
   lifecycle to `active` with `docket_transition`. Read the pinned lifecycle
   if the server differs. Existing item: `docket_get` then `docket_update`
   with the existing ID and revision; preserve its identity.
5. Verify with `docket_get` and `docket_skill_list(project="master", ...)`.
   Required tool names must be real; use an empty dependency list when the
   skill is useful to terminal agents without tool activation. Do not guess
   optimization fields or copy unrelated profiles.
6. Call `docket_flush(project="master")` before taking the authored snapshot:
   mutations may still be in its write-ahead sidecar. Inspect raw and semantic
   diffs against the untouched copy. Explain serializer normalization; stop
   for any unexplained existing-content change.
7. Verify the authored snapshot in a planned container job or VM on copies,
   using the matching editor for Docket's project. Exercise the real
   `MasterBootstrapPlan`/`MasterBootstrapApply` or `bootstrap_project` path:
   fresh install, existing install, and an edited shipped-item install.
   Require all intended active skills in `docket_skill_list`; require the
   edited content to survive with a conflict report. Retain commands, revisions,
   input hashes, merge reports and logs outside Git; inspect script errors as
   well as exit status. Do not start Godot against the live host Minerva tree.
8. Close only the staged project with `docket_project_close(name="master")`;
   this keeps its file. Copy the exact API-authored snapshot to
   `src/Data/master.dct`, review the final diff and stage that path explicitly.
   Commit with the task ID only when authorized. Scan the exact outgoing
   history before push; publishing still needs human authorization.

Do not hand-edit tool-owned `.dct` files or edit a live user's master to test
shipping. Do not flush unrelated projects, delete user caches, or ask for a
live restart as a substitute for the isolated fixtures. A failed prerequisite
is a named limitation, never a successful merge check.

## Content fields

- `title`: human-readable chooser title; `description`: when to use it.
- `preconditions` and `outcome`: required context and observable success.
- `steps`: instructions/ideas and recovery appropriate to the approved scope.
- `tags`: discovery categories; `tool_deps`: actual tools, or empty.
- `source="master"` and active status identify a shipped skill.

Use the current Docket MCP schemas as the field authority; create/update now
expose `tool_deps`. Never generate UUIDs, timestamps or JSONL records by hand.

## Source pointers

- `src/Data/master.dct`: shipped baseline.
- `src/Scripts/Services/DocketHost/DocketHost.gd`: bootstrap request forwarding.
- Docket `scripts/core/master_bootstrap_plan.gd` and `master_bootstrap_apply.gd`:
  merge decisions, validation and persisted baseline/seen-ID state.
- T1 `minerva:01a11ccd62a3`: measured staged authoring and merge behaviour.

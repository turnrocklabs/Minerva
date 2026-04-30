# Pickup — Annotation v2 Substrate

Last updated: 2026-04-30 (post Round 2b anchor registry)

## Where I left off

**Round 1 (contract tests + smoke consumer scaffolding) shipped GREEN-RED.**
Commit `76d4b8e4` adds 25 .gd contract test files + a `run_all.sh` aggregator
under `src/test/annotations_v2/`. Baseline: `0 passed, 358 failed`, runner
exits 0 (RED-as-expected). Reviewed by Opus cold; verdict approve_with_notes.

**Round 1.5 fix-up is done.** Work item `019ddbcfeef774bb` rebuilt
`libterminal` via `scripts/build-extensions.sh macos`, evicting stale native
`AnnotationV2Schema/Lifecycle/Author` symbols, and hardened
`test_annotation_v2_envelope.gd` from hollow `ClassDB` checks into behavioral
GDScript assertions. Verification: native symbol count `0`, envelope `78/0`,
v1 substrate `146/0`.

**Round 2a envelope is done.** `019ddb7593467eef` is `done`; the three envelope
implementation files are still untracked working-tree files and should be kept:
`AnnotationV2Schema.gd`, `AnnotationLifecycle.gd`, `AnnotationAuthor.gd`.

**Round 2b anchor registry is done.** Work item `019ddb75ffad7dd8` added
`AnnotationAnchorRegistry.gd`, `CoreAnchors.gd`, hardened the registry/core
tests, and added an optional `AnnotationHost.get_anchor_registry()` +
`validate_annotation_anchor()` hook. Verification: anchor registry `38/0`,
core anchors `29/0`, full annotations-v2 suite `145 passed, 279 failed`
(`EXIT: PARTIAL` from future-round RED tests).

**Scope refinement recorded in docket comments #266/#267.** v2 should be framed
as a **base annotation substrate plus plugin/domain extensions**. Base kinds are
cross-editor annotations such as text/comment, arrow/callout, region/highlight,
and future ink/freehand. Plugin/domain extensions include PCB trace/bus hints,
CAD edge/face actions, etc. Action-intent and LLM apply flows are first-class
but not mandatory for every kind; some annotations are durable review/reasoning
artifacts that may remain after work is applied.

CAD UX work remains paused (working CAD editor exists elsewhere; not blocker).

## What to do on the laptop

Next work item:

```
/work-cycle 019ddb767fe871ba
```

This is **Round 2c: Base AnnotationHost.resolve_anchor +
anchor_screen_rect contract**. Implement the host resolution hook on top of the
now-green envelope and anchor registry. Keep the substrate projection-agnostic:
base/core anchors can resolve generically, while plugin hosts resolve their own
semantic anchors.

> **Reconstruction note** (2026-04-29 laptop): the original substrate IDs
> referenced in earlier revisions of this file (`019ddacc5f76`, `019ddacc9c95`,
> `019ddacd*`, `019ddae35c78`) were created on the desktop but never committed
> to `Docs/minerva.dct`. The plan + 11 children were rebuilt from discussion
> `0bd63d76bb70` (comments #248 #249 #250) on the laptop with new IDs (below).
> The reframe sharpened the action-intent + PCB-as-proof-of-value framing,
> shifting acceptance criteria on five children (envelope lifecycle,
> built-in/plugin kind split, chat context, MCP, trust boundary). On
> 2026-04-30, scope was refined again to base substrate + plugin/domain
> extensions, with action-intent as one workflow rather than the whole model.

## Plan map

Project: `minerva` (always pass `project="minerva"` to docket tools).

- DCR root: `019ddb704374` — First-class editor annotations: base substrate + plugin semantic anchors
- Plan: `019ddb70ca45` — Annotation v2 substrate (base annotations + semantic anchors)
- Discussion: `0bd63d76bb70` — Annotation substrate refactor (resolved into the DCR)

### Children of the plan

Status legend: ✅ done · ⏳ open/backlog

| Status | ID | Title |
|--------|----|-------|
| ✅ | `019ddb7593467eef` | Annotation v2 envelope: typed anchor, payload, lifecycle, author, summary |
| ✅ | `019ddb75ffad7dd8` | Plugin-scoped anchor registry (validate / summary / repair) |
| ⏳ | `019ddb767fe871ba` | Base AnnotationHost.resolve_anchor + anchor_screen_rect contract *(NEXT)* |
| ⏳ | `019ddb76ed897520` | Broken / stale anchor UX (canvas, sidebar, MCP, chat) |
| ⏳ | `019ddb77576b7b56` | Resolve cache + perf budget |
| ⏳ | `019ddb77c4b37516` | Built-in anchors carry generic kinds; plugin anchors carry plugin kinds |
| ⏳ | `019ddb7843b4742d` | Capability-aware to_chat_context (structured_json IS the action contract) |
| ⏳ | `019ddb78c40c74bc` | MCP query / update_status surface + apply-tool hook |
| ⏳ | `019ddb796041719a` | v1 → v2 migration + coexistence hooks |
| ✅ | `019ddb7a0f407621` | Contract tests + smoke consumer (text editor) — Round 1 RED scaffolding shipped (commit `76d4b8e4`) |
| ⏳ | `019ddb7aaf247033` | Plugin trust boundary + fail-containment (render / resolver / apply-tool) |
| ✅ | `019ddbcfeef774bb` | Fix stale libterminal stubs + harden contract tests with behavior |

The remaining backlog items have full implementation detail in their
descriptions (method signatures, perf numbers, lifecycle enum + transitions,
test groups) and are readable cold by an implementer with no session history.

## Recommended round order (within the work-cycle)

1. ✅ **Round 1 done**: `019ddb7a0f407621` test scaffolding shipped RED in
   commit `76d4b8e4`. Run `bash src/test/annotations_v2/run_all.sh` to
   confirm baseline `0 passed, 358 failed`.
2. ✅ **Round 1.5 done**: `019ddbcfeef774bb` — rebuilt `libterminal`, hardened
   envelope tests.
3. ✅ **Round 2a done**: Envelope (`019ddb7593467eef`) + anchor registry
   (`019ddb75ffad7dd8`) green.
4. ⏳ **Round 2c NEXT**: resolve_anchor (`019ddb767fe871ba`).
5. ⏳ **Round 3**: Cache (`019ddb77576b7b56`) + Trust (`019ddb7aaf247033`) +
   Broken UX (`019ddb76ed897520`) in parallel.
6. ⏳ **Round 4**: Chat (`019ddb7843b4742d`) + Built-in/plugin kinds split
   (`019ddb77c4b37516`) + MCP (`019ddb78c40c74bc`) + Migration
   (`019ddb796041719a`) in parallel.
7. ⏳ **Round 5**: Smoke consumer (text editor wiring). HITL stop — human
   verifies the "select text → add comment → LLM marks applied" flow.

Migration and MCP query may slot earlier than round 4 if other tasks force
them — see plan body.

## State of the trees at handoff

Minerva (`user/imran/experiments/swarm`, HEAD = `76d4b8e4`):
- Round 1 contract tests committed (`src/test/annotations_v2/`, 25 .gd + runner).
- **Untracked/modified working tree from Round 2a/2b — keep, do not delete:**
  - `src/Scripts/Services/Annotations/AnnotationV2Schema.gd`
  - `src/Scripts/Services/Annotations/AnnotationLifecycle.gd`
  - `src/Scripts/Services/Annotations/AnnotationAuthor.gd`
  - `src/Scripts/Services/Annotations/AnnotationAnchorRegistry.gd`
  - `src/Scripts/Services/Annotations/CoreAnchors.gd`
  - `src/test/annotations_v2/test_annotation_v2_envelope.gd`
  - `src/test/annotations_v2/test_annotation_anchor_registry.gd`
  - `src/test/annotations_v2/test_core_anchors.gd`
- **Native contamination fixed locally**: rebuilt
  `src/bin/libterminal.macos.template_debug.framework/libterminal.macos.template_debug`;
  stale annotation symbol count is `0`.
- `Docs/minerva.dct` modified (docket transitions accumulated this session;
  uncommitted — fix-up item will fold in with its commit).
- Submodule working-tree mods in `vendor/godot_cef` and `vendor/EIRTeam.FFmpeg`
  are local build patches (per CLAUDE.md) — not committed, not blocking.

`~/github/plugins` (`main`):
- 19 commits ahead of origin. Working tree clean.
- Round 2b-α click-to-add edge-number tool is on disk at
  `cad/ui/tools/cad_edge_number_tool.gd` but not wired — will be rebuilt on the
  v2 `AnnotationAuthorTool` contract once substrate ships.

## Constraints to carry forward

- Always pass `project="minerva"` to docket MCP tools when working with
  substrate IDs (saved as docket hint `docket/minerva-project-flag`).
- Off-tree plugin scripts must use `preload()`, not `class_name`
  (memory: `project_off_tree_plugin_class_names.md`).
- Plugin annotation code never crosses into another plugin's data — only via
  MCP, per the substrate's trust boundary task (`019ddb7aaf247033`).
- 2D ortho panes in CAD are intentionally edge-only x-ray, NOT 3D renders.
- **Reverting C++ source under `src/gdextension/terminal/` does NOT evict the
  compiled binary.** Always rebuild via `scripts/build-extensions.sh <platform>`
  after any reversion, or stale native registrations will shadow GDScript
  classes. Symptom: `Parse Error: Class "X" hides a native class.`
  (Lesson from this session — see fix-up item `019ddbcfeef774bb`.)
- **Round-1 contract tests are existence-only and will pass against hollow
  shadow stubs.** When implementing any round, read the relevant test file
  and add behavioral assertions (call methods with arguments, assert on
  return values) before declaring green. Nudge hint key planned:
  `minerva-testing/annotations-v2-existence-only-trap`.

## To pick up cold

1. `git pull` on both `~/github/Minerva` (branch `user/imran/experiments/swarm`)
   and `~/github/plugins` (branch `main`).
2. Read `Docs/pickup.md` (this file).
3. `git status` — expect 3 untracked GDScript files under
   `src/Scripts/Services/Annotations/` (Round 2a partial). Keep them.
4. `git log --oneline -5` — HEAD should be `76d4b8e4` (Round 1 RED).
5. Run the verification probes:
   - `godot --headless --path src --script test/annotations_v2/test_annotation_v2_envelope.gd`
   - `godot --headless --path src --script test/annotations_v2/test_annotation_anchor_registry.gd`
   - `godot --headless --path src --script test/annotations_v2/test_core_anchors.gd`
6. `/work-cycle 019ddb767fe871ba`.

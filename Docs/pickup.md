# Pickup — Annotation v2 Substrate

Last updated: 2026-04-29

## Where I left off

Pivoted away from CAD UX Round 2b mid-stream because the surfaced problems
(modal-tool lockup, chord-vs-parametric edge midpoints, mouse_filter freeze)
were symptoms of an annotation substrate that conflated 2D primitives with
semantic anchors. New plan: refactor the substrate first; CAD/PCB adopt later.

CAD UX work is paused, not abandoned. A working CAD editor exists elsewhere,
so this is not a blocker.

## What to do on the laptop

Run:

```
/work-cycle 019ddacd6e34
```

This task (`Annotation v2 contract tests and smoke consumer`) is the recommended
**first** work-cycle for the substrate plan. It writes red contract tests
covering every other task in the plan, plus the text-editor smoke consumer
flow. Tests-first forces every upstream task to commit to a concrete schema
before any implementer touches them.

The task description is fully self-contained — it lists the smoke consumer
(text editor with `core/text.range` anchor, NOT CAD/PCB), the per-upstream-task
test groups, and a 5-round decomposition.

## Plan map

Project: `minerva` (always pass `project="minerva"` to docket tools).

- DCR root: `019ddacc5f76` — First-class editor annotations
- Plan: `019ddacc9c95` — Annotation v2 semantic-anchor substrate
- Discussion: `0bd63d76bb70` — Annotation substrate refactor

### Children of the plan

| ID | Title |
|----|-------|
| `019ddaccb2be` | Annotation v2 envelope (typed anchor, payload, status, author, schema_version) |
| `019ddaccca9a` | Plugin-scoped anchor registry (validate/summary/repair) |
| `019ddacce0a3` | Base AnnotationHost resolve_anchor contract |
| `019ddaccf5ba` | Broken/stale anchor UX (canvas, sidebar, MCP, chat) |
| `019ddacd08a2` | Resolve cache + perf budget |
| `019ddacd1bb6` | Generic kinds carry plugin anchors via host resolve |
| `019ddacd2ea8` | Capability-aware to_chat_context |
| `019ddacd4275` | MCP query/update surface |
| `019ddacd5bd2` | v1 migration + coexistence hooks |
| **`019ddacd6e34`** | **Contract tests + smoke consumer ← START HERE** |
| `019ddae35c78` | Plugin trust boundary + fail-containment |

All eleven items are backlog and have full implementation detail in their
descriptions (envelope literals, method signatures, perf numbers, lifecycle
enum + transitions, test groups). They are designed to survive context
compaction — readable cold by an implementer with no session history.

## Recommended round order (within the work-cycle)

1. **Round 1 (start here)**: `019ddacd6e34` test scaffolding only — write all
   contract tests as red. Single Sonnet implementer + Opus reviewer.
   Stop condition 3c (auto-verified, no human gate).
2. **Round 2**: Envelope + Registry + Resolve in parallel.
3. **Round 3**: Cache + Trust + Broken UX in parallel.
4. **Round 4**: Chat + Generic kinds.
5. **Round 5**: Smoke consumer (text editor wiring). HITL stop — human verifies
   the "Add note here" flow.

Migration (`019ddacd5bd2`) and MCP query (`019ddacd4275`) slot in around
rounds 3–4.

## State of the trees on this commit

Minerva (`user/imran/experiments/swarm`):
- All annotation v2 substrate DCR work-items updated and ready.
- Memory pointer in `~/.claude/projects/-home-imran-github-Minerva/memory/project_active_cycle_plan.md`
  rewritten as the post-compaction entry point.
- Submodule working-tree mods in `vendor/godot_cef` and `vendor/godot_wry` are
  local build patches (per CLAUDE.md) — not committed, not blocking.

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
  MCP, per the substrate's trust boundary (`019ddae35c78`).
- 2D ortho panes in CAD are intentionally edge-only x-ray, NOT 3D renders.

## To pick up cold

1. `git pull` on both `~/github/Minerva` (branch `user/imran/experiments/swarm`)
   and `~/github/plugins` (branch `main`).
2. Read `Docs/pickup.md` (this file) and the active-cycle memory file.
3. `git log --oneline -5` to confirm both repos.
4. `/work-cycle 019ddacd6e34`.

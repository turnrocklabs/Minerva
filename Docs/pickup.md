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
/work-cycle 019ddb7a0f407621
```

This task (`Contract tests + smoke consumer (text editor) — START HERE`) is the
recommended **first** work-cycle for the substrate plan. It writes red contract
tests covering every other task in the plan, plus the text-editor smoke
consumer flow. Tests-first forces every upstream task to commit to a concrete
schema before any implementer touches them.

The task description is fully self-contained — it lists the smoke consumer
(text editor with `core/text.range` anchor, NOT CAD/PCB), the per-upstream-task
test groups, and a 5-round decomposition.

> **Reconstruction note** (2026-04-29 laptop): the original substrate IDs
> referenced in earlier revisions of this file (`019ddacc5f76`, `019ddacc9c95`,
> `019ddacd*`, `019ddae35c78`) were created on the desktop but never committed
> to `Docs/minerva.dct`. The plan + 11 children were rebuilt from discussion
> `0bd63d76bb70` (comments #248 #249 #250) on the laptop with new IDs (below).
> The reframe sharpened the action-intent + PCB-as-proof-of-value framing,
> shifting acceptance criteria on five children (envelope lifecycle,
> built-in/plugin kind split, chat context, MCP, trust boundary).

## Plan map

Project: `minerva` (always pass `project="minerva"` to docket tools).

- DCR root: `019ddb704374` — First-class editor annotations: action-intent envelope + plugin semantic anchors
- Plan: `019ddb70ca45` — Annotation v2 substrate (action-intent + semantic anchors)
- Discussion: `0bd63d76bb70` — Annotation substrate refactor (resolved into the DCR)

### Children of the plan

| ID | Title |
|----|-------|
| `019ddb7593467eef` | Annotation v2 envelope: typed anchor, payload, lifecycle, author, summary |
| `019ddb75ffad7dd8` | Plugin-scoped anchor registry (validate / summary / repair) |
| `019ddb767fe871ba` | Base AnnotationHost.resolve_anchor + anchor_screen_rect contract |
| `019ddb76ed897520` | Broken / stale anchor UX (canvas, sidebar, MCP, chat) |
| `019ddb77576b7b56` | Resolve cache + perf budget |
| `019ddb77c4b37516` | Built-in anchors carry generic kinds; plugin anchors carry plugin kinds |
| `019ddb7843b4742d` | Capability-aware to_chat_context (structured_json IS the action contract) |
| `019ddb78c40c74bc` | MCP query / update_status surface + apply-tool hook |
| `019ddb796041719a` | v1 → v2 migration + coexistence hooks |
| **`019ddb7a0f407621`** | **Contract tests + smoke consumer (text editor) ← START HERE** |
| `019ddb7aaf247033` | Plugin trust boundary + fail-containment (render / resolver / apply-tool) |

All eleven items are backlog and have full implementation detail in their
descriptions (envelope literals, method signatures, perf numbers, lifecycle
enum + transitions, test groups). They are designed to survive context
compaction — readable cold by an implementer with no session history.

## Recommended round order (within the work-cycle)

1. **Round 1 (start here)**: `019ddb7a0f407621` test scaffolding only — write
   all contract tests as red. Single Sonnet implementer + Opus reviewer.
   Stop condition 3c (auto-verified, no human gate).
2. **Round 2**: Envelope (`019ddb7593467eef`) + Anchor registry
   (`019ddb75ffad7dd8`) + resolve_anchor (`019ddb767fe871ba`) in parallel.
3. **Round 3**: Cache (`019ddb77576b7b56`) + Trust (`019ddb7aaf247033`) +
   Broken UX (`019ddb76ed897520`) in parallel.
4. **Round 4**: Chat (`019ddb7843b4742d`) + Built-in/plugin kinds split
   (`019ddb77c4b37516`) + MCP (`019ddb78c40c74bc`) + Migration
   (`019ddb796041719a`) in parallel.
5. **Round 5**: Smoke consumer (text editor wiring). HITL stop — human verifies
   the "select text → add comment → LLM marks applied" flow.

Migration and MCP query may slot earlier than round 4 if other tasks force
them — see plan body.

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

# Pickup — Presentation plugin

Last updated: 2026-05-02

## Where I left off

Active workstream: **Presentation plugin** (PowerPoint-style slide authoring + fullscreen presenting, as a Minerva plugin).

Pre-work this session: audited the substrate and plugin platform to map what already exists vs. what the DCR assumed. Recommended first cycle is the Scaffold task; we paused before kicking it off so the user could compact.

## What to do next

### Recommended first cycle: Scaffold

**Task:** `019dc0bc196173469d0823891d88bea1` — "Scaffold: plugin directory, manifest, Go stub, empty slide-editor scene".

**Deliverable:** plugin loads in plugin manager, mounts an empty slide-editor pane, has a Go binary stub running. Validates the off-tree plugin pattern works for this consumer.

**Mode:** hybrid (main-context implementer + cold reviewer sub-agent at the end). No `/work-cycle` wrapper. The CAD plugin is a working reference for the scaffold pattern; pattern reuse means re-briefing a fresh-context implementer is mostly cost without benefit. Cold reviewer's "did you forget the `.uid`/`plugins.json` cache" gotcha audit is the load-bearing piece. See memory `feedback_subagent_mode_per_task.md`.

**Reference scaffold:** `~/github/plugins/cad/manifest.json` + `~/github/plugins/cad/cad-plugin/main.go` (Go stub) + the `~/github/plugins/cad/ui/*.gd` and `*.tscn` files for the panel scene.

### Plan tasks (8 total, all backlog)

DCR (proposed): `019dc0bbd6937264880b1327c942d5b6`
Plan: `019dc0bbfcc57d81b4ac1300d4923094`

| Independent | ID | Title |
|---|---|---|
| ✅ | `019dc0bc196173469d0823891d88bea1` | Scaffold: plugin dir, manifest, Go stub, empty slide-editor scene |
| ✅ | `019dc0bc2f387f78a768e12e2da8f7b5` | Slide document model: types + tile layouts + mixed content |
| ✅ | `019dc0bc3ca07970b3cbce37093a89a4` | Slide editor UI: list panel + canvas + tile manipulation |
| ✅ | `019dc0bc46997bd488ffbcf4acb18ca4` | Reveal script: per-slide annotation IDs revealed on next-press |
| 🚧 | `019dc0bc54227391b5162f6324cb5338` | Fullscreen presentation mode (platform-dep) |
| 🚧 | `019dc0bc69087f45ba23a4045b435e78` | Pen input capture (substrate-dep) |
| ✅ | `019dc0bc768a7fc19c7ab73009762231` | MCP tools: create/edit/reorder slides, start, navigate, render thumbnail |
| 🚧 | `019dc0bc824a7d8d9d238526c6835de0` | Scenario validation: 10-slide deck end-to-end with annotations + pen ink |

5 of 8 tasks have **no platform/substrate dependency** — Scaffold → Model → Editor UI → Reveal Script → MCP tools is a viable independent path.

### Substrate-side prereqs (for the 🚧 tasks)

Filed under DCR-2's plan, NOT the presentation plan. Both `backlog`:

- `019dc0ebf9d5797a82af41edd4c8c180` — "ink_stroke primitive: ordered points with pressure/tilt"
- `019dc0ec06f77301858eed9cc22bb116` — "Live-authoring API: batched high-frequency writes for pen-stroke capture"

When time comes for pen input capture (`019dc0bc6908...`), unblock these first.

### Audit findings (2026-05-02): what already exists vs. what's missing

| Capability | Status | Pointer |
|---|---|---|
| `ink_stroke` primitive registered | ABSENT | `BuiltinKinds.gd:23` says "post-MVP"; `_validate_prim_ink_stroke()` exists in `AnnotationSchema.gd`; `ITEM_TYPE_INK_STROKE` constant in `AnnotationCanvas.gd` but unused |
| Existing primitives | PRESENT | `text`, `point`, `line`, `arrow`, `rect`, `polygon`, `polyline` registered in `BuiltinKinds.gd:26-36` |
| Batched/streaming annotation API | ABSENT | `AnnotationHost.add_annotation` is single-annotation; `MCPAnnotationTools` notes live-auth is task `019dc0ec...` "NOT HERE" |
| Plugin fullscreen capability | SCAFFOLD | `PluginDefinition.gd:670` parses `fullscreen_capable` manifest field but no broker enforces it |
| Plugin multi-window | SCAFFOLD | `PluginDefinition.gd:673` parses `multi_window` field but no Window-spawn API for plugins |
| Exclusive input grab | ABSENT | No `take_over_window` / input-grab API on PluginScenePanelBroker |

→ Scaffold + Model + Editor UI + Reveal Script + MCP tools can all proceed against current state. Fullscreen + pen capture defer until the substrate/platform tasks above land.

## Cold pickup checklist

1. `git pull` on `~/github/Minerva` (branch `user/imran/experiments/swarm`).
2. Read `Docs/pickup.md` (this file).
3. `git status` in Minerva — expect submodule drift only (`vendor/EIRTeam.FFmpeg`, `vendor/godot_cef` — pre-existing local build patches per CLAUDE.md). `git log --oneline -5` — head should be `6f82c011`.
4. Run the substrate regression suite from Minerva root:
   ```
   for t in test/annotations_v2/test_workbench_selection_sync.gd \
            test/annotations_v2/test_kind_extension_api.gd \
            test/annotations_v2/test_annotation_overlay_draw.gd; do
     godot --headless --path src --script "$t"
   done
   ```
   Expect 39 PASS / 0 FAIL.
5. Read CAD plugin's scaffold as the reference pattern:
   ```
   ~/github/plugins/cad/manifest.json
   ~/github/plugins/cad/cad-plugin/main.go     # if exists; or wherever the Go stub lives
   ~/github/plugins/cad/ui/CADPanel.tscn        # panel scene
   ~/github/plugins/cad/ui/CADPanel.gd          # panel script
   ```
6. Start the Scaffold task: transition `019dc0bc1961...` `backlog → open → in_progress`. Implement in main context. Spawn cold reviewer at the end with file allowlist + scaffold-checklist (manifest fields, off-tree class_name discipline, `.uid` / `plugins.json` cache, Go stub loadable).

## Constraints to carry forward

- Always pass `project="minerva"` to docket MCP tools when working with substrate/plan IDs.
- Off-tree plugin scripts must use `preload()`, not `class_name` for cross-script types (memory: `feedback_off_tree_plugin_class_names.md`).
- Plugin annotation code never crosses into another plugin's data — only via MCP, per the substrate's trust boundary.
- When adding/removing plugin scripts, update BOTH `~/github/plugins/<id>/manifest.json` AND `~/.local/share/godot/app_userdata/Minerva/plugins/plugins.json` (cached). Skipping the cached one means Godot still loads the deleted script.
- `queue_redraw()` does NOT trigger `_draw()` in headless tests — call `overlay._draw()` directly to assert draw-call behavior.
- Docket state machine doesn't allow skipping states. work_item: backlog → open → in_progress → blocked → done. bug: new → triaged → active → resolved. Resolution string only on terminal hop.
- AnnotationHost capability shape is **frozen** for canvas-sync compatibility — extend, don't rename.
- Plugin Go binaries are per-machine — rebuild after `git pull` touches `*.go` (memory: `project_cad_plugin_binary.md`). Same caveat will apply to the presentation plugin's Go stub.
- Sub-agent mode is a per-task call (memory: `feedback_subagent_mode_per_task.md`). Don't default to `/work-cycle` for everything.

## Paused work (not picking up — see git/docket only if needed)

- **CAD Phase B2** is `blocked` on bug `019dec49988b7091933371908d6bbb00` ("CAD callout annotations don't properly track their edge"). Latest commit `cad@622c67c` (untested). Bug body has full theory tree + file:line pointers if/when this gets revisited. **Not on the active workplan.** B3, B4, and substrate tasks for ink/live-auth remain in backlog and will be reconsidered when their dependencies clear.

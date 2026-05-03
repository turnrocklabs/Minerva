# Pickup — CAD Phase B paused, switching to Presentation plugin

Last updated: 2026-05-02 (B1 done; B2 blocked on a bug; new workstream: presentation plugin)

## Where I left off

### CAD Phase B status

**B1 shipped** (`cad@c0118b2`). cad/edge anchor schema + `register_anchor_resolver` + `_resolve_edge_anchor` callable on `Cad_AnnotationHost`. Live HITL probe via `minerva_annotations_repair_anchor` confirmed: hit case returned `position=[-40,100]`, `stale=false` (Z stripped by substrate's `_normalise_resolve_result` flatten — substrate convention, fine for substrate consumers); miss case (`id=99999`) returned `stale=true`, `lifecycle_effective=stale`. Cold reviewer PASS on all asserts. Substrate test suite 39/0. Docket `019de9b807e67c01` → done.

**B2 blocked** (`019de9b82b977e11` → blocked, blocked_by `019dec49988b7091`). Three WIP commits on `cad`:

```
622c67c  WIP: CAD Phase B2 fix — screen-relative box_offset (UNTESTED)
62cc20d  WIP: CAD Phase B2 HITL follow-up — camera-tracking + text dialog
12e897b  WIP: CAD Phase B2 — migrate edge-number kind/tool to anchor envelope
```

What works: kind reads anchor live via `host._resolve_edge_anchor` (Vector3 path, bypassing substrate flattening); tool emits new envelope `{anchor:{plugin:"cad",type:"edge",id:N}, payload:{text, box_offset:[x,y,z]}}`; perspective-only filter via `camera.projection == PROJECTION_PERSPECTIVE`; pre-selected fast-path via `host.get_current_selection_anchor("cad/edge")`; AcceptDialog text input (Enter or OK confirms); `Cad_AnnotationHost._process` emits `annotations_changed` when any pane camera moves so the substrate AnnotationOverlay redraws on camera transforms.

What's broken: at HITL on `62cc20d`, the leader+anchor-dot did not visually connect to the edge midpoint. The fix attempt at `622c67c` (screen-relative back-projection of `box_offset` so box center lands at `edge_screen + (150,-120)` px) is **untested** — user paused before re-HITL'ing.

**Bug**: `019dec49988b7091933371908d6bbb00` — "CAD callout annotations don't properly track their edge". Severity 3. Body has full theory tree (1-mitigated, 4-not-yet-investigated), file:line pointers, and explicit recommendation: HITL `622c67c` first; if still broken, instrument `cad_edge_number_kind.render` with print() for `anchor_screen / leader_target / box_rect` and compare to expected.

### B3 / B4 still in backlog
- `019de9b859d97f51` — B3: worker edge-ID stability (open A/B/C design Q)
- `019de9b874dc704e` — B4: MCPCadTools._cad_annotate_edges → emit anchor envelopes

Both depend on B2's anchor envelope adoption being functional. Resume after B2 unblocks.

## What to do next

### New workstream: Presentation plugin

PowerPoint-style slide authoring + fullscreen presenting, as a Minerva plugin.

**DCR (proposed):** `019dc0bbd6937264880b1327c942d5b6` — "Presentation plugin: PowerPoint-style slide authoring + fullscreen presenting"

**Plan (backlog):** `019dc0bbfcc57d81b4ac1300d4923094` — "Plan: Presentation Plugin (v1)"

**Plan tasks (8, all backlog):**

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

### Substrate-side prereqs (filed under DCR-2 plan, not presentation plan)

Both `backlog`. Already filed; pen input task is platform-dep on these.

- `019dc0ebf9d5797a82af41edd4c8c180` — "ink_stroke primitive: ordered points with pressure/tilt"
- `019dc0ec06f77301858eed9cc22bb116` — "Live-authoring API: batched high-frequency writes for pen-stroke capture"

### Audit findings (2026-05-02): what already exists vs. what's missing

| Capability | Status | Pointer |
|---|---|---|
| `ink_stroke` primitive registered | ABSENT | `BuiltinKinds.gd:23` says "post-MVP"; `_validate_prim_ink_stroke()` exists in `AnnotationSchema.gd`; `ITEM_TYPE_INK_STROKE` constant in `AnnotationCanvas.gd` but unused |
| Existing primitives | PRESENT | `text`, `point`, `line`, `arrow`, `rect`, `polygon`, `polyline` registered in `BuiltinKinds.gd:26-36` |
| Batched/streaming annotation API | ABSENT | `AnnotationHost.add_annotation` is single-annotation; `MCPAnnotationTools` notes live-auth is task `019dc0ec...` "NOT HERE" |
| Plugin fullscreen capability | SCAFFOLD | `PluginDefinition.gd:670` parses `fullscreen_capable` manifest field but no broker enforces it |
| Plugin multi-window | SCAFFOLD | `PluginDefinition.gd:673` parses `multi_window` field but no Window-spawn API for plugins |
| Exclusive input grab | ABSENT | No `take_over_window` / input-grab API on PluginScenePanelBroker |

→ 5 of the 8 plan tasks (scaffold, model, editor UI, reveal script, MCP tools) have **no platform/substrate dependency**. Fullscreen + pen capture + end-to-end scenario validation defer until ink_stroke + live-auth + platform fullscreen are activated.

### Recommended first cycle: Scaffold

`019dc0bc196173469d0823891d88bea1` — Scaffold the plugin. Deliverable: plugin loads in plugin manager, mounts an empty slide-editor pane, has a Go binary stub running. Validates the off-tree plugin pattern (CAD plugin proves it works) for this consumer.

**Mode: hybrid** (main-context implementation + cold reviewer at the end). No `/work-cycle` wrapper. Lessons from B2: full work-cycle wrapper added overhead without commensurate value when the implementer's spec was UX-ambiguous; cold reviewer alone is the high-value piece. Scaffold is mostly mechanical (manifest schema, Go stub, scene), so cold reviewer's "did you forget the `.uid`/`plugins.json` cache" gotcha catches dominate.

### Caveat for the next session

CAD plugin Go binary is per-machine — rebuild after `git pull` touches `*.go` (memory `project_cad_plugin_binary.md`). Same applies to whatever Go binary the presentation scaffold lands.

## Plan map

Project: `minerva` (always pass `project="minerva"` to docket tools).

### CAD plugin (paused)
- DCR: `019dc054a453` — CAD plugin: port MCAD experiment as first platform consumer
- Plan: `019dc0552d6a` — Plan: CAD Plugin (v1 through exports)
- Phase A: ✅ all done (A1-A4)
- Phase B1: ✅ done (`cad@c0118b2`)
- Phase B2: 🚧 blocked by bug `019dec49988b7091`
- Phase B3-B4: backlog, dependent on B2

### Presentation plugin (active)
- DCR: `019dc0bbd6937264` — Presentation plugin (proposed)
- Plan: `019dc0bbfcc57d81` — Plan: Presentation Plugin (v1)

### Substrate (DCR-2)
- ink_stroke + live-auth tasks `019dc0ebf9...` / `019dc0ec06...` — backlog, prereqs for pen-input feature in presentation

## Constraints to carry forward

- Always pass `project="minerva"` to docket MCP tools when working with substrate IDs.
- Off-tree plugin scripts must use `preload()`, not `class_name` for cross-script types (memory: `feedback_off_tree_plugin_class_names.md`).
- Plugin annotation code never crosses into another plugin's data — only via MCP, per the substrate's trust boundary.
- 2D ortho panes in CAD are intentionally edge-only x-ray, NOT 3D renders.
- When adding/removing plugin scripts, update BOTH `~/github/plugins/<id>/manifest.json` AND `~/.local/share/godot/app_userdata/Minerva/plugins/plugins.json` (cached). Skipping the cached one means Godot still loads the deleted script.
- `queue_redraw()` does NOT trigger `_draw()` in headless tests — call `overlay._draw()` directly to assert draw-call behavior.
- Docket state machine doesn't allow skipping states. work_item: backlog → open → in_progress → blocked → done. bug: new → triaged → active → resolved. Resolution string only on terminal hop.
- AnnotationHost capability shape is **frozen** for canvas-sync compatibility — extend, don't rename.
- Substrate's `_normalise_resolve_result` flattens Vector3 → Vector2 in `host.resolve_anchor(...)` results (AnnotationHost.gd:330-332). Plugins that need Vector3 (CAD perspective callout) call the underscore-prefixed resolver method directly.
- Substrate AnnotationOverlay only redraws on `annotations_changed`; for camera-projected kinds, the host must emit it on camera transform (Cad_AnnotationHost does this in `_process`).

## Cold pickup checklist

1. `git pull` on `~/github/Minerva` (branch `user/imran/experiments/swarm`) and `~/github/plugins/cad` (branch `main`).
2. Read `Docs/pickup.md` (this file).
3. In Minerva: `git status` — expect `Docs/minerva.dct` modified + submodule drift only. `git log --oneline -5`.
4. In cad plugin: `git status --short` — clean. `git log --oneline -4` — head should be `622c67c`.
5. **Rebuild the cad-plugin Go binary on this machine** if its mtime is older than `*.go` source — see `~/.claude/projects/-Users-ipeerbhai-github-Minerva/memory/project_cad_plugin_binary.md`.
   ```
   cd ~/github/plugins/cad && go build -o cad-plugin .
   ```
6. Run the substrate regression suite from Minerva root:
   ```
   for t in test/annotations_v2/test_workbench_selection_sync.gd \
            test/annotations_v2/test_kind_extension_api.gd \
            test/annotations_v2/test_annotation_overlay_draw.gd; do
     godot --headless --path src --script "$t"
   done
   ```
   Expect 39 PASS / 0 FAIL.
7. **For presentation plugin work**: kick off `019dc0bc196173469d0823891d88bea1` (Scaffold) in hybrid mode. Read CAD plugin's `~/github/plugins/cad/manifest.json` + `cad-plugin/main.go` as the reference scaffold pattern.
8. **For CAD bug investigation** (if revisiting B2): start with `cad@622c67c` HITL retest. If still broken, see bug `019dec49988b7091` body for theories A-E and file:line pointers to instrument.

## Process notes worth remembering

- **R2a / B2 lesson**: cold reviewer can only verify against the spec. When the spec is UX-ambiguous (e.g., "default offset = camera_right + camera_up * 30" doesn't say what should look right), reviewer PASSes the diff but HITL fails. Mitigation: write fuller per-task specs *before* implementation, or accept that some bugs will only surface in HITL and plan for fast iteration loops.
- **Hybrid mode** (main-context implementer + cold reviewer sub-agent, no `/work-cycle` wrapper) is a good fit when:
  - Spec has UX or design judgment calls that benefit from in-conversation user feedback
  - The implementer's value-add (file edits + test runs) is small relative to the briefing cost
  - Cold reviewer's structural audit (file allowlist, per-method delta, banned framings) is the high-value piece
- **Full `/work-cycle`** is right for mechanical, well-specified tasks where re-briefing a fresh-context agent is cheap and parallelism would help.
- **HITL roll-forward as a separate WIP commit** (cad@b483293, 62cc20d, 622c67c) preserves the prior commits as historical evidence rather than amending. Easier to bisect when the regression bites later.

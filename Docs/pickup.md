# Pickup — Presentation plugin

Last updated: 2026-05-03

## Where I left off

Active workstream: **Presentation plugin** (PowerPoint-style slide authoring + fullscreen presenting, as a Minerva plugin).

T1 (Scaffold) and T2 (Slide document model) are both shipped. The plugin is installed and loads cleanly; the document model with three tile kinds (text/image/spreadsheet) is in place with 84 passing headless tests. Next: T3 — the slide editor UI.

## What to do next

### Recommended next cycle: T3 — Slide editor UI

**Task:** `019dc0bc3ca07970b3cbce37093a89a4` — "Slide editor UI: list panel + canvas + tile manipulation".

**Deliverable:** the placeholder Label in `SlideEditorPanel.tscn` is replaced with the real authoring UI:
- Slide list panel (left, scrollable, click-to-select, drag-to-reorder)
- Canvas (middle, framed at deck aspect — 16:9)
- Tile renderers: RichTextLabel (text/BBCode/lists), TextureRect (image), GridContainer (spreadsheet)
- Drag handles for moving tiles, corner handles for resizing
- Add/delete affordances for tiles + slides
- Calls `SlideEditorPanel.set_deck()` and emits `content_changed` on every mutation

**Mode:** hybrid — implement in main context, cold reviewer at the end. T3 is bigger than T2 (probably 600–900 lines of new GDScript + UI scenes). May span multiple sessions; commit WIP at meaningful boundaries.

**Reference:**
- Tile model + helpers: `~/github/plugins/presentation/ui/slide_model.gd`
- Panel script: `~/github/plugins/presentation/ui/SlideEditorPanel.gd` (already wires save/load; just needs UI replacing the placeholder)
- Existing Minerva spreadsheet renderer: `~/github/Minerva/src/Scripts/UI/Controls/SpreadsheetEditor/SpreadsheetEditor.gd` — possible reuse for the spreadsheet tile renderer.
- BBCode rendering: Godot's `RichTextLabel` parses `[b][/b]`, `[i][/i]`, `[s][/s]` natively.

### Plan tasks (8 total)

DCR: `019dc0bbd6937264880b1327c942d5b6`
Plan: `019dc0bbfcc57d81b4ac1300d4923094`

| Status | ID | Title |
|---|---|---|
| ✅ done | `019dc0bc196173469d0823891d88bea1` | Scaffold: plugin dir, manifest, Go stub, empty slide-editor scene |
| ✅ done | `019dc0bc2f387f78a768e12e2da8f7b5` | Slide document model: types + tile layouts + mixed content |
| ⏭ next | `019dc0bc3ca07970b3cbce37093a89a4` | Slide editor UI: list panel + canvas + tile manipulation |
| backlog | `019dc0bc46997bd488ffbcf4acb18ca4` | Reveal script: per-slide annotation IDs revealed on next-press |
| 🚧 | `019dc0bc54227391b5162f6324cb5338` | Fullscreen presentation mode (platform-dep) |
| 🚧 | `019dc0bc69087f45ba23a4045b435e78` | Pen input capture (substrate-dep) |
| backlog | `019dc0bc768a7fc19c7ab73009762231` | MCP tools: create/edit/reorder slides, start, navigate, render thumbnail |
| 🚧 | `019dc0bc824a7d8d9d238526c6835de0` | Scenario validation: 10-slide deck end-to-end with annotations + pen ink |

T7 (MCP tools) is independent of T3/T4 and can interleave if you want the LLM-edit path live before the human-edit UI.

T5 (fullscreen) was previously marked substrate-blocked, but the user's clarification on 2026-05-03 — "near-fullscreen popup window with a top bar, not OS-fullscreen" — likely sidesteps the substrate gap (Godot can spawn a `Window` node directly from the panel without needing platform support). Worth re-checking T5's blocked status when picked up.

### Substrate-side prereqs (still backlog)

Filed under DCR-2's plan, NOT the presentation plan. Both `backlog`:

- `019dc0ebf9d5797a82af41edd4c8c180` — "ink_stroke primitive: ordered points with pressure/tilt"
- `019dc0ec06f77301858eed9cc22bb116` — "Live-authoring API: batched high-frequency writes for pen-stroke capture"

Unblock these before starting T6 (pen input capture).

## Schema locked for v1 (T2)

- `version: 1`, `aspect: "16:9"` (4:3 / 1:1 also valid in `ASPECTS_VALID`)
- Slides: `{id, title?, background, tiles[], reveal[]}` — title omit-when-default; reveal is for T4
- Background: `{kind: "color"|"image", value: "#hex" | base64-png}`
- Tiles use 0..1 normalized slide-relative coords
- Three tile kinds: `text` (BBCode `[b]/[i]/[s]` + plain/bullet/numbered modes), `image` (base64-embedded), `spreadsheet` (mirrors `SpreadsheetCell.to_dict()` per cell — omit-when-default)
- Charts in v1 are **image tiles**, not a separate kind. Chart tile kind deferred to v2.
- Speaker notes are **annotations** (T4), not a schema field.

## Cold pickup checklist

1. `git pull` on `~/github/Minerva` (branch `user/imran/experiments/swarm`).
2. Read `Docs/pickup.md` (this file).
3. `git -C ~/github/plugins log --oneline -5` and `git -C ~/github/Minerva log --oneline -5` — both should be on a recent T2-completion commit.
4. Run the substrate regression suite:
   ```
   for t in test/annotations_v2/test_workbench_selection_sync.gd \
            test/annotations_v2/test_kind_extension_api.gd \
            test/annotations_v2/test_annotation_overlay_draw.gd; do
     godot --headless --path src --script "$t"
   done
   ```
   Expect 39 PASS / 0 FAIL.
5. Run the presentation plugin's model tests:
   ```
   godot --headless --path ~/github/Minerva/src \
     --script ~/github/plugins/presentation/test/test_slide_model.gd
   ```
   Expect 84 PASS / 0 FAIL.
6. Read the slide model: `~/github/plugins/presentation/ui/slide_model.gd` lines 19–60 (constants + constructors).
7. Start T3: transition `019dc0bc3ca07970b3cbce37093a89a4` `backlog → open → in_progress`. Implement in main context. Spawn cold reviewer at the end with file allowlist + UI checklist (BBCode rendering, drag handles, slide list reordering).

## Constraints to carry forward

- Always pass `project="minerva"` to docket MCP tools when working with substrate/plan IDs.
- Off-tree plugin scripts: class_name MUST start with the canonical prefix (for "presentation" → `Presentation_`); see memory `project_plugin_class_name_prefix_rule.md`.
- New plugin scripts: list them in BOTH `~/github/plugins/<id>/manifest.json` AND the `class_names` + `scripts` arrays inside `~/.local/share/godot/app_userdata/Minerva/plugins/plugins.json` (cached). Skipping the cached one means Godot still uses the stale list.
- JSON round-trip turns ints into floats — validators that use `x is int` will fail; accept whole-number floats in schema validators (memory: `project_godot_json_int_to_float.md`).
- Plugin Go binaries are per-machine — rebuild after `git pull` touches `*.go` (memory: `project_cad_plugin_binary.md`). Same for the presentation plugin's Go stub.
- Sub-agent mode is a per-task call (memory: `feedback_subagent_mode_per_task.md`). Don't default to `/work-cycle` for everything.
- AnnotationHost capability shape is **frozen** for canvas-sync compatibility — extend, don't rename.
- Plugin annotation code never crosses into another plugin's data — only via MCP, per the substrate's trust boundary.
- LLMs see slides as RENDERED PNGs, not raw JSON (memory: `project_presentation_llm_edit_model.md`). T7 will register `presentation_render_slide` for that path.

## Paused work (not picking up — see git/docket only if needed)

- **CAD Phase B2** is `blocked` on bug `019dec49988b7091933371908d6bbb00` ("CAD callout annotations don't properly track their edge"). Latest commit `cad@622c67c` (untested). Bug body has full theory tree + file:line pointers if/when this gets revisited. **Not on the active workplan.** B3, B4, and substrate tasks for ink/live-auth remain in backlog and will be reconsidered when their dependencies clear.

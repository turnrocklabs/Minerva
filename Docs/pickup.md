# Pickup — Presentation plugin

Last updated: 2026-05-03 (EOD, Round 1 of DRY refactor done)

## Where I left off

Active workstream: **Presentation plugin** — universal-select DRY refactor in progress. Round 1 (schema migrations) shipped; Round 2 (TileAnnotationHost adapter) is the next launch.

T3 R2 collapsed Round 1's 3-pane layout (list / canvas / inspector) into a single-canvas PowerPoint UX: tool palette (Select / Text / Image / Sheet) on a single toolbar, click-drag-to-place rubber band, inline TextEdit for text tiles, wheel-zoom (cursor-anchored, [0.25, 5.0]), middle-drag pan, Background popover, fullscreen preview Window. Round-1 files (`slide_list_panel.gd`, `tile_inspector.gd`) are kept on disk but unwired from the R2 panel — will revive when the user comes back to multi-slide ergonomics.

User's decision: **the SELECT button must reuse the substrate's universal-select tool** (AnnotationTransformTool — corner scale / edge axis-lock / rotate-ring / inside translate, via AnnotationOverlay for input dispatch + writeback). Custom drag/resize/halo code in `slide_canvas.gd` (~300 LOC) gets ripped out and replaced. The presentation host will be a full substrate citizen — supporting both tile-as-annotation rows AND real substrate kinds (callout / 2d_arrow / 2d_text) on `slide.annotations[]`. Eight work_items filed under DCR `019dc0bbd6937264880b1327c942d5b6`.

## What to do next

### Universal-select DRY refactor — work-cycle in flight

| Order | ID | Title | Status |
|---|---|---|---|
| 1a | `019def2880ba7c8886f47bf2511e73ef` | Schema: tile.rotation field | **done (Round 1)** |
| 1b | `019defbd27767cb6a679de6dd4a02c4b` | Schema: slide.annotations[] field | **done (Round 1)** |
| 2 | `019def2848547eaab2806d979429412d` | Build `Presentation_TileAnnotationHost` adapter (dual-source, substrate kinds + tile kinds) | **done (Round 2)** |
| 3 | `019def2862aa771fbbf9ef4aad55c52c` | Define `Presentation_TileKind*` AnnotationKind subclasses (geometry-only, no `render()`) | **done (Round 2)** |
| 4 | `019def28aaac79928594bff9eaa8b965` | Replace slide_canvas custom drag/resize/halo with substrate tools + AnnotationOverlay | next (Round 3, high-risk; manual) |
| 5 | `019def28c59e71309330e4421c84038e` | Tests for adapter + kinds + dual-source + signal idempotence | Round 4 |
| 6 | `019def28e6be7e358a7a80e33014e526` | HITL: end-to-end universal-select re-review (closes T3 R2) | gate |
| 7 | `019defbd4a0c7752b8e3b9bb2ab213ec` | Wire substrate AnnotationToolbar (callout / 2d_arrow / 2d_text) into SlideEditorPanel | post-HITL, pre-T4 |

Round 1 deliverables (plugins commit `e2dc967`, path-portability fix `2371d8d`):
- `slide_model.gd`: optional `tile.rotation: float` (omit-when-default) on all 3 tile constructors + `set_tile_rotation` mutator + validator updates.
- `slide_model.gd`: optional `slide.annotations: Array` (omit-when-empty) on `make_slide` + `add_annotation` / `update_annotation` / `remove_annotation` mutators + validator updates.
- `test_slide_model.gd`: 168 PASS / 0 FAIL (was 84 / 0).

Round 2 deliverables (5 new files in `~/github/plugins/presentation/ui/`):
- `presentation_tile_kind_base.gd` — `Presentation_TileKindBase extends AnnotationKind`. Geometry-only adapter (bounds, hit_test, transform_annotation, primary_anchor_point); `has_visual_render()` → false; no `render()`.
- `presentation_tile_kind_{text,image,spreadsheet}.gd` — thin subclasses; `extends "presentation_tile_kind_base.gd"` (string-path; sibling class_name fails for off-tree per `feedback_off_tree_plugin_class_names.md`).
- `presentation_tile_annotation_host.gd` — `Presentation_TileAnnotationHost extends AnnotationHost`. Dual-source `get_annotations()` (synthesized tile annotations + persisted `slide.annotations[]`); routes `update/add/remove` by kind discriminator (`presentation_tile_*` → tile writeback; substrate kinds → `slide_model` mutators); `set_selected_annotation_id` emits `selection_changed` only on actual change; `_init` registers BuiltinKinds + 3 tile kinds.
- `manifest.json`: 5 new files appended to `ui.panels[0].scripts`.
- Smoke test verified end-to-end: tile (0.1, 0.1, 0.3, 0.2) on 1920×1080 → rect_px (192, 108, 576, 216); translate(+100, 0) writes back tile.x = 0.1521; callout add persists to slide.annotations[].
- Tests still 168/0 + 39/0 (Round 4 will add new integration tests).

Defect log (caught by orchestrator, not implementer):
- Round 1: `set_tile_rotation` was self-reported as added but missing from source; tests script-errored silently. Found by Opus reviewer running tests with stderr capture.
- Round 2: Subclasses used `extends Presentation_TileKindBase` (sibling class_name) — fails parse for off-tree plugins. Found by orchestrator smoke test before reviewer launch. Fix: `extends "presentation_tile_kind_base.gd"`. Nudge hint saved under `minerva-plugin-platform/off_tree_extends_pattern`.

DCR: `019dc0bbd6937264880b1327c942d5b6`
Plan: `019dc0bbfcc57d81b4ac1300d4923094`
T3 work_item (still in_progress): `019dc0bc3ca07970b3cbce37093a89a4` — see comment 315 for full R2-end state.

**Substrate tools to reuse (read these first):**
- `~/github/Minerva/src/Scripts/Services/Annotations/kinds/AnnotationSelectTool.gd` (152 LOC)
- `~/github/Minerva/src/Scripts/Services/Annotations/kinds/AnnotationTransformTool.gd` (521 LOC) — unified SRT gizmo with zone enum (CORNER_TL/TR/BL/BR, EDGE_T/B/L/R, ROTATE_TL/TR/BL/BR, INSIDE, OUTSIDE)
- `~/github/Minerva/src/Scripts/Services/Annotations/AnnotationHost.gd` (interface contract)
- `~/github/Minerva/src/Scripts/Services/Annotations/AnnotationKind.gd` (hit_test, bounds)

**Reference for the existing R2 canvas (the thing being refactored):**
- `~/github/plugins/presentation/ui/slide_canvas.gd` (973 LOC; DragMode.MOVE/RESIZE/PLACE, custom dashed halo `_draw()`, cursor-anchored wheel zoom, inline TextEdit overlay)
- `~/github/plugins/presentation/ui/SlideEditorPanel.gd` (panel orchestrator, tool palette wiring, fullscreen Window spawn)
- `~/github/plugins/presentation/ui/slide_model.gd` (validators + constructors — the `tile.rotation` schema migration lives here)

### Stretch / deferred

- `019dc0bc46997bd488ffbcf4acb18ca4` — T4 Reveal script (annotation-id sequencing on next-press)
- `019dc0bc54227391b5162f6324cb5338` — T5 Fullscreen mode (the `Window` approach in R2 likely closes this)
- `019dc0bc69087f45ba23a4045b435e78` — T6 Pen input (substrate-blocked)
- `019dc0bc768a7fc19c7ab73009762231` — T7 MCP tools (independent; can interleave)
- Stretch: modal SpreadsheetEditor for in-tile cell editing
- Stretch: drag-to-reorder slides (Round 1 had up/down buttons; reorder UX never picked back up)

## Cold pickup checklist

1. `git pull` on `~/github/Minerva` (branch `user/imran/experiments/swarm`).
2. `git -C ~/github/plugins pull` (presentation plugin lives in the plugins monorepo).
3. Read `Docs/pickup.md` (this file).
4. `git -C ~/github/plugins log --oneline -5` and `git -C ~/github/Minerva log --oneline -5` — both should show today's WIP commits at the head.
5. Run substrate regression suite:
   ```
   for t in test/annotations_v2/test_workbench_selection_sync.gd \
            test/annotations_v2/test_kind_extension_api.gd \
            test/annotations_v2/test_annotation_overlay_draw.gd; do
     godot --headless --path src --script "$t"
   done
   ```
   Expect 39 PASS / 0 FAIL.
6. Run presentation plugin's model tests:
   ```
   godot --headless --path ~/github/Minerva/src \
     --script ~/github/plugins/presentation/test/test_slide_model.gd
   ```
   Expect 84 PASS / 0 FAIL.
7. Read the canvas to refactor: `~/github/plugins/presentation/ui/slide_canvas.gd` (focus on DragMode handling, `_draw()` halo, hit-test loop).
8. Pick up work_item `019def2880ba7c8886f47bf2511e73ef` (schema migration first — smallest, unblocks the chain).

## Schema (locked through R2 — rotation field pending)

- `version: 1`, `aspect: "16:9"` (4:3 / 1:1 also valid in `ASPECTS_VALID`)
- Slides: `{id, title?, background, tiles[], reveal[]}` — title omit-when-default; reveal is for T4
- Background: `{kind: "color"|"image", value: "#hex" | base64-png}`
- Tiles use 0..1 normalized slide-relative coords
- Three tile kinds: `text` (BBCode `[b]/[i]/[s]` + plain/bullet/numbered modes), `image` (base64-embedded), `spreadsheet` (mirrors `SpreadsheetCell.to_dict()` per cell — omit-when-default)
- **Pending v1.x**: optional `rotation: float = 0.0` on tile, omit-when-default. Backwards-compat with existing decks.
- Charts in v1 are **image tiles**, not a separate kind. Chart tile kind deferred to v2.
- Speaker notes are **annotations** (T4), not a schema field.

## Constraints to carry forward

- Always pass `project="minerva"` to docket MCP tools when working with substrate/plan IDs.
- Off-tree plugin scripts: class_name MUST start with the canonical prefix (for "presentation" → `Presentation_`); see memory `project_plugin_class_name_prefix_rule.md`.
- New plugin scripts: list them in BOTH `~/github/plugins/<id>/manifest.json` AND the cached `~/.local/share/godot/app_userdata/Minerva/plugins/plugins.json` (`class_names` + `scripts` arrays). Skipping the cached one means Godot uses the stale list.
- JSON round-trip turns ints into floats — validators that use `x is int` will fail; accept whole-number floats (memory: `project_godot_json_int_to_float.md`). The new `tile.rotation` validator must follow this rule.
- `:=` inference fails through `preload()`-imported Scripts; use explicit type annotations on locals like `var preview: Control = _SlideCanvas.new()` (nudge: `walrus_inference_through_preload`).
- Plugin Go binaries are per-machine — rebuild after `git pull` touches `*.go` (memory: `project_cad_plugin_binary.md`).
- AnnotationHost capability shape is **frozen** for canvas-sync compatibility — extend, don't rename.
- Plugin annotation code never crosses into another plugin's data — only via MCP, per the substrate's trust boundary.
- LLMs see slides as RENDERED PNGs, not raw JSON (memory: `project_presentation_llm_edit_model.md`). T7 will register `presentation_render_slide` for that path.
- White-on-white text fix in R2: RichTextLabel needs `default_color` theme override; Label needs `font_color`; TextEdit needs StyleBoxFlat with white bg + dark text + cyan border. Don't regress this when refactoring.

## Paused work (not picking up — see git/docket only if needed)

- **CAD Phase B2** is `blocked` on bug `019dec49988b7091933371908d6bbb00` ("CAD callout annotations don't properly track their edge"). Latest commit `cad@622c67c` (untested). Bug body has full theory tree + file:line pointers if/when this gets revisited. **Not on the active workplan.** B3, B4, and substrate tasks for ink/live-auth remain in backlog.

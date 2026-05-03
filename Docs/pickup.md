# Pickup — Presentation plugin

Last updated: 2026-05-03 (EOD)

## Where I left off

Active workstream: **Presentation plugin** — T3 Round 2 PowerPoint-style rewrite shipped, but a substrate-DRY refactor of the SELECT tool is now blocking the HITL re-review sign-off.

T3 R2 collapsed Round 1's 3-pane layout (list / canvas / inspector) into a single-canvas PowerPoint UX: tool palette (Select / Text / Image / Sheet) on a single toolbar, click-drag-to-place rubber band, inline TextEdit for text tiles, wheel-zoom (cursor-anchored, [0.25, 5.0]), middle-drag pan, Background popover, fullscreen preview Window. Round-1 files (`slide_list_panel.gd`, `tile_inspector.gd`) are kept on disk but unwired from the R2 panel — will revive when the user comes back to multi-slide ergonomics.

User's last decision: **the SELECT button must reuse the substrate's universal-select tool** (AnnotationSelectTool + AnnotationTransformTool — corner scale / edge axis-lock / rotate-ring / inside translate). Custom drag/resize/halo code in `slide_canvas.gd` (~300 LOC) gets ripped out and replaced. Six work_items filed under DCR `019dc0bbd6937264880b1327c942d5b6` covering the integration.

## What to do next

### Recommended next cycle: full-DRY universal-select integration

Pick up the 6 work_items in this order — they form a chain:

| Order | ID | Title |
|---|---|---|
| 1 | `019def2880ba7c8886f47bf2511e73ef` | Schema migration: add optional `tile.rotation` (do this first — adapter needs it) |
| 2 | `019def2848547eaab2806d979429412d` | Build `Presentation_TileAnnotationHost` adapter |
| 3 | `019def2862aa771fbbf9ef4aad55c52c` | Define AnnotationKind subclasses for tile kinds |
| 4 | `019def28aaac79928594bff9eaa8b965` | Replace slide_canvas custom drag/resize/halo with substrate tools |
| 5 | `019def28c59e71309330e4421c84038e` | Tests for adapter + kinds |
| 6 | `019def28e6be7e358a7a80e33014e526` | HITL: end-to-end universal-select tool re-review (closes T3 R2) |

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

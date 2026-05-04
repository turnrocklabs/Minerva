# Pickup — Presentation plugin

Last updated: 2026-05-03 (EOD; Round 3 HITL polish landed; MCP interface is the next workstream)

## Where I left off

Active workstream: **Presentation plugin** — universal-select DRY refactor functionally complete. Round 3 (substrate integration) shipped and went through several rounds of HITL fixes. Codex pitched in to split the host responsibility cleanly. Next session pivots to **T7 MCP tools** (`019dc0bc768a7fc19c7ab73009762231`).

## What changed this session (post-Round-3 HITL polish)

Both repos have uncommitted work that lands in this session's WIP commit.

### Plugins repo (`~/github/plugins`)

- **`presentation_tile_annotation_host.gd`** — Codex added `configure_surface(include_tiles: bool, include_substrate_annotations: bool)` so the host can be reconfigured to be tile-only (canvas) vs substrate-only (panel chrome). Selection prune routine respects the configured surfaces. **Preserve this — do not undo.**
- **`SlideEditorPanel.gd`** — Codex moved the substrate `AnnotationHost` ownership up to the panel itself. Panel host calls `configure_surface(false, true)` (substrate kinds only); canvas keeps a separate host with `configure_surface(true, false)` (tile kinds only). Panel registers/deregisters with `AnnotationHostRegistry` on plugin load/unload. Coupled via the new `slide_canvas.slide_rect_changed` signal so substrate annotations on `slide.annotations[]` keep the right pixel rect. Panel also overrides `Editor.get_annotation_host()` so the AnnotationDockPane mounts.
- **`presentation_tile_kind_base.gd`** — minor (Codex touched).
- **`slide_canvas.gd`** —
  - Codex added `slide_rect_changed` signal + a `get_host()` helper so the panel can sync.
  - Today: shrunk default click-place size for TEXT tool (`CLICK_PLACE_NORM_W` 0.35→0.10, `CLICK_PLACE_NORM_H` 0.20→0.045 — H bisected after two rounds of "too big" / "too small").
  - Today: hooked `TextEdit.text_changed` → new `_autosize_text_tile_x()`. Inline edit grows tile.w only on X to fit the widest typed line (font-measured via `get_string_size`); never shrinks during a single edit, never touches Y. Y-overflow is intentional per user's "X-only" directive.

### Minerva repo (`~/github/Minerva`)

- **`src/Scripts/UI/Views/EditorPane.gd`** — added `_on_tab_bar_gui_input` + `_show_rename_tab_dialog`. Double-click any editor tab now pops a small rename dialog; Enter/OK applies, blank/unchanged is a no-op. For `Editor` controls the new value goes through the `tab_title` setter (so AnnotationHostRegistry re-keys correctly); for non-Editor children it falls back to `Tabs.set_tab_title`. Works for every editor type, not just presentation.

### Docs / artifacts

- `/tmp/butter_tarts.mdeck` — hand-authored demo deck (1 slide; BBCode-large title tile + bullet outline tile). Validates that the `.mdeck` JSON is straightforward enough for an MCP write path.

## What to do next

### T7 MCP tools — promoted to active

Work_item `019dc0bc768a7fc19c7ab73009762231`. See its docket comment 318 for the suggested initial tool surface and implementation site (`src/Scripts/Services/MCP/Modules/MCPPresentationTools.gd`, pattern-match `MCPEditorTools.gd`).

Suggested first cut:
- `presentation_create_deck(path, title?)`
- `presentation_open_deck(path)`
- `presentation_add_slide(deck_path|tab, position?, title?)`
- `presentation_add_text_tile(deck_path|tab, slide_index, x, y, w, h, content, text_mode)`
- `presentation_add_image_tile(deck_path|tab, slide_index, x, y, w, h, image_path|base64)`
- `presentation_set_slide_background(deck_path|tab, slide_index, color|image_path)`
- `presentation_render_slide(deck_path|tab, slide_index) → PNG` (LLM vision path per `project_presentation_llm_edit_model.md`)

### HITL polish still open (deferred until after MCP scope)

Tracked on `019def28e6be7e358a7a80e33014e526` (comment 317). Items:
- Scale gizmo: drag corner translates instead of scales. Root cause unknown — may be substrate's scale-around-center vs opposite-corner UX choice.
- Rotate gizmo: visual rotation not applied to tile views (tile.rotation field updates but RichTextLabel / TextureRect / GridContainer don't apply `Control.rotation` in `_layout_views`).
- Save/load round-trip of rotation not yet manually verified.
- Fullscreen Window with rotated tiles not yet re-verified.

### Universal-select DRY refactor — work_items recap

| Order | ID | Title | Status |
|---|---|---|---|
| 1a | `019def2880ba7c8886f47bf2511e73ef` | Schema: tile.rotation field | done (R1) |
| 1b | `019defbd27767cb6a679de6dd4a02c4b` | Schema: slide.annotations[] field | done (R1) |
| 2 | `019def2848547eaab2806d979429412d` | TileAnnotationHost adapter | done (R2) |
| 3 | `019def2862aa771fbbf9ef4aad55c52c` | TileKind subclasses | done (R2) |
| 4 | `019def28aaac79928594bff9eaa8b965` | slide_canvas substrate rewire | done (R3 + HITL polish) |
| 5 | `019def28c59e71309330e4421c84038e` | Tests for adapter + kinds + dual-source | Round 4 (deferred) |
| 6 | `019def28e6be7e358a7a80e33014e526` | HITL: end-to-end SRT re-review | partial; gizmo issues open |
| 7 | `019defbd4a0c7752b8e3b9bb2ab213ec` | Wire substrate AnnotationToolbar | post-HITL, pre-T4 |
| **T7** | **`019dc0bc768a7fc19c7ab73009762231`** | **MCP tools** | **next-up** |

DCR: `019dc0bbd6937264880b1327c942d5b6`
Plan: `019dc0bbfcc57d81b4ac1300d4923094`

## Cold pickup checklist

1. `git pull` on `~/github/Minerva` (branch `user/imran/experiments/swarm`).
2. `git -C ~/github/plugins pull` (branch `main`).
3. Read `Docs/pickup.md` (this file).
4. `git -C ~/github/plugins log --oneline -5` and `git -C ~/github/Minerva log --oneline -5` — both should show today's WIP commits at the head.
5. Substrate regression suite (sanity):
   ```
   for t in test/annotations_v2/test_workbench_selection_sync.gd \
            test/annotations_v2/test_kind_extension_api.gd \
            test/annotations_v2/test_annotation_overlay_draw.gd; do
     godot --headless --path src --script "$t"
   done
   ```
   Expect 39 PASS / 0 FAIL.
6. Plugin model tests (sanity):
   ```
   godot --headless --path ~/github/Minerva/src \
     --script ~/github/plugins/presentation/test/test_slide_model.gd
   ```
   Expect 168 PASS / 0 FAIL (post-Round-1).
7. Open Minerva, double-click any editor tab to confirm rename dialog still works.
8. Open `/tmp/butter_tarts.mdeck` to confirm slide renders (title tile + bullet outline).
9. Read `~/github/Minerva/src/Scripts/Services/MCP/Modules/MCPEditorTools.gd` as the pattern.
10. Pick up work_item `019dc0bc768a7fc19c7ab73009762231` (T7 MCP tools).

## Schema

- `version: 1`, `aspect: "16:9"` (`4:3` / `1:1` also valid)
- Slide: `{id, title?, background, tiles[], reveal[], annotations?}` — title and annotations both omit-when-default
- Background: `{kind: "color"|"image", value: "#hex" | base64-png}`
- Tiles use 0..1 normalized slide-relative coords
- Three tile kinds: `text` (BBCode + plain/bullet/numbered modes), `image` (base64-embedded), `spreadsheet`
- Optional `rotation: float = 0.0` on tile (omit-when-default; v1.x)
- Speaker notes are **annotations** on `slide.annotations[]` (T4), not a schema field
- File extension: `.mdeck`

## Constraints to carry forward

- Always pass `project="minerva"` to docket MCP tools when working with substrate/plan IDs.
- Off-tree plugin scripts: class_name MUST start with `Presentation_`. For `extends` between sibling plugin scripts use string-path (`extends "foo.gd"`), NOT class_name (memory: `feedback_off_tree_plugin_class_names.md` + nudge `off_tree_extends_pattern`).
- New plugin scripts: list them in BOTH `~/github/plugins/<id>/manifest.json` AND the cached `~/.local/share/godot/app_userdata/Minerva/plugins/plugins.json`.
- JSON round-trip turns ints into floats — validators that use `x is int` will fail; accept whole-number floats (memory: `project_godot_json_int_to_float.md`).
- AnnotationHost capability shape is **frozen** for canvas-sync compatibility — extend, don't rename.
- Plugin annotation code never crosses into another plugin's data — only via MCP, per the substrate's trust boundary.
- LLMs see slides as RENDERED PNGs, not raw JSON (memory: `project_presentation_llm_edit_model.md`). T7 MCP `presentation_render_slide` will own that path.
- White-on-white text fix in R2: RichTextLabel needs `default_color` theme override; Label needs `font_color`; TextEdit needs StyleBoxFlat with white bg + dark text + cyan border. Don't regress.
- AnnotationOverlay does NOT call `tool.on_activate(host)` — caller must do it explicitly (nudge `substrate_tool_on_activate_required`; substrate chore filed for overlay to own this).
- Codex's host separation pattern (panel = substrate-only host, canvas = tile-only host, coupled via `slide_rect_changed`) is load-bearing — do not collapse back to a single host.

## Paused work (not picking up — see git/docket only if needed)

- **CAD Phase B2** is `blocked` on bug `019dec49988b7091933371908d6bbb00` ("CAD callout annotations don't properly track their edge"). Latest commit `cad@622c67c` (untested). Bug body has full theory tree + file:line pointers if/when this gets revisited. **Not on the active workplan.** B3, B4, and substrate tasks for ink/live-auth remain in backlog.

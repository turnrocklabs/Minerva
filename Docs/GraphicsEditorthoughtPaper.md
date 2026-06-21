# Graphics Editor Thought Paper: Toward a Leonardo-class Infinite Canvas

> Status: thinking / design exploration. Not a committed spec.
> Audience: humans and the LLMs that will implement this.
> Scope: the **V2** graphics editor (`src/Scripts/UI/Controls/GraphicsEditor/`), which is the
> canonical, AI-native editor. The older `GraphicsEditor.gd` is abandoned and out of scope.

## 1. Why this paper exists

Minerva's V2 graphics editor is already an AI-native image editor — typed layers, a real
tool state machine, selections with marching ants, a layer chooser, and an LLM/MCP-driven
media-generation pipeline. But its **infinite canvas does not feel good**. Drawing near the
edge of a layer causes the layer to lurch and reallocate; layers are independent rectangles
that must be positionally aligned; transforms resample destructively.

By contrast, the drawing app **Leonardo** has an infinite canvas that "just works" — you can
draw anywhere, forever, and layers stay coherent without any sense of bounds.

This paper captures: what Leonardo does, what Minerva does today, why the difference exists,
and a concrete, incrementally-adoptable concept for closing the gap — **without** breaking
Minerva's AI/media-gen contracts.

The work is anchored to one driving scenario (Section 5): a human and an AI iterating on a
single image, where the human's strokes are allowed to overflow the original image bounds and
the AI then redraws at the new, larger size.

## 2. Background: Leonardo

Leonardo is an installed Windows pen-drawing app (`leonardo.0.17.70.win64.exe`). Despite an
initial assumption that it was C#, the binary tells a different story:

- Native x86-64, **Qt5** only as the windowing shell.
- Leaked debug source paths reveal it is a **C** application (author root `C:\xade\code\...`).
  So decompiling "back to clean source" is neither possible nor the point — we want its
  **architecture and feel** as inspiration, expressed as a spec our own implementers can use.

The leaked module names map out its architecture directly:

```
brush\br_tile.c              server\sv_composite_tile.c    server\sv_layer.c
p_canvas.c  p_layer.c  p_zoom.c    ui_canvas.c  ui_layer.c    utilities\blend.c  im_mask.c
```

Key takeaways:

- **Tile-based canvas** (`br_tile.c`, `sv_composite_tile.c`, "dabs, tiles"). This is the root
  of the infinite feel.
- **Client/server split** (`sv_*`) — a compositor server composites tiles independently of
  the UI, keeping painting responsive.
- **OpenEXR tiled I/O** is linked in.
- **Layer model**: `FLAGS · INDEX · GROUP · BLEND · NAME`, and layers contain "nodes." It has
  **groups** and **blend modes** — both things Minerva still lacks.
- A stroke **stabilizer** (`/options/stabilizer/`) is a meaningful part of the "feel."

### 2.1 How Leonardo's canvas works

The world is conceptually **infinite**, anchored at a single global origin.

- Each layer is a **sparse set of fixed-size tiles** (e.g. 64²/128²), keyed by integer tile
  coordinate. Only tiles that have actually been painted exist in memory.
- Painting past an "edge" simply **allocates new tiles on demand**. There is no giant buffer to
  reallocate, no content to shift, no resample.
- **All layers share one global tile grid**, so they are aligned *by construction*. There is no
  "align the layers" operation — coincident tile coordinates are coincident pixels.
- The visible **canvas frame** is just an **export/output rectangle**. It does not bound where
  you may paint. ("Set canvas frame rectangle" exists as an explicit, separate concept in the
  binary's command tree.)

The consequence: drawing is edgeless and smooth, memory scales with painted area (not with the
bounding box), and layer compositing is a per-tile operation.

## 3. How Minerva V2's canvas works today

Reading the V2 code, the situation is a sharp split: **the view is already infinite; the
content is not.**

### 3.1 The view (good — keep it)

Pan and zoom operate on a `Camera2D` (`input_area_camera`) inside a `SubViewport`
(`GraphicsEditorV2._gui_input`, `_pan_canvas`, `_zoom`):

- Zoom is **cursor-anchored**: `_zoom()` records the world position under the mouse, applies the
  zoom factor, then repositions the camera so that same world point stays under the cursor.
- Zoom is clamped to `[MIN_ZOOM, MAX_ZOOM]`; pan scales by `1 / zoom` so it feels constant at any
  zoom level.

This is genuinely a Leonardo-like infinite *viewport* and should be preserved.

### 3.2 The content (the problem)

Each `LayerV2 extends Control` holds **one finite `Image`** rendered through a child
`texture_rect` (`LayerV2._update_texture_from_image`). On `setup()`, Background / Canvas /
Drawing layers are all created at one fixed square size.

When a stroke leaves a layer's image bounds, `LayerV2.expand_to_point()` runs:

1. Computes a new size, **rounded up to a multiple of 64** (because generative models want
   64-aligned dimensions).
2. Allocates a brand-new `Image`.
3. `blit_rect`s the old pixels into it.
4. **Shifts the layer's position** to compensate so existing content doesn't visually move.

And `_adjust_control_size()` (transform tool) **Lanczos-resamples** the entire image when a
layer is resized.

### 3.3 Why it feels terrible

| Symptom | Root cause in code |
|---|---|
| Hitch / stutter when drawing past an edge | Full `Image` allocate + `blit_rect` mid-stroke in `expand_to_point` |
| Surface "lurches" rather than extends | Growth quantized to multiples of 64 |
| Layers must be manually aligned | Each layer is its own rectangle at its own size/position; no shared origin |
| Resizing degrades quality / is slow | `_adjust_control_size` resamples the whole image with Lanczos |
| Memory tied to bounding box, not painted area | Single dense `Image` per layer |

This is precisely the "create bounded layer regions, then align them" experience the canvas
should not have.

## 4. Concept: tile the strokes, keep the AI images whole

The core realization: **Minerva is closer than it feels.** The infinite view already exists;
only the **raster storage of hand-drawn layers** is wrong. The fix is local, and it respects a
hard constraint of the AI pipeline.

### 4.1 The AI constraint (why we do NOT unify everything)

Generative media-gen returns **full images, not deltas/brush-strokes**, and the `MediaGen`
service takes an **input image**, not a layer. Masks are therefore **paired to a specific image
layer** (the drag-link `linked_mask_layer` mechanism) rather than being a single global
selection. This asymmetry is intentional and must be preserved.

This maps cleanly onto Minerva's existing layer **types**:

- `IMAGE` layers are AI output → naturally **full, bounded images**. Leave them as a single
  `Image`. (They are full images *because* that's what generation produces.)
- `DRAWING` and `MASK` layers are **human deltas** → these are the layers that call
  `expand_to_point` and feel bad. **These are the ones to tile.**

So the design is a **hybrid**, and the hybrid boundary is the layer type — not a compromise but
a direct reflection of how human and AI content differ.

### 4.2 The proposal

**Tile the `DRAWING` and `MASK` layer raster; leave `IMAGE` layers as single images; composite
to a full `Image` at the AI/export boundary.**

1. **Tiled raster backing.** Replace a drawing/mask layer's single `image: Image` with a sparse
   `Dictionary[Vector2i → Image]` of fixed-size tiles (start with 128² or 256²). All tiled
   layers share **one global tile coordinate system** anchored at the world origin.

2. **Paint.** Map a world pixel to `(tile_coord, in-tile offset)`; lazily create the tile if it
   does not exist; write pixels into it; mark it dirty. No realloc, no position shift, no
   64-pixel jump, no bound. Drawing is infinite by construction, and all tiled layers are aligned
   automatically.

3. **Render.** A custom `_draw()` (or cached per-tile `ImageTexture`s) draws only the tiles that
   exist, each at its grid position. A tile's texture is regenerated only when its dirty flag is
   set. This is the analogue of Leonardo's `sv_composite_tile.c`.

4. **Composite-to-Image at the boundary (preserves the AI contract).** Keep the existing
   `image` getter, but have it **rasterize the relevant tile region into one `Image`** — the
   canvas frame rectangle, or the painted bounding box padded up to a multiple of 64. `MediaGen`,
   `compose_final_image`, save-as-PNG, and send-to-Note keep receiving exactly the full image they
   expect today. **Tiling is invisible above this line.**

5. **Frame rectangle as output, not bound.** Adopt Leonardo's distinction: a movable/resizable
   "frame" defines what gets exported or sent to AI, decoupled from where the human may paint.

### 4.3 What explicitly does NOT change

- The `Camera2D` / `SubViewport` view and its cursor-anchored zoom.
- `IMAGE` layers (single `Image`), positioned in the same global grid as tiled layers.
- The media-gen pipeline: mask pairing (`linked_mask_layer`), `MediaGen.generate_mask_bytes`,
  `send_media_selective_edit_request`, the `MODEL_METADATA`/action model, and MCP
  (`execute_ai_action` / `get_ai_capabilities`).

### 4.4 Deliberately deferred (related, not required first)

- **Blend modes + per-layer opacity** (Leonardo's `BLEND` column; today V2's `_blend_colors` is a
  plain over-composite).
- **Layer groups** (Leonardo's `GROUP`).
- **Stroke stabilizer** and dab-spacing for brush feel.
- **Non-destructive transforms** (replace the Lanczos resample on resize with a view transform).

### 4.5 Smallest viable first step

*(Full prototype spec in §6.)* Prototype a `TiledRaster` backing class behind the `image` getter
on the **Drawing layer only**:

- Route the brush tool's pixel writes through `TiledRaster.set_pixel` / stroke API.
- Render dirty tiles via cached per-tile textures.
- Implement `TiledRaster.to_image(region)` for the export/AI path.
- Leave the camera, `IMAGE` layers, mask pairing, and compose untouched.

If the feel is right on one layer type, extend to `MASK`.

## 5. Driving scenario: Human + AI on one image

This is the end-to-end experience the design must make effortless. Each step notes what makes it
"just work" under the proposal.

1. **Human prompts for an image.** Human types a prompt; `MediaGen` generates.
2. **Image created.** Result lands as an `IMAGE` layer — a single full image at the model's
   output resolution, placed at the world origin in the shared grid.
3. **Human draws past the image's bounds.** The active **`DRAWING` layer is tiled**, so strokes
   that extend beyond the original image simply allocate new tiles. *No realloc, no lurch, no
   64-jump — it just works,* and the new strokes are spatially aligned to the AI image because
   both share the global grid.
4. **Human asks AI to redraw, considering the strokes.** On send, the editor **composites the
   region** — the union of the AI image and the painted tiles' bounding box — into one `Image`,
   padded to a multiple of 64. That single composited image (optionally with a paired mask) is
   what goes to `MediaGen`. The human never thinks about tiles or sizes.
5. **AI redraws at the new, larger size.** Because step 4 produced a correctly-sized full image
   that already includes the overflow region, the model regenerates at the new dimensions with the
   human's strokes as context. The returned full image becomes a new `IMAGE` layer in the same
   grid — and the loop can continue.

The throughline: **humans paint on an infinite tiled surface; the AI boundary flattens the
relevant region into the full image generation requires.** Infinite feel for the human, full-image
contract for the model — no conflict.

### 5.1 Worked example: the cartoon cat

A concrete run of the scenario, mapped to layer types and tile behavior at each step.

**Narrative.** "Draw a cartoon cat sitting on a couch." The human gets one. They then add a
speech balloon saying *"Meow"*, paint stripes onto the cat, reshape its whiskers, and notice the
**tail is cut off by the original crop**. They draw the tail's extension *past the image's right
edge*. Finally they composite everything and ask the LLM to redraw the cat consistently: clean up
and shrink the balloon, make the painted-on changes feel native to the original art, **extend the
canvas to include the tail along the edge they defined**, and re-ink so the whole thing reads as
one coherent drawing.

| # | Human action | Layer(s) involved | What happens internally |
|---|---|---|---|
| 1 | Prompt: "cartoon cat on a couch" | — | `MediaGen` `create` action; prompt → image. |
| 2 | Receives the cat | `IMAGE` (e.g. 1024×768) | Single full `Image`, placed at the world origin in the shared grid. **Stays whole** (AI output is a full image). |
| 3a | Adds a "Meow" balloon | `SPEECH_BUBBLE` | A vector-ish balloon layer, positioned over the cat. Not tiled, not rasterized yet. |
| 3b | Paints stripes / reshapes whiskers *on top of* the cat | `DRAWING` (tiled) | Strokes land in tiles overlapping the cat's footprint. Same global grid → pixel-aligned with the `IMAGE` layer with zero alignment work. |
| 3c | Draws the **tail extension past the right edge** | same `DRAWING` (tiled) | Strokes beyond the cat image simply **allocate new tiles**. No realloc, no lurch, no 64-jump. The painted region's bounding box now extends past the original image. |
| 4 | "Composite and redraw consistently" | all of the above | Editor computes the **union region** (cat image ∪ painted tiles ∪ balloon), pads it up to a multiple of 64, and flattens it into **one input `Image`**. |
| 5 | AI returns the redrawn cat | new `IMAGE` | Full image at the **new, larger** dimensions (now including the tail area). Added as a new layer in the same grid; the iteration loop can continue. |

**Why step 3c "just works."** The tail is drawn on a tiled `DRAWING` layer, so "past the edge" is
not a special case — it is the *normal* case of touching an unallocated tile. The original `IMAGE`
layer is untouched and does not reallocate. The human never sees a boundary.

**The composite at step 4 (the crux).** This is the human-infinite → AI-full-image boundary doing
its job:

- **Region = union, not the original frame.** Because the painted bounding box now extends right
  (the tail) — and possibly down (the couch) — the composited image is *larger* than the original
  cat. That larger size is precisely the "zoom out to include the tail" the human asked for; it
  falls out of the geometry, not a manual canvas-resize.
- **Padding to ×64** happens only here, at the boundary — never on the layers themselves.
- **Flattening order** respects the layer stack: `IMAGE` (cat) → `DRAWING` (stripes/whiskers/tail)
  → `SPEECH_BUBBLE` ("Meow"), composited top-down into the input image.

**This is an `edit`, not a `mask_edit`.** The human wants the *whole* image reinterpreted
("make it all consistent"), so no `linked_mask_layer` is involved. The request is image-to-image:
**composited image + an instruction prompt**, using the model's `edit` action. The instruction
carries the intent ("clean and shrink the speech balloon, integrate the painted changes, re-ink for
consistency, keep the extended tail"). Contrast this with the masked flow (Section on media-gen),
which is for *localized* edits to a specific image layer.

**The harmonization knob.** "Make my painted strokes feel like part of the original" is governed by
**denoise strength** (the `denoise` param, default `0.75`). Lower denoise preserves the human's
exact strokes but harmonizes less; higher denoise re-renders more aggressively into a single
coherent style at the cost of stroke fidelity. This example is the canonical case for surfacing
denoise (and `cfg`) as a visible "how much should the AI reinterpret vs. preserve?" control.

**Design decisions this example surfaces:**

- **Speech bubble: rasterize or re-vector?** To let the AI "clean up the balloon," the balloon must
  be *in* the composited image (rasterized). But the human may still want a crisp, editable vector
  balloon afterward. Option: send the rasterized balloon to the AI for styling reference, but keep
  the original `SPEECH_BUBBLE` layer live and re-overlay it (optionally restyled) on the returned
  image, rather than baking the AI's raster balloon permanently.
- **What defines the output extent?** Here it is the painted union (auto-grow to include the tail).
  We likely also want an explicit, draggable **frame rectangle** so the human can say "include this
  much margin around the tail" rather than relying solely on stroke bounds.
- **Result is a new layer, not an overwrite.** Returning the redraw as a *new* `IMAGE` layer
  preserves the human's `DRAWING`/`SPEECH_BUBBLE` layers for further iteration or A/B comparison;
  the old composite inputs are not destroyed.
- **Coordinate continuity across the loop.** The new (larger) `IMAGE` must be positioned so its
  content still aligns to the same world origin the human painted against, so a *subsequent* round
  of strokes still lands where expected.

## 6. TiledRaster prototype spec

This section specifies the smallest change that delivers Leonardo-like drawing feel: a sparse,
tile-based raster backing for **`DRAWING`** layers (then `MASK`), leaving `IMAGE` layers and the
camera/view untouched. It is written to be implementable directly against the current V2 code.

### 6.1 What today's code does (the call-sites we are replacing)

The entire stroke path is sized to the **whole layer image**:

- `LayerV2.expand_to_point()` reallocates the layer's single `Image` (rounded to ×64) and the layer
  is repositioned (`DrawingTool._start_stroke` / `_add_stroke_point` call it up to twice per event,
  emitting a `GraphicsEditorUndo.ResizeCommand`).
- `GPUBrushRenderer.initialize_buffers()` allocates **full-layer-sized** GPU textures (stroke,
  backup, output, selection) at the start of *every* stroke and frees them at the end.
- `DrawingTool._build_selection_mask()` walks **every pixel** (`O(w·h)`) to pack a selection bitmask
  per stroke.
- `DrawingTool._update_visual_preview()` calls `GPUBrushRenderer.get_output_image()` — a **full
  output-texture readback** — every ~16 ms during a stroke.

Each of these scales with the layer's bounding box. On an infinite canvas the bounding box is
unbounded, so each is a failure mode. Tiling makes **the tile** (not the layer image) the unit of
allocation, dispatch, readback, and undo.

### 6.2 Goals / non-goals

**Goals.** Edgeless drawing with no realloc/lurch/×64-jump; layers aligned by a shared origin;
memory proportional to *painted* area; a clean `to_image(region)` boundary that preserves the
full-image AI contract; drop-in behind `LayerV2.image` so unrelated code keeps working.

**Non-goals (this prototype).** Blend modes, layer groups, stabilizer, non-destructive transforms,
tiling `IMAGE` layers, GPU per-tile dispatch (Phase 2). CPU-stamp first; prove the feel.

### 6.3 Data model

```gdscript
class_name TiledRaster
extends RefCounted

const TILE: int = 256                     # tile edge in px (prototype default; tune later)
const FMT := Image.FORMAT_RGBA8

# Sparse storage. Key = tile coord in the SHARED WORLD grid (not layer-local).
# A missing key means "fully transparent, unallocated" — never materialized.
var _tiles: Dictionary = {}               # Vector2i -> Tile

class Tile:
    var image: Image                      # TILE x TILE, FMT
    var texture: ImageTexture             # cached; rebuilt only when dirty
    var dirty: bool = true                # texture needs re-upload
    var nonempty: bool = false            # has any a>0 pixel (for GC / bounds)
```

**Coordinate model.** One global tile grid shared by all tiled layers, anchored at world origin.
A world pixel `p` maps to `tile_coord = (floor(p.x / TILE), floor(p.y / TILE))` and in-tile offset
`p - tile_coord * TILE`. Because every tiled layer uses the same grid, coincident world pixels are
coincident tile slots → **layers are aligned with zero bookkeeping** and never reposition.

### 6.4 API surface

Designed so `LayerV2` (for `DRAWING`/`MASK`) holds a `TiledRaster` and exposes the same `image`
getter the rest of the code already consumes.

```gdscript
# --- pixel / stamp writes (called by DrawingTool) ---
func get_pixel(world: Vector2i) -> Color
func set_pixel(world: Vector2i, c: Color) -> void
func stamp(center: Vector2, radius: int, color: Color,
           coverage: Callable) -> void        # paints into all overlapped tiles, marks them dirty
func blend_stamp(center, radius, color, coverage) -> void  # alpha-aware variant

# --- tile access / lifecycle ---
func get_tile(coord: Vector2i, create := false) -> Tile
func iter_tiles() -> Array                      # [{coord, Tile}] for existing tiles only
func mark_dirty(coord: Vector2i) -> void
func gc_empty_tiles() -> void                   # drop tiles whose pixels are all transparent

# --- the AI / export boundary (preserves the full-image contract) ---
func painted_bounds() -> Rect2i                 # union of nonempty tiles, in world px
func to_image(region: Rect2i = painted_bounds(),
              pad_to := 0) -> Image             # flatten tiles -> one dense Image (pad_to=64 for AI)
func from_image(img: Image, origin: Vector2i = Vector2i.ZERO) -> void  # seed tiles from an Image
```

`to_image()` is the single place tiling becomes a dense buffer; it is what feeds
`compose_final_image`, `MediaGen.*`, save-as-PNG, and send-to-Note. `pad_to = 64` satisfies the
generative-model alignment requirement **only at this boundary** — never on the layers.

### 6.5 Rendering

Replace the layer's single `texture_rect` (for tiled types) with per-tile draws:

- A `LayerV2._draw()` path for `DRAWING`/`MASK` iterates `iter_tiles()` and
  `draw_texture(tile.texture, coord * TILE)`. Only tiles in the camera's visible world rect need to
  be drawn; cull the rest.
- A tile's `texture` is rebuilt (`ImageTexture.update`) only when `dirty`. Stamping marks the 1–4
  overlapped tiles dirty; nothing else re-uploads.

This is the analogue of Leonardo's `sv_composite_tile.c`: composite/redraw is per-tile and
incremental, not whole-surface.

### 6.6 Integration points (concrete edits)

| Current code | Change for tiled `DRAWING` layers |
|---|---|
| `LayerV2.expand_to_point()` + `ResizeCommand` in `DrawingTool` | **Removed from the stroke path.** Drawing past an edge just stamps into not-yet-existing tiles (lazily created). No realloc, no `position -= offset`. |
| `LayerV2.image` setter (single `Image`) | For tiled types, route through `from_image()`; keep single-`Image` setter for `IMAGE` layers. |
| `LayerV2.image` getter (returns the dense `Image`) | For tiled types, return `to_image()` (cache + invalidate on stroke end) so existing consumers keep working. |
| `DrawingTool._draw_brush_stamp` (writes to `editor.active_layer.image` / `_stroke_buffer`) | Write via `TiledRaster.blend_stamp(center, radius, color, coverage)`; reuse the existing `_get_cached_circle_pixels` coverage as the `coverage` callable. |
| `_stroke_buffer` / `_layer_backup` (full-layer Images) | Becomes per-tile: snapshot only the tiles the stroke touches for max-alpha coverage + undo. |
| `GPUBrushRenderer.initialize_buffers` (full-layer buffers) | **Phase 2:** init/dispatch per affected tile (or per dirty-rect of tiles). Phase 0/1 use the CPU stamp path. |
| `DrawingTool._build_selection_mask` (`O(w·h)`) | Restrict to `painted_bounds()` / touched tiles; full-canvas selection becomes per-tile. |
| `_update_visual_preview` full `get_output_image()` readback | Re-upload only dirty tiles' textures; no full-surface readback. |
| `GraphicsEditorUndo.DrawStrokeCommand` (before/after full image) | Capture before/after of **touched tiles only** (list of `(coord, Image)`); far smaller and bounded. |
| `compose_final_image` / `MediaGen` / save / send-to-note | Call `layer.raster.to_image(frame_or_bounds, pad_to=64)`. Behavior identical above the boundary. |

`LayerV2.position` for tiled layers is fixed at the world origin (tiles carry position via their
coords), eliminating the per-expansion repositioning that causes the lurch today.

### 6.7 Phased plan

- **Phase 0 — CPU prototype (Drawing layer only).** Add `TiledRaster`; back `DRAWING` layers with
  it; route `DrawingTool` stamps through `blend_stamp`; per-tile `_draw()`; implement `to_image()`.
  Delete `expand_to_point` from the drawing stroke path. *Goal: prove the feel on one layer type.*
- **Phase 1 — Dirty-tile rendering + per-tile undo.** Cache textures, cull to viewport, snapshot
  touched tiles for undo, `gc_empty_tiles()`.
- **Phase 2 — GPU per-tile.** Make `GPUBrushRenderer` operate on the affected tile set instead of
  full-layer buffers; eliminate full readback.
- **Phase 3 — `MASK` layers tiled** (same backing; mask-channel export via `to_image`).
- **Phase 4 — Retire `expand_to_point`** for all tiled types; keep it only where `IMAGE` layers are
  legitimately resized.

### 6.8 Acceptance criteria

1. Drawing a continuous stroke from inside the original image out past its edge shows **no hitch,
   no jump, no repositioning** (the cat-tail case, §5.1 step 3c).
2. Memory for a small drawing on a nominally huge canvas stays proportional to painted area.
3. `to_image(frame, pad_to=64)` returns a pixel-identical result to today's flattened layer for the
   same painted content (so `MediaGen` / compose are unaffected).
4. Two tiled layers painted at the same world coordinates overlay exactly, with no alignment step.
5. Undo of a stroke restores only the touched tiles and is visually identical to a full-image undo.

## 7. Open questions

- **Tile size.** 128² vs 256²: trade-off between allocation granularity / memory and per-tile
  texture-update cost.
- **Region for step 4.** Frame rectangle vs painted bounding box vs explicit user selection —
  which defines "what the AI sees," and how is it shown?
- **64-alignment.** Apply padding only at the composite boundary (preferred) — confirm no model
  path still needs layer-level 64-alignment.
- **Tile rendering path in Godot.** Custom `Control._draw()` looping `draw_texture` over tiles,
  vs per-tile `Sprite2D` children, vs a `RenderingServer` canvas-item approach for large tile
  counts.
- **Undo across tiles.** Per-tile dirty snapshots vs stroke-based command log
  (`GraphicsEditorUndo.Command`).
- **Coexistence during migration.** Drawing layers tiled while Image layers stay whole — confirm
  selection, transform, and merge paths handle both backings.

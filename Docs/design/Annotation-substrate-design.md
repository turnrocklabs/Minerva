# Annotation Substrate — Design

**Status:** Implemented substrate, UX workbench in progress
**Date:** 2026-04-30
**Scope:** DCR-2 — cross-editor annotation subsystem
**Source spec:** `Docs/Plugin-platform-thought.md` §3
**Policy:** `Docs/Plugin-platform-policy.md`
**Escalation:** `Docs/Plugin-platform-escalation.md`

---

## 1. Overview

Annotations are **spatially-anchored, editor-agnostic, persistent overlays** authored by humans or LLMs on top of any visual document. Distinct from Notes (thread-level, free-floating) and from document structure (traces, components, glyphs). Three responsibilities, only three:

1. **Storage.** One sidecar JSON file per document (`foo.ext.annotations.json`).
2. **Registry + dispatch.** An `AnnotationKind` table plugins extend; renderers dispatch by `kind`.
3. **MCP surface.** A small, composable CRUD + overlay + live-stroke tool set.

Core ships the substrate and built-in 2D kinds plus the generic `callout` kind. Plugins contribute additional kinds (`cad_3d_plane`, `pcb_net_callout`, etc.). Unknown kinds are preserved verbatim and rendered as placeholders — never dropped.

Non-goals decided upstream: ephemeral flag, inheritance-based extensibility, centralized storage.

---

## 2. Annotation Data Schema

### 2.1 Annotation envelope

```json
{
  "id": "ann_01",
  "author": "human",
  "kind": "2d_arrow",
  "view_context": "pcb",
  "primitives": [ { ... } ],
  "payload": { "text": "move this trace" },
  "created_at": "2026-04-23T14:22:01Z",
  "updated_at": "2026-04-23T14:25:11Z"
}
```

| Field | Type | Required | Notes |
|---|---|---|---|
| `id` | string | yes | Stable within sidecar. Substrate-generated `ann_<6-hex>`. |
| `author` | `"human"` \| `"ai"` | yes | Closed enum. No free-form authorship. |
| `kind` | string | yes | Discriminator. Matches a key in the registry or is preserved as unknown. |
| `view_context` | string | yes | How coordinates are interpreted. See §3. |
| `primitives` | array | yes | Ordered list of 2D primitive objects. |
| `payload` | object | no | Kind-specific extra data. Schema defined by the kind. |
| `created_at` | RFC3339 string | yes | |
| `updated_at` | RFC3339 string | no | Absent until first `update`. |

Unknown top-level fields are preserved on round-trip.

### 2.2 Built-in 2D primitive sub-schemas

All coordinates are doubles. Coordinate system depends on `view_context` (§3).

```json
// arrow
{ "kind": "arrow", "from": [x1, y1], "to": [x2, y2], "head_size": 1.5? }

// text
{ "kind": "text", "at": [x, y], "content": "string", "size": 2.5? }

// region (closed polygon; rectangle is a 4-point special case)
{ "kind": "region", "points": [[x1,y1], [x2,y2], ...], "filled": true? }

// polyline (open; no close segment)
{ "kind": "polyline", "points": [[x1,y1], [x2,y2], ...] }

// highlight (rectangular color wash over a document region)
{ "kind": "highlight", "rect": [x, y, w, h] }

// measure_distance (annotates a linear measurement between two points)
{ "kind": "measure_distance", "from": [x1,y1], "to": [x2,y2], "unit": "mm"? }

// measure_angle (three points a-b-c; angle at b)
{ "kind": "measure_angle", "a": [x,y], "b": [x,y], "c": [x,y] }

// measure_radius (circle inferred from center + point on circumference)
{ "kind": "measure_radius", "center": [x,y], "edge": [x,y] }

// ink_stroke (post-MVP; see §6)
{ "kind": "ink_stroke",
  "points": [[x, y, p, t], ...],
  "width_min": 0.3, "width_max": 2.5,
  "smoothing": "catmull_rom"? }
```

A single annotation's `primitives[]` can combine primitives (e.g., an arrow annotation often includes one `arrow` + one `text` label).

### 2.3 Kind ↔ primitive relationship

The annotation `kind` (e.g., `2d_arrow`) selects the **renderer and authoring tool**; the `primitives` are the geometric payload. A built-in kind like `2d_arrow` implies `primitives = [{arrow}, optional {text}]`. A plugin kind like `cad_3d_plane` places an arbitrary set of 2D primitives inside a plane's local frame (§12). This indirection is what lets unknown kinds still render as placeholders: even if the kind is unregistered, the substrate can compute `bounds(primitives)` and draw a grey box.

A kind MAY declare `primitives_optional: true` in its registration (e.g., text-editor range annotations where `payload.range: [line, col, line, col]` is the complete anchor and no visual primitives exist). When so declared, `primitives` may be absent or empty.

---

## 3. Coordinate Semantics

The substrate is editor-agnostic. Each editor publishes a coordinate contract so that `primitives` mean the same thing every time that editor opens.

| Editor | `view_context` values | Primitive coords |
|---|---|---|
| PCB | `"pcb"` | `mm` on board. `(0,0)` = board origin; `+x` right, `+y` down. Same space as `PCBData.board_width/height`. |
| CAD 2D per-view | `"cad:top"`, `"cad:front"`, `"cad:right"`, `"cad:iso"` | Pixels in that SubViewport's canvas overlay; visible only in that view. |
| CAD 3D plane | `"cad:world"` | `primitives` are in **plane-local 2D (u, v)**; plane itself defined in world 3D via `payload.plane` (§12). |
| Graphics | `"graphics"` | Pixels in document space (pre-zoom). |
| Text | `"text"` | `[line, column]` pairs for point primitives; `[line1, col1, line2, col2]` for ranges. Pixel coords forbidden — survives reflow/font change. |
| Spreadsheet | `"spreadsheet"` | `"A1:C5"`-style range strings in `payload.range`; `primitives` optional. Cell ranges are the anchor. |
| Presentation | `"pres:slide:<n>"` | Normalized `[0..1, 0..1]` over slide. Survives resize. |

**Rule:** `view_context` is a closed enum per editor, documented at editor registration time. A plugin editor publishes its supported contexts alongside its kinds. Mismatched `view_context` (sidecar says `"pcb"`, document is `.mcad`) → render as unknown placeholder (§10) and log a warning.

---

## 4. AnnotationKind Registry Contract

### 4.1 GDScript interface

```gdscript
# Abstract. One instance per registered kind.
class_name AnnotationKind extends RefCounted

# Required properties
var name: StringName              # e.g. &"2d_arrow" — globally unique
var display_name: String          # "Arrow" — for UI
var schema_version: int = 1       # bump on breaking payload change
var owning_plugin: StringName     # &"core" or plugin id

# Optional properties
var toolbar_icon: Texture2D       # for authoring toolbar
var default_payload: Dictionary   # skeleton for new annotations of this kind

# Required methods
func render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
    push_error("render() must be overridden")

func hit_test(annotation: Dictionary, point: Vector2, threshold: float) -> bool:
    return false

func bounds(annotation: Dictionary) -> Rect2:
    return Rect2()

# Optional methods
func validate(annotation: Dictionary) -> PackedStringArray:
    # return [] on success, array of error messages otherwise
    return []

func author_ui() -> AnnotationAuthorTool:
    # null means: use default primitive-level author UI
    return null
```

### 4.2 AnnotationRenderContext

Passed to `render()`. A thin facade so kinds aren't bound to a single `CanvasItem`:

```gdscript
class_name AnnotationRenderContext extends RefCounted

var canvas_item: RID              # draw target for RenderingServer
var transform: Transform2D        # document-space → screen-space
var viewport_rect: Rect2          # clip rect
var theme: Theme                  # colors, fonts
var zoom: float                   # editor zoom (for thickness scaling)
var view_context: String          # read-only

# Drawing helpers (mirror Godot's _draw API, transform applied)
func draw_line(a, b, color, width=1.0)
func draw_polyline(points, color, width=1.0)
func draw_polygon(points, colors)
func draw_string(font, pos, text, color, size)
func draw_rect(rect, color, filled)
func to_screen(p: Vector2) -> Vector2
func from_screen(p: Vector2) -> Vector2
```

Editors differ in camera/zoom/transform; the context abstracts that so a plugin's `render()` works identically in PCB's canvas, CAD's SubViewports, and Graphics' panel.

### 4.3 Registry API

```gdscript
# In MinervaCore (autoload)
func register_annotation_kind(kind: AnnotationKind) -> bool
func deregister_annotation_kind(name: StringName) -> bool
func get_annotation_kind(name: StringName) -> AnnotationKind   # null if unknown
func list_annotation_kinds() -> Array[AnnotationKind]

signal annotation_kind_registered(name: StringName)
signal annotation_kind_deregistered(name: StringName)
```

Registration collisions: second registration of the same `name` **fails** (returns false, logs a warning). Plugins must namespace (`cad_*`, `pcb_*`, `pres_*`). Core reserves `2d_*`.

### 4.4 Naming convention

Per policy: `<plugin>_<kind>` (e.g., `cad_3d_plane`). Core's built-in kinds use the `2d_` prefix and are reserved. The substrate treats `2d_*` as core-owned; plugins cannot register that namespace.

---

## 5. Built-In 2D Kinds

Each ships registered at startup, owned by `&"core"`. Format: kind → primitives → render → hit-test → bounds.

| Kind | Primitives | Render | Hit-test | Bounds |
|---|---|---|---|---|
| `2d_arrow` | `[arrow]` or `[arrow,text]` | line + triangle head at `to`, head size scaled with floor on `ctx.zoom`; optional label perpendicular near midpoint | distance-to-segment ≤ threshold, plus label AABB | AABB of endpoints grown by head size ∪ label |
| `2d_text` | `[text]` | draw string at `at`; zoom-bounded size | point inside text AABB grown by threshold | text AABB from font metrics |
| `2d_region` | `[region]` polygon | stroked polygon; low-alpha fill if `filled` | point-in-polygon (even-odd) with fat edges | AABB of vertices |
| `2d_highlight` | `[highlight]` | low-alpha filled rect, no stroke | point in rect grown by threshold | the rect |
| `2d_measure_distance` | `[measure_distance]` + optional `[text]` | dimension line with end ticks, midpoint label of computed distance in editor's unit | distance to segment; label AABB | endpoints ∪ label |
| `2d_measure_angle` | `[measure_angle]` | two rays a-b and b-c, arc sweep, numeric label inside arc | point near either ray, arc, or label | three-point AABB + arc radius + label |
| `2d_measure_radius` | `[measure_radius]` | circle outline, radial line, numeric label | annulus around circumference; near radial line or label | circle bounding rect ∪ label |
| `2d_polyline` | `[polyline]` + optional `[text]` | stroked open polyline, no fill | swept-distance to polyline; label AABB | AABB of points ∪ label |
| `callout` | optional | leader line + label bubble from resolved/snapshot anchor to text | label AABB | anchor point ∪ label |

**Units.** Measure kinds read the display unit from `AnnotationRenderContext.unit` (string: `"mm"`, `"in"`, `"deg"`, etc.). Numeric primitive values stay numeric; the renderer formats display strings unit-aware. Do not embed units inside numeric values, and do not rely on numeric-type fidelity across JSON round-trips — Godot's JSON parser can coerce `int` ↔ `float` in ways that lose information. When a specific primitive needs to override the context unit, use `"unit": "in"` on that primitive; the renderer looks up `payload.unit` / `primitive.unit` first, then falls back to context.

**Author colors.** Default from `author`: `human` = light magenta (matches PCB convention so migration is lossless), `ai` = cyan. `payload.color` overrides.

### 5.1 Callout Anchor Policy

`callout` is generic-plus-plugin-anchor-capable. It accepts `*/*` anchors, including plugin semantic anchors such as `cad/edge` and `pcb/net`. The substrate owns the default payload, summary, leader line, label bubble, and broken fallback. The host/plugin owns anchor resolution and projection.

This avoids forcing every plugin to define a duplicate callout kind just to attach normal revision intent to a semantic entity. Plugins should still define custom kinds when the payload carries domain behavior, for example `pcb_bus_hint` or `cad_edge_note`.

---

## 5.2 UX Substrate Contract

Editor and plugin panels mount the substrate workbench instead of subclassing it.

The host-facing contract lives on `AnnotationHost`:

```gdscript
func get_capabilities() -> Dictionary
func get_document_identity() -> Dictionary
func get_panes() -> Array
func get_domain_pickers() -> Array
func get_current_selection_anchor(kind: String = "") -> Dictionary
func get_kind_body_view(kind: String) -> Control
func apply_annotation(annotation_id: String) -> Dictionary
func update_annotation_lifecycle(annotation_id: String, lifecycle: String, patch: Dictionary = {}) -> Dictionary
func get_annotation_display_index(annotation: Dictionary) -> int
```

The substrate-owned UI pieces are:

- `AnnotationDockPane`: per-editor collapsible dock with bottom/right modes.
- `AnnotationWorkbench`: header, counts, filters, add flow, list rows, resolve/reopen/delete/repair/applied actions, and selection sync.
- `AnnotationOverlay`: base overlay with `MOUSE_FILTER_IGNORE` while idle and `MOUSE_FILTER_STOP` only while a tool is active.
- `AnnotationToolbar`: compact/labeled modes plus host capability filtering for tools and kinds.

Plugins own only domain-specific pieces: anchor resolvers, projection into panes/views, domain pickers, optional custom kind rendering, and optional kind body views.

Display numbering is persisted as `display_index` on each annotation. Numbers are gap-preserving: resolving or deleting `#2` does not renumber later annotations.

---

## 5.3 Overlay Canvas + Position-Source Contract

The overlay-canvas DCR (`019de0cf51b87125ae03e4986bc05200`) extends the substrate from a paint-only overlay into a positioned-item canvas with an anchor-uniform endpoint contract for kinds that span two points (arrow, callout) or live at a free position (free text, future ink).

### `AnnotationCanvas` — positioned-item surface

`src/Scripts/Services/Annotations/AnnotationCanvas.gd` extends `AnnotationOverlay` with an item registry, hit-testing, z-order, selection state, and selection-handle rendering. Annotation kinds register **item types** with the canvas; the canvas owns interaction (drag, marquee, select), kinds own rendering for their item type.

Canvas API:

```gdscript
# Item-type registry — kinds register draw + hit-test callbacks
canvas.register_item_type(type_name, {
    "draw": Callable(canvas, item) -> void,
    "hit_test": Callable(item, point) -> bool,        # optional; defaults to bounds
    "supported_transforms": PackedStringArray,         # subset of [translate, rotate, scale]
})

# Item lifecycle — items are plain Dictionaries with id, type, position, optional bounds/z_order/payload
canvas.add_item(item) -> id
canvas.remove_item(id)
canvas.update_item_position(id, pos)
canvas.update_item_bounds(id, rect)
canvas.update_item_payload(id, payload)
canvas.get_item(id) / get_items() / clear_items() / item_count()

# Z-order
canvas.bring_to_front(id) / send_to_back(id)

# Selection
canvas.select_item(id, additive=false)
canvas.deselect_item(id) / clear_item_selection() / set_item_selection(ids)
canvas.get_selected_item_ids() -> PackedStringArray

# Hit testing
canvas.hit_test(point) -> id      # topmost wins; respects per-item type hit_test callback
canvas.items_in_rect(rect) -> ids  # for marquee selection
```

Reserved item-type names: `callout-bubble`, `arrow-segment`, `free-text`, `ink-stroke` (last is a future-DCR slot — registering with no draw callback is allowed; the canvas simply skips drawing).

### `core/canvas.point` substrate anchor

A free position on the overlay canvas is itself an anchor:

```json
{"plugin": "core", "type": "canvas.point", "id": {"x": 100.0, "y": 200.0}, "snapshot": {"position": [100.0, 200.0]}}
```

Built helper: `CoreAnchors.make_canvas_point(x, y) -> Dictionary`. Resolved by the substrate inside `AnnotationHost.resolve_anchor` — every host gets canvas-point resolution without registering a host-local Callable. Canvas points are never marked stale.

### Position sources and `resolve_position_source`

Arrow and callout endpoints, and any future kind that needs a point, accept a **position source** that is one of:

- `Vector2`
- `[x, y]` — array form
- `{x, y}` — bare dict (treated as inline canvas point)
- An anchor envelope `{plugin, type, id, snapshot, ...}` resolved by host or substrate

`AnnotationHost.resolve_position_source(source) -> Vector2 | null` resolves any of these uniformly. Returns `null` only when there is genuinely no signal (no resolver registered AND no `snapshot.position` to fall back on). Stale anchors with snapshot positions still return the snapshot position so kinds can render broken endpoints in place.

Plugins exposing point-precision domain anchors (e.g. `pcb/trace.point`, `cad/edge.point`) Just Work as arrow/callout endpoints — kinds do not need to know the anchor type, only that resolution returns a position.

### Anchor-aware kind payload extensions

Existing built-in kinds gain optional anchor-aware payload paths. The legacy primitives path stays intact — when the new payload fields are absent, the kind falls back to its primitives-based render/bounds/hit-test.

**`2d_arrow`** — when `kind_payload.endpoint_a` and `kind_payload.endpoint_b` are present, both are resolved as position sources and the arrow renders a segment between them. Optional `head_size`, `head_style` (`single` / `double` / `none`).

**`2d_text`** — when `kind_payload.text` is present, the text renders at the position resolved from the annotation's `anchor` field (typically a `core/canvas.point` for free placement). Optional `font_size`, `scale`, `rotation_rad`.

**`callout`** — `kind_payload.bubble_pos` `[x, y]` overrides the default offset-based bubble placement so a user-dragged bubble persists independently of the anchor. The leader line picks the nearest edge midpoint of the bubble for a clean look. Anchor position is resolved live via `ctx.host.resolve_position_source` (snapshot fallback when host is absent).

### Render path

`AnnotationKind.render(ctx, annotation)` continues to be the single render entry point. `AnnotationRenderContext.host: Object` exposes the host so kinds can call `ctx.host.resolve_position_source(...)` for anchor-aware paths. Kinds without a host context (hit-test/bounds calls) fall back to anchor `snapshot.position` so static geometry queries remain stable.

---

## 6. `ink_stroke` Primitive (post-MVP)

### 6.1 Shape
```json
{
  "kind": "ink_stroke",
  "points": [[x, y, p, t], ...],
  "width_min": 0.3,
  "width_max": 2.5,
  "smoothing": "catmull_rom",
  "color": "#ff00ffcc"
}
```

- `x`, `y` in `view_context`-local units.
- `p` ∈ `[0, 1]`, stylus pressure. `null` for non-pressure devices; renderer treats as `0.5`.
- `t` is the sample timestamp in ms since stroke start. Enables replay.

### 6.2 Variable-width mapping
`width(p) = lerp(width_min, width_max, p)`. Applied per-sample; rendered as a triangle-fan ribbon or as `draw_polyline_colors` with tapered ends. Smoothing options: `"none"`, `"catmull_rom"` (default). Core ships with one smoother; plugins can render ink themselves if they need exotic stroke styles (pressure-to-opacity, nib tilt, etc.) by registering a kind that embeds an `ink_stroke` primitive.

### 6.3 Hit-test and bounds
- **Hit-test:** swept-distance test against the polyline using max sample width as fat radius. O(N) in sample count; acceptable for sub-thousand-sample strokes.
- **Bounds:** AABB of `(x, y)` samples, grown by `width_max / 2`.

### 6.4 Built-in kind: `2d_ink_stroke`
Ships one wrapping `ink_stroke` with default author-tool (pen input). Presentation's live pen-capture uses this plus the streaming MCP API (§8.3).

---

## 7. Sidecar File I/O

### 7.1 Path convention
- Document: `<anything>/foo.ext`
- Sidecar: `<anything>/foo.ext.annotations.json` — same directory, `.annotations.json` suffix appended to the **full filename including extension**.
- Examples: `board.minpcb` ↔ `board.minpcb.annotations.json`, `part.mcad` ↔ `part.mcad.annotations.json`, `deck.minpres` ↔ `deck.minpres.annotations.json`.

The double-extension pattern guarantees uniqueness even when a folder holds two documents with the same stem but different extensions (`foo.mcad` and `foo.minpcb`).

### 7.2 On-disk shape
```json
{
  "substrate_version": 1,
  "document": {
    "path": "board.minpcb",
    "kind": "minpcb",
    "hash": "sha256:..."
  },
  "annotations": [ /* array, not dict — preserves author order */ ],
  "unknown_kinds": []
}
```

- `document.path` is always stored **sidecar-relative** (not absolute). Typically just the filename.
- `document.hash` is optional; used only to warn on mismatch ("annotations were authored against a different version of this file"). Not used to reject loading.
- `unknown_kinds` is populated by loaders that encountered kinds not in the registry — see §10.

### 7.3 Atomic write protocol
1. Serialize to JSON.
2. Write to `foo.ext.annotations.json.tmp` in same directory.
3. `fsync` the tmp file.
4. Rename `foo.ext.annotations.json.tmp` → `foo.ext.annotations.json` (POSIX rename is atomic within a filesystem).
5. On Windows, the substrate uses `MoveFileExW(... REPLACE_EXISTING | WRITE_THROUGH)` via Godot's `DirAccess`.

Rationale: avoids half-written sidecars on crash. Matches behavior policy owes to all persistent document state.

### 7.4 Path semantics inside sidecar payloads
Kinds can stash paths in their `payload` (CAD's `reference.path`, Presentation's media). Rules:

- **Relative paths** in payloads resolve against the **sidecar's directory**, not `user://` and not CWD.
- **Absolute paths** stay absolute through save/load.
- **Project export** (§9) rewrites all paths to package-relative as it packs.
- **Project unpack** rewrites them back to absolute paths under the unpack destination.

Paths the substrate knows about live in a `payload.paths` array (convention, not enforced). Kinds that embed paths in ad-hoc locations are responsible for their own export rewrites and should call `ProjectPackage.rewrite_path()` (a new helper) during pack/unpack hooks.

### 7.5 Write orchestration
- On document save: sidecar written immediately after doc save succeeds. If doc save fails, sidecar is **not** written.
- On MCP mutation: 250 ms debounce; a burst of `add` calls produces one write.
- On kind-owning plugin stop: substrate flushes pending writes before teardown.
- Zero-annotation documents have no sidecar on disk; sidecars are never auto-created.

---

## 8. MCP Tool Surface

All tools namespaced `minerva_annotations_*`. Few composable tools per policy. `kind` is validated at call time against the live registry; unknown values are rejected by the MCP layer (sidecar data with unknown kinds is still preserved on load — that path is sidecar I/O, not MCP).

### 8.1 CRUD

```
minerva_annotations_list(document_path) -> [Annotation]
  Lists all annotations in the sidecar of the given document.
  Unknown kinds are returned; caller sees raw JSON.

minerva_annotations_add(document_path, annotation) -> {id}
  annotation.id optional; substrate assigns if missing.
  Validates against registered kind's schema + validate(); 400 on violation.

minerva_annotations_update(document_path, id, patch) -> {ok}
  Shallow patch over top-level fields; primitives replaced wholesale if in patch.
  Bumps updated_at.

minerva_annotations_delete(document_path, id) -> {ok}
  Deletes by id. Idempotent (404 on missing is ok=false, not an error).
```

**Validation errors** are always structured: `{ok: false, errors: [{field_path: "primitives[0].from", message: "expected 2-element array", code: "type"}, ...]}`. No plain-string error returns — LLMs need structured results to reason about what went wrong.

**Author attribution.** All MCP-originated calls set `annotation.author = "ai"` regardless of caller identity or the user account the LLM is acting under. `"human"` is reserved for direct-UI authoring in the Godot editor surface. Annotations are bi-directional — humans communicate intent to LLMs, and LLMs communicate back to humans — but the origination channel (MCP vs UI) is what determines the field.

### 8.2 Rendering

```
minerva_annotations_render_overlay(
  document_path,
  view: string,                    // one of the editor's view_contexts
  width: int, height: int,
  include_document: bool = false,  // if true, composite over document render
  include_kinds: [string] = []     // empty = all
) -> { image_png: base64 }
```

Used by LLMs to see what they're annotating. The substrate invokes the editor's renderer (document) if `include_document`, then dispatches to each kind's `render()`. Editors register a `render_document(view, w, h) -> Image` callback at editor-registration time.

### 8.3 Live-authoring (post-MVP)

For pen capture during Presentation and CAD-plane sketching, the CRUD path is too chatty. Batched-write API:

```
minerva_annotations_start_stroke(document_path, stroke_meta) -> {stroke_id}
  stroke_meta: { kind, view_context, payload, width_min, width_max, color }
  Reserves an id; no sidecar write yet.

minerva_annotations_add_points(stroke_id, points: [[x,y,p,t], ...]) -> {ok}
  Appends to in-memory buffer. Debounced overlay redraw. No sidecar write.

minerva_annotations_end_stroke(stroke_id) -> {annotation}
  Flushes the stroke into an annotation (kind defaults to 2d_ink_stroke unless
  overridden in start), persists to sidecar (atomic write, §7.3), returns final record.

minerva_annotations_abort_stroke(stroke_id) -> {ok}
  Discards buffered points.
```

**Lifetime:** in-memory strokes hold no lock. A crash before `end_stroke` loses the stroke — acceptable, live pen capture is interactive by nature. Strokes older than 5 minutes without activity auto-abort.

---

## 9. Project-Export Integration

`ProjectPackage.gd` packs a `.minpackage` zip with a `project.minproj` manifest and a `files/` tree. Annotation integration:

### 9.1 Pack
When packing a document at `original_path`, the packer checks for a sidecar:
```
<original_path>.annotations.json
```
If it exists:
1. Read it.
2. Rewrite internal paths (§7.4) to package-relative (`files/<path>` form).
3. Write to zip at `files/<package_path>.annotations.json` alongside the document entry at `files/<package_path>`.
4. Record the sidecar entry in `project.minproj` under `Editors[i].sidecar` so unpack knows to restore it.

Non-existent sidecar = no-op. The absence of a sidecar does not block export.

### 9.2 Unpack
When unpacking an editor entry that has a `sidecar` field:
1. Extract `files/<pkg_path>.annotations.json` to `<files_destination>/<pkg_path>.annotations.json`.
2. Rewrite internal paths back to absolute or relative-to-sidecar as appropriate.
3. The `Editors[i].file` rewrite is unchanged.

### 9.3 Project-file pack (non-export save)
Project save (non-export) does **not** copy sidecars — sidecars live next to originals on disk. The `.minproj` references the original paths; sidecars ride along implicitly.

### 9.4 Editor-type agnosticism
`ProjectPackage` does not know anything about annotation kinds. It only knows that a document may have a sibling sidecar file with a fixed naming convention. Kind-specific path rewrites are delegated to the kind's `rewrite_paths(annotation, mode: "pack"|"unpack", base: String)` optional method — registered by the kind, called per annotation during pack/unpack.

---

## 10. Unknown-Kind Fallback

When the loader encounters an annotation with a `kind` not in the registry:

1. **Preserve.** The annotation is retained verbatim in memory and re-written on save. No data loss.
2. **Render placeholder.** Use `bounds(primitives)` (computable substrate-side because primitive schemas are substrate-owned) to draw a grey dashed rectangle with:
   - The kind name in small text near a corner.
   - A warning glyph.
3. **Tooltip on hover:** `"Plugin not installed: {owning_plugin_hint}. Annotation kind '{kind}' is preserved but not rendered."` The `owning_plugin_hint` is extracted from the kind string's prefix (`cad_3d_plane` → `cad`).
4. **Hit-test:** AABB hit with standard threshold.
5. **Log once** per unknown kind per load. Repeat loads don't spam.
6. **MCP visibility:** unknown annotations appear in `list`. They can be deleted and re-positioned (if the editor supports primitive-level drag), but their `payload` is read-only from the UI. MCP `update` is allowed — agents may edit unknown-kind payloads.

On save, unknown kinds round-trip into the `annotations[]` array exactly as loaded (plus any `updated_at` bumps from MCP edits). They do **not** move to the `unknown_kinds[]` metadata array — that array is a summary counter only (see §7.2), written for diagnostic purposes.

---

## 11. Authoring UI Framework

### 11.1 AnnotationToolbar widget
A shared `AnnotationToolbar` Control. Hosted optionally by each editor (PCB, CAD, Graphics, Presentation). Not hosted by Text (annotations there are created via MCP or a context menu).

The toolbar is populated at runtime from the registry's kinds. Each kind contributes:
- One tool button if `author_ui()` is non-null.
- Label, icon from `display_name` / `toolbar_icon`.
- Ordering: core kinds first (fixed order), then plugin kinds in registration order. Sortable in user settings.

### 11.2 AnnotationAuthorTool contract

```gdscript
class_name AnnotationAuthorTool extends RefCounted

func on_activate(editor: AnnotationHost) -> void
func on_deactivate() -> void
# Forwarded from editor's _input, document-space coords already applied.
func on_pointer_down(pos, button, mods) -> bool
func on_pointer_move(pos) -> void
func on_pointer_up(pos, button, mods) -> bool
func draw_preview(ctx: AnnotationRenderContext) -> void  # optional in-progress preview

signal annotation_ready(annotation: Dictionary)
signal cancelled()
```

`AnnotationHost` is a thin editor-side protocol exposing `add_annotation(dict)`, `transform_doc_to_screen()`, and current `view_context`.

### 11.3 Dynamic register/deregister
When a plugin registers a kind with an `author_ui()`, the toolbar receives the `annotation_kind_registered` signal and appends a button. On deregister, the button is removed; if that tool is currently active, it's deactivated first and any in-progress stroke is aborted.

### 11.4 Keyboard shortcuts
Core kinds have fixed shortcuts: `A` = arrow, `T` = text, `R` = region, `H` = highlight, `M` = measure distance, `Shift+M` = angle, `Ctrl+M` = radius. Plugin kinds can request a shortcut via `preferred_shortcut` — collision falls back to unshortcutted.

---

## 12. 3D Annotation Extension (CAD)

The substrate accommodates CAD's `cad_3d_plane` kind **without special-casing the core**. The trick is that `primitives` are always 2D; the 3D-ness lives in the annotation's `payload.plane`, which defines a world-3D plane in whose local `(u, v)` frame the primitives sit.

### 12.1 `cad_3d_plane` kind (owned by CAD plugin)
```json
{
  "id": "ann_17",
  "kind": "cad_3d_plane",
  "author": "human",
  "view_context": "cad:world",
  "primitives": [
    { "kind": "arrow", "from": [0, 0], "to": [5, 3] },
    { "kind": "text",  "at":   [2, 4], "content": "too sharp" }
  ],
  "payload": {
    "plane": {
      "origin":  [10.0, 0.0, 5.0],
      "normal":  [0.0, 1.0, 0.0],
      "u_axis":  [1.0, 0.0, 0.0]
    }
  }
}
```

### 12.2 How this fits the substrate
- Core's `render/hit_test/bounds` contract is unchanged. The CAD plugin's `render()` for `cad_3d_plane`:
  1. Reads `payload.plane` to build a world-3D basis.
  2. For each primitive, transforms `(u, v, 0)` → world 3D → SubViewport screen coords via that camera.
  3. Uses `ctx.draw_*` normally.
- `hit_test` reverses: screen → ray → ray/plane intersection → `(u, v)` → 2D hit-test.
- `bounds` returns screen-space AABB by projecting plane-local primitive bounds through the current camera.

### 12.3 Why this works
- Core never imports 3D types. `Transform3D`, `Plane`, `Camera3D` live only inside CAD's `render()`.
- Other editors wanting "2D sketch on a plane in 3D" (future Spatial, Graphics-in-3D) reuse the same pattern with their own `*_3d_plane` kind.
- Unknown-kind fallback still works without the CAD plugin — grey placeholder via `bounds(primitives)` returning the 2D AABB of the `(u, v)` coords. Meaningless in world 3D but not crash-worthy; tooltip explains the missing plugin.

---

## 13. Unhappy Paths

- **Sidecar corrupt / partial JSON.** Loader backs up the bad file to `foo.ext.annotations.json.corrupt-<unix>` and loads empty annotations. Non-blocking banner in the editor. Never blocks document open. Atomic-write (§7.3) makes this rare.
- **Primitive out of bounds.** Coords outside editor canvas (e.g., text at `x=10000` on a 100mm PCB) are not rejected. Editor may offer "zoom to annotation". Rendering clamps.
- **Plugin registers mid-session.** Unknown-placeholder annotations of that kind are re-rendered normally on next redraw, triggered by `annotation_kind_registered`.
- **Plugin deregisters mid-use.** Active authoring tool deactivates first (§11.3). Existing annotations of that kind remain in memory, round-trip on save, placeholder-render from then on.
- **Concurrent edits (two agents, or agent + user).** Writes serialized through the editor's annotation-service on Godot's main loop + debounced flush. Shallow-patch `update` is last-write-wins at field level. Live strokes isolated by `stroke_id`.
- **Document renamed inside Minerva.** Sidecar renamed in the same transaction. External `mv` outside Minerva orphans the old sidecar at the old path; policy accepts this — no repair scanner.
- **Kind schema version mismatch.** Registry entry's `schema_version` checked against sidecar entries. Kinds may define `migrate(annotation, from_version)`; absent that, annotation loads as-is with a warning.
- **Very large sidecars.** Soft target < 5 MB; no hard limit. Pen-capture can blow this — plugins should chunk or downsample.

---

## 14. Questions — All Resolved 2026-04-24

*Inline answers from the user are preserved below as the decision record. Resolutions have been propagated into the body above (§2, §5, §7, §8). Notable downstream impact: sidecar naming is now `.annotations.json` (not `.meta.json`); `2d_polyline` added to built-in kinds; `primitives_optional` flag supported; structured validation errors; author=ai for all MCP calls; PCB route-hints reframed as domain-specific plugin-registered annotation kinds (handled in PCB-migration design task).*


1. **Text-editor annotations without primitives.** For `view_context: "text"`, an annotation is primarily a `[line, col]` range + payload text. Should `primitives[]` be optional (empty array allowed) for such kinds? Spec shows primitives as the vehicle; text highlights feel like payload-only. Recommendation: allow empty `primitives[]` when the kind's schema declares `primitives_optional: true`.
-- Yes, allow empty makes sense here.

2. **Measure-primitive rendering unit.** Does each editor provide a unit string via `AnnotationRenderContext` (`ctx.unit`), or does each annotation carry a `primitive.unit` explicitly? Spec silent. Recommendation: context-provided, overridable per primitive.
-- tough one due to JSON serialization. We currently hit issues where numbers serialize to float, when should be int. So, context-provided with coercion to specific primitives, maybe?

3. **PCB route-hints.** §3.8 of the thought paper defers this. Design assumes route-hints stay structural (not an annotation kind) — they have semantic meaning (AI routing directives) distinct from overlay marks. **Confirm.**
-- This is more like an annotiation extenion. Route hints (like bus routing, individual trace routing) are still annotations (real routes would be in the board's YAML file), and really communicate intent to the LLM. However they are domain specific -- so we have a concept of a plugin extending annotations in some way.

4. **Per-view visibility in CAD.** Spec says `view_context: "cad:top"` annotations are visible only in the top SubViewport; `"cad:world"` are visible in all. Does the substrate need a general "view filter" mechanism (beyond the plugin-owned kind deciding), or is per-kind filtering sufficient? Recommendation: per-kind filtering; substrate stays oblivious.
-- I'll defer this until I see it in action. Let's assert that the recommendation is correct for now.

5. **MCP schema-validation surface.** Should `minerva_annotations_add` return structured validation errors (field path + message), or plain-text? Recommendation: structured, matching the existing MCP error format.
-- structured, always. Easier for LLMs to understand.

6. **Author attribution when an LLM uses a human's account.** `author` is `human` | `ai`, closed. If a user drives an LLM that calls an annotation tool, who is the author? Recommendation: always `ai` when called via MCP; `human` only from direct UI input. Needs confirmation.
-- confirm. Annotations are bi-directional. Humans use them to communicate intent to LLM, and LLM can use them to communicate intent to human.

7. **Sidecar collision with existing `*.annotations.json` conventions.** Any other Minerva subsystem use `.annotations.json`? Quick audit recommended before locking the name. Alternative: `.annotations.json` (more explicit, less collision-prone). Recommendation: audit first; fall back to `.annotations.json` if needed.
-- Possibly. We should pre-empt by using .annotations.json anyway.

8. **PCB migration bridging.** Existing `PCBAnnotation` stores `positions: Array[Vector2]` + `type` enum. Migration maps cleanly onto the new substrate (arrow = 2 positions, text = 1, region = 2 corners, polyline → `region` with `filled: false` or a new `2d_polyline` kind). Recommendation: add `2d_polyline` as a built-in kind to avoid lossy migration. **Add to built-in list?** This design currently excludes it.
-- Unsure, it seems like it would be a fine addition, so let's add it and see.
---

*End of design document.*

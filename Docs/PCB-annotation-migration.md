# PCB Annotation Migration — Design

**Status:** Design, pre-implementation
**Date:** 2026-04-24
**Scope:** Bridge existing in-tree `PCBData.gd` annotations + route-hints onto the merged annotation substrate.
**Source spec:** `Docs/Plugin-platform-thought.md` §3.8
**Substrate:** `Docs/design/Annotation-substrate-design.md`
**Plan-decisions:** Item 6 of comment on `019dc054c4167872b9cc767d9a4e25dd` — route-hints are a plugin-registered annotation kind, not structural data.
**Executes via (future):** DCR `019dc140291979a49a8081bf91abe2ff` (PCB → plugin migration).

---

## 1. Overview

Today PCB annotations and route-hints are first-class fields on `PCBData`, persisted inline in the `.minpcb` JSON, drawn directly by `PCBCanvas`, and exposed through PCB-specific MCP tools. The merged substrate provides a generic envelope, `AnnotationKind` registry, sidecar I/O (`foo.minpcb.annotations.json`), and platform MCP tools (`minerva_annotations_*`). This document specifies the field mapping, kind names PCB will register, storage migration from inline → sidecar, MCP migration, and execution sequencing for the future DCR. **No code in this task.** Out of scope: substrate changes, anchor repair, route-hint *interpretation* logic (`pcb_interpret_route_hints` keeps its current semantics; only its inputs/outputs are repiped). Outcome: PCB stops owning annotation storage; CRUD goes through the substrate; existing `.minpcb` files load identically; the only on-disk change is annotation/route-hint data moving from `.minpcb` to a sibling sidecar.

---

## 2. Existing PCB Annotation Shape

### 2.1 `PCBAnnotation` (`PCBAnnotation.gd`)

| Field | Type | Default | Semantics |
|---|---|---|---|
| `id` | `String` | `""` | Unique per `PCBData`. Format `ann_<6-digit decimal>` (note: substrate uses 6-hex). |
| `type` | enum `AnnotationType` | `TEXT` | `ARROW` / `TEXT` / `REGION` / `POLYLINE`. Determines how `positions[]` are interpreted. |
| `positions` | `Array[Vector2]` | `[]` | mm in board coordinates. ARROW=2, TEXT=1, REGION=2 (corners), POLYLINE=N. |
| `text` | `String` | `""` | Body for TEXT, label for the others. |
| `color` | `Color` | `(0.95, 0.5, 0.9)` (light magenta) | `_get_author_color(author)` chooses; user override allowed. |
| `author` | `String` | `"human"` | Closed in practice: `"human"` or `"ai"`. |
| `created_at` | `float` | `0.0` | Unix seconds. |
| `associated_component` | `String` | `""` | Optional reference to a `components[]` entry. |
| `associated_net` | `String` | `""` | Optional reference to a `nets[]` entry. |

On disk: serialized via `to_dict()` with `positions` as `[{x,y}, ...]`, type as the enum **key string** (e.g. `"ARROW"`), color as `Color.to_html()`. The whole map sits at `PCBData.annotations[ann_id]` and is included in `PCBData.to_dict()` under `annotations: {id: dict}`.

### 2.2 `PCBRouteHint` (`PCBRouteHint.gd`)

| Field | Type | Default | Semantics |
|---|---|---|---|
| `id` | `String` | `""` | `rhint_<6-digit decimal>`. |
| `hint_type` | enum `HintType` | `SINGLE_TRACE` | `WAYPOINT` / `SINGLE_TRACE` / `BUS`. |
| `detail_level` | enum `DetailLevel` | `GUIDED` | `SPARSE` / `GUIDED` / `DETAILED`. Auto-derived from waypoint count on create. |
| `layer` | `String` | `""` | KiCAD layer (`F.Cu`, `B.Cu`, …). Empty = unspecified. |
| `width` | `float` | `0.0` | mm; 0 = default. |
| `bus_spacing` | `float` | `0.0` | mm; 0 = default. |
| `source_pins` | `Array[String]` | `[]` | `"U1.15"` form. |
| `dest_pins` | `Array[String]` | `[]` | Same. |
| `net_names` | `Array[String]` | `[]` | Optional. |
| `waypoints` | `Array[Vector2]` | `[]` | mm in board coords; semantic differs by detail_level. |
| `author` | `String` | `"human"` | |
| `text` | `String` | `""` | Freeform. |
| `created_at` | `float` | `0.0` | Unix seconds. |
| `color` | `Color` | teal/purple by author | |
| `client_id` | `String` | `""` | Idempotency key (used to dedupe across MCP retries). |

On disk: `PCBData.to_dict().route_hints[id]` carrying every field above as primitives.

---

## 3. Field-by-Field Mapping (PCBAnnotation → Platform)

The platform envelope (substrate §2.1) is `{id, author, kind, view_context, primitives[], payload, created_at, updated_at?}`.

| PCB field | Platform field | Notes |
|---|---|---|
| `id` (`ann_NNNNNN` decimal) | `id` (`ann_<6-hex>`) | Migration regenerates IDs to substrate format. Old IDs stashed in `payload.legacy_id` for forensic traceability. (References to annotation IDs from elsewhere in the PCB pipeline are limited to MCP returns; nothing else stores them.) |
| `type` (enum) | `kind` (string) | See §5: `ARROW → pcb_annotation_arrow`, `TEXT → pcb_annotation_text`, `REGION → pcb_annotation_region`, `POLYLINE → pcb_annotation_polyline`. |
| `positions[]` | `primitives[]` | Per-type translation below. Coordinates carry over verbatim — both sides are mm in board space (substrate `view_context = "pcb"` matches `PCBData.board_*`). |
| `text` | (a) primitive `text.content` for TEXT; (b) `primitives[1] = {kind:"text", at, content}` for ARROW/REGION/POLYLINE when label non-empty; (c) `payload.label` is **not** used — the text primitive is the canonical surface. | |
| `color` | `payload.color` (only when it differs from author default) | Preserves user overrides; default magenta (human) / cyan (ai) match substrate built-ins so no override is written for unmodified annotations. |
| `author` | `author` | Closed enum already aligned (`"human"` / `"ai"`). |
| `created_at` (Unix float) | `created_at` (RFC3339) | Migration converts via `Time.get_datetime_string_from_unix_time(int(t)) + "Z"`. |
| `associated_component` | `payload.associated_component` | Preserved as opaque PCB-domain reference. |
| `associated_net` | `payload.associated_net` | Same. |

### 3.1 Per-type primitive translation

| `PCBAnnotation.type` | Resulting `primitives[]` |
|---|---|
| `ARROW` | `[{kind:"arrow", from:[positions[0].x, positions[0].y], to:[positions[1].x, positions[1].y]}]` plus `{kind:"text", at:<midpoint+offset>, content:text}` only when `text != ""`. The substrate's `2d_arrow` renderer already handles an optional trailing text primitive. |
| `TEXT` | `[{kind:"text", at:[positions[0].x, positions[0].y], content:text}]` |
| `REGION` | `[{kind:"region", points:[[x1,y1],[x2,y1],[x2,y2],[x1,y2]], filled:false}]` — promote 2-corner box to a 4-vertex polygon (substrate `region` requires ≥3 points). Optional `{kind:"text", at:<corner1>, content:text}` if `text != ""`. |
| `POLYLINE` | `[{kind:"polyline", points:[[x,y]...]}]` plus optional trailing text primitive. Maps directly onto the `2d_polyline` built-in (added to substrate per plan-decision item 2). |

### 3.2 Color preservation

Substrate built-in author colors are: `human` = light magenta, `ai` = cyan — chosen specifically to match PCB's defaults (substrate §5 *Author colors*). Migration therefore **drops** the per-annotation `color` field whenever it equals the author default; only user-customized colors are written to `payload.color` as `#RRGGBBAA` hex. This keeps the migrated sidecar minimal and lets the substrate's color logic stay authoritative.

---

## 4. PCBRouteHint Mapping — `pcb_route_hint` Kind

Per plan-decision item 6, route-hints become a single PCB-plugin-registered annotation kind named **`pcb_route_hint`**. Rationale:

- A single kind is enough — `hint_type` (`waypoint`/`single_trace`/`bus`) is captured in `payload.hint_type`. The renderer already branches on this internally; collapsing to one kind avoids three near-identical registrations.
- Route-hints communicate intent ("AI: route this corridor"); they are overlays, not board-state. They never become persisted traces — the existing `interpret_route_hints` flow stays.
- Color, hit-test, and waypoint-rendering code in `PCBCanvas._draw_route_hint` ports cleanly into the kind's `render()`/`hit_test()`.

### 4.1 Envelope

```json
{
  "id": "ann_<6-hex>",
  "author": "human",
  "kind": "pcb_route_hint",
  "view_context": "pcb",
  "primitives": [
    { "kind": "polyline", "points": [[x1,y1], [x2,y2], ...] }
  ],
  "payload": {
    "hint_type":     "single_trace",
    "detail_level":  "guided",
    "layer":         "F.Cu",
    "width":         0.25,
    "bus_spacing":   0.0,
    "source_pins":   ["U1.15"],
    "dest_pins":     ["U2.1"],
    "net_names":     [],
    "text":          "",
    "client_id":     "uuid-or-empty",
    "legacy_id":     "rhint_413210"
  },
  "created_at": "2026-04-24T19:54:00Z"
}
```

### 4.2 Notes

- The `polyline` primitive holds the waypoints. When `waypoints.is_empty()`, `primitives` is `[]`; `pcb_route_hint` declares `primitives_optional: true` so the substrate accepts that case.
- Idempotency: `payload.client_id` carries today's `client_id`. The PCB plugin keeps the dedup logic (lookup-then-insert) inside its wrapper around `minerva_annotations_add`, not in the substrate.
- Self-referencing rejection (`source == dest`) lives in `AnnotationKind.validate()` for `pcb_route_hint`.
- Color: route-hint defaults (teal human / purple AI) differ from author defaults. Apply at `render()` time; persist `payload.color` only when the user customizes.

---

## 5. Kind Names

PCB registers **five** kinds from its plugin startup:

| Kind | Owner | Purpose |
|---|---|---|
| `pcb_annotation_arrow` | `&"pcb"` | Arrow with optional label, mm coords. |
| `pcb_annotation_text` | `&"pcb"` | Standalone text note. |
| `pcb_annotation_region` | `&"pcb"` | Closed polygon highlight (2-corner box stored as 4-point polygon). |
| `pcb_annotation_polyline` | `&"pcb"` | Open polyline. |
| `pcb_route_hint` | `&"pcb"` | Routing hint (§4). |

### 5.1 Why PCB-specific kinds, not core `2d_*`?

Alternative: PCB writes `2d_arrow`, `2d_text`, `2d_region`, `2d_polyline` directly. Pros: less boilerplate. Cons: PCB tunes hit-test thresholds per type (`PCBAnnotation.contains_point`); arrow authoring snaps to component pins (PCB-specific tool); future affordances ("associated_component" halo, layer-aware rendering) need kind ownership; the registry's namespace guard forbids plugins from using `2d_*` regardless. **Decision: register PCB-specific kinds.** Each composes from the core `2d_*` renderer's logic so basic appearance stays consistent; `pcb_route_hint` has no core equivalent.

---

## 6. Storage Migration — Inline → Sidecar

### 6.1 Today

`.minpcb` is a JSON file produced by `PCBData.to_dict()` containing top-level keys including `annotations: {id: dict}` and `route_hints: {id: dict}`. Loading reverses through `load_from_dict`.

### 6.2 Target

`board.minpcb` is the document; `board.minpcb.annotations.json` is the sidecar (substrate §7.1). `PCBData.annotations` and `PCBData.route_hints` are no longer persisted in `.minpcb`.

### 6.3 One-way migration on first load

When the PCB plugin opens an old `.minpcb`:

1. Parse `.minpcb` JSON.
2. If `annotations` or `route_hints` keys are present **and non-empty**, run an in-memory translator:
   - For each `annotation` dict: build the platform envelope per §3, append to a list.
   - For each `route_hint` dict: build the platform envelope per §4, append.
3. Build the sidecar payload `{substrate_version: 1, document: {path: <basename>, kind: "minpcb"}, annotations: [...], unknown_kinds: []}` and call `AnnotationSidecar.write_sidecar()`.
4. Drop the in-memory `annotations` and `route_hints` from the loaded `PCBData`. The plugin now reads them through the substrate.
5. **Save policy: strip-on-next-save.** The next time the user saves, `.minpcb` is written without `annotations` / `route_hints` keys. The sidecar is the source of truth.

### 6.4 Dual-write vs strip-on-next-save

Decision: **strip on next save** (one-shot migration, no dual-write window). Dual-writing creates divergence risk: an old Minerva opening a dual-written file mutates inline data while the sidecar drifts. `.minpcb` is Minerva-internal (pcb-architect YAML is the external channel) so external round-trip risk is low. Migration is silent on first open; on save the file shrinks and the sidecar lands next to the document.

### 6.5 No-annotations boards

If `annotations` and `route_hints` are both absent or empty, no sidecar is created (substrate §7.5). Behavior is indistinguishable from a fresh board.

---

## 7. MCP Migration — Annotation Tools

### 7.1 Affected tools

`minerva_pcb_add_annotation`, `minerva_pcb_list_annotations`, `minerva_pcb_remove_annotation`, `minerva_pcb_clear_annotations`.

### 7.2 Decision: thin-wrapper, deprecate in two releases

Keep all four as **thin wrappers** that translate to `minerva_annotations_*` against the PCB document path. Wrappers accept the existing argument shape, mark themselves deprecated in the tool description ("Use `minerva_annotations_add` with `kind=pcb_annotation_arrow`"), translate per §3, and forward. `clear` becomes `list` + per-id `delete`. Rationale: existing skill prompts reference these names; hard removal breaks them. Two-release deprecation gives skills time to migrate. Per platform policy (tools dispatched in the plugin's own MCP server), the wrappers live in the PCB plugin once it lands.

---

## 8. MCP Migration — Route-Hint Tools

### 8.1 Affected tools

`minerva_pcb_add_route_hint`, `minerva_pcb_list_route_hints`, `minerva_pcb_remove_route_hint`, `minerva_pcb_clear_route_hints`, `minerva_pcb_interpret_route_hints`.

### 8.2 Decision

- **`add` / `list` / `remove` / `clear`:** thin wrappers, same posture as §7. Translate to `minerva_annotations_*` with `kind=pcb_route_hint`. `client_id` idempotency stays in the wrapper (lookup-then-add against `minerva_annotations_list`).
- **`interpret`:** **stays as-is** — not annotation-CRUD; it reads freeform annotations and emits structured hints. After migration, inputs come from `minerva_annotations_list` and outputs from `minerva_annotations_add` with `kind=pcb_route_hint`. Tool name and signature unchanged; only the implementation is repiped.

### 8.3 List/filter semantics

`minerva_annotations_list` returns *all* annotations regardless of kind. The route-hint wrappers filter by `kind == "pcb_route_hint"` before returning, so the existing `pcb_list_route_hints` behavior is preserved.

---

## 9. Execution Plan

Ordered steps for the future PCB-as-plugin migration DCR (`019dc140291979a49a8081bf91abe2ff`):

1. **Register PCB kinds** in the PCB plugin's startup. Add `Pcb_AnnotationArrow`, `_Text`, `_Region`, `_Polyline`, `Pcb_RouteHint` extending `AnnotationKind`; implement `render()`/`hit_test()`/`bounds()` (and `validate()` where useful); `owning_plugin = &"pcb"`.
2. **One-shot loader** in `PCBData.load_from_dict` post-step: if legacy keys present, translate per §3/§4, write sidecar via `AnnotationSidecar.write_sidecar()`, clear in-memory legacy fields.
3. **Strip-on-save:** remove `annotations` / `route_hints` from `PCBData.to_dict()`; delete the two fields from `PCBData`.
4. **Render dispatch:** delete `PCBCanvas._draw_annotations` / `_draw_route_hints`; single overlay pass iterates the substrate's per-document list and calls `AnnotationRegistry.dispatch_render`.
5. **Hit-test dispatch:** replace `PCBData.get_annotation_at` / `get_route_hint_at` in `PCBCanvas` input handling with `AnnotationRegistry.dispatch_hit_test`.
6. **Authoring UI:** drop PCB toolbar buttons for the migrated kinds; mount the platform `AnnotationToolbar`. Each kind contributes `author_ui()`.
7. **MCP wrappers:** mark eight `pcb_*` annotation/route-hint tools deprecated in description text; reroute handlers to translate-and-forward to `minerva_annotations_*`. Wrappers live in the PCB plugin's MCP server.
8. **`pcb_interpret_route_hints`:** repipe to read via `minerva_annotations_list` and emit via `minerva_annotations_add`. Keep name and signature.
9. **Tests:** for each fixture `.minpcb`, assert canvas-overlay screenshots match pre/post migration; sidecar count correct; `.minpcb` no longer contains legacy keys after second save.
10. **Deprecation tracking:** open a follow-up docket item to remove wrappers in two releases.

---

## 10. Backward Compatibility

### 10.1 New Minerva opens an old `.minpcb` (inline annotations)

Step 2 of the execution plan converts inline → sidecar on first load. UI is identical. Saving rewrites `.minpcb` without the legacy keys; sidecar persists.

### 10.2 Old Minerva opens a new `.minpcb` (no inline annotations, sibling sidecar present)

The `.minpcb` loads cleanly — `load_from_dict` defaults missing `annotations` / `route_hints` to empty. The sidecar is invisible to old Minerva. Board opens with no overlays but no errors. On save, old Minerva writes empty `annotations` / `route_hints` keys; the sidecar is untouched. Annotations re-appear when reopened in new Minerva. Acceptable: old Minerva is effectively read-only for these overlays on new files; this is a single-user app where version mixing is rare.

### 10.3 Document rename (in-Minerva)

PCB plugin must include sidecar in any future "rename document" path. Out-of-band `mv` orphans the sidecar — explicitly accepted by substrate policy (§13).

---

## 11. Open Questions

1. **Arrow text-primitive position.** Migrating an `ARROW` with a label needs a `text.at` value, but the renderer auto-places labels perpendicular to the midpoint. Recommendation: write `text.at = midpoint(start,end)` and let the kind treat it as a hint, free to override.
2. **`detail_level` after migration.** Today auto-derived on create from waypoint count. Keep stored in `payload` (allows hand-edit) or recompute? Recommendation: keep stored.
3. **Change journal coverage.** `PCBData.record_change` logs annotation/route-hint mutations. After migration, mutations route through the substrate. Recommendation: PCB plugin subscribes to substrate signals to retain journal coverage.
4. **ID regeneration impact.** Migration assigns new substrate-format IDs (`ann_<6-hex>` from old `ann_NNNNNN`/`rhint_NNNNNN`). The change journal stores legacy IDs that become dead references after the one-shot. Acceptable (journal is a log, not a query target), but flag for the executing agent.
5. **`pcb_route_hint` as one kind vs three.** §4 collapses three `hint_type` values into one kind with `payload.hint_type`. Alternative: three kinds (`pcb_route_hint_waypoint`, `_single_trace`, `_bus`). The collapsed form mirrors today's code structure; revisit if rendering branches grow significantly.

---

## 12. Acceptance Criteria

The future migration DCR is "done" when all of the following hold:

1. **Round-trip parity.** For each fixture board in `src/Scenes/PCBSamples/` and any test `.minpcb`s in the repo: open in pre-migration Minerva, screenshot the canvas overlay; open in post-migration Minerva, screenshot the canvas overlay; pixel diff is dominated by font-rendering jitter only (no missing or moved annotations).
2. **Sidecar emission.** After opening + saving an old `.minpcb` with N≥1 annotations and M≥1 route-hints, the directory contains a sibling `<name>.minpcb.annotations.json` with `annotations[]` length N+M, valid against the substrate schema (`AnnotationSchema.validate_annotation` returns no errors per entry).
3. **Inline strip.** After the second save, the `.minpcb` file no longer contains the top-level keys `annotations` or `route_hints`.
4. **MCP wrapper compatibility.** Existing skill prompts that call `minerva_pcb_add_annotation` / `_add_route_hint` succeed unchanged. The same data is observable via `minerva_annotations_list` against the PCB document path.
5. **Empty-board sanity.** A `.minpcb` with no annotations and no route-hints does not produce a sidecar after a load+save cycle.
6. **Old-Minerva opens new file.** A pre-migration build opens a post-migration `.minpcb` (with sidecar) without errors. (Acceptable: annotations not visible.)
7. **Color preservation.** A migrated annotation whose original `color` matched the author default has no `payload.color` in the sidecar; one whose color was customized writes `payload.color` and renders identically.
8. **Substrate registry collision-free.** `AnnotationRegistry.register_annotation_kind` returns `true` for all five `pcb_*` kinds at plugin start; deregister returns `true` on plugin stop.
9. **Tests in PCB plugin's test suite** cover: annotation type-by-type migration; route-hint type-by-type migration; idempotent re-load (load → save → load gives identical sidecar); `pcb_interpret_route_hints` end-to-end through the substrate.

---

*End of design document.*

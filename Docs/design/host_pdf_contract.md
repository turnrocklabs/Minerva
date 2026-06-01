# `host.pdf.*` Capability Contract

**Status:** FROZEN — owner-signed-off 2026-05-31 (docket P1.0 `019e80a0293d`, done). Changes require a new docket item.
**Date:** 2026-05-31
**Branch:** `pdf-print-substrate`
**Scope:** The host capability surface for *precise PDF generation*. The single API both the P1.1 generator sidecar AND the nametag-maker plugin code against. Freezing this is what unblocks parallel work (P1.1 sidecar ‖ plugin non-PDF 90%).
**Upstream:** DCR `019e809f` (design of record). Sidecar process/framing precedent: `Go-python-bridge-design.md`.
**Non-goals:** view/preview/notes (P2), export-a-view (P3), print (P4), PDFium, a from-scratch PDF clone. Crop-mark / duplex / registration math lives in the *plugin*, not here.

---

## 1. The core decision (sign-off gate)

fpdf is internally **stateful**: `FPDF()` → `add_page()` → `set_font()` → `cell()`/`image()`/`line()` → `output()`. The pickup's primitive list (`new_doc`, `add_page`, `set_font`, `draw_*`, `output`) reads like that stateful sequence. There are two ways to expose it across the broker boundary:

| Model | Shape | Reliability | Durability | Cost |
|---|---|---|---|---|
| **A. Stateful handle** | `new_doc → doc_handle`; N calls reference it; `output(handle) → bytes` disposes | Sidecar holds open sessions → leak/GC/timeout policy, concurrency state, crash-mid-build loses work, N round-trips over stdio | Must define handle lifecycle + recovery; more surface to keep stable | Chatty |
| **B. Stateless declarative batch** ✅ | One `host.pdf.generate(doc)` call carrying the whole document (pages → ops); returns bytes | Pure function: idempotent, retryable, no session state, crash = retry | Smallest stable surface; one verb | One round-trip |

**Recommendation: B — stateless declarative batch.** The rubric (reliability → durability → cost → …) points hard at B: no session leaks, no concurrency races, no GC/timeout policy, crash-safe by construction. It also matches how the Python tool *actually* works — it builds the entire document in memory, then calls `output()` exactly once. The plugin already computes every coordinate locally (it's pure geometry: grid layout, crop marks, duplex column-reversal, registration offsets), so it can emit one flat op list and submit it in a single call.

**The primitives don't disappear — they become op *kinds* inside the batch** (`draw_text`, `draw_image`, `draw_line`, `draw_rect`), not separate stateful capabilities.

> **Signed off as Model B (2026-05-31).** Everything in §3–§8 assumes Model B. Full rubric rationale for this and the three sub-decisions below is in §11.

The other two choices made inside the recommendation:
- **Text auto-shrink runs in the sidecar** (`fit` on `draw_text`), not via a separate `measure_text` round-trip. The original's only stateful dependency is `get_string_width` inside the shrink loop; pushing the loop into the sidecar keeps the API one-shot and avoids the plugin duplicating font metrics (DRY).
- **No font handle.** Fonts are referenced by `(family, style)` name; the sidecar bundles the fonts. Size is per-op. (Detail in §4.)

---

## 2. Coordinate system & units

- **Unit: points** (1 in = 72 pt). Matches the original (`FPDF(unit='pt')`) and the registration-offset math, which is already in points.
- **Origin: top-left**, x → right, y → down (fpdf convention).
- **Page format: Letter** (612 × 792 pt) is the v1 default and the only format P1.1 must guarantee; the schema accepts a `format` string so other sizes are a data change, not an API change.
- **Auto page-break is always OFF.** This substrate does precise absolute positioning; the host never reflows. (The original sets `set_auto_page_break(False)`.)
- **Color: `[r, g, b]`**, integers 0–255 (matches `set_draw_color(200,200,200)`). Default text/stroke color `[0,0,0]`.

---

## 3. The capability

**One capability: `host.pdf.generate`.** Deny-by-default; the plugin manifest must declare it:

```json
"permissions": { "host_capabilities": ["host.pdf.generate"] }
```

No filesystem or network grant is implied — bytes come back in-band (base64); the plugin persists them itself (its own scoped `host.files.write`, or `host.dialogs.file_picker`). Generation neither reads nor writes the disk.

### Envelope (matches every other host capability)

Success: `{ "success": true, "result": { … } }`
Failure: `{ "success": false, "error_code": "…", "error_message": "…", "plugin_id": "…", … }`

---

## 4. Request schema — `args` to `host.pdf.generate`

```jsonc
{
  // Document-level defaults (all optional; shown with defaults).
  "defaults": {
    "format": "Letter",        // page size; v1 guarantees "Letter"
    "orientation": "portrait", // "portrait" | "landscape"
    "unit": "pt"               // v1 guarantees "pt"
  },

  // Optional PDF metadata (maps to set_title/author/subject/creator).
  "metadata": {
    "title": "Name Tags",
    "author": "…",
    "subject": "…",
    "creator": "Minerva host.pdf"
  },

  // Image registry: embed each image's bytes ONCE; ops reference by id.
  // (gofpdf, like fpdf, caches images — re-drawing the same id is cheap.)
  "images": [
    { "id": "icon", "format": "png", "bytes_b64": "<base64 PNG>" }
  ],

  // Pages, in order. Each page is an ordered op list drawn back-to-front.
  "pages": [
    {
      // optional per-page overrides of defaults.format / orientation
      "ops": [ /* see §5 */ ]
    }
  ]
}
```

**Fonts (no handle, no doc-level table in v1).** Each `draw_text` op names its font inline as `{ "family": "DejaVuSans", "style": "", "size": 20 }`. v1 guarantees exactly the bundled set the original needs:

| family | style | bundled file (shipped *with the sidecar*, never read from the OS) |
|---|---|---|
| `DejaVuSans` | `""` (regular) | DejaVuSans.ttf |
| `DejaVuSans` | `"B"` (bold) | DejaVuSans-Bold.ttf |

Bundling these is the explicit fix for the original's `/usr/share/fonts/...` hardcode — the guaranteed mac/Windows crash. A request naming any other `(family, style)` returns `font_not_available` with the available list. *Custom-font embedding via a `fonts:[{family, style, bytes_b64}]` registry is a reserved future field — not guaranteed in v1.*

---

## 5. Op kinds

Every op is `{ "kind": "...", ... }`. Each op carries its own style (stroke width, colors) — there is **no sticky graphics state** across ops, which is what makes the batch order-independent to reason about and crash-safe.

### `draw_text`
```jsonc
{
  "kind": "draw_text",
  "text": "Ada Lovelace",
  "x": 24.5, "y": 30.0,           // top-left of the text cell, points
  "font": { "family": "DejaVuSans", "style": "B", "size": 20 },
  "w": 219.0,                      // cell width; align applies within it.
                                   //   omit → cell width = measured text width
  "h": 24.0,                       // line height; omit → size * 1.2
  "align": "C",                    // "L" | "C" | "R" within w. default "L"
  "color": [0, 0, 0],              // optional, default black
  "fit": {                         // optional auto-shrink (replaces get_string_width loop)
    "max_width": 219.0,            //   shrink font.size until text width ≤ max_width
    "min_size": 12,                //   floor; stop shrinking here even if it overflows
    "step": 1                      //   decrement (default 1)
  }
}
```
Maps to gofpdf `SetXY` + `CellFormat`. `fit` makes the sidecar measure-and-shrink before drawing, reproducing the original's auto-shrinking name field exactly.

### `draw_image`
```jsonc
{
  "kind": "draw_image",
  "image_id": "icon",              // must exist in doc.images → else unknown_image_id
  "x": 24.5, "y": 30.0,
  "w": 28.8,                       // width in points
  "h": 0,                          // 0 (or omit) → preserve aspect ratio from w
  "angle": 0                       // optional rotation about the image CENTER,
                                   // degrees CLOCKWISE-positive. omit/0 = none.
                                   // when h is auto (0) the center is derived
                                   // from the image's intrinsic aspect.
}
```

### `draw_line`
```jsonc
{
  "kind": "draw_line",
  "x1": 0, "y1": 0, "x2": 11.3, "y2": 0,
  "width": 0.35,                   // stroke width, points. default 0.2
  "color": [200, 200, 200]         // default black
}
```

### `draw_rect`
```jsonc
{
  "kind": "draw_rect",
  "x": 36, "y": 54, "w": 243, "h": 168,
  "style": "D",                    // "D" stroke | "F" fill | "DF" both. default "D"
  "stroke_width": 0.25,            // default 0.2
  "stroke_color": [200, 200, 200], // default black
  "fill_color": [255, 255, 255]    // required only when style includes "F"
}
```

---

## 6. Response schema

```jsonc
{
  "success": true,
  "result": {
    "bytes_b64": "<base64 of the application/pdf bytes>",
    "byte_size": 48213,            // decoded size, for the plugin to sanity-check
    "page_count": 4,
    "content_type": "application/pdf"
  }
}
```

The plugin decodes `bytes_b64` and does whatever it likes with the bytes (write via `host.files.write`, hand to the P2 viewer, etc.). The host does not persist anything.

---

## 7. Error codes

Reused from `PluginErrors` as-is: `capability_not_granted`, `schema_validation_failed`, `payload_too_large`, `backend_error` (sidecar down / timed out / framing fault — same treatment as the CAD bridge `crashed`/`internal`).

New codes to add to `PluginErrors` **in P1.2** (named here so the contract is complete):

| code | when | extra fields |
|---|---|---|
| `font_not_available` | op names a `(family, style)` the sidecar didn't bundle | `family`, `style`, `available: [...]` |
| `unknown_image_id` | `draw_image.image_id` not in `doc.images` | `image_id`, `page_index`, `op_index` |
| `image_decode_failed` | a `doc.images[].bytes_b64` isn't valid base64 / isn't the declared format | `image_id` |
| `pdf_generation_failed` | gofpdf raised while building/serializing | `detail` |

`schema_validation_failed.detail` carries the offending location (e.g. `pages[0].ops[3]: draw_rect style "F" requires fill_color`). Validation is strict: unknown op kinds and unknown keys are rejected, mirroring the strict-allowlist style of `host.documents.set_state`.

---

## 8. Mapping: every `TagRenderer` primitive → contract op

Proves the surface is sufficient to port the original with zero gaps.

| `generate_tags.py` call | contract |
|---|---|
| `FPDF(unit='pt', format='Letter')` + `set_auto_page_break(False)` | `defaults: {format:"Letter", unit:"pt"}` (auto-break always off) |
| `set_title/author/subject/creator` | `metadata` |
| `add_font('DejaVu','',…)` / `('DejaVu','B',…)` | bundled — referenced as `font.family:"DejaVuSans"`, `style:""`/`"B"` |
| `add_page()` (front & back) | each entry in `pages[]` |
| `image(icon_path, x, y, w)` | `draw_image {image_id, x, y, w}` (icon embedded once in `images`) |
| `_draw_name` shrink loop + centered `cell(…, align='C')` | `draw_text {…, w: content_width, align:"C", fit:{max_width, min_size:12}, font.size:20}` |
| `_draw_class/room/group` `set_font(10)` + positioned `cell` | `draw_text {x, y, font.size:10, align}` (manual corners → explicit x,y) |
| `_draw_corner_marks` `set_line_width` + `set_draw_color` + `line(…)` | `draw_line {…, width:0.35, color:[200,200,200]}` ×8 |
| `_draw_full_guides` `rect(…)` | `draw_rect {…, style:"D", stroke_width:0.25, stroke_color:[200,200,200]}` |
| `output(path)` | response `bytes_b64` (plugin writes the file) |

Front/back column-reversal, registration offsets (`back_offset_x/y`), the 4×2 centered grid, and the 4 mm corner-mark length are **plugin-side geometry** — the plugin computes final x/y/w and emits ops. The host stays a dumb, faithful renderer. (DRY guardrail: the host owns *drawing*; the plugin owns *layout*.)

---

## 9. Limits

- **Payload cap: 8 MB** per request (`_FILES_MAX_BYTES`, matching `host.files`/`host.documents`). For a nametag run this is comfortable — one small reused PNG icon + a few KB of ops. Embedded images dominate; the registry-by-id design means an image counts once regardless of how many `draw_image` ops reference it. Over-cap → `payload_too_large`. *(P1.2 to confirm the cap holds for realistic decks; if a future consumer needs large raster art, a blob-handle path like `host.documents.put_blob` is the escalation, not a bigger inline cap.)*

---

## 10. P1.1 / P1.2 wiring notes (informative — not part of the frozen contract)

- **Generator = pure-Go `go-pdf/fpdf` MCP sidecar.** Simpler than the CAD bridge: gofpdf is pure Go, so there is **no Python subprocess** — the sidecar *is* the worker. Reuse the capability-broker pattern + the length-prefixed-JSON framing and crash/restart/circuit-breaker model from `Go-python-bridge-design.md` §2–§3.
- The broker routes `host.pdf.generate` to the sidecar and wraps its reply in the standard envelope (P1.2), exactly as `_handle_mcp_proxy` wraps tool results today.
- **P1.1 acceptance is the pixel-diff gate:** render the original sample deck via this contract and diff against `generate_tags.py` output. If a font/DPI/kerning detail won't reproduce under gofpdf, that's the trigger to fall back to an embedded-Python (fpdf2) sidecar — the *contract above does not change either way* (that's the point of freezing it).

---

## 11. Decisions & rubric rationale (signed off 2026-05-31)

All four design choices were checked against the project rubric — **reliability → durability → cost → readability → DRY → well-factored** — applied lexicographically: a higher tier dominates; lower tiers only reinforce or break ties. Each decision is recorded with the tier that *decided* it.

| # | Decision | Deciding tier |
|---|---|---|
| 1 | **Stateless declarative batch** (Model B), not a stateful handle API | **reliability** (top tier, dominant) |
| 2 | **Auto-shrink in the sidecar** (`fit` on `draw_text`), not a separate `measure_text` round-trip | **reliability** (measurement/render consistency) |
| 3 | **One verb `host.pdf.generate`** for v1; no reserved `host.pdf.measure` | **durability** (reliability tied) |
| 4 | **8 MB cap** (`_FILES_MAX_BYTES`), blob-handle path as the named escalation | **reliability** (consistency + bounded memory) |

### Q1 — stateless batch vs stateful handle

**Reliability decides it.** A stateful handle holds session state in the sidecar between calls, introducing failure modes that don't exist in the batch model: crash mid-build loses the in-progress doc with no clean recovery; orphaned handles if the plugin dies before `output`; concurrent generates need session isolation; N round-trips = N failure opportunities per doc. The batch is one atomic call — pure input→output, idempotent, retryable verbatim. **Durability** reinforces (batch freezes one verb + one schema; the handle model must additionally freeze a create/refer/dispose/timeout/GC lifecycle). **Cost** reinforces (handle model is chattier over stdio and needs a handle table + GC + timeouts in the sidecar).

*Honest caveat (still reliability tier):* the batch rides one message, so a doc exceeding 8 MB fails as one rejected call where a handle model could build incrementally — a real edge for the handle model at extreme scale. It does not flip the tier: not the v1 case, covered by Q4's escalation, and an over-cap rejection is a loud clean failure, not a silent hole.

### Q2 — `fit` in sidecar vs `measure_text` round-trip

**Reliability decides it.** With `fit`, measurement and drawing occur in one process against one font instance — the metrics that *choose* the size are exactly the metrics that *draw* it, consistent by construction. A `measure_text` round-trip computes the shrink decision in a separate call; if the sidecar restarts or the font version shifts between trips, the decision is made against stale metrics → text overflows or mis-sizes. **Cost** reinforces (`fit` is one trip vs N, one per text item). *Note:* this was NOT chosen on DRY grounds — `measure_text` also keeps metrics host-side, so neither option duplicates them; the honest justification is reliability + cost.

### Q3 — one verb vs reserving `host.pdf.measure` now

**Reliability is a tie** (an unused verb adds no failure modes). **Durability decides it:** adding `measure` later is purely additive — a new capability, zero change to `generate` — so deferring paints us into no corner, while reserving it now with no consumer means publishing a contract untested against real need (the "published-but-wrong API" hazard). **Cost** reinforces (building/testing/audit-wiring an unused verb is YAGNI). The decision is cheaply reversible precisely because the later add is additive.

### Q4 — 8 MB cap + named blob escalation

**Reliability decides it.** 8 MB matches `_FILES_MAX_BYTES` used by `host.files`/`host.documents` — one predictable behavior across the whole host surface, bounded peak memory (base64 decoded in broker *and* sidecar at once), loud `payload_too_large` on overflow. A larger inline cap is mildly reliability-negative (larger stdio frames raise fragmentation/timeout risk and peak memory). **Durability** reinforces (one constant governs the whole surface; a PDF-specific cap would be a second magic number to drift; the blob-handle growth path is designed now, not repainted later). Matches house precedent — the CAD bridge's binary-payload hatch is likewise "never in v1, measure first."

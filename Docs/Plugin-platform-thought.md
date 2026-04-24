# Plugin Platform — Thought Paper

**Status:** Design exploration / pre-implementation
**Date:** 2026-04-24
**Context:** Emerged from a conversation about porting the MCAD experiment (`~/gitlab/ccsandbox/experiments/cad`) into Minerva as a plugin. The scope broadened as we worked: the CAD port depends on two platform capabilities Minerva doesn't fully have yet — a plugin system that can host first-class editor tabs, and a cross-editor annotation substrate. Rather than bundle those into the CAD work, we separate them as the real leverage points. CAD becomes the first consumer of both.

Supersedes `CAD-thought.md` (same `Docs/` directory).

---

## 1. Vision

Three coupled initiatives, ordered by leverage:

1. **Plugin platform expansion** — let plugins ship first-class editor tabs (Godot scenes), not just webview panels. Minerva's current plugin system supports stdio-MCP backends and HTML panels only; extending it to native Godot front-ends unlocks PCB, CAD, and (likely) Graphics as plugins instead of in-tree editors.

2. **Annotations as a platform subsystem** — cross-editor, spatially-anchored marks authored by humans or LLMs. Every editor with a visual surface wants them; PCB has a partial implementation today; CAD needs 3D variants; text and graphics want them too. Pulled out of any single editor and made a shared substrate.

3. **CAD** — the first consumer of both. Parametric B-Rep modeling via a textual DSL, with a collaborative human-graphical / LLM-textual workflow. Its design is much thinner once it doesn't own annotations or editor-hosting.

Priority order matters. The CAD port is the reason we're doing this, but it's the third in dependency order. Validate the platform capabilities first (ideally with smaller consumers), land CAD on top.

---

## 2. Plugin Platform Expansion

### 2.1 Today

Plugins are out-of-process MCP servers communicating over stdio JSON-RPC. They can expose MCP tools, receive state/event pushes, and optionally host **HTML webview panels** via `godot_wry` or `godot_cef`. Full reference: `src/plugins/plugin_system_guide.md`. Example plugins: `obs_controller` (Go, full-featured), `notes_helper` (Python, minimal).

What plugins **cannot** do today: ship a native Godot scene as an editor tab with the same rights as an in-tree editor (PCBEditor, TextEditor, SpreadsheetEditor).

### 2.2 Goal

**A plugin can ship a full first-class editor tab.** Concretely:

- Register a new editor kind with Minerva (file extension + creation path), analog of adding to `Editor.Type`.
- Instance the plugin's Godot scene into a tab when that kind is opened.
- Integrate with save / load / unsaved-changes tracking.
- Integrate with Minerva's file-dialog flow (open/save with the plugin's extension).
- Integrate with project-file and project-export (`.minpackage`) serialize/deserialize.
- Exchange bidirectional IPC between the scene and the plugin's MCP process.
- Have the plugin's MCP tools reachable from Minerva the same way in-tree MCP tools are.

This is the floor. Anything less, and PCB cannot migrate to a plugin — it uses all of these surfaces today.

### 2.3 Design sketch

**Manifest extension.** Today's `"ui": {"panels": ["foo"]}` becomes typed entries:

```json
"ui": {
  "panels": [
    {
      "name": "cad_viewer",
      "kind": "godot_scene",
      "entry_scene": "ui/CadViewer.tscn",
      "scripts": ["ui/CadViewer.gd", "ui/CadCanvas.gd", "ui/OrbitCamera.gd"],
      "file_extensions": [".mcad"],
      "ipc_channels": ["cad.render_request", "cad.annotation_added"]
    }
  ]
}
```

Legacy string entries continue to parse as `{kind: "html", entry: "ui/foo.html"}` for backward compatibility.

**Scene loading.** `ResourceLoader.load(entry_scene).instantiate()` with plugin-relative resolution. All referenced scripts must be declared in `scripts[]`; anything on disk but not in the manifest is rejected at load. This is cheap now and leaves a door open for tighter sandboxing later without redesigning the manifest.

**Scene ↔ MCP broker.** New `PluginScenePanelBroker` (analog of the existing `PluginWebviewBroker`). Scene emits signals on declared `ipc_channels`; broker routes to the plugin's MCP process. Reverse direction: plugin pushes messages to the broker, which dispatches to the scene via a Minerva-provided singleton on the scene's node path.

**Lifecycle hooks.** The plugin's root scene node may implement:
- `_on_panel_loaded(ctx)` — called after instance, after IPC wiring. `ctx` includes plugin id, data directory, and the broker handle.
- `_on_panel_unload()` — called before free, allows graceful teardown.

Scene is freed on plugin stop/reload; reinstanced on restart.

**Namespacing.** Plugins must prefix `class_name` declarations with plugin id (`class_name Cad_Viewer`, not `class_name Viewer`). Install-time collision check against other installed plugins and against Minerva's own `class_name` list.

**Hot-reload.** `.gd` and `.tscn` added to the auto-reload watch list (currently `py/js/sh/json`). On `.gd` change, attempt live `GDScript.reload()`; on failure (known fragile for syntactically invalid GDScript), fall back to plugin stop/start.

**Trust model.** Matches existing plugin policy — user-approved on install, audit-logged. Godot-scene plugins have full engine access. Rationale: we already run arbitrary user-approved Go/Python binaries with full OS access; a scene inside Godot is not a broader attack surface. An API whitelist would be security theater we'd spend effort building and users would routinely disable.

### 2.4 Prior art

- **`rich-panel` experiment** (`~/gitlab/ccsandbox/experiments/rich-panel`). Proves GDScript-load-at-runtime (`GDScript.new()` / `reload(source)` / `new()`) and end-to-end MCP↔Godot UI. Does **not** solve: `.tscn`-from-plugin loading (it loads source strings), plugin-relative paths, reverse IPC (panel → MCP), lifecycle hooks, or trust model. We copy its loader mechanic, replace its HTTP-on-:3030 bridge with the `PluginScenePanelBroker`, and add the missing contracts.
- **PCBEditor** (`src/Scripts/UI/Controls/PCBEditor/`). The in-tree pattern we imitate: pure data model (RefCounted) + canvas (Control with `_draw()`) + MCP tool module via `MCPToolModule` subclass + programmatic UI in `_build_ui()`. Not itself a plugin yet — its migration validates the plugin platform.

### 2.5 Migration path for editors

Not every editor wants to be a plugin, and not every editor should move at once.

| Editor | Migration plan |
|--------|----------------|
| **CAD** | Built as a plugin from day one. First consumer, validates the platform. |
| **PCB** | Migrates to a plugin after CAD proves the path. |
| **Graphics** | Possible plugin candidate; decide after CAD + PCB. Its reliance on in-engine image manipulation is an argument either way. |
| **Spreadsheet** | Stays native. Tightly coupled to Minerva core. |
| **Text** | Stays native. Same. |

### 2.6 MVP scope

Smallest useful milestone: a "hello" plugin that registers a custom file extension, ships a Godot scene with a button, receives an MCP call that updates the scene's label, and saves/loads a trivial document to a plugin-defined file format. All lifecycle surfaces (install, start, stop, reload, project-export hook) exercised. Validated in isolation before CAD or PCB touches it.

---

## 3. Annotations

### 3.1 Design principles

- **Annotations attach spatially, not by object identity.** An annotation stores a position (or a pair, for arrows), not a reference to a trace/edge/component. "What is this pointing at?" is a spatial query answered at read time, not a stored fact.
- **No anchor-repair subsystem.** If the trace moves, the arrow stays where it was. Humans or LLMs re-point or delete. This is an explicit non-goal, not a bug.
- **Annotations are not ephemeral at the system level.** Humans and LLMs create and delete them whenever. The storage format has no TTL, no auto-cleanup, no `ephemeral` flag. Many uses will be short-lived in practice; that's a usage pattern, not a schema concern.
- **Annotations are different from Notes.** Notes are document-level, free-floating, attached to threads. Annotations are element-level, positional, attached to a document's visual surface. Don't conflate.
- **Core owns the substrate; plugins contribute kinds.** Annotation data is editor-agnostic JSON, stable across installs. Plugins extend the set of annotation *kinds* via a registry, not by subclassing or replacing the namespace.

### 3.2 Core data model

```json
{
  "id": "ann_01",
  "author": "human" | "ai",
  "kind": "2d_arrow" | "2d_text" | "2d_region" | "2d_highlight" |
          "2d_measure_distance" | "2d_measure_angle" | "2d_measure_radius" |
          "cad_3d_plane" | "<plugin-registered>",
  "view_context": "pcb" | "cad:top" | "cad:front" | "cad:right" | "cad:iso" |
                  "cad:world" | "graphics" | "text",
  "primitives": [ ... ],
  "payload": { "text": "move this trace" },
  "created_at": "2026-04-24T..."
}
```

Primitives are editor-independent 2D drawing elements:

```json
{ "kind": "arrow", "from": [x1, y1], "to": [x2, y2] }
{ "kind": "text", "at": [x, y], "content": "..." }
{ "kind": "region", "points": [[x1,y1], [x2,y2], ...] }
```

What varies across annotation kinds is **what coordinate system the primitives live in**.

### 3.3 2D annotations (PCB, Graphics, Text)

Primitives live in document-local 2D coordinates (mm on the PCB, pixels or vector units in Graphics, line+column or character-range in Text). Straightforward.

### 3.4 3D annotations (CAD) — the annotation plane

CAD's 3D geometry breaks the 2D assumption. An arrow drawn in a top-view SubViewport is nonsensical in the iso view. Solution: annotations are authored **on a plane in world 3D**, and primitives are 2D in the plane's local coordinates.

```json
{
  "id": "ann_17",
  "author": "human",
  "kind": "cad_3d_plane",
  "view_context": "cad:world",
  "plane": {
    "origin": [x, y, z],
    "normal": [nx, ny, nz],
    "u_axis": [ux, uy, uz]
  },
  "primitives": [
    { "kind": "arrow", "from": [u1, v1], "to": [u2, v2] },
    { "kind": "text", "at": [u, v], "content": "too sharp" }
  ]
}
```

Planes can be authored by picking a face, by picking three points, or by aligning with a view. Matches how SolidWorks / Fusion / Onshape do 3D sketches and callouts.

An annotation authored on a plane is **visible in all views** that see that plane. An annotation authored in `view_context: "cad:top"` (not world-scoped) is visible only in the top SubViewport — useful for "circle this feature during discussion" without committing to a world-3D callout.

### 3.5 Plugin extension: registry + renderer dispatch

Three patterns were considered:

- **Inheritance** (plugin class extends core annotation class): fragile across plugin boundaries; zombie subclasses on unload; couples plugin version to core.
- **Namespace replacement** (plugin replaces annotation module): last loaded wins; plugins can't cooperate; core loses control of storage.
- **Registry** (plugins register new kinds with a small contract): chosen.

The contract:

```
AnnotationKind {
  name: "cad_3d_plane"                // globally unique discriminator
  schema: { ... }                     // JSON schema for the data blob
  render(surface_ctx, annotation)     // draw in the editor's render surface
  hit_test(annotation, point) -> bool
  bounds(annotation) -> Rect2
  author_ui (optional)                // authoring tool UI for this kind
}
```

Core ships built-in kinds. Plugins register new kinds at startup. **Annotation data is editor-agnostic JSON**, so an `.mcad` or `.minpcb` file's annotations round-trip regardless of which plugins are loaded. Unknown kinds render as a grey placeholder with a "plugin not installed: cad" tooltip — not silently dropped, not loudly erroring.

This gives us three guarantees:
- A fresh Minerva install can read any project's annotations; built-in 2D primitives always render.
- Plugins are additive, not replaceable. CAD registers `cad_3d_plane`; PCB later registers `pcb_net_callout`; they coexist.
- Serialization is stable across installs.

### 3.6 Storage: sidecar

Annotations live in a sidecar file next to the document: `foo.mcad` ↔ `foo.mcad.annotations.json`; `foo.minpcb` ↔ `foo.minpcb.annotations.json`. Reasons:

- Git-friendly; annotations diff cleanly as JSON.
- LLM can read/edit via generic `file_read`/`file_edit` tools.
- Portable across machines without Minerva-specific indexing.
- Survives copy-paste of the raw file.
- Plays cleanly with Minerva project-export: both files get packed together.

Sidecar trades off against centralized storage (single table in the Minerva project file, keyed by document URL), which would make "show me all stale annotations across the project" trivial but wouldn't travel with files outside Minerva.

**Path semantics** (fix now to avoid drift):
- Paths inside the sidecar are resolved relative to the sidecar's containing directory.
- Absolute paths stay absolute.
- On project export, paths are rewritten to package-relative.
- On unpack, paths are rewritten back to absolute.

### 3.7 MCP surface

```
minerva_annotations_list(document_path) -> [Annotation]
minerva_annotations_add(document_path, annotation) -> {id}
minerva_annotations_update(document_path, id, patch) -> {ok}
minerva_annotations_delete(document_path, id) -> {ok}
minerva_annotations_render_overlay(document_path, view) -> {image_png}
```

Per-editor tools (e.g., `mcad_render`) can include annotations in their output via a `show: [..., "annotations"]` flag.

### 3.8 PCB migration

PCB's existing annotation system (`PCBData.gd`: `PCBAnnotation` + `PCBRouteHint`, authored `"human"` or `"ai"`) is a partial implementation of this substrate. Migration:

1. Core annotation subsystem ships. PCB keeps its existing annotations running unchanged.
2. PCB's existing annotation kinds migrate to platform-registered kinds (`pcb_2d_arrow`, `pcb_2d_region`). Data format stabilizes at the platform's.
3. PCB route-hints might stay PCB-specific (they're not really annotations — they're AI routing directives with structural meaning) or fold in as another kind. Decide during migration.

Timing: after CAD is working.

---

## 4. CAD (first consumer)

### 4.1 Vision

LLMs and humans collaborate on parametric CAD, each in their preferred medium.

- **Humans work mostly graphically.** 4-view canvas, orbit/zoom/pan, annotate with arrows/regions/measurements. "The object exists; I describe what to change."
- **LLMs work mostly in code.** Textual DSL (`.mcad`) they author, edit, regenerate. "The object is a program; I compose its definition."
- **Both can cross over.** Humans drop into the DSL via Minerva's TextEditor. LLMs see renders and annotations via MCP tools.

The shared artifact is the `.mcad` file. The collaboration pattern mirrors PCBEditor: one text editor on the source, one dedicated CADEditor panel for the graphical surface. They share a file, not a panel.

### 4.2 Backend architecture

```
Minerva ─stdio MCP─▶ CAD plugin (Go binary)
                     │
                     └─subprocess, JSON-over-stdio─▶ Python worker
                                                      (Build123d / OCCT)
```

- **Go MCP server**: protocol, `.mcad` I/O, `.mcad.annotations.json` sidecar coordination, render/export orchestration, Godot-scene panel.
- **Python worker as a subprocess**: runs the existing `mcad/` package (lex/parse/translate/evaluate/export) almost unchanged. Subprocess isolation over in-process `goempy` because OCCT's C++ exceptions are real and we want crash isolation. `goempy`-style embedding remains an optimization path if packaging or latency later demands it.

**Why Go + Python, not pure Go or pure Rust.** Pure Go has no credible B-Rep library in 2026 (every option is mesh/SDF-based, reintroducing the approximation we're trying to escape). Rust + `opencascade-rs` is LGPL-encumbered, has open fillet/chamfer crashes, and requires a full rewrite of the 1899-line translator. Go + embedded-or-subprocess Python + Build123d keeps the existing translator intact and rides the most battle-tested OCCT wrapper in the ecosystem. Revisit in ~18 months if `opencascade-rs` hardens.

### 4.3 `.mcad` file format

Pure DSL text on disk. Annotations live in the platform sidecar: `foo.mcad` + `foo.mcad.annotations.json`. The sidecar also holds reference geometry pointers and view state:

```json
{
  "version": 1,
  "annotations": [ /* platform-standard shape, see §3.2 */ ],
  "reference": {
    "path": "/abs/or/rel/to/scan.stl",
    "kind": "stl" | "pointcloud_ply" | "pointcloud_pcd",
    "transform": [[1,0,0,0],[0,1,0,0],[0,0,1,0],[0,0,0,1]],
    "opacity": 0.35
  },
  "view_state": {
    "layout": "quad" | "single",
    "cameras": {"top": {...}, "front": {...}, "right": {...}, "iso": {...}}
  }
}
```

**Reference geometry persistence policy:**
- In project files: path-reference only. Don't bloat every save with scan data.
- In project exports (`.minpackage`): copy the STL/PLY into the package's `files/` and rewrite the path at pack time.
- In the sidecar at rest: always a path. Transform and opacity live alongside.

For single-file portability when emailing a project, add `File → Export as Bundle…` that produces a `.mcadproj` zip — separate from the working format.

### 4.4 CAD panel

True 4-view (2×2 SubViewports): top, front, right, isometric. Preset-switch on one viewport is a v0 shortcut, not a v1 product — engineers expect the four-pane layout. First-angle / third-angle projection toggle in settings.

Ported from the MCAD experiment's Godot app: `mesh_display.gd` (tessellated mesh rendering), `edge_overlay.gd` (edge number labels), `orbit_camera.gd` (orbit/pan/zoom). The experiment's `view_pane.gd` single-viewport UI is replaced by the 4-view layout.

Annotation authoring toolbar is contributed by the platform, with CAD registering the `cad_3d_plane` kind and its authoring UI.

### 4.5 MCP tool surface

Composable, enum-valued parameters preferred over many narrow tools.

```
mcad_validate(source) 
  -> { ok, errors: [{line, col, message}], warnings: [...] }

mcad_render(
  view: "top" | "front" | "right" | "iso" | "all4",
  show: ["mesh", "edges", "edge_numbers", "reference",
         "deviation_heatmap", "annotations"],
  width?, height?
) -> { image_png, edge_map?, metadata }

mcad_list_edges(source) -> [{ id, kind, coords, ... }]

mcad_deviation(dsl_output_ref, reference_ref) 
  -> { max_mm, rms_mm, p95_mm, per_region: [...] }

mcad_export(
  format: "stl_binary" | "step" | "blender_quad" | "drawing_pdf" | "dxf_2d",
  source_path, output_path, options?
) -> { ok, path, warnings? }
```

`mcad_validate` as a first-class fast-feedback tool is important — the LLM's inner loop is "write DSL, know if it parses and evaluates" before it asks for a render.

### 4.6 Exports

**v1 (core loop):**
| Format | Use case | Notes |
|--------|----------|-------|
| Binary STL | 3D/resin printing | Direct Build123d export |
| STEP | CNC, CAM handoff | Direct Build123d export; universal machine-shop format |

**Post-v1 (real engineering work each):**
| Format | Use case | Notes |
|--------|----------|-------|
| Blender (quads + UVW) | Game assets | Headless Blender subprocess for retopo + UV unwrap. Fail gracefully if Blender absent. |
| Engineering drawing (PDF) | Manufacturing quotes, shop floor | OCCT HLRBRep → 2D projection → PDF. v1 scope if/when we do it: 3-view ortho + iso + linear/diameter/angular dims + title block + ANSI/ISO toggle. **Deferred from v1**: GD&T, section views, detail views, surface finish symbols. |
| DXF-2D | Laser/waterjet | Bonus if cheap after drawings |

### 4.7 Guiding scenario

A human crashes their car into the garage, breaks the driver-side mirror, scans the shards with a Revopoint/Shining3D, and asks the LLM to recreate the mirror's parametric geometry. Once the model exists, the human repositions shards virtually, verifies against scans, and exports STL for resin reprinting.

This exercises everything: pointcloud import, noise discrimination, shard registration, visual diffing, LLM-in-the-loop DSL synthesis, quantitative deviation, manufacturing export. Possibly impossible for v1. It's the forcing function that shapes capability design, not an acceptance test.

Day-to-day development targets: T-beam with countersunk holes, mouse body (both already used in the experiment). More added by trial and error.

### 4.8 Scenario phasing

- **P0 (v1)**: DSL → compile → render → 4-view → annotations → STL/STEP export. Reference geometry overlay. The core loop.
- **P1**: `mcad_deviation` quantitative tool (Hausdorff, RMS, per-region heatmap). LLM gets a scalar handle on "how wrong, where."
- **P2**: Pointcloud import (PLY/PCD) with preprocessing sidecar — denoise, normal estimation, optional RANSAC primitive detection. LLM receives interpreted hints ("this region ≈ cylinder r≈12mm") rather than raw noise.
- **P3**: Shard registration/reassembly tooling — ICP or feature-based pose estimation. Possibly a sibling plugin.
- **P4 (north star)**: closed-loop auto-fit. Gradient-free optimization over a discrete DSL space; research-grade for open-ended geometry, feasible for parameterized templates.

Reference overlay + `mcad_deviation` move earlier than the MCAD experiment had them — that loop is the differentiated part of the product. Exports beyond STL/STEP come after.

---

## 5. Cross-Cutting: Development Sequencing

Order reflects dependency, not importance.

1. **Plugin platform MVP.** Hello-world scene-hosted editor tab. File extension registration. Scene↔MCP IPC round-trip. Save/load/project-export hooks.
2. **Annotation substrate.** Data model, sidecar file convention, built-in 2D kinds, kind registry API, MCP tools. No editor-specific rendering yet — just the plumbing.
3. **CAD plugin scaffold.** Manifest, Go MCP stub, empty Godot scene panel, subprocess-to-Python-worker skeleton.
4. **Port MCAD backend** (Python `mcad/` package into the plugin, wired through the subprocess bridge). Add `mcad_validate` early.
5. **CAD panel UI.** 4-view layout, mesh rendering, edge overlay (port from experiment).
6. **Annotations in CAD.** Register `cad_3d_plane` kind. Basic 2D annotation authoring in each SubViewport.
7. **Reference geometry overlay + `mcad_deviation`.** The differentiated loop. Prioritized ahead of advanced exports.
8. **Exports v1.** STL + STEP. Project-export hooks for the sidecar and reference geometry.
9. **T-beam and mouse-body scenarios end-to-end.** Iterate MCP surface from what scenarios demand.
10. **Pointcloud import + preprocessing sidecar.**
11. **PCB migration to plugin.** Validates generality of the platform.
12. **Engineering drawings / Blender / shard registration** as separate streams. No longer on the CAD v1 critical path.

---

## 6. Open Questions

1. **Go↔Python bridge mechanics.** Subprocess chosen; remaining: message framing (newline-delimited JSON vs length-prefixed), child lifetime (per-request vs long-lived), error surface.
2. **Lifecycle hook `ctx` shape.** What's in `_on_panel_loaded(ctx)`? At least: plugin id, data directory, broker handle. Anything else?
3. **Annotation kind schema validation.** Where does the JSON schema live — manifest, registration call, separate file?
4. **PCB route-hints**: migrate to an annotation kind, or stay structural?
5. **Graphics migration decision.** Plugin candidate, or stays native?
6. **Blender sidecar script distribution.** `go:embed` into the plugin binary and write to tempdir per invocation? Versioning?
7. **Project-file vs project-export hooks for plugin-contributed editors.** PluginDefinition needs a way to declare "my editor kind serializes like this" so Minerva's existing project-file writer can delegate.

---

## 7. Non-Goals / Deferred

- **Anchor repair.** Explicit non-goal; annotations are spatially anchored and don't chase moving objects. Human/LLM deletes or re-points.
- **Ephemeral flag on annotations.** Not in the schema. All annotations are persistent from the system's view.
- **Texturing/painting** (Wafer, Material Maker). Post-MVP CAD work.
- **GD&T, section views, surface finish callouts** in engineering drawings.
- **`opencascade-rs` migration.** Revisit in ~18 months.
- **Pointcloud→DSL framed as reversing geometry.** The LLM hypothesizes DSL and convergence-tests against quantitative deviation.
- **API-whitelist sandboxing of plugin Godot scenes.** Match existing plugin trust model; don't build security theater.

---

## 8. Prior Art Referenced

- `rich-panel` (`~/gitlab/ccsandbox/experiments/rich-panel`) — runtime GDScript loading, MCP↔Godot-UI bridge end-to-end. Partial; gaps documented in §2.4.
- PCBEditor (`src/Scripts/UI/Controls/PCBEditor/`) — the in-tree pattern. Data-model + canvas + MCP tool module; programmatic UI in `_build_ui()`; undo history + change journal; annotation authoring with human/ai author field. First migration target after CAD.
- MCAD experiment (`~/gitlab/ccsandbox/experiments/cad`) — the CAD code we port. Python backend (Flask today → MCP stdio as a plugin), GDScript frontend (single-viewport today → 4-view), polar-sweep edge numbering, T-beam V1 test part.
- Minerva plugin system (`src/plugins/plugin_system_guide.md`) — the base we extend.

# CAD Plugin — Thought Paper

**Status:** Design exploration / pre-implementation
**Date:** 2026-04-23
**Context:** Emerged from discussion about porting the MCAD experiment (`~/gitlab/ccsandbox/experiments/cad`) into Minerva as a first-class plugin. Written after exploration of the experiment, the existing Minerva plugin system, and the PCBEditor reference pattern.

---

## 1. Vision

LLMs and humans collaborate on parametric CAD, each working in the medium they're best at.

- **Humans work mostly graphically.** They want to see the thing, orbit it, point at edges, measure things, circle regions. Their mental model is "the object exists; I describe what to change about it."
- **LLMs work mostly in code.** They want a textual DSL they can author, edit, reason about, and regenerate. Their mental model is "the object is a program; I compose its definition."
- **Both can cross over.** Humans can drop into the DSL via Minerva's TextEditor when they want precision. LLMs can see renders and annotations via MCP tools when they need to close the loop multi-modally.

The shared artifact is the `.mcad` file — a textual DSL that compiles to precise B-Rep geometry via OCCT. Annotations and reference geometry live alongside it, scoped to the same project.

The collaboration pattern mirrors PCBEditor: one Minerva text editor operating on the source, one dedicated CADEditor panel for the graphical/annotative surface. They share a file, not a panel.

---

## 2. Guiding Scenario

A human crashes their car into the garage and breaks the driver-side mirror. They scan the shards with a consumer 3D scanner (Revopoint, Shining3D) and bring the point clouds into Minerva. They ask the LLM to recreate the mirror's original geometry in DSL form. Once a parametric model exists, the human can reposition shards virtually, verify the reconstruction against the scans, and export STL for resin reprinting.

This scenario exercises everything simultaneously: pointcloud import, noise-vs-geometry discrimination, shard registration, visual diffing, LLM-in-the-loop DSL synthesis, quantitative deviation measurement, and manufacturing export. It is intentionally at the edge of feasibility — possibly impossible for v1. It serves as the forcing function that shapes capability design, not as an acceptance test.

Less-ambitious scenarios that will drive day-to-day development:
- T-beam with countersunk holes (already used in the experiment)
- Mouse body (aspirational loft example from the experiment)
- Further scenarios added by trial and error during integration

---

## 3. High-Level Architecture

```
┌────────────────────────────────────────────────────────────┐
│                         Minerva                            │
│                                                            │
│  ┌──────────────────┐      ┌──────────────────────────┐   │
│  │  TextEditor      │      │  CADEditor panel          │   │
│  │  (.mcad source)  │◄────►│  (4-view, annotations)    │   │
│  └──────────────────┘      └──────────────┬───────────┘   │
│                                            │               │
│                                            │ IPC           │
│  ┌─────────────────────────────────────────▼───────────┐   │
│  │       Minerva plugin system (stdio MCP)             │   │
│  └─────────────────────────────────────────┬───────────┘   │
└────────────────────────────────────────────┼───────────────┘
                                             │ JSON-RPC
                    ┌────────────────────────▼────────────┐
                    │     CAD plugin (single Go binary)    │
                    │                                      │
                    │  ┌─────────────┐    ┌─────────────┐ │
                    │  │  Go MCP     │    │  Embedded   │ │
                    │  │  server +   │◄──►│  Python +   │ │
                    │  │  .mcad I/O  │    │  Build123d  │ │
                    │  └─────────────┘    └─────────────┘ │
                    └──────────────────────────────────────┘
```

- **Go layer**: MCP stdio server, `.mcad` file I/O, annotation/reference/view-state management, render coordination, export pipeline coordination.
- **Python layer**: lex/parse/translate/evaluate/export — the full existing `mcad/` package, dropped in almost unchanged. Runs in-process via `goempy` (go:embed + Astral's python-build-standalone) or as a child process, depending on what's cleanest.
- **Minerva TextEditor**: operates on `.mcad` as plain text. No special case needed — it is plain text.
- **CADEditor panel**: ships with the plugin as a Godot scene (not HTML). Loaded via an extension to Minerva's plugin system (see §6).

---

## 4. Key Decisions

### 4.1 Backend kernel: Go + embedded Python + Build123d

Investigated alternatives:
- **Pure Go**: no credible B-Rep option in 2026. Every pure-Go CAD library (`sdfx`, `fauxgl`, `soypat/sdf`) is mesh/SDF-based, which re-introduces the exact approximation we're trying to escape.
- **Rust + opencascade-rs**: technically viable but LGPL-encumbered, fillet/chamfer crashes open, requires full Rust rewrite of the 1899-line `translator.py`. ~1 person-quarter of extra work for marginal runtime gain.
- **Go + embedded Python + Build123d** (chosen): ~25–30 MB compressed binary via `goempy`, single `go build` per platform, no Docker, zero install burden on end users. Keeps the existing translator intact. OCCT via the most battle-tested Python wrapper in the ecosystem.

Revisit in ~18 months if `opencascade-rs` hardens.

### 4.2 Two editors (text + graphical), mirror of PCB

Matches the existing PCBEditor pattern. Humans use whichever editor matches their mental mode; LLMs primarily use the TextEditor (standard `file_read`/`file_edit` tools work without special support) and the CAD MCP tools for rendering and deviation feedback.

### 4.3 `.mcad` file format: pure DSL on disk + `.mcad.meta.json` sidecar

Rubric grading across nine criteria (DSL UX inside/outside Minerva, LLM UX via generic file tools, git diff, merge conflicts, robustness, portability, implementation cost, reference-geometry handling) favored this split decisively. The pure-DSL file remains grep/diff/merge-friendly; the sidecar holds annotations, reference geometry pointers, and view state as structured JSON.

For single-file portability when emailing a project, provide `File → Export as Bundle…` that produces a `.mcadproj` zip, separate from the working format.

### 4.4 Reference geometry persistence policy

- **In project files**: path-reference only. Don't bloat every save with 10s of MB of scan data.
- **In project exports (`.minpackage`)**: copy the referenced STL/PLY into the package's `files/` directory and rewrite the path at pack time. Exports are the "it must work on another machine" artifact; embedding refs is the user's expectation there.
- **In `.mcad.meta.json` at rest**: always a path. The transform matrix and opacity live alongside the path.

### 4.5 True 4-view canvas (2×2 SubViewports)

Engineers expect it. Preset-switch on a single viewport is a v0 shortcut, not a v1 product. The rendering cost (4× draw calls for the CAD panel) is acceptable given CAD panels aren't continuously redrawn like game worlds.

Views: top, front, right, isometric (swappable to first-angle projection for ISO users).

### 4.6 Plugin system extension: Godot-scene front-ends

The current plugin system only supports HTML webview panels. We extend the manifest's `ui.panels` to a typed form:

```json
"ui": {
  "panels": [
    {
      "name": "cad_viewer",
      "kind": "godot_scene",
      "entry_scene": "ui/CadViewer.tscn",
      "scripts": ["ui/CadViewer.gd", "ui/CadCanvas.gd", "ui/OrbitCamera.gd"],
      "ipc_channels": ["cad.render_request", "cad.annotation_added", "cad.deviation_computed"]
    }
  ]
}
```

Legacy `"panels": ["foo"]` strings continue to parse as `{kind: "html", entry: "ui/foo.html"}` for backward compatibility.

Design elements:
- **Loading**: `ResourceLoader.load(entry_scene).instantiate()`. All referenced scripts must be listed explicitly in `scripts[]`; anything on disk but not in the manifest is rejected at load (upgrade path to tighter sandboxing later without redesigning the manifest).
- **Path scoping**: all paths resolved relative to the plugin's `data_directory`. No `..` escapes, no absolute paths, no `res://` references to Minerva internals.
- **Trust model**: matches existing plugin policy — user-approved on install, audit-logged. Godot-scene plugins have full engine access. Rationale: we already run arbitrary user-approved Go/Python binaries with full OS access; a GDScript scene inside Godot is not a broader surface than those binaries. Pretending otherwise with an API whitelist would be security theater.
- **Namespacing**: plugins must prefix `class_name` declarations with plugin ID (`class_name Cad_Viewer`, not `class_name Viewer`). Validation at install-time for collisions.
- **Lifecycle**: formal hooks `_on_panel_loaded(plugin_ctx)` and `_on_panel_unload()`. Scene freed on plugin stop/reload; reinstanced on restart.
- **Hot reload**: `.gd`/`.tscn` added to the auto-reload watch list (currently `py/js/sh/json`). Runtime `reload()` of GDScript is known to be fragile on invalid source; plugin reload falls back to stop/start when reload fails.

### 4.7 Prior art referenced

- **`rich-panel` experiment** (`~/gitlab/ccsandbox/experiments/rich-panel`): proves the GDScript-load-at-runtime mechanic and the MCP↔Godot UI bridge end-to-end. Does not solve plugin-relative paths, reverse IPC (panel → MCP), lifecycle hooks, or trust model. We copy its loader mechanic, replace its HTTP bridge with a proper `PluginScenePanelBroker` (analog of the existing `PluginWebviewBroker`), and add the missing contracts.
- **PCBEditor** (`src/Scripts/UI/Controls/PCBEditor/`): the pattern we imitate for data-model/canvas/MCP-tool-module split. Not itself a plugin — it's in-tree — but its shape transfers.
- **MCAD experiment** (`~/gitlab/ccsandbox/experiments/cad`): the code we port. Python backend, GDScript frontend, polar-sweep edge-numbering innovation, T-beam as V1 test part.

---

## 5. MCP Tool Surface (v1 sketch)

Composable, enum-valued parameters preferred over many narrow tools.

```
mcad_render(
  view: "top" | "front" | "right" | "iso" | "all4",
  show: ["mesh", "edges", "edge_numbers", "reference", "deviation_heatmap", "annotations"],
  width?: int, height?: int
) -> {image_png: bytes, edge_map?: [...], metadata}

mcad_deviation(dsl_output_ref, reference_ref) 
  -> {max_mm, rms_mm, p95_mm, per_region: [...]}

mcad_list_edges(dsl_source) -> [{id, kind, coords, ...}]
mcad_get_annotations(project_path) -> [{id, kind, author, anchor, payload, ...}]

mcad_export(
  format: "stl_binary" | "step" | "blender_quad" | "drawing_pdf" | "dxf_2d",
  source_path, output_path,
  options?: {...}  // format-specific (e.g., projection: first|third for drawing_pdf)
) -> {ok, path, warnings?}
```

Further tools added through scenario testing. Measurement queries, parameter sweeps, and pointcloud preprocessing are likely additions.

---

## 6. Exports

Four supported formats on the manufacturing path. Texturing/painting deferred.

| Format | Use case | Implementation notes |
|--------|----------|----------------------|
| **Binary STL** | 3D printing, resin printing | Direct Build123d export |
| **STEP** | CNC, CAM handoff | Direct Build123d export; universal machine-shop lingua franca |
| **Blender (quads + UVW)** | Game assets, rendering pipelines | Requires headless Blender subprocess (`blender --background --python retopo.py`). OCCT tessellates to triangles; quad retopo + UV unwrap is Blender's job. **Fail gracefully if Blender absent.** |
| **Engineering drawing (PDF)** | Manufacturing quotes, shop floor | OCCT HLRBRep (hidden-line removal) → 2D projection → PDF. v1: 3-view orthographic + isometric + linear/diameter/angular dimensions + title block + ANSI/ISO projection toggle. **DXF-2D as bonus** if cheap. **Deferred**: GD&T, section views, detail views, surface finish symbols, thread callouts. |

---

## 7. Guiding-Scenario Phasing

The broken-mirror scenario is the north star. Capability delivery is phased so each phase is useful on its own:

- **P0 (v1)**: STL import, semi-transparent reference overlay in 4-view. LLM iterates manually using rendered views.
- **P1**: `mcad_deviation` quantitative tool — Hausdorff, RMS, per-region heatmap render. LLM has a scalar handle on "how wrong, where."
- **P2**: Pointcloud import (PLY/PCD) with preprocessing sidecar — denoise (statistical outlier removal), normal estimation, optional RANSAC primitive detection. LLM receives interpreted hints ("this region ≈ cylinder r≈12mm") rather than raw noise.
- **P3**: Shard registration/reassembly tooling — ICP or feature-based pose estimation for multi-part inputs. Possibly a sibling plugin rather than part of CAD.
- **P4 (north star)**: closed-loop auto-fit. LLM proposes DSL; pipeline evaluates deviation; LLM refines until under tolerance. Gradient-free optimization over a discrete DSL space is its own research problem; feasible for parameterized templates, genuinely hard for open-ended synthesis.

---

## 8. `.mcad.meta.json` Schema Sketch

```json
{
  "version": 1,
  "annotations": [
    {
      "id": "ann_01",
      "kind": "arrow" | "text" | "region" | "measure_distance" | "measure_angle" | "measure_radius",
      "author": "human" | "ai",
      "view": "top" | "front" | "right" | "iso" | "world",
      "anchors": [{"edge_id": 4}, {"point": [x, y, z]}],
      "payload": {"text": "too sharp", "value_mm": 12.5},
      "created_at": "2026-04-23T..."
    }
  ],
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

Anchors reference **edge numbers** (stable under parameter change via the polar-sweep numbering) wherever possible. Point-anchors are the fallback.

---

## 9. Open Design Items

Captured here so they don't fall through the cracks as implementation begins:

1. **Scene ↔ MCP reverse bridge**. Webviews have `ipc.postMessage()`; GDScript panels currently have nothing. Need a symmetric mechanism — probably a `PluginScenePanelBroker` with register/emit APIs matching the webview broker's shape.
2. **Plugin-relative resource resolution**. `ResourceLoader` needs to load from the plugin's `data_directory`, not `res://`. Path rewrite at load-time or plugin-context object passed to the loader.
3. **Lifecycle hook signatures**. Exact shape of `_on_panel_loaded(ctx)` and `_on_panel_unload()`. What's in `ctx`?
4. **Namespacing validation**. Install-time scan for `class_name` collisions across installed plugins.
5. **Hot-reload resilience**. Fallback-to-stop/start on GDScript reload failure. Needs a retry budget to avoid thrash.
6. **Go↔Python bridge shape**. In-process via `goempy` vs child process with JSON-over-stdio. `goempy` gives tighter coupling; subprocess gives crash isolation for OCCT's C++ exceptions. Decide during prototyping.
7. **Blender sidecar script**. The retopo + UV unwrap `.py` needs to live somewhere. Ship inside the plugin binary (`go:embed`) and write to tempdir per invocation.
8. **Drawing generation**. HLRBRep ergonomics in Build123d need verification. Title-block templating. Sheet sizes (A/A0–A4, US Letter/Tabloid).

---

## 10. Non-Goals / Deferred

- **Texturing/painting** (Wafer 1.2, Material Maker 1.6). Post-MVP. Useful after the core loop works.
- **GD&T, section views, detail views, surface finish/thread callouts**. Post-v1. v1 drawings target the 80% of machine shops that quote from 3-view + dims.
- **opencascade-rs migration**. Revisit in ~18 months.
- **Pointcloud → DSL is not framed as reversing geometry.** The LLM is *hypothesizing* DSL and convergence-testing against quantitative deviation. This framing matters when setting expectations.

---

## 11. Development Sequencing (proposed)

Loose order. Each item is independently useful so sequencing can shift.

1. Scaffold plugin directory `src/plugins/cad/` with manifest, Go stub MCP server, empty Godot scene panel.
2. Design and prototype the `PluginScenePanelBroker` + Godot-scene plugin loading in Minerva's plugin system. Validate with a minimal "hello from Godot" scene.
3. Port the existing Python `mcad/` package into the plugin. Wire Go MCP tools → Python evaluator over the chosen bridge.
4. Implement TextEditor integration (just works — `.mcad` is plain text) and `.mcad.meta.json` sidecar handling in Minerva's file I/O.
5. Build CADEditor panel — 2×2 view layout, mesh rendering, edge overlay (port from experiment's `mesh_display.gd` + `edge_overlay.gd`).
6. Annotations: arrow/text/region authoring, then measurement tools.
7. Exports: STL, STEP (straightforward via Build123d). Then drawings. Then Blender (graceful-absence path).
8. Reference-geometry import (STL), semi-transparent overlay, `mcad_deviation` tool.
9. Project-file and project-export hooks (`EditorContainer.serialize/deserialize` case for CAD; reference-geometry copy at pack time).
10. T-beam and mouse-body scenarios end-to-end. Iterate the MCP surface from what scenarios demand.
11. Pointcloud import + preprocessing sidecar.
12. Shard registration (likely separate plugin by this point).

---

## 12. Feedback

Overall assessment: the direction is strong. The paper has a real product thesis, keeps the shared artifact centered on a plain-text `.mcad` file, and is unusually honest about the hard parts instead of hand-waving them away.

### What seems especially solid

- **Two-editor model is the right shape.** The split between TextEditor for the DSL and CADEditor for graphical interaction matches how humans and LLMs actually want to work.
- **Pure DSL + sidecar is the right storage model.** Keeping `.mcad` grep/diff/merge-friendly while moving annotations, reference geometry pointers, and view state into `.mcad.meta.json` is a good trade.
- **The broken-mirror scenario is a useful north star.** It is ambitious enough to force the right capability questions while still being explicitly framed as design pressure rather than a v1 acceptance test.
- **The paper phases the hard problem honestly.** P0 through P4 keeps the long-term vision visible without pretending that closed-loop auto-fit is easy.

### Main concern

This currently reads like two projects bundled together:

1. A CAD plugin with a DSL, renderer, exports, reference-geometry overlay, and deviation tooling.
2. A new Minerva plugin-platform capability for Godot-scene front-ends.

That platform work may be justified, but it is also a schedule risk because it becomes a prerequisite for proving the core CAD loop. If possible, the project should validate the CAD loop with the least novel host/platform work first, then harden the Godot-scene plugin system once the loop is real.

### Specific concerns and recommendations

- **Resolve the Go↔Python boundary early.** This is too central to stay open for long. The safest first move is a subprocess boundary with JSON-over-stdio: easier debugging, better crash isolation for OCCT/C++ failures, and less coupling during early iteration. Embedding can remain an optimization step if packaging or latency later demands it.
- **Add a compile/validate MCP tool early.** Render, deviation, and export are important, but the agent will need structured parser/translator/build diagnostics constantly. A boring `mcad_validate` or `mcad_build` tool that returns structured errors and warnings will probably matter more day-to-day than one more render variant.
- **Treat annotation-anchor repair as a first-class problem.** Stable edge numbering may get far, but topology-changing edits will still break anchors. The doc should probably assume anchor invalidation and define at least a minimal repair strategy instead of treating point anchors as enough of a fallback.
- **Define path semantics precisely.** The sidecar schema should state exactly how relative paths are resolved and normalized. That needs to be fixed early or portability and packaging behavior will become inconsistent.
- **Trim v1 exports if needed.** STL and STEP belong in the first useful cut. Blender retopo and engineering drawing generation both look like scope traps. They are good targets, but they should not delay the core DSL/render/reference/deviation loop.

### Sequencing adjustment I would make

Move reference-geometry overlay and `mcad_deviation` earlier in the development order. That feedback loop is the differentiated part of the product. It should come before lower-priority export work like drawings or Blender output.

### Bottom line

The architecture is defensible and the product direction is good. The most important discipline will be tightening v1 around this loop:

1. Edit DSL.
2. Compile and render reliably.
3. Overlay reference geometry.
4. Quantify deviation.
5. Iterate quickly.

If those five steps work well, the rest of the roadmap becomes much easier to justify and prioritize.

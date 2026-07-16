# PCB UI Native Cluster — R0 Contract

Umbrella: docket `019f6a69b8a2` (under DCR `019dc140`). Serial plan (owner-ratified
2026-07-16, Minerva sheets "PCB UI Work Plan" + "PCB UI Functional Tests"):
R0 (`019f6a89029b`, this doc) → WC-1 pin inspector (`019f6a8918fe`) → HITL-1 →
WC-2 substrate (`019f6a892ea4`) → WC-3 single-trace (`019f6a894a37`) → HITL-2 →
WC-4 bus (`019f6a895b64`) → HITL-3. One round may not start before the previous
round's gate is green.

Native-parity source of truth: tag `pre-cutover-2026-07-07` —
`PCBRouteHint.gd` (model), `PCBCanvas.gd` L82 RouteHintMode /
L1378 preview / L2361-2520 click flows, `PCBEditor.gd` 365-373 + 665-698
(pin inspector).

## 1. Spike findings (answered 2026-07-16)

**(a) Does AnnotationOverlay block canvas pan/zoom while a tool is active? YES.**
`AnnotationOverlay.gd:86` sets `MOUSE_FILTER_STOP` whenever a tool is active;
`pcb_canvas.gd:813+` takes middle-drag pan and wheel zoom via `_gui_input`,
which the overlay occludes. Corroborated by PCBPanel.gd:626 comment and the
CAD sticky-tool memory. **WC-2 fix**: the overlay treats only LEFT/RIGHT
buttons as tool input; MIDDLE, WHEEL_*, and InputEventPanGesture are forwarded
to a duck-typed host method `forward_navigation_input(event)` (PCB host relays
to the canvas). Tools never see navigation events.

**(b) Do key events reach author tools? ONLY Escape / Delete / Backspace.**
`AnnotationOverlay.gd:189-204` forwards those three as pseudo
`on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, <keycode>)` calls — an
established (if ugly) convention. Enter is NOT forwarded. **WC-2 fix**: forward
`KEY_ENTER`/`KEY_KP_ENTER` using the SAME pseudo-pointer convention (do not
invent a new hook). Bus phase-advance therefore gets both double-click and
Enter (E2E-7C keyboard branch is GO, pending that WC-2 change).

**(c) Does pcb_get_image render route hints today? YES when the panel is
visible on screen; NULL headless.** `_get_image` →
`PcbAnnotationHost.render_content_to_image` (PcbAnnotationHost.gd:377) is a
parent-viewport frame grab cropped to the canvas global rect; the overlay
mounts at `PCBPanel.get_annotation_overlay_parent()` sharing the canvas origin,
so overlay-drawn hints land inside the crop. Consequences:
- No new render path needed for agent SEE — WC-3 only adds probes/regressions.
- E2E pixel-probe steps (E2E-3A/B, E2E-6B) run WINDOWED (`xvfb-run` when no
  display); headless `pcb_get_image` returning the graceful null envelope gets
  its own assertion.
- Known limits (accepted, documented): capture is one frame behind on first
  call; a hidden tab yields a stale frame.

**(c2) Discovered bug while probing (filed `019f6a8d1391`, fix in WC-2):**
`MCPAnnotationTools._annotations_add` (MCPAnnotationTools.gd:975) kind-checks
against the GLOBAL registry, so plugin kinds (`pcb_route_hint`) are rejected
even with a valid live `editor_name` — agents currently cannot author
plugin-kind annotations via MCP at all (the apply-loop writes proposals via the
host directly). Fix: resolve the host first; use `host.get_registry()` for the
kind check, `primitives_optional`, and `dispatch_validate`, global as fallback
(mirrors the read path at :537-541). E2E-5 depends on this fix.

## 2. Pad API (WC-1)

`PcbAnnotationHost` gains two public, side-effect-free lookups (the private
`_pad_at` string helper is refactored to use them, not duplicated):

```
pad_at(doc_pos: Vector2, radius_mm := 5.0) -> Dictionary
  # {} on miss; else {component: "U1", pin: "15", position: Vector2 (board mm)}
  # Nearest pad wins inside the radius; deterministic tie-break by
  # (component, pin) lexicographic.

pin_info(component: String, pin: String) -> Dictionary
  # {} on unknown ref; else {
  #   ref: "U1.15", pin_name: String ("" if none),   # footprint geometry name
  #   net: String ("" if unconnected),
  #   net_members: ["J2.3", ...],                    # other pins on the net
  #   trace_ids: [...], trace_count: int }           # traces touching the pad
```

Display rule (native parity): geometry `pin_name` > `net` > `(unconnected)`.

## 3. Pin inspector UX (WC-1)

- Canvas mode INSPECT_PIN in the panel's mode cluster; toolbar toggle button,
  shortcut Shift+P, tooltip "Click on a pin to see its info (Shift+P)".
- Hover: nearest-pad label at cursor (native L1444 behavior). Click: select pin
  → Pin Info section in the panel (Component.Pin + display rule above +
  net_members list). Click empty space: clear + hide. Switching tools or
  toggling off clears selection. Escape exits the mode.
- Parity-plus (in scope if cheap, cuttable): selected pin's net members
  highlighted on canvas.
- MCP parity tool `minerva_pcb_pin_info` (MCPPcbPanelTools): args
  `{editor_name, ref: "U1.15"}` OR `{editor_name, x_mm, y_mm}` (routed through
  the SAME pad_at/pin_info calls). Returns pin_info dict + `display_name`
  exactly as the UI shows it. Garbage ref → structured error, not a crash.

## 4. Workflow-kind substrate contract (WC-2)

- `AnnotationKind` gains `workflow_class: bool = false`. `pcb_route_hint`
  declares true.
- Review annotations panel EXCLUDES workflow-class annotations; a separate
  workflow listing surface shows ONLY them (per-host, kind-grouped).
- Layer-keyed visibility: workflow annotations carrying `kind_payload.layer`
  respect the host's layer-visibility state (C3 = `019f33d2c9bf`; E2E-2D is a
  red-to-green repro). Exact hook shape is WC-2 implementer's choice; the
  behavior is pinned by E2E-2.
- MCP read surfaces (`annotations_list/query/resolve_ref`) are UNCHANGED —
  separation is UI-only (E2E-2C/E regression).
- Also in WC-2 (all core, all small, all spike-driven): navigation
  pass-through (§1a), Enter forwarding (§1b), annotations_add host-registry
  fix (§1c2).

## 5. Single-trace author tool (WC-3)

State machine (native L2406 parity):
```
IDLE --click pad--> DRAWING(source=pad)     # pad_at snap, radius 5mm
IDLE --click empty--> DRAWING(source=point)
DRAWING --click empty--> append waypoint
DRAWING --click pad--> commit(dest=pad)     # pad == source → CANCEL (self-ref)
DRAWING --double-click empty--> commit(dest=point)
DRAWING --right-click / Escape--> cancel
```
Commit emits `annotation_ready` with a `build_route_hint_envelope` envelope:
`hint_type=single_trace`, source_pins/dest_pins as available, interior
waypoints only, current layer, semantic pad anchor when source is a pad.
Live preview: dashed polyline + mode label + source-pin label (native L1378).
Rendering keeps the SHIPPED coloring (layer tint for human, substrate cyan for
AI author) — native teal/purple is superseded, not restored.
Clear-by-author (human / AI / all) via route listing + context menu, host-side
filter on `author.kind`.
In-panel route-flow toolbar cluster (conscious partial reversal of Round-B "no
authoring in panel"): buttons activate the substrate tools; implementations
remain `AnnotationAuthorTool`s. Tool activation is mutually exclusive; mode
label reflects the active mode; deactivation restores Select.

## 6. Bus author tool (WC-4)

3-phase machine (native L2436 parity): SOURCE_PINS → WAYPOINTS → DEST_PINS;
advance on double-click or Enter (§1b); duplicate-pin guard; commit envelope
`hint_type=bus`, waypoints = corridor ONLY (pad positions never duplicated into
waypoints).
**Contract decision (E2E-7B): mismatched counts.** Commit is REFUSED when
`dest_pins` is non-empty and `len(dest_pins) != len(source_pins)` (status
message explains); an EMPTY dest list is allowed (open corridor — router
resolves destinations from nets). Deterministic; the native editor's
silent-commit behavior is rejected.
Zero source pins: phase cannot advance (native parity).

## 7. LLM ergonomics (READ / SEE / ACT)

| Feature | READ (MCP) | SEE (image) | ACT |
|---|---|---|---|
| Pin inspector | `minerva_pcb_pin_info` ≡ panel display (same lookup) | n/a (ephemeral) | n/a |
| Route hints | `annotations_list/query` unchanged by WC-2 separation | hints + proposals visible in `pcb_get_image` (§1c) | `annotations_add` after §1c2 fix ≡ tool-authored (E2E-5, E2E-3C) |
| Board result | `pcb_get_components/get_nets/export` | traces render in image | `apply_route_hints` with REAL Go worker (owner-blessed) |

## 8. Acceptance matrix

E2E-1 … E2E-7 exactly as in the Minerva sheet "PCB UI Functional Tests"
(owner-blessed 2026-07-16). Gates per round: WC-1 → E2E-1; WC-2 → E2E-2;
WC-3 → E2E-3/4/5; WC-4 → E2E-6/7. Real Go route worker in E2E-3C/E2E-6C
(subprocess-boundary fake only as CI fallback when the built binary is absent).
Image-probe steps run windowed (`xvfb-run` acceptable). Granular seam checks
are implementer's discretion and gate nothing.

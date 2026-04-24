# Plugin Platform — Policy

**Status:** Active  **Date:** 2026-04-24

Pre-approved defaults for implementation of DCR-1, DCR-2, DCR-3, DCR-4 and related platform work. Sub-agents and the coordinating agent follow these without user interruption. Situations not covered here → escalate per `Plugin-platform-escalation.md`.

## Architecture

- Subprocess + JSON-over-stdio > in-process embedding when a language/runtime boundary is crossed. Trade tightness for crash isolation.
- Long-lived workers > per-request workers. Warm state + connection cost matters.
- Sidecar (`foo.ext.annotations.json`) > embedded blobs for per-document metadata.
- Registry + renderer dispatch > inheritance or namespace replacement for plugin extensibility.
- **There is no complete exemplar yet.** No existing Minerva code shows "Godot-scene front-end + out-of-process backend + MCP IPC + first-class editor tab" end-to-end. CAD is the first consumer; it establishes the pattern. Cite by concern, not by whole-system imitation:
  - *Canvas rendering + input handling*: PCBCanvas.gd (`Control._draw()`, world/screen transforms, input state machines).
  - *Manifest + Go MCP server + lifecycle + host capabilities*: OBS Controller plugin.
  - *Webview IPC broker shape (pattern for scene broker)*: PluginWebviewBroker.gd.
  - *GDScript runtime loading*: rich-panel experiment (note its HTTP bridge and source-string loading are **not** to be copied).
- **Data model ownership**: plugin owns its data in the Go/Python backend. The Godot scene is a view/controller that syncs via MCP IPC — **do not transfer PCBEditor's in-process data-ownership pattern**.
- **MCP tool registration**: tools declared in manifest and dispatched in the plugin's own MCP server (like OBS), **not** registered in Minerva's MinervaMCPServer. This is the direct inverse of how in-tree PCBEditor works.
- **Undo / change journal**: lives in the plugin backend. Scene queries it via IPC when needed.
- **UI composition**: prefer `.tscn` for static shell (layouts, anchors, themes, signal wiring) — use Godot's editor tooling. Build dynamic content in code: registry-driven toolbars, data-bound lists, runtime-varying children. Hybrid (`.tscn` scaffold + code fills dynamic parts) is expected.
- Editor-lookup patterns (like `MCPToolUtils.find_<kind>()`) are in-tree conveniences and **do not transfer** to plugins — the plugin's MCP server looks up its own scene via the broker, not via Minerva's editor registry.

## Conventions

- Plugin `class_name` prefix = plugin id (`Cad_Viewer`, not `Viewer`).
- Plugin-contributed annotation kinds named `<plugin>_<kind>` (e.g., `cad_3d_plane`).
- MCP tool names `<plugin>_<verb>[_<noun>]`.
- Prefer few composable MCP tools over many narrow tools.
- Closed-enum parameters when possible; open strings only for plugin-registered kinds.

## Error handling

- Fail gracefully + warn. Never silently drop.
- Go: wrap with `fmt.Errorf("context: %w", err)`. No silent swallowing.
- Godot: signal or log. No `print()` in shipped code.

## Trust

- Godot-scene plugins match existing plugin trust policy: user-approved on install, audit-logged, no new sandbox. No API whitelisting.
- Manifest `scripts[]` enforced at load — undeclared scripts rejected. Cheap guardrail; preserves upgrade path to tighter sandboxing without manifest redesign.

## Paths

- Sidecar-relative paths resolve against sidecar directory; absolute stay absolute.
- Project export rewrites paths to package-relative; unpack reverses.
- Plugin resources resolve relative to plugin `data_directory`. No `..`, no absolute paths, no `res://` to Minerva internals.

## Hot reload

- Attempt live reload first (GDScript.reload / ResourceLoader). Fall back to plugin stop/start on failure. No retry loop.

## Scope limits

- Bug fixes along the task path: fix in place.
- Adjacent refactors: file follow-up work_item; don't expand scope.
- Dependency upgrades mid-task: escalate.
- Changes outside task's owned directories: escalate.

## v1 cuts

- CAD exports: binary STL + STEP only. All other formats post-v1.
- Engineering drawings: not in v1.
- Presentation v1: slide authoring + fullscreen + presenter view + reveal script + pen capture. No PPTX import/export.

## Out of scope

- Anchor repair for annotations (spatial attachment drifts; humans/LLMs delete or re-point).
- Ephemeral flag on annotations.
- API-whitelist sandboxing of plugin Godot scenes.
- Migrating native editors (text, spreadsheet) to plugins.

## Verification

- Each task's Definition-of-Done (filed as a comment on the task's docket item) is mandatory for task completion.
- Build green + tests green + DoD criteria verified → task done.
- Do not ship a task with zero test coverage; add tests inside task scope.

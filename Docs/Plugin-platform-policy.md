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

## Host terminal capability grants (agent-relay DCR 019eafbdcfb3 A2)

Four new capabilities in `ALLOWED_HOST_CAPABILITIES` (PluginDefinition.gd):

- `host.terminal.list` — enumerate open terminal tabs; no args; read-only.
- `host.terminal.read` — read viewport or scrollback row range; no side-effects.
- `host.terminal.write` — send keystrokes/bytes to a PTY; defaults `raw=true` (plugin
  SDKs send real control bytes; the MCP-layer `c_unescape` would corrupt them).
- `host.terminal.wait` — long-poll for output to settle; returns `bell_rung`
  (Unix/macOS only; always false on Windows due to no ghostty shim),
  `shell_exited`, and `shell_exit_code` when the shell exits.

All four delegate to the corresponding `minerva_terminal_*` MCP tool implementations
via `CapabilityBroker._handle_host_terminal_tool`. Arg allowlists are enforced
(unknown keys → `schema_validation_failed`). Error code on tool failure:
`terminal_tool_error`. The broker wraps results in `PluginErrors.success({...})`.

These are the **interactive / observational family** — plugins observe and converse
with terminals; they do not own terminal lifecycle (create/close remain out of reach
for v1 plugins).

Grant policy: each is grantable individually (unlike a blanket `mcp.proxy:*`).
Auto-granted on install like all other host capabilities except
`host.permissions.grant_scope`. No UI escalation required.

`host.terminal.exec` (pre-existing) runs a one-shot shell command and returns merged
stdout+stderr — a separate capability with a different trust model (command execution
vs. observation). Terminal resolution for exec goes through the same
`TerminalSessionRegistry` path as the four capabilities above (chat-passthrough T3):
an explicit `terminal_id` resolves to a session (background sessions included); calls
that name no terminal keep the historical prefer-a-visible-UI-terminal behavior, and
never land in an unnamed background session.

### Lifecycle & restart semantics (chat-passthrough DCR, v1 — deliberate)

Background terminal sessions are **NOT persisted across a Minerva restart**. PTY
children are OS children of the Minerva process; they die with it. v1 makes that
the honest contract instead of pretending otherwise:

- Sessions are **in-memory only**. `TerminalSessionRegistry` has no save/serialize
  surface and writes no files; the registry starts **empty on every boot**.
- Terminal ids are **per-process** (derived from instance ids). They are meaningless
  after a restart and must **never be stored durably** — not in plugin state, not in
  project files, not in agent notes.
- A consumer that wants "the same terminal back" after a restart stores the
  **COMMAND + CWD** it originally launched with and creates a **fresh session**
  (`minerva_terminal_create background:true` + write the command). That is exactly
  how the upcoming passthrough-chat relaunch affordance works: the chat remembers
  what it launched, not which PTY it lived in.

## PLUGIN_EVENT trigger type (agent-relay DCR 019eafbdcfb3 A6)

`TriggerDefinition.TriggerType.PLUGIN_EVENT` (value 4) routes plugin events into the
agent trigger system. Key fields:

- `plugin_id` — filter by plugin id; empty = any plugin.
- `plugin_event_name` — filter by event name; empty = any event.
- `consecutive_fire_limit` — pause after N consecutive fires (default 5; 0 =
  unlimited). Counter resets on human message in the target agent chat.

Reset seam caveat: `agent_chat_finished` only fires for IsAgentChat histories
(ChatPane.gd). A PLUGIN_EVENT trigger targeting a plain chat re-arms only via
`minerva_update_trigger` (toggle enabled) — not via human message. Acceptable for
the standard use-case (MESSAGE_EXISTING into an agent chat).

Payload keys from the plugin event are merged into the trigger context so they can be
referenced in `initial_message` templates (e.g. `{terminal_id}`).

## Verification

- Each task's Definition-of-Done (filed as a comment on the task's docket item) is mandatory for task completion.
- Build green + tests green + DoD criteria verified → task done.
- Do not ship a task with zero test coverage; add tests inside task scope.

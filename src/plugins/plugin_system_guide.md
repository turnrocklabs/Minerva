# Minerva Plugin System Guide

Plugins are supervised out-of-process programs that communicate with Minerva via stdio MCP (JSON-RPC over stdin/stdout). Any language that can read stdin and write stdout works: Go, Python, Node.js, Rust, etc.

## Creating a Plugin

A plugin is a directory containing at minimum:

```
my_plugin/
├── manifest.json    # Required: declares identity, tools, permissions
├── help.md          # Recommended: usage docs returned by minerva_plugin_help
├── <entrypoint>     # The executable or script
└── ui/              # Optional: webview panel HTML
    └── panel.html
```

### manifest.json (minimal)

```json
{
  "id": "my_plugin",
  "name": "My Plugin",
  "version": "0.1.0",
  "host_api_version": "1",
  "backend": {
    "transport": "stdio",
    "entrypoint": "python3",
    "args": ["server.py"]
  },
  "tools": [
    {
      "name": "minerva_my_plugin_do_thing",
      "description": "Does a thing.",
      "input_schema": {
        "type": "object",
        "properties": {
          "text": {"type": "string", "description": "Input text"}
        },
        "required": ["text"]
      }
    }
  ],
  "permissions": {
    "host_capabilities": [],
    "network": {"mode": "none"},
    "filesystem": {"mode": "none"}
  }
}
```

### Key Rules

- **Tool names** MUST start with `minerva_<plugin_id>_` (e.g., `minerva_my_plugin_do_thing`)
- **entrypoint** is the command to run (e.g., `python3`, `node`, `./my_binary`)
- **args** are passed after the entrypoint (e.g., `["server.py"]`)
- **Relative entrypoints** like `./my_binary` are resolved to absolute paths from the plugin directory
- **stdout** is the MCP transport — ONLY write JSON-RPC messages to stdout
- **stderr** is for logging — Minerva captures it and shows warnings/errors as toasts

### Protocol

The plugin must implement MCP (Model Context Protocol) over stdio:

1. Minerva sends `initialize` → plugin responds with capabilities
2. Minerva sends `notifications/initialized`
3. Minerva sends `tools/list` → plugin returns its tool definitions
4. Minerva sends `tools/call` with tool name and arguments → plugin returns result

Each message is a single line of JSON terminated by `\n`.

**Request from Minerva:**
```json
{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"minerva_my_plugin_do_thing","arguments":{"text":"hello"}}}
```

**Response from plugin:**
```json
{"jsonrpc":"2.0","id":1,"result":{"content":[{"text":"{\"result\":\"done\"}","type":"text"}]}}
```

### Language-Specific Tips

**Go**: Use `github.com/modelcontextprotocol/go-sdk` (official MCP SDK with StdioTransport). Single binary, zero dependencies. Build with `go build -o my_plugin .`

**Python**: Use `sys.stdin.readline()` for reading (NOT `for line in sys.stdin` — different buffering). Write to `sys.stdout` with `flush=True`. Log to `sys.stderr` via the `logging` module.

**Node.js**: Use `readline` on stdin. Write to stdout with `process.stdout.write()`.

## Installing a Plugin

```
minerva_plugin_install(manifest_path: "/absolute/path/to/manifest.json")
```

This registers the plugin in Minerva's database. The plugin directory stays where it is.

## Lifecycle

```
minerva_plugin_start(id: "my_plugin")    # Launch process, MCP handshake
minerva_plugin_stop(id: "my_plugin")     # Graceful shutdown
minerva_plugin_restart(id: "my_plugin")  # Stop + start (process misbehaving)
minerva_plugin_reload(id: "my_plugin")   # Stop + start (code changed)
```

- **autostart**: Set via Plugin Manager UI or DB — starts the plugin on Minerva launch
- **auto_reload**: Watches plugin files for changes and auto-restarts (hot reload for development)
- **Crash detection**: 3+ crashes in 60 seconds → CRASH_LOOP state (won't auto-restart)

## Discovery

Once a plugin is running, its tools appear in `minerva_tool_search`:

```
minerva_tool_search(query: "my_plugin")
```

The internal LLM and external MCP clients can discover and call plugin tools just like built-in tools.

## Permissions

### host_capabilities

Plugins that need to call Minerva's own tools (e.g., create notes, read files) must declare capabilities:

```json
"host_capabilities": ["mcp.proxy:minerva_create_note"]
```

The user must grant these in the Plugin Manager UI. Supports wildcards: `mcp.proxy:minerva_note_*`, `mcp.proxy:*`.

### Network modes

- `"none"` — no network access
- `"localhost"` — local connections only (add `"ports": [4455]` to declare which)
- `"unrestricted"` — any network access

### Filesystem modes

- `"none"` — no filesystem access
- `"scoped_paths"` — access only to declared paths (e.g., `"user://plugins/data/my_plugin/"`)

## Events and State (optional)

Plugins can push notifications to Minerva at any time (not just during tool calls):

**Event** (edge-triggered, for transitions):
```json
{"jsonrpc":"2.0","method":"minerva/plugin_event","params":{"event":"my.thing_happened","payload":{"detail":"..."}}}
```

**State** (latest snapshot, overwrites previous):
```json
{"jsonrpc":"2.0","method":"minerva/plugin_state","params":{"state":{"connected":true,"status":"ready"}}}
```

Declare events in the manifest:
```json
"events": [
  {"name": "my.thing_happened", "payload_schema": {"type": "object"}}
],
"state": {
  "schema": {"type": "object", "properties": {"connected": {"type": "boolean"}}}
}
```

Query state: `minerva_plugin_state(id: "my_plugin")`

## Webview UI (optional)

Plugins can have a webview panel in Minerva's editor pane:

```json
"ui": {
  "panels": ["my_plugin_panel"],
  "ipc_messages": ["my.action1", "my.action2"]
}
```

Place the HTML at `ui/panel.html`. The Minerva JS bridge is auto-injected:

```javascript
// Call Minerva MCP tools
await minerva.call('minerva_my_plugin_do_thing', {text: 'hello'});

// Receive pushed state from the plugin
minerva.onPluginState(function(state) { updateUI(state); });

// Receive pushed events
minerva.onPluginEvent(function(name, payload) { handleEvent(name, payload); });
```

## Help File

Create `help.md` in your plugin directory. Agents call `minerva_plugin_help(id: "my_plugin")` to read it. Include:
- Getting started workflow
- Tool call sequences and dependencies
- Configuration requirements
- Common use cases

## Active-tab focus indicator

The blue border that marks the active editor tab is defined entirely in
`src/assets/themes/blue_dark_mode.theme` (the project's default dark theme,
applied at runtime to `root_control` by `singleton_object.gd:2058`).

Two distinct style entries produce the visual:

| Theme type | Style key | Color | Border widths (T/R/B/L) | What you see |
|---|---|---|---|---|
| `TabContainer` | `tab_selected` | `Color(0.1647, 0.3451, 0.8314)` ≈ #2A58D4 | 2 / 4 / 2 / 0 | Blue top + side border on the active tab chip |
| `CodeEdit` | `focus` | `Color(0.1647, 0.3451, 0.8314)` | 1 / 1 / 1 / 1 | Blue 1 px border around the code-editor surface when it holds keyboard focus |

**Do `PLUGIN_SCENE` tabs inherit this?**
Yes — both effects apply automatically:

- `TabContainer/tab_selected` is painted by the engine for whichever child of the
  `TabContainer` is current. Because `EditorPane`'s `TabContainer` is the same
  widget for all editor types, the selected-tab chip gets the blue border regardless
  of whether the content is a `CodeEdit`, a plugin scene, or anything else.
- `CodeEdit/focus` is irrelevant for `PLUGIN_SCENE` editors (they contain no
  `CodeEdit`); the plugin scene's own controls will receive whatever focus style
  their type carries in the theme.

No fix is needed. Plugin scene tabs already participate in the `tab_selected`
blue-chip styling. If a plugin panel wants its own inner content to show a
blue border on focus, it should use a `PanelContainer` or `StyleBoxFlat` that
reads from the theme's `CodeEdit/focus` entry (as `CefWebViewEditor._apply_editor_style()`
does at `src/Scripts/UI/Controls/WebViewEditor/CefWebViewEditor.gd:46`).

## ResponsiveContainer — Bootstrap-style width classification

`ResponsiveContainer` (`res://Scripts/UI/Controls/responsive_container.gd`) is a
platform-provided `Container` subclass that classifies its own rendered width into
one of five Bootstrap-equivalent breakpoint classes. Plugin Godot-scene panels can
use it to switch layouts when the panel is resized.

### Breakpoints

| Class | Width range       |
|-------|-------------------|
| `xs`  | < 480 px          |
| `sm`  | 480 – 767 px      |
| `md`  | 768 – 1023 px     |
| `lg`  | 1024 – 1439 px    |
| `xl`  | ≥ 1440 px         |

### Copy-paste usage

**In your panel .tscn** — add a `ResponsiveContainer` node and attach the script:

```
[ext_resource type="Script" path="res://Scripts/UI/Controls/responsive_container.gd" id="1_rc"]

[node name="ResponsiveContainer" type="Container" parent="."]
script = ExtResource("1_rc")
```

Children of the node lay themselves out normally (anchors, size flags). The
container only _classifies_ width; it does not reflow children automatically.

**In your panel .gd (in-tree)** — connect the signal and switch layout:

```gdscript
func _ready() -> void:
    var rc := $ResponsiveContainer as ResponsiveContainer
    rc.width_class_changed.connect(_on_width_class_changed)
    # Apply initial state before the first resize event fires.
    _on_width_class_changed(rc.width_class)

func _on_width_class_changed(cls: StringName) -> void:
    match cls:
        ResponsiveContainer.CLASS_LG, ResponsiveContainer.CLASS_XL:
            _grid.columns = 4
            _grid.visible  = true
            _stack.visible = false
        ResponsiveContainer.CLASS_MD:
            _grid.columns = 2
            _grid.visible  = true
            _stack.visible = false
        _: # xs, sm
            _grid.visible  = false
            _stack.visible = true
```

**From an off-tree plugin** — Godot's parser cache only sees scripts under
`res://`, so off-tree plugin scripts cannot statically reference the
`ResponsiveContainer` class name. Use `preload()` + base-class typing instead:

```gdscript
const _RC := preload("res://Scripts/UI/Controls/responsive_container.gd")

func _ready() -> void:
    var rc: Container = $ResponsiveContainer  # base type, not class_name
    rc.width_class_changed.connect(_on_width_class_changed)
    _on_width_class_changed(rc.get("width_class"))
```

The `width_class` property and `width_class_changed` signal are duck-typeable —
the wire surface is the public contract.

**Reading the class without a signal** (one-shot check):

```gdscript
var cls: StringName = $ResponsiveContainer.width_class
if cls == ResponsiveContainer.CLASS_XS:
    do_narrow_thing()
```

### Live demo

The `hello_scene` plugin ships a smoke-test panel (`responsive_smoke`) that
demonstrates all three layout modes. Open it from the plugin's editor items list
and resize the panel to see the layout change in real time.

## Host Terminal Capabilities

Four capabilities let a plugin observe and converse with open terminal tabs without
owning their lifecycle (create/close remain out of reach for plugins — intentional v1
scope).

These capabilities delegate to the same `minerva_terminal_*` MCP tool implementations
that external MCP clients use, so the result shapes are identical. They form the
**interactive / observational family** alongside the existing `host.terminal.exec`
(which runs a one-shot command in a subprocess and returns merged stdout+stderr).

Declare each one you need in `permissions.host_capabilities`.

### host.terminal.list

List all open terminal tabs.

**Args:** none

**Returns:**
```json
{
  "success": true,
  "result": {
    "success": true,
    "terminals": [
      {"id": "12345", "name": "Terminal 1", "visible": true, "cols": 220, "rows": 50}
    ],
    "count": 1
  }
}
```

The inner `id` is the Godot instance ID (a string of digits). Pass it to the other
three capabilities.

### host.terminal.read

Read the visible viewport or a specific scrollback row range.

**Args:**

| Arg | Type | Description |
|---|---|---|
| `terminal_id` | string | Terminal ID from `host.terminal.list`. Empty = active terminal. |
| `start_row` | integer | Start row in scrollback (0 = top of history). Omit for visible viewport. |
| `end_row` | integer | End row in scrollback. Omit for visible viewport. |

Only `start_row`/`end_row` are allowed arg keys. Unknown keys return
`error_code: "schema_validation_failed"`.

**Returns (viewport):**
```json
{
  "success": true,
  "result": {
    "success": true,
    "content": "$ ls -la\ntotal 12\n...",
    "rows": 12,
    "cols": 220,
    "total_scrollback_rows": 1024,
    "viewport_rows": 50
  }
}
```

**Returns (row range):** same shape plus `start_row` and `end_row` echoed back.
Row indexing is screen-absolute using stable absolute rows from `get_scroll_info()`.

### host.terminal.write

Send text or keystrokes to a terminal PTY. Non-blocking — returns as soon as the
bytes are queued.

**Args:**

| Arg | Type | Description |
|---|---|---|
| `terminal_id` | string | Terminal ID. Empty = active terminal. |
| `text` | string (required) | Text to send. |
| `raw` | boolean | Send bytes verbatim without processing escape sequences. **Default: `true`** for this capability (see note below). |

**Platform note:** `host.terminal.write` defaults `raw=true` because plugin SDKs
(Go, Rust) send real control characters in JSON strings (e.g. a literal `\r` byte),
and the MCP-side `c_unescape` step — which exists to convert LLM-typed escape strings
like `\\r` into real bytes — would corrupt those literal backslashes. If your plugin
builds escape sequences as backslash strings rather than as real bytes, pass `raw=false`.

**Platform availability:** the `bell_rung` counter and `shell_exited`/`shell_exit_code`
fields from `host.terminal.wait` depend on the ghostty-vt shim (built by
`scripts/build-extensions.sh`). The shim is compiled only for Unix/macOS; the Windows
terminal glue has no ghostty shim and `bell_rung` will always be `false` there.

**Returns:**
```json
{"success": true, "result": {"success": true, "bytes_sent": 3}}
```

### host.terminal.wait

Long-poll: block until new output settles (or timeout), then return the screen
content. The recommended pattern after `host.terminal.write`.

**Args:**

| Arg | Type | Description |
|---|---|---|
| `terminal_id` | string | Terminal ID. Empty = active terminal. |
| `timeout_ms` | integer | Max wait in ms. Default 30000. |
| `settle_ms` | integer | Wait for output to stop for this many ms before returning. Default 500. |

**Returns:**
```json
{
  "success": true,
  "result": {
    "success": true,
    "content": "$ echo hello\nhello\n$ ",
    "rows": 3,
    "cols": 220,
    "total_scrollback_rows": 1027,
    "viewport_rows": 50,
    "timed_out": false,
    "waited_ms": 612,
    "bell_rung": false
  }
}
```

Additional fields present only when the shell exits during the wait:

| Field | Type | Description |
|---|---|---|
| `bell_rung` | boolean | A standalone BEL character arrived during the wait. Useful as a fast-path turn-completion signal when the CLI agent is bell-capable. Unix/macOS only — always `false` on Windows. |
| `shell_exited` | boolean | The shell process exited during the wait. |
| `shell_exit_code` | integer | Exit code (only present when `shell_exited` is true). |

### Error code

All four capabilities share the error code `terminal_tool_error` when the delegated
`minerva_terminal_*` tool returns a failure:

```json
{
  "success": false,
  "error_code": "terminal_tool_error",
  "error_message": "No terminal found",
  "plugin_id": "my_plugin",
  "capability": "host.terminal.read"
}
```

A `schema_validation_failed` error is returned if you pass an unrecognized argument key.

### When to use these vs mcp.proxy:minerva_terminal_*

Use the dedicated capabilities (`host.terminal.list/read/write/wait`) when your plugin
needs fine-grained individual grants — each is grantable independently. Use
`mcp.proxy:minerva_terminal_list` (and similar) if you already have a broad
`mcp.proxy:*` grant and do not need per-capability control. The behavior and result
shapes are identical; the only difference is the grant mechanism.

`host.terminal.exec` is a separate capability for running a one-shot shell command
and capturing its output; it does not interact with open terminal tabs.

## PLUGIN_EVENT Trigger Type

Plugins can wake a Minerva agent chat when something significant happens (a CLI agent
turn completes, a scan finishes, a render is done). The mechanism is:

1. The plugin emits a `minerva/plugin_event` notification on stdout (declare the
   event in `events[]` in the manifest).
2. A `PLUGIN_EVENT` trigger (trigger_type=4) subscribes to that event and fires a
   `MESSAGE_EXISTING` action into the target agent chat.

### Creating a PLUGIN_EVENT trigger

```
minerva_create_trigger(
  name: "relay turn → agent chat",
  agent_id: "<agent-definition-id>",
  trigger_type: 4,            # PLUGIN_EVENT
  action_type: 1,             # MESSAGE_EXISTING
  plugin_id: "agent-relay",   # empty = any plugin
  plugin_event_name: "agent_relay.turn_completed",  # empty = any event
  consecutive_fire_limit: 5,  # 0 = unlimited
  initial_message: "A new agent turn is ready. terminal_id={terminal_id}",
  enabled: true
)
```

Event payload keys are merged into the trigger context, so `{terminal_id}` in
`initial_message` expands from the event payload.

### consecutive_fire_limit and the agent-chat-only reset caveat

`consecutive_fire_limit` (default 5; 0 = unlimited) prevents runaway loops: after
the trigger fires N consecutive times, it pauses. The counter and pause reset when a
human message lands in the target chat — **but only if the target is an agent chat**
(a chat driven by an agent definition). A paused trigger pointing at a plain
(non-agent) chat re-arms only via `minerva_update_trigger` (change `enabled` to
false then true again, or change another field).

This is acceptable for the primary use-case (MESSAGE_EXISTING into an agent chat,
which is the only action type that meaningfully interacts with a conversation loop).

### Declaring events in the manifest

```json
"events": [
  {
    "name": "my_plugin.thing_done",
    "description": "Emitted when a long-running operation completes.",
    "payload_schema": {
      "type": "object",
      "properties": {
        "terminal_id": {"type": "string"},
        "status": {"type": "string"}
      }
    }
  }
]
```

Undeclared event names log a warning but are still delivered. The manifest
`events[]` shape accepts either `payload_schema` or `description` — both parse.

### agent-relay as a reference consumer

The `agent-relay` plugin (in the plugins repo) is the canonical reference consumer:
it declares `"host.terminal.list"`, `"host.terminal.read"`, `"host.terminal.write"`,
`"host.terminal.wait"` in `permissions.host_capabilities`, and emits the
`agent_relay.turn_completed` event that a PLUGIN_EVENT trigger can subscribe to.

## Management Tools Reference

| Tool | Description |
|------|-------------|
| `minerva_plugin_help` | This guide (no id) or plugin-specific docs (with id) |
| `minerva_plugin_list` | List all installed plugins with status |
| `minerva_plugin_install` | Install from manifest.json path |
| `minerva_plugin_remove` | Uninstall (optionally delete data) |
| `minerva_plugin_start` | Launch plugin process |
| `minerva_plugin_stop` | Graceful shutdown |
| `minerva_plugin_restart` | Stop + start (misbehaving process) |
| `minerva_plugin_reload` | Stop + start (code changed) |
| `minerva_plugin_inspect` | Full manifest, capabilities, audit log |
| `minerva_plugin_state` | Latest pushed state snapshot |

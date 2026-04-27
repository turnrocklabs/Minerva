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

# Plugin Platform Expansion — Design

**Status:** Design (pre-implementation)
**Date:** 2026-04-24
**Scope:** DCR-1 capabilities described in `Docs/Plugin-platform-thought.md` §2.
**Related:** `Docs/Plugin-platform-policy.md`, `Docs/Plugin-platform-escalation.md`.

---

## 1. Overview

This subsystem extends Minerva's stdio-MCP plugin platform so a plugin can contribute a **first-class editor tab** built from a native Godot scene, not only an HTML webview. A plugin ships a `.tscn` + whitelisted `.gd` scripts, registers a file-extension-backed editor kind, binds bidirectional IPC between the scene and its MCP backend, and participates in Minerva's save / load / project-file / project-export flows with the same rights as `PCBEditor`. The in-process broker (mirroring `PluginWebviewBroker`) replaces the HTTP bridge used in the `rich-panel` experiment — all scene ↔ MCP traffic stays in-process and flows through one validated, audited chokepoint.

---

## 2. Manifest Schema

Panels are the extension point. Today's `"ui": { "panels": [ "name" ], "ipc_messages": [ ... ] }` remains legal; the entries in `panels` may now be either strings (legacy) or typed objects (new).

### 2.1 Typed panel entry (new)

```json
{
  "ui": {
    "panels": [
      {
        "name": "cad_viewer",
        "kind": "godot_scene",
        "entry_scene": "ui/CadViewer.tscn",
        "scripts": [
          "ui/CadViewer.gd",
          "ui/CadCanvas.gd",
          "ui/OrbitCamera.gd"
        ],
        "file_extensions": [".mcad"],
        "ipc_channels": [
          "cad.render_request",
          "cad.annotation_added"
        ],
        "fullscreen_capable": false,
        "multi_window": false
      }
    ],
    "ipc_messages": [ "cad.render_request", "cad.annotation_added" ]
  }
}
```

Field semantics:

| Field | Type | Required | Notes |
|---|---|---|---|
| `name` | string | yes | Unique within the plugin. Used by the broker as the panel identity. |
| `kind` | `"html"` \| `"godot_scene"` | no | Defaults to `"html"`; legacy entries are normalised to `"html"`. |
| `entry_scene` | plugin-relative path | if `kind=godot_scene` | `.tscn` file. Must be inside `data_directory`. No `..`, no absolute paths. |
| `entry` | plugin-relative path | if `kind=html` | Legacy `html` field (e.g. `ui/panel.html`). |
| `scripts` | array of plugin-relative paths | if `kind=godot_scene` | Whitelist of `.gd` files the scene is allowed to load. See §4 for enforcement. |
| `file_extensions` | array of strings | no | Extensions registered with Minerva's file-dialog and editor-container. Must start with `.`. Lowercase. Conflict handling: §7. |
| `ipc_channels` | array of strings | no | Channels the scene may emit / receive. Must intersect with `ui.ipc_messages` for outbound calls (see §4). |
| `fullscreen_capable` | bool | no | Default `false`. See §10. |
| `multi_window` | bool | no | Default `false`. See §11. |

### 2.2 Parsing rules (decided: no legacy string form)

Backward compatibility is NOT required — the only plugin using the current shape is OBS Controller, which is updated in the same change to use the typed form. Panels must be typed entries from here on; legacy string form is rejected.

`PluginDefinition._from_dict_internal()`:

1. `panels[i]` must be a `Dictionary` with a `name` field. String entries → manifest rejected with `panel_must_be_typed`.
2. `kind` defaults to `"html"` if absent. `"godot_scene"` → validate `entry_scene` + `scripts` present; reject manifest on missing.
3. `PluginDefinition.ui_panels` is `Array[Dictionary]`; a parallel `ui_panel_names` `Array[String]` is kept for broker lookups.

**Go + HTML plugins (like today's OBS Controller) remain supported** via `kind: "html"`. Adding `kind: "godot_scene"` alongside gives the Go-backend-plus-Godot-frontend shape the CAD plugin needs. The two are orthogonal: a plugin can declare panels of either kind or both.

### 2.3 Editor-items linkage

The existing top-level `editor_items` field is extended; each entry may now reference a scene-kind panel:

```json
"editor_items": [
  { "id": "new_cad_doc", "name": "New CAD Document", "panel": "cad_viewer", "default_filename": "untitled.mcad" }
]
```

Semantics unchanged for HTML panels. For scene panels, "New → <name>" instantiates an editor via §7.

---

## 3. Scene Loading Flow

From "plugin is installed" to "scene rendered in an editor tab":

1. **Trigger.** User opens a file whose extension matches a plugin-registered extension; or `EditorContainer.new_editor(kind)` is called from "File → New"; or a plugin pushes a `minerva/open_panel` (user-confirmed, same policy as today's webview panels).
2. **Resolve.** `PluginEditorRegistry` (new thin singleton owned by `SingletonObject`) maps `extension → (plugin_id, panel_name)` or `kind_id → (plugin_id, panel_name)`.
3. **Ensure running.** If plugin is `INSTALLED`/`STOPPED`, `PluginManager.start_plugin()` is awaited. `CRASH_LOOP`/`ERROR` → refuse with a toast pointing at Plugin Manager.
4. **Build `Editor` wrapper.** `Editor.create(Type.PLUGIN_SCENE, file, tab_title)` (new enum value) clears `%VBoxContainer`, stashes `plugin_id`/`panel_name`, delegates to `PluginScenePanelHost.instantiate_into(vbox, plugin_id, panel_name, editor)`.
5. **Validate manifest panel entry.** Missing / wrong-kind → placeholder `Control` with diagnostic + "Reload plugin" button. Tab still opens.
6. **Resolve paths.** `data_directory + entry_scene` and each `scripts[i]`, canonicalised via `String.simplify_path()`, rejected if escape `data_directory`.
7. **Script whitelist preload.** `ResourceLoader.load(abs_path, "GDScript", CACHE_MODE_IGNORE)` for every `scripts[i]`; failure → placeholder.
8. **Load `.tscn`.** `ResourceLoader.load(entry_scene_abs, "PackedScene", CACHE_MODE_IGNORE)`. Before `instantiate()`, `_audit_packed_scene()` walks the `PackedScene`'s internal resource table and rejects any script reference whose path is not in `scripts[]`.
9. **Instantiate.** Root must be a `Control`.
10. **Wire broker.** `PluginScenePanelBroker.register_panel(root, plugin_id, panel_name, ipc_channels)` connects the scene's outbound `request` signal and installs an inbound push handler.
11. **Mount.** `vbox.add_child(root)`; `PRESET_FULL_RECT`, `SIZE_EXPAND_FILL`.
12. **Fire `_on_panel_loaded(ctx)`** on root if the method exists. Earliest point the scene may issue IPC.
13. **Tab handoff.** `EditorPane.add(editor)` with title from `default_filename` / `associated_object.file` / panel `name`.

Every failure yields a diagnostic-bearing placeholder tab, never a silent no-op.

---

## 4. PluginScenePanelBroker

Mirrors `PluginWebviewBroker`. Same validation + audit posture; different transport primitives because the peer is a Godot node, not a JS context.

### 4.1 Class shape

```gdscript
class_name PluginScenePanelBroker
extends RefCounted

signal panel_registered(plugin_id: String, panel_name: String)
signal panel_unregistered(plugin_id: String, panel_name: String)

# Dependencies (ctor-injected; same pattern as PluginWebviewBroker)
var plugin_manager: PluginManager
var plugin_policy: PluginPolicy
var capability_broker: CapabilityBroker
var audit_log: PluginAuditLog

# --- Panel registry ------------------------------------------------------

## register_panel(panel_root, plugin_id, panel_name, declared_channels)
##   Stores the weak ref + wires signal plumbing. Called by PluginScenePanelHost
##   after _on_panel_loaded has returned.
func register_panel(panel_root: Node, plugin_id: String, panel_name: String,
                    declared_channels: PackedStringArray) -> void

## unregister_panel(plugin_id, panel_name)
##   Called by PluginScenePanelHost on tab-close or plugin stop/reload.
func unregister_panel(plugin_id: String, panel_name: String) -> void

func unregister_plugin_panels(plugin_id: String) -> void

# --- Outbound (scene -> plugin) -----------------------------------------

## handle_scene_request(panel_name, channel, payload, reply_id) -> void
##   Called from the scene via a `request` signal. Validates against manifest,
##   dispatches to plugin backend or capability broker. Result is pushed back
##   via `reply(panel_name, reply_id, result)`.
func handle_scene_request(panel_name: String, channel: String,
                          payload: Dictionary, reply_id: String) -> void

# --- Inbound (plugin -> scene) ------------------------------------------

## push_to_panel(plugin_id, panel_name, channel, payload) -> bool
##   Called by PluginEventBroker when the plugin emits an async notification
##   addressed to a panel. Returns false if the panel is not live.
func push_to_panel(plugin_id: String, panel_name: String,
                   channel: String, payload: Dictionary) -> bool
```

### 4.2 Scene-side contract

A scene-kind panel root must expose a `request` signal and a `receive` method:

```gdscript
# Emitted by the scene when it wants to call a plugin tool.
# reply_id is generated by the scene (UUID / counter). Payload must be serialisable.
signal request(channel: String, payload: Dictionary, reply_id: String)

# Called by the broker when the plugin pushes an async message addressed to this panel.
func receive(channel: String, payload: Dictionary) -> void
```

The broker routes `reply(panel_name, reply_id, result)` back into the scene by emitting an internal `_reply(reply_id, result)` signal on a helper node Minerva attaches to the panel root as `$_MinervaIPC`. Scenes that want a promise-style API may use the helper's `await_reply(reply_id)` coroutine.

### 4.3 Validation rules (same posture as webview broker)

1. `panel_name` must be registered → deny (`panel_not_registered`).
2. Panel's declared owner must match `plugin_id` (spoof check).
3. `channel` must be in `panels[].ipc_channels` **and** `ui.ipc_messages` (top-level allowlist authoritative; `ipc_channels` scopes channels to specific panels).
4. Payload ≤ `MAX_PAYLOAD_BYTES` (64 KiB, same as webview).
5. `capability:…` → `CapabilityBroker.dispatch()`; else → MCP `tools/call` with tool name = channel, arguments = payload.
6. Every decision audits through `PluginAuditLog` with the same event constants; prefix detail-dict with `scene_` to distinguish from webview events.

### 4.4 Ownership

`SingletonObject.plugin_scene_panel_broker` is constructed alongside `plugin_webview_broker` with the same dependencies. `PluginScenePanelHost` resolves it via the singleton, parallel to `WebViewEditor`'s resolution of the webview broker.

---

## 5. Lifecycle Protocol

### 5.1 Hooks on the scene's root node

All optional. Presence is probed by `Object.has_method()`. All hooks run on the main thread.

```gdscript
# Called after scene is added to tree and broker is wired.
func _on_panel_loaded(ctx: Dictionary) -> void

# Called before the scene is removed / freed (tab close, plugin stop, reload).
# Scene must not initiate new IPC from inside this hook.
func _on_panel_unload() -> void

# Optional: called when Minerva asks the panel to serialise its document.
# Return value is passed to the plugin's minerva_<plugin>_save_document tool
# (or whatever the manifest declares as save_channel). See §8.
func _on_panel_save_request() -> Dictionary

# Optional: called when Minerva asks the panel to load a document.
func _on_panel_load_request(document: Dictionary) -> void
```

### 5.2 `ctx` shape

```gdscript
{
  "plugin_id":       String,          # e.g. "cad"
  "panel_name":      String,          # e.g. "cad_viewer"
  "data_directory":  String,          # absolute, read-only view
  "broker":          PluginScenePanelBroker,   # direct handle; equivalent to emitting `request`
  "file_path":       String,          # associated file or "" for untitled
  "associated_object": Variant,       # Editor.associated_object, may be null
  "editor":          Editor,          # wrapper node; used for unsaved-flag APIs
  "host_api_version": "1"             # matches manifest requirement
}
```

Rationale: `broker` exposed directly so scripts can use awaited helpers without signal plumbing. `data_directory` lets the scene locate its own assets. `editor` lets the scene push unsaved-state without a singleton lookup.

### 5.3 Call-order guarantees

1. `_init()` → `_ready()` run as Godot schedules during `instantiate()`.
2. Scene is added to the tree **before** `_on_panel_loaded` fires. Broker is already wired. `request` signals emitted from `_ready()` are queued and delivered after `_on_panel_loaded` returns (broker uses a `call_deferred` trampoline on first registration).
3. `_on_panel_unload` fires **before** broker unregistration and `queue_free()`. IPC from inside `_on_panel_unload` → `panel_unloading`.
4. On plugin stop/reload, `_on_panel_unload` fires for every live panel in undefined order before any `queue_free()`.
5. `_on_panel_save_request` fires during `Editor.save()` matching the existing `override_save` ordering.

### 5.4 Re-instancing

Scene instance is **not** reused across stop/start. Reload = unload → free → restart plugin → fresh instantiate. State survival is the plugin's responsibility (persist via `data_directory` or a Minerva note/artifact capability).

---

## 6. Namespacing

### 6.1 `class_name` prefix rule

Any `class_name` declared in a plugin-shipped `.gd` **must** match the regex:

```
^[A-Z][A-Za-z0-9]*_[A-Za-z0-9_]+$
```

where the portion before the first `_` is the PascalCased plugin id (leading char upper, rest lower). Examples:

| Plugin id | Legal | Illegal |
|---|---|---|
| `cad` | `Cad_Viewer`, `Cad_OrbitCamera`, `Cad_Edge_Label` | `Viewer`, `CADViewer`, `cad_Viewer` |
| `obs_controller` | `Obs_controller_Scene` | `ObsController_Scene` (internal underscore forbidden in prefix) |

To keep the rule unambiguous with underscore-containing plugin ids, we canonicalise the prefix as `plugin_id.capitalize().replace("_", "")` — e.g. `obs_controller` → `Obscontroller`, so `Obscontroller_Scene` is the required form. The install-time check computes the canonical prefix and compares.

### 6.2 Collision check at install time

`PluginDB.install()` post-validate pass:

1. Grep each `scripts[i]` for `^class_name\s+(\w+)`.
2. Each captured name: (a) must match the prefix regex; (b) must not collide with Minerva's core class_name index (scanned once at app boot from `res://Scripts/**/*.gd`) or with any already-installed plugin's class_names.
3. Record the plugin's class_names in `PluginDB` for future installs to check against.

### 6.3 Install-rejection UX

Failures return a structured error from `PluginManager.install_plugin()`:

```json
{ "error": "class_name collision",
  "detail": { "script": "ui/CadViewer.gd", "class_name": "Viewer",
              "conflicts_with": "core:src/Scripts/UI/Controls/Viewer.gd" } }
```

The installer UI surfaces this in the existing "Install failed" toast with a "Copy diagnostic" button. No auto-rename. The plugin author must update their source.

### 6.4 What the rule does and does not protect

- Prevents one plugin clobbering another plugin's `class_name` entry (Godot's global class index is last-writer-wins).
- Does **not** sandbox script-level autoloads — plugins are not allowed to register autoloads (enforced by ignoring any `project.godot` shipped in the plugin directory; Minerva only ingests `manifest.json`).
- Does not constrain internal node names inside a scene; only top-level `class_name` identifiers.

---

## 7. Editor Integration

### 7.1 New `Editor.Type` entry

```
enum Type {
  TEXT, GRAPHICS, VIDEO, PACKAGE, LOGS, KANBAN, SPREADSHEET, PCB,
  VIDEO_EDITOR, ACTIVITY_LOG, WEBVIEW, PLUGIN_MANAGER, WORKER_STATUS,
  DOCKET,
  PLUGIN_SCENE,   # NEW
}
```

`Editor.create()` gains a `PLUGIN_SCENE` match arm that reads `plugin_id` + `panel_name` off the editor instance (set by the caller) and delegates to `PluginScenePanelHost.instantiate_into(vbox, plugin_id, panel_name, editor)`.

### 7.2 Registry

```gdscript
class_name PluginEditorRegistry
extends RefCounted

# extension (lowercased, leading '.') -> { plugin_id, panel_name }
var _ext_to_panel: Dictionary = {}
# editor_item_id -> { plugin_id, panel_name, default_filename }
var _kind_to_panel: Dictionary = {}

func register_plugin(def: PluginDefinition) -> Array[String]   # returns warnings
func unregister_plugin(plugin_id: String) -> void
func resolve_extension(ext: String) -> Dictionary
func resolve_editor_kind(kind_id: String) -> Dictionary
func list_extensions() -> Array[String]                         # for file dialog filter
func list_editor_kinds() -> Array[Dictionary]                   # for "New" submenu
```

Called from `PluginManager.install_plugin()` / `remove_plugin()` / on start/stop. The registry is the single place `EditorContainer` asks when the file dialog returns a path or when the "New" menu is constructed.

### 7.3 File-dialog hook

`EditorContainer` (or whichever component configures `FileDialog` today — it is a call made from `menuMain.gd` file-submenu handlers) queries `PluginEditorRegistry.list_extensions()` and appends `*.mcad ; Plugin:cad` style filters to the existing list. When the dialog returns a path, resolution order is:

1. Minerva core extension table (`.md`, `.py`, `.gd`, …).
2. Plugin registry.
3. Fallback to `Editor.Type.TEXT`.

Plugin extensions never override core; if a plugin declares `.md`, the registration fails at install time.

### 7.4 "New →" menu

`menuMain._build_new_menu()` iterates `PluginEditorRegistry.list_editor_kinds()` and appends an item per entry. Index mapping is done via a sidecar dict so menu indices stay stable across shown / hidden submenus.

### 7.5 Save / unsaved-changes integration

`Editor` gains `is_plugin_scene()`, `_save_plugin_scene()`, `_is_plugin_scene_saved()`.

Two save modes per panel (manifest `save_mode`):

- `"host_owned"` (default). On save, `Editor.save_file_to_disc()` invokes `_on_panel_save_request()` on the scene root, serialises the returned `Dictionary` as JSON (or raw bytes when the dict has `{ "_bytes": PackedByteArray }`), and writes it. Simpler; fits text-format plugin docs.
- `"plugin_owned"`. Minerva's save button dispatches `capability:editor.request_save` with the file path; the scene's `_on_panel_save_request` return value is ignored — the plugin writes the file itself and pushes back a `save.completed` notification that clears the unsaved flag. Fits plugins whose backend (e.g. CAD/Go) already owns file I/O.

Unsaved-flag state rides on a `content_changed` signal the scene emits; the host routes it to the `Editor` wrapper, reusing `_on_editor_changed`.

### 7.6 Open flow from associated_object

The existing `Editor.associated_object` mechanism (used to re-focus an open tab for the same object rather than opening a duplicate) applies unchanged — the plugin-registered editor kind opts in by setting `associated_object = file_path` in its `editor_items` handler.

---

## 8. Project-File and Project-Export Hooks

### 8.1 Project-file (`.minproj`)

Manifest extension:

```json
"project_file": { "serialize_channel": "cad.project_serialize",
                  "deserialize_channel": "cad.project_deserialize" }
```

Both channels must also appear in `ui.ipc_messages`. On save, Minerva invokes `serialize_channel` per open plugin-scene editor with `{ file_path, panel_name, editor_id }` and expects `{ tab_state: Dictionary, sidecar_paths: [String] }`. `tab_state` is embedded under `editors.plugin_scene[editor_id]`; `sidecar_paths` are recorded but not packed (pointer-only, matching thought paper §4.3). On open, Minerva calls `EditorContainer.new_editor(file_path)`, waits for `_on_panel_loaded`, then dispatches `deserialize_channel` with the saved `tab_state`.

### 8.2 Project-export (`.minpackage`)

```json
"project_export": { "collect_channel": "cad.project_export_collect",
                    "apply_channel":   "cad.project_export_apply" }
```

Flow: (1) `collect_channel` → plugin returns `{ files: [{src_abs, pack_rel}], paths_to_rewrite: {field_path: pack_rel} }`; (2) Minerva copies files into the package and rewrites paths in the serialised tab state to package-relative; (3) on unpack, `apply_channel` with `{ unpack_dir }` lets the plugin rewrite internal references back to absolute. Plugins without these hooks serialise via project-file only and contribute no sidecar files.

### 8.3 Versioning

Tab state embeds `{ version, plugin_id, plugin_version, panel_name, payload }`. Uninstalled-plugin deserialise → placeholder tab with "Install `<id>` to open this document". Version mismatch → `deserialize_channel` receives a `stored_version` hint; migration is the plugin's problem.

---

## 9. Hot-Reload

### 9.1 File-watch extensions

`PluginManager.WATCH_EXTENSIONS` grows to `["py","js","sh","json","gd","tscn"]`. The existing poll-and-debounce path fires for `.gd` / `.tscn` the same as today.

### 9.2 Decision tree on change

```
file changed:
  ext in ["py","js","sh","json"]    -> plugin stop + start (unchanged today)
  ext == "gd":
    if plugin has no live scene panels -> stop + start
    else:
      for each loaded script at that path, attempt script.reload()
      if all reload() OK:
        for each live panel, call `_on_hot_reload()` on root if method exists
        log "hot_reload_gd_ok"
      else:
        log "hot_reload_gd_failed"
        fall back to plugin stop + start
  ext == "tscn":
    for each live panel using that tscn (looked up via plugin_id + panel_name):
      call `_on_panel_unload()` on the root
      unregister broker for this panel instance
      free the old scene
      re-run §3 scene loading flow in the SAME Editor wrapper (new instance)
      call `_on_panel_loaded(ctx)` on the new root
      log "hot_reload_tscn_ok"
    scenes with no current instance: next open picks up the new version
  multiple extensions changed -> union; tscn path always triggers its own in-place re-instantiate
```

**Scene state is lost across `.tscn` reload.** Plugins that want state continuity persist via `data_directory` or a Minerva artifact — same constraint as today's webview panels. A `_on_panel_save_state()` / `_on_panel_restore_state()` pair is not in v1; add later if the loss becomes painful.

**Rationale for in-place re-instantiate on `.tscn` (vs plugin stop/start).** Optimizes the tight authoring loop — save `.tscn` in the Godot editor, see the change immediately in the live Minerva session. Plugin stop/start was rejected as too heavy for `.tscn`-only changes because it also restarts the backend process and resets all other panels owned by the same plugin. `GDScript.reload()` fragility only applies to `.gd`; `PackedScene` reload is well-supported in Godot 4.6. Fallback on failure: re-instantiate fails loud (placeholder tab with diagnostic), user triggers explicit plugin reload if needed.

Integration with Godot's file-system dock is **not** in scope; the existing modtime-poll approach is kept.

### 9.3 Panel continuity

On stop + start the live `Editor` tab is preserved. Its inner scene is freed during stop, re-instantiated when plugin re-reaches `RUNNING`; during the gap the tab shows a "Reloading…" placeholder and IPC returns `plugin_not_running`. No auto-save; unsaved in-scene state is lost unless the scene persists via `data_directory`. Matches today's webview-panel behaviour.

### 9.4 Cancellation races

`_reload_pending` is cleared on explicit `stop_plugin` (existing) and additionally on uninstall. No new race introduced.

---

## 10. Fullscreen / Exclusive-Input Capability

Driven by the Presentation plugin (post-MVP). Manifest:

```json
"panels": [{ ..., "fullscreen_capable": true, "exclusive_input": true }]
```

Runtime API is capability-brokered, not direct `DisplayServer`:

```
capability:window.request_fullscreen   payload: { window: "main" | "presenter" }
capability:window.exit_fullscreen
capability:input.grab_exclusive        payload: { grab: bool }
```

`CapabilityBroker` gates behind the manifest bits. User grant is required at install time (two new toggles in the permissions UI).

**Semantics.** Fullscreen transitions the hosting window to `WINDOW_MODE_EXCLUSIVE_FULLSCREEN`; editor chrome hides and restores on exit. Exclusive input suppresses Minerva global shortcuts *except* a fixed escape hatch (`Ctrl+Alt+Esc`) — `Escape` alone is not the hatch because presentation remotes routinely send it. One grab at a time; concurrent requests return `capability_busy`.

**Crash interaction.** Plugin stop / reload / crash while holding fullscreen → Minerva force-releases the grab and restores windowed mode *before* running unload hooks. No stuck-fullscreen-on-crash.

---

## 11. Multi-Window Support

Post-MVP. Manifest:

```json
"panels": [{ ..., "multi_window": true, "window_roles": ["main", "presenter"] }]
```

`window_roles` enumerates named window slots; Minerva persists their positions in the project layout.

**Lifecycle.** Scene instantiated **once per window**; each gets its own `_on_panel_loaded(ctx)` with `ctx.window_role` distinguishing them. Broker tracks `(plugin_id, panel_name, window_role) → panel_root`. Inbound pushes may target a specific role or broadcast (`window_role = "*"`). Closing a window runs `_on_panel_unload` for that instance only; other instances stay live.

**Crash isolation.** A GDScript error in one window's scene does not free other instances; broker validation is per-instance. If the plugin *backend* process dies, all windows go to placeholder uniformly.

**v1 cut.** MVP parses the manifest field but rejects secondary-window opens with `not_implemented`. Forward-compatible; no migration when the follow-up DCR enables it.

---

## 12. Unhappy Paths

Posture throughout: fail loud, render a diagnostic, never silently drop.

| Failure | Behaviour |
|---|---|
| Manifest missing `entry_scene` for `kind=godot_scene` | Install rejected in `PluginDefinition.validate()`. |
| `entry_scene` / script path escapes `data_directory` | Placeholder tab; "scene path escapes plugin directory". |
| Scripted path not in `scripts[]` whitelist | `_audit_packed_scene()` → placeholder tab naming the offending path. |
| `GDScript.reload()` fails on a whitelisted script | Placeholder tab; on hot-reload path, fall back to plugin stop/start (§9). |
| `.tscn` root is not a `Control` | Placeholder tab; "root must extend Control, got X". |
| `_on_panel_loaded` raises | Wrapped in guarded `Callable.call()`; panel stays visible, broker stays wired, diagnostic printed + toast. |
| Scene emits `request` before registration | Broker rejects `panel_not_registered`; trampoline (§5.3) shrinks the window to zero in normal `_ready()` flow. |
| Plugin backend dies mid-edit | Live panels get `_on_panel_unload`; tab swaps to placeholder with "plugin stopped — click to restart". Tab file-path preserved so restart reopens same document. In-memory state lost. |
| `class_name` collision at install | Install rejected with structured error identifying the conflicting path. |
| Extension collision with core | Install succeeds; extension registration skipped with warning. Plugin usable via "New →". |
| Extension collision between plugins | First-installed wins; later's extension skipped with warning. |
| IPC payload > 64 KiB | Broker denies `payload_too_large`. Large blobs (CAD renders) must chunk or be written to `data_directory` and passed by path. |
| Deserialise tab for uninstalled plugin | Placeholder tab tagged with plugin id + version; "Install `<id>` to open this document". |
| `_on_panel_save_request` returns null/malformed | Unsaved flag stays; toast "save failed: invalid payload". |
| Fullscreen held while plugin crashes | Minerva force-releases fullscreen + input grab before unload hooks run. |
| Multi-window: new-window request during backend stop | Broker rejects `plugin_stopping`. |
| Plugin-A depends on plugin-B | Out of scope for DCR-1; no dependency graph, start order is DB order. |

---

## 13. Questions — Reviewed 2026-04-24

*User answered inline below. Resolutions propagated into the body above: backward-compat dropped (§2.2); canonicalized `class_name` prefix for underscore-containing ids confirmed (§6.1); both save modes retained (§7.5); two channel pairs for project-file + project-export kept (§8); `.tscn` hot-reload is in-place re-instantiate, not stop/start (§9.2); fullscreen requires install-time capability grant (§10); multi-window manifest field parsed in v1, secondary-open rejected (§11.4); scene-only degraded mode valid without CEF/WRY (§12 – no code change needed). Q4 (IPC reply mechanism) resolved via rubric on DCR-1 plan decision comment — Option A (helper node + `await_reply`) wins on ergonomics with marginal memory/CPU cost.*


Places where the spec is silent *and* the decision is non-reversible, or where policy and spec contradict. Flagged per `Plugin-platform-escalation.md` item 8.

1. **`class_name` prefix for underscore-containing plugin ids.** Policy says "prefix = plugin id (e.g. `Cad_Viewer`)". For `obs_controller` this is either `Obs_controller_Scene` (ambiguous with the separator) or `Obscontroller_Scene` (drop internal underscores). This design proposes the latter (§6.1). Accept, or forbid underscore-containing plugin ids? Irreversible — dictates author-visible class names.
-- accept

2. **Save-mode default (§7.5).** Design proposes manifest `save_mode` with `host_owned` default / `plugin_owned` alternative. Preferred default? Is having both modes worth the surface, or forbid one?
-- both is fine

3. **Project-file vs project-export hook split (§8).** Design proposes two channel pairs (`serialize/deserialize`, `collect/apply`). Alternative: one pair with a `mode: "file" | "export"` discriminator. Simpler manifest; costs asymmetric behaviour for plugins that implement only one. Which?
-- Minerva always allows both project file saves and project file exports, so we need both channels here, I think.

4. **Scene-side IPC reply mechanism (§4.2).** Design proposes a Minerva-attached `$_MinervaIPC` helper node exposing `await_reply`. Alternative: scene provides `receive_reply(reply_id, result)` directly. Helper-node is friendlier but adds a mandatory sibling to every plugin scene. Preference?
-- Either is fine on its own, but performance risks should be better understood here. Make a rubric that uses both Memory pressure and CPU utilization as parts of the rubric, add anything you believe applies to the rubric, then grade the alternatives. Pick the winner.

5. **Hot-reload of `.tscn` (§9.2).** Design proposes `.tscn` change → always stop/start. Alternative: re-instantiate in-place. Latter is cheaper for UI iteration but breaks in-scene state plugins may care about. Accept conservative default, or attempt live tscn reload?
-- unsure. When we add a new plugig, we'd have to load the scene once at least. So, let's aim for hot-reload. It makes authoring plugins at runtime easier in trial/error loops.

6. **Fullscreen grant surface (§10).** Policy silent on whether fullscreen / exclusive-input require a user install-time grant (like `host_capabilities`) or are always-available when declared. Design proposes grant-required. Always-on-when-declared means simpler UI but higher "plugin captures my screen" risk. Preference?
-- A capability grant makes sense here.

7. **Multi-window in MVP (§11.4).** Design proposes parse-but-reject-at-runtime. Alternative: drop the manifest field entirely until the follow-up DCR. Forward-compat vs YAGNI.
-- Keep the manifest field. we have at least one plugin that will need 2 editors -- the CAD plugin.

8. **CEF/WRY presence assumption.** Scene-kind panels need neither extension. This design assumes the plugin platform remains functional (degraded to scene-only) in CEF-free / WRY-free builds. Confirm.
-- confirmed.

---

*End of design.*

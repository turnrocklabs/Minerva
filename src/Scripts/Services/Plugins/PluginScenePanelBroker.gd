class_name PluginScenePanelBroker
extends RefCounted
## IPC broker that mediates all communication between plugin Godot-scene panels
## and plugin backends / host capabilities.
##
## Mirrors PluginWebviewBroker's validation and audit posture.
## The peer here is a Godot Node, not a JS webview context, so the transport
## primitives differ: signal-based request/reply instead of evaluate_javascript.
##
## Security model:
##   - Scene panels NEVER call plugin backends or CapabilityBroker directly.
##   - Every outbound call is validated against the plugin's manifest before dispatch.
##   - Undeclared channels are rejected outright.
##   - Host capability calls are gated by PluginPolicy (deny-by-default).
##   - All decisions — allow or deny — are written to PluginAuditLog.
##   - Payload size is capped at MAX_PAYLOAD_BYTES (64 KiB).
##
## Message flow (scene -> plugin):
##   1. Scene emits its `request(channel, payload, reply_id)` signal.
##   2. Caller (PluginScenePanelHost) invokes handle_scene_request().
##   3. Broker validates panel ownership, channel declaration, and payload.
##   4. Broker dispatches:
##        "capability:<name>"  -> CapabilityBroker.dispatch()
##        Everything else      -> plugin backend MCPServerConnection (tools/call)
##   5. Broker delivers result to scene via $_MinervaIPC._reply(reply_id, result).
##
## Message flow (plugin -> scene):
##   1. PluginEventBroker receives an event addressed to a panel.
##   2. PluginEventBroker calls push_to_panel(plugin_id, panel_name, channel, payload).
##   3. Broker calls scene_root.receive(channel, payload) if the panel is live.
##
## Lifecycle insertion points (left clean for PluginScenePanelHost):
##   - register_panel()   — call after scene is added to tree, before _on_panel_loaded.
##   - unregister_panel() — call inside _on_panel_unload, before queue_free.
##
## Audit event prefix for scene events is "scene_" to avoid collisions with
## PluginWebviewBroker's "ipc_" prefix.


# ---------------------------------------------------------------------------
# Audit event constants
# ---------------------------------------------------------------------------

## scene_request was validated and dispatched.
const EVENT_SCENE_ALLOWED    := "scene_allowed"
## scene_request was rejected at validation.
const EVENT_SCENE_DENIED     := "scene_denied"
## scene_request dispatch completed (result available).
const EVENT_SCENE_DISPATCHED := "scene_dispatched"
## push_to_panel: panel found and receive() called.
const EVENT_SCENE_PUSH       := "scene_push"
## push_to_panel: panel not live (not an error; plugin may push before panel opens).
const EVENT_SCENE_PUSH_MISS  := "scene_push_miss"
## push_progress: panel found and on_progress() called.
const EVENT_SCENE_PROGRESS   := "scene_progress"
## push_progress: panel not live, wrong owner, or scene lacks on_progress.
const EVENT_SCENE_PROGRESS_MISS := "scene_progress_miss"
## A reply or request outlived the registration it belonged to (the key was
## re-registered while the backend was busy) and was dropped, not redirected.
const EVENT_SCENE_STALE_REGISTRATION := "scene_stale_registration"
## attach_buffer_to_panel: panel subscribed to a DocumentBuffer.
const EVENT_BUFFER_ATTACHED  := "buffer_attached"
## detach_buffer_from_panel: panel unsubscribed.
const EVENT_BUFFER_DETACHED  := "buffer_detached"
## buffer_attached but spoof check failed or panel missing.
const EVENT_BUFFER_DENIED    := "buffer_denied"

# ---------------------------------------------------------------------------
# Platform-reserved channels (DCR 019dfa66 §T5)
# ---------------------------------------------------------------------------
# These channels are pushed by the broker to paired_dsl panels in response to
# DocumentBuffer lifecycle events. They are NOT validated against
# ipc_channels — they are platform-managed (mirroring `on_progress`).
# The scene receives them via its `receive(channel, payload)` method.

## Initial notification when a render panel attaches to a buffer.
## Payload: {"path": String, "text": String, "version": int}
const CHANNEL_ATTACH_BUFFER  := "attach_buffer"
## Forwarded from DocumentBuffer.text_changed.
## Payload: {"text": String, "version": int}
const CHANNEL_TEXT_CHANGED   := "text_changed"
## Final notification when a render panel detaches.
## Payload: {"path": String}
const CHANNEL_DETACH_BUFFER  := "detach_buffer"

# ---------------------------------------------------------------------------
# Platform-reserved host.fs.* channels (DCR 019dfa66 §T7.5 — host_capabilities)
# ---------------------------------------------------------------------------
# Plugin file-watch capability. Like attach_buffer/text_changed/detach_buffer,
# these are platform-managed: host.fs.watch and host.fs.unwatch are inbound
# RPCs (panel emits request, broker replies); host.fs.changed is an outbound
# push. None of them are declared in the plugin manifest's ipc_channels —
# they bypass the allowlist as the substrate's filesystem-watcher capability.

## Plugin asks host to watch a path. RPC; reply via _deliver_reply.
## Payload: {"path": String}. Reply: {"success": bool, "error": String?}.
const CHANNEL_HOST_FS_WATCH   := "host.fs.watch"
## Plugin asks host to stop watching a path it previously watched.
## Payload: {"path": String}. Reply: {"success": bool, "error": String?}.
const CHANNEL_HOST_FS_UNWATCH := "host.fs.unwatch"
## Host pushes a change notification to any panels that watched the path.
## Pushed via scene.receive() (bypass push_to_panel).
## Payload: {"path": String, "mtime": int, "size": int}
const CHANNEL_HOST_FS_CHANGED := "host.fs.changed"

## Owner_id prefix passed to FileWatcherService for plugin-panel subscriptions.
## Format: "plugin_panel:<plugin_id>:<panel_name>". This means panel detach
## (which calls unwatch_all on this owner_id) cleanly removes the panel's
## subscriptions even if the panel didn't pair every watch with an unwatch.
const _FS_OWNER_PREFIX := "plugin_panel"


# Platform-reserved host_owned_save channels (DCR T6 R0 — panel-state IPC
# for plugin-scene editors that don't carry a canonical DocumentBuffer).
#
# Pattern: CapabilityBroker.dispatch sees host.documents.get_state /
# set_state for a plugin-scene editor whose buffer is null; it asks this
# broker to round-trip via the panel.
#
# Inbound: broker pushes a request to the panel (via push_to_panel /
# scene.receive). Outbound: panel emits a response back via the existing
# panel→broker `request` signal, with channel == CHANNEL_HOST_OWNED_SAVE_RESPONSE
# and a request_id matching what was pushed.
#
# Like host.fs.*, these channels bypass the manifest ipc_channels allowlist
# because they're substrate primitives the host owns.

## Broker pushes "give me your state": {"request_id": String, "op": "get"}
const CHANNEL_HOST_OWNED_SAVE_GET_REQUEST := "host_owned_save.get_request"
## Broker pushes "apply this state": {"request_id": String, "op": "set",
## "state": Dictionary} where state is the deck/panel state dict.
const CHANNEL_HOST_OWNED_SAVE_SET_REQUEST := "host_owned_save.set_request"
## Panel responds with: {"request_id": String, "success": bool,
## "state": Dictionary?, "error_code": String?, "error_message": String?}
const CHANNEL_HOST_OWNED_SAVE_RESPONSE    := "host_owned_save.response"

## Default timeout for panel-state requests. Panels typically respond
## within a frame; 5 seconds is generous enough to absorb scene reload
## delays without leaving the broker hung indefinitely.
const PANEL_STATE_REQUEST_TIMEOUT_SEC := 5.0

## Timeout for panel→backend tool calls. MCPServerConnection.call_tool defaults to
## 120s, which is far too short for long-running backend work (e.g. media-gen
## video, which can run 20+ min). Use a generous ceiling that matches the media
## client's own request budget so the three layers (panel await, host dispatch,
## backend client) stay aligned; a dead backend still resolves early via
## connection-loss rather than waiting this out.
const SCENE_BACKEND_CALL_TIMEOUT_SEC := 1800.0

static func _fs_owner_id(plugin_id: String, panel_name: String) -> String:
	return "%s:%s:%s" % [_FS_OWNER_PREFIX, plugin_id, panel_name]


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

## Maximum byte size of a serialised payload Dictionary (JSON form).
## Matches PluginWebviewBroker.MAX_PAYLOAD_BYTES.
const MAX_PAYLOAD_BYTES := 65536  # 64 KiB


# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

signal panel_registered(plugin_id: String, panel_name: String)
signal panel_unregistered(plugin_id: String, panel_name: String)


# ---------------------------------------------------------------------------
# Dependencies (ctor-injected; same pattern as PluginWebviewBroker)
# ---------------------------------------------------------------------------

## PluginManager: used to resolve plugin definitions and get MCP connections.
## Untyped Variant to allow test stubs via duck-typing (same pattern as
## CapabilityBroker._get_minerva_server). In production, assign a PluginManager.
var plugin_manager = null

## PluginPolicy: used to check capability grants before host-capability dispatch.
var plugin_policy: PluginPolicy = null

## CapabilityBroker: used to execute host-capability calls.
var capability_broker: CapabilityBroker = null

## PluginAuditLog: used to record every IPC decision.
var audit_log: PluginAuditLog = null


# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

## panel_name -> _PanelEntry
## Each entry stores the weak ref to the scene root, plugin ownership, declared
## channels, and the attached MinervaIPC helper.
var _panel_registry: Dictionary = {}

## Reverse map for host.fs.* push routing: absolute_path -> set-of-panel_names
## (each panel_name → true). When FileWatcherService emits file_changed for a
## path, broker iterates this map and pushes host.fs.changed to each subscribed
## panel via scene.receive(). Maintained on host.fs.watch / host.fs.unwatch
## RPCs and on panel teardown.
var _fs_path_subscribers: Dictionary = {}

## Pending panel-state requests issued via request_panel_state, keyed by
## request_id. Each value is a `_PanelStateAwaiter` whose `completed` signal
## resolves with the panel's response (or a timeout-shaped failure).
##
## Lifecycle: created in request_panel_state, populated when the panel emits
## a CHANNEL_HOST_OWNED_SAVE_RESPONSE with the matching id, erased after the
## awaiter resolves (or timeout). Callers must `await awaiter.completed` to
## get the result; the broker emits then erases.
var _pending_panel_state: Dictionary = {}

## Monotonic counter for panel-state request ids. Combined with a "panel-state-"
## prefix for easy distinction in audit logs.
var _next_panel_state_request_id: int = 0

## Per-editor blob store: editor_name -> {handle -> {bytes, content_type, refcount}}
##
## Blobs are stored by reference — PackedByteArray is reference-typed in Godot 4,
## so storing the caller's value without .duplicate() is intentional and saves
## memory. Callers MUST NOT mutate the bytes after storing.
##
## Cleared on editor close via _clear_blobs_for_editor. R2+ will expose this
## store through host.documents.get_blob / put_blob capabilities.
var _blob_stores: Dictionary = {}

## Per-editor monotonic handle counter: editor_name -> int (next handle index).
##
## This counter is never reset, even after _clear_blobs_for_editor, so handles
## are never re-used within an editor's lifetime. Collision safety: a blob
## loaded at startup, GC'd mid-session, then a new blob stored later gets a
## distinct handle rather than colliding with any handle a plugin may have
## cached or serialised.
var _next_blob_handle: Dictionary = {}


## Awaiter for a single panel-state request. Lifetime is bounded by either
## the response landing (handle_scene_request emits) or a timeout fallback.
##
## owner_plugin_id + owner_panel_name are stored so _resolve_panel_state_response
## can verify that the response originated from the panel we asked. Without
## this binding, a malicious or buggy plugin could emit a host_owned_save.
## response with another panel's request_id and resolve the awaiter with
## arbitrary state. Identifiers are enumerable (counter-based "panel-state-N")
## so the binding is mandatory, not optional.
class _PanelStateAwaiter extends RefCounted:
	signal completed(result: Dictionary)
	var resolved: bool = false
	var owner_plugin_id: String = ""
	var owner_panel_name: String = ""

	func resolve(result: Dictionary) -> void:
		if resolved:
			return
		resolved = true
		completed.emit(result)

## Whether the file_changed signal has been hooked. Connected lazily on the
## first host.fs.watch call so unit tests that don't exercise host.fs.* don't
## see the watcher hook.
var _fs_signal_connected: bool = false


# ---------------------------------------------------------------------------
# Constructor
# ---------------------------------------------------------------------------

func _init(
		p_plugin_manager = null,          # PluginManager in production; untyped for testability
		p_plugin_policy: PluginPolicy = null,
		p_capability_broker: CapabilityBroker = null,
		p_audit_log: PluginAuditLog = null
) -> void:
	plugin_manager    = p_plugin_manager
	plugin_policy     = p_plugin_policy
	capability_broker = p_capability_broker
	audit_log         = p_audit_log


# ---------------------------------------------------------------------------
# Panel registry
# ---------------------------------------------------------------------------

## Register a plugin scene panel with the broker.
##
## Called by PluginScenePanelHost after the scene root is added to the tree
## and before _on_panel_loaded is fired.
##
## Parameters:
##   panel_root         — root Control node of the plugin scene.
##   plugin_id          — owning plugin's id (e.g. "cad").
##   panel_key          — the REGISTRY KEY: unique per open panel instance.
##                        Callers that mount one panel per editor tab pass a
##                        per-editor key (Editor.plugin_panel_key); a caller
##                        with only a manifest name may pass that instead, at
##                        the cost of one registration per plugin.
##   declared_channels  — channels this panel is allowed to use, from
##                        the manifest's panels[].ipc_channels field.
##   manifest_panel_name — panels[].name from the manifest; defaults to
##                        panel_key when the caller has nothing better.
##   editor             — the owning Editor wrapper, held weakly so
##                        get_panel_for_editor can resolve by the tab title and
##                        file path the editor has RIGHT NOW.
##
## Attaches a MinervaIPC helper node as "$_MinervaIPC" on the panel root.
## Wires panel_root's `request` signal to handle_scene_request.
##
## Uses call_deferred for the first-registration trampoline so that requests
## emitted during _ready() queue behind _on_panel_loaded (design §5.3).
func register_panel(
		panel_root: Node,
		plugin_id: String,
		panel_key: String,
		declared_channels: PackedStringArray,
		manifest_panel_name: String = "",
		editor: Object = null
) -> void:
	if not _validate_registration_args(panel_root, plugin_id, panel_key):
		return
	var panel_name: String = manifest_panel_name if not manifest_panel_name.is_empty() else panel_key

	if _panel_registry.has(panel_key):
		var existing: _PanelEntry = _panel_registry[panel_key]
		var existing_owner: String = existing.plugin_id
		if existing_owner != plugin_id:
			push_warning(
				"[PluginScenePanelBroker] Panel '%s' was owned by '%s', re-assigning to '%s'" % [
					panel_key, existing_owner, plugin_id
				]
			)
		else:
			push_warning(
				"[PluginScenePanelBroker] Panel '%s' is already registered for plugin '%s'; re-registering" % [
					panel_key, plugin_id
				]
			)
		# Detach the old buffer + helper before overwriting.
		_disconnect_buffer(existing)
		_detach_ipc_helper(existing)

	# Create and attach the MinervaIPC helper node.
	var ipc_helper := MinervaIPC.new()
	ipc_helper.name = MinervaIPC.HELPER_NODE_NAME
	panel_root.add_child(ipc_helper)

	# Build registry entry.
	var entry := _PanelEntry.new()
	entry.panel_ref   = weakref(panel_root)
	entry.plugin_id   = plugin_id
	entry.panel_key   = panel_key
	entry.panel_name  = panel_name
	entry.channels    = declared_channels
	entry.ipc_helper  = ipc_helper
	entry.editor_ref  = weakref(editor) if editor != null else null
	_panel_registry[panel_key] = entry

	# Wire the scene's outbound `request` signal to the broker.
	# We use call_deferred so any `request` emitted during _ready() is
	# delivered after _on_panel_loaded returns (§5.3 trampoline). The wiring
	# carries this registration's generation so a request that lands after the
	# key has been re-registered is dropped rather than served to the newcomer.
	if panel_root.has_signal("request"):
		var generation: int = _entry_generation(entry)
		panel_root.request.connect(
			func(channel: String, payload: Dictionary, reply_id: String) -> void:
				call_deferred(
					"handle_scene_request",
					panel_key, channel, payload, reply_id, generation
				)
		)
	else:
		push_warning(
			("[PluginScenePanelBroker] Panel '%s' (plugin '%s') has no `request` signal; " +
			"outbound IPC will not work") % [panel_key, plugin_id]
		)

	print(
		"[PluginScenePanelBroker] Registered panel '%s' -> plugin '%s' (%d channel(s))" % [
			panel_key, plugin_id, declared_channels.size()
		]
	)
	panel_registered.emit(plugin_id, panel_key)


## Unregister a single panel.
##
## Called by PluginScenePanelHost when a tab is closed or a plugin is stopped.
## Should be called inside the _on_panel_unload hook, before queue_free.
func unregister_panel(plugin_id: String, panel_name: String) -> void:
	panel_name = _panel_key_for(plugin_id, panel_name, false)
	if not _panel_registry.has(panel_name):
		push_warning(
			"[PluginScenePanelBroker] unregister_panel: panel '%s' is not registered" % panel_name
		)
		return

	var entry: _PanelEntry = _panel_registry[panel_name]
	if entry.plugin_id != plugin_id:
		push_warning(
			"[PluginScenePanelBroker] unregister_panel: panel '%s' is owned by '%s', not '%s'" % [
				panel_name, entry.plugin_id, plugin_id
			]
		)
		return

	_disconnect_buffer(entry)
	_cleanup_fs_subscriptions(plugin_id, panel_name)
	_detach_ipc_helper(entry)
	_panel_registry.erase(panel_name)

	print(
		"[PluginScenePanelBroker] Unregistered panel '%s' from plugin '%s'" % [
			panel_name, plugin_id
		]
	)
	panel_unregistered.emit(plugin_id, panel_name)


## Unregister all panels belonging to a plugin.
##
## Called when a plugin is stopped or uninstalled.
func unregister_plugin_panels(plugin_id: String) -> void:
	var to_remove: Array[String] = []
	for panel_name in _panel_registry.keys():
		var entry: _PanelEntry = _panel_registry[panel_name]
		if entry.plugin_id == plugin_id:
			to_remove.append(panel_name)

	for panel_name in to_remove:
		var entry: _PanelEntry = _panel_registry[panel_name]
		_disconnect_buffer(entry)
		_cleanup_fs_subscriptions(plugin_id, panel_name)
		_detach_ipc_helper(entry)
		_panel_registry.erase(panel_name)
		panel_unregistered.emit(plugin_id, panel_name)

	if not to_remove.is_empty():
		print(
			"[PluginScenePanelBroker] Unregistered %d panel(s) for plugin '%s'" % [
				to_remove.size(), plugin_id
			]
		)


# ---------------------------------------------------------------------------
# Query helpers
# ---------------------------------------------------------------------------

## Returns true if a registration answers to panel_name: its registry key, or
## the manifest panel name of exactly one live tab (of plugin_id when given,
## of any plugin otherwise), the same way every other name-keyed entry point
## resolves it. A non-empty plugin_id must own the registration found — the
## other entry points spoof-check after resolving, and this one is no laxer.
func is_panel_registered(panel_name: String, plugin_id: String = "") -> bool:
	var key := _panel_key_for(plugin_id, panel_name)
	if not _panel_registry.has(key):
		return false
	return plugin_id.is_empty() \
		or (_panel_registry[key] as _PanelEntry).plugin_id == plugin_id


## Returns the plugin_id that owns a panel, or "" if not resolvable.
## Accepts anything get_panel_for_editor accepts, so an ownership check and the
## panel lookup that precedes it can never disagree about which panel is meant.
func get_panel_owner(panel_key: String) -> String:
	# Exact key first, and without a liveness test: teardown asks who owns a
	# registration precisely when the scene root has just been freed, and a
	# dead entry must still be unregisterable by its owner.
	if _panel_registry.has(panel_key):
		return (_panel_registry[panel_key] as _PanelEntry).plugin_id
	var key := resolve_editor_key(panel_key)
	if key.is_empty():
		return ""
	return (_panel_registry[key] as _PanelEntry).plugin_id


## Precision tiers for the names a panel answers to. The tier is a property of
## the KIND of name, not of its position in any list, so an entry that lacks a
## title (or whose title equals its file name) does not promote its remaining
## aliases: a bare file name is tier FILE_NAME on every entry.
enum _AliasTier { KEY, TITLE, PATH, FILE_NAME, MANIFEST }


## Every name a caller may legitimately use to address `entry`, mapped to its
## _AliasTier: the registry key, the editor's current tab title, the document's
## absolute path, its bare file name, and the manifest panel name. A string
## that is several of these at once keeps its most precise tier. The editor is
## read at call time — never cached — so renaming a tab or saving to a new path
## cannot leave a stale alias behind.
func _entry_aliases(entry: _PanelEntry) -> Dictionary:
	var aliases: Dictionary = {entry.panel_key: _AliasTier.KEY}
	var editor: Object = entry.editor_ref.get_ref() if entry.editor_ref != null else null
	if editor != null and is_instance_valid(editor):
		if "tab_title" in editor:
			var title := str(editor.get("tab_title"))
			if not title.is_empty() and not aliases.has(title):
				aliases[title] = _AliasTier.TITLE
		if "file" in editor:
			var path := str(editor.get("file"))
			if not path.is_empty():
				if not aliases.has(path):
					aliases[path] = _AliasTier.PATH
				var base := path.get_file()
				if not base.is_empty() and not aliases.has(base):
					aliases[base] = _AliasTier.FILE_NAME
	if not aliases.has(entry.panel_name):
		aliases[entry.panel_name] = _AliasTier.MANIFEST
	return aliases


## The one name of `entry` a caller sees in a listing: its tab title when the
## editor has one, otherwise the registry key.
func _entry_display_name(entry: _PanelEntry) -> String:
	var aliases: Dictionary = _entry_aliases(entry)
	for alias in aliases.keys():
		if int(aliases[alias]) == _AliasTier.TITLE:
			return str(alias)
	return entry.panel_key


## The registry key behind a name a plugin passes to a name-keyed entry point
## (push_to_panel, get_attached_buffer, unregister_panel, ...). A registry key
## is returned as it is when it belongs to `plugin_id` (any plugin when "");
## another plugin's key is not this plugin's address for anything and is
## treated like any other string. Anything else is taken as the manifest panel
## name and resolved to the one panel of `plugin_id` (any plugin when "") under
## it — a plugin that has one tab open may keep addressing it by that name.
## Zero matches return the name unchanged, so the caller's own not-registered
## path runs and quotes what it was given; more than one refuses the same way
## an ambiguous editor name does, since picking one would silently serve the
## wrong tab.
##
## live_only=true (queries, pushes) considers live entries. Destructive
## callers (unregister, detach) pass false: a dead entry with the same
## plugin+name still occupies the registry, and resolving past it would remove
## the live tab instead of the one that was closed.
func _panel_key_for(plugin_id: String, panel_name: String, live_only: bool = true) -> String:
	if _panel_registry.has(panel_name) and (plugin_id.is_empty()
			or (_panel_registry[panel_name] as _PanelEntry).plugin_id == plugin_id):
		return panel_name
	var matches: Array = []
	for key in _panel_registry.keys():
		var entry: _PanelEntry = _panel_registry[key]
		if (plugin_id.is_empty() or entry.plugin_id == plugin_id) \
				and entry.panel_name == panel_name \
				and (not live_only or _is_panel_alive(entry)):
			matches.append(key)
	if matches.size() == 1:
		return str(matches[0])
	if matches.size() > 1:
		_warn_ambiguous_name(panel_name, matches, live_only)
	return panel_name


func _warn_ambiguous_name(editor_name: String, matches: Array, live_only: bool = true) -> void:
	push_warning(
		("[PluginScenePanelBroker] '%s' names %d %s (%s); address one by its "
		+ "registry key, or by the '<title> [<key>]' form list_panel_editor_names prints")
		% [editor_name, matches.size(),
			"live panels" if live_only else "registrations (some closed without unregistering)",
			str(matches)]
	)


## Resolve any name a caller may address a live panel by to its registry key,
## or "" when nothing live answers to it.
##
## Aliases are ranked (see _entry_aliases) and the most precise tier that has
## candidates wins, so a manifest panel name never outranks the tab title of a
## different document. A name that two live panels answer to at the same tier
## is AMBIGUOUS and resolves to "" — the caller then gets editor_not_found with
## both names listed rather than a coin flip between two documents.
##
## Dead entries (freed scene root) are skipped, so a panel whose scene failed
## to stay alive is never "found".
##
## The disambiguated form list_panel_editor_names prints for a tied title —
## "<title> [<key>]" — is also accepted, so a caller can paste back the exact
## string the refusal offered them. It is tried only after no alias matched:
## a panel literally titled that way is addressed by its title, never by the
## key in its brackets.
func resolve_editor_key(editor_name: String) -> String:
	if editor_name.is_empty():
		return ""
	var best_tier: int = -1
	var matches: Array = []
	for key in _panel_registry.keys():
		var entry: _PanelEntry = _panel_registry[key]
		if not _is_panel_alive(entry):
			continue
		var tier: int = int(_entry_aliases(entry).get(editor_name, -1))
		if tier < 0:
			continue
		if best_tier < 0 or tier < best_tier:
			best_tier = tier
			matches = [key]
		elif tier == best_tier:
			matches.append(key)
	if matches.size() == 1:
		return str(matches[0])
	if matches.size() > 1:
		_warn_ambiguous_name(editor_name, matches)
		return ""
	return _key_from_display_name(editor_name)


## The registry key inside a disambiguated display name ("<title> [<key>]"), or
## "" when the string is not exactly what list_panel_editor_names would print
## for a live entry: that entry's current display name + " [" + its key + "]".
## Any other bracketed string — a stale paste, a title that merely ends in a
## bracketed key — is not this form.
func _key_from_display_name(editor_name: String) -> String:
	if not editor_name.ends_with("]"):
		return ""
	var open_at: int = editor_name.rfind(" [")
	if open_at < 0:
		return ""
	var key: String = editor_name.substr(open_at + 2, editor_name.length() - open_at - 3)
	if key.is_empty() or not _panel_registry.has(key):
		return ""
	var entry: _PanelEntry = _panel_registry[key]
	if not _is_panel_alive(entry):
		return ""
	return key if editor_name == "%s [%s]" % [_entry_display_name(entry), key] else ""


## Returns the live scene-panel root addressed by editor_name, or null.
##
## editor_name may be the registry key, the editor's tab title (including the
## "(1)" Minerva appends to a second tab on the same file), the document's
## absolute path, its bare file name, or the manifest panel name when only one
## instance of that panel is open. Returns null when nothing live answers, when
## the name is ambiguous, or when the registered scene root has been freed.
##
## Used by PluginToolRegistry to dispatch panel-executed tools
## (executor == "panel", DCR 019f6c3d0e3d).
func get_panel_for_editor(editor_name: String) -> Node:
	var key := resolve_editor_key(editor_name)
	if key.is_empty():
		return null
	var entry: _PanelEntry = _panel_registry[key]
	return entry.panel_ref.get_ref() as Node


## Returns the names a caller can actually address right now: for each LIVE
## panel, the editor tab title when one is known, otherwise the registry key.
##
## Two file-less tabs of one plugin are titled with the same manifest panel name
## (EditorPane.add_plugin_scene_editor), so that title resolves to neither of
## them. Listing it twice would send the caller straight back into the tie, so a
## title more than one live panel answers to is printed as "<title> [<key>]" —
## the key being the one alias that is unique — and resolve_editor_key accepts
## that form back verbatim.
##
## Every string printed is checked to resolve back to the entry it was made
## for: a live tab may be titled exactly like another entry's bracketed form
## (or like its key), and the title tier would then capture the paste. Such
## an entry is printed as its bare key, which only ever resolves to itself.
##
## Used for the editor_not_found error UX — callers list what IS available, so
## a registration whose scene root has been freed must not appear here.
func list_panel_editor_names() -> Array:
	var displays: Dictionary = {}   # registry key -> display name
	var display_counts: Dictionary = {}
	for key in _panel_registry.keys():
		var entry: _PanelEntry = _panel_registry[key]
		if not _is_panel_alive(entry):
			continue
		var display: String = _entry_display_name(entry)
		displays[key] = display
		display_counts[display] = int(display_counts.get(display, 0)) + 1

	var names: Array = []
	for key in displays.keys():
		var display: String = str(displays[key])
		if int(display_counts.get(display, 0)) > 1:
			display = "%s [%s]" % [display, str(key)]
		if resolve_editor_key(display) != str(key):
			display = str(key)
		if not names.has(display):
			names.append(display)
	return names


## Returns the names of registrations whose scene root is gone. Registration
## happens only after the scene instantiates (PluginScenePanelHost step 10), so
## an entry can only be here because its root was freed without the panel
## unregistering — a closed tab or a stopped plugin that skipped its teardown
## hook, never a panel that failed to load. These are NOT known editors:
## nothing can be dispatched to them. They are reported separately so a caller
## who addressed one is told why it cannot be reached instead of being told the
## name is unknown.
func list_dead_panel_editor_names() -> Array:
	var names: Array = []
	for key in _panel_registry.keys():
		var entry: _PanelEntry = _panel_registry[key]
		if _is_panel_alive(entry):
			continue
		for alias in _entry_aliases(entry).keys():
			if not names.has(alias):
				names.append(alias)
	return names


# ---------------------------------------------------------------------------
# Outbound: scene -> plugin
# ---------------------------------------------------------------------------

## Handle a request emitted by a plugin scene panel.
##
## Parameters:
##   panel_key  — the registry key of the panel that emitted the signal. The
##                manifest's name for that panel is read off the entry; the two
##                differ, and only the manifest name may be checked against the
##                manifest.
##   channel    — the declared channel, e.g. "cad.render_request" or
##                "capability:notes.create".
##   payload    — a Dictionary of call-specific arguments.
##   reply_id   — caller-generated ID; result is delivered to the scene's
##                $_MinervaIPC._reply(reply_id, result).
##   generation — the registration the request was emitted under (see
##                _entry_generation), or 0 to accept whatever is registered
##                now. The reply is delivered only to that same registration:
##                a hot reload re-registers the key with a fresh helper while
##                the backend is still busy, and the old reply must not
##                satisfy a reused reply id on the new panel.
##
## Validation order (mirrors PluginWebviewBroker.handle_ipc_message):
##   1. Basic input validation.
##   2. Resolve panel -> plugin_id.
##   3. Validate panel ownership against manifest.
##   4. Validate channel against panel's declared_channels (per-panel scope).
##   5. Validate channel against manifest ui.ipc_messages (global allowlist).
##   6. Validate payload size.
##   7. Dispatch to CapabilityBroker or plugin backend.
##   8. Deliver reply via $_MinervaIPC._reply().
func handle_scene_request(
		panel_key: String,
		channel: String,
		payload: Dictionary,
		reply_id: String,
		generation: int = 0
) -> void:

	# --- 1. Basic input validation -------------------------------------------
	if panel_key.is_empty():
		push_warning("[PluginScenePanelBroker] handle_scene_request: empty panel_key")
		return

	if channel.is_empty():
		push_warning("[PluginScenePanelBroker] handle_scene_request: empty channel")
		return

	# --- 2. Resolve panel -> plugin -------------------------------------------
	if not _panel_registry.has(panel_key):
		# Nothing is registered under this key, so there is no manifest name to
		# report; the key is all the audit can name it by.
		_audit("", EVENT_SCENE_DENIED, {
			"panel_name": panel_key,
			"panel_key": panel_key,
			"channel": channel,
			"reason": "panel_not_registered",
		})
		_deliver_error(panel_key, reply_id,
			PluginErrors.permission_denied("",
				"Panel '%s' is not registered with any plugin" % panel_key))
		return

	var entry: _PanelEntry = _panel_registry[panel_key]
	var plugin_id: String = entry.plugin_id
	# The manifest's name for this panel. The registry key is unique per open
	# tab and is NOT in the manifest, so every manifest-facing check and every
	# message that quotes "the panel the plugin declared" uses this.
	var manifest_panel: String = entry.panel_name

	# A request wired under an earlier registration of this key belongs to a
	# helper that no longer exists; the panel now under the key never asked.
	if generation != 0 and _entry_generation(entry) != generation:
		_audit(plugin_id, EVENT_SCENE_STALE_REGISTRATION, {
			"panel_name": manifest_panel,
			"panel_key": panel_key,
			"channel": channel,
			"reply_id": reply_id,
			"reason": "request_from_superseded_registration",
		})
		return
	generation = _entry_generation(entry)

	# Guard: check that the panel root is still alive (weak ref).
	if not _is_panel_alive(entry):
		_audit(plugin_id, EVENT_SCENE_DENIED, {
			"panel_name": manifest_panel,
			"panel_key": panel_key,
			"channel": channel,
			"reason": "panel_root_freed",
		})
		# No live panel to deliver to; log and return.
		push_warning(
			"[PluginScenePanelBroker] handle_scene_request: panel root for '%s' has been freed" % panel_key
		)
		return

	# --- 2.5. Platform-reserved host.fs.* channels (DCR §T7.5) ----------------
	# These are platform capabilities; bypass the manifest channel allowlist
	# and dispatch directly. Same justification as attach_buffer/text_changed.
	if channel == CHANNEL_HOST_FS_WATCH:
		var fs_result := _handle_host_fs_watch(plugin_id, panel_key, payload)
		_audit(plugin_id, EVENT_SCENE_DISPATCHED, {
			"panel_name": manifest_panel, "panel_key": panel_key, "channel": channel,
			"scene_success": fs_result.get("success", false),
		})
		_deliver_reply(panel_key, reply_id, fs_result)
		return
	if channel == CHANNEL_HOST_FS_UNWATCH:
		var fs_result := _handle_host_fs_unwatch(plugin_id, panel_key, payload)
		_audit(plugin_id, EVENT_SCENE_DISPATCHED, {
			"panel_name": manifest_panel, "panel_key": panel_key, "channel": channel,
			"scene_success": fs_result.get("success", false),
		})
		_deliver_reply(panel_key, reply_id, fs_result)
		return
	if channel == CHANNEL_HOST_OWNED_SAVE_RESPONSE:
		# Panel responding to a broker-initiated panel-state request. No
		# reply expected (panel is responding, not requesting); just resolve
		# the matching awaiter and audit the dispatch. Pass the resolved
		# plugin_id + panel_key so _resolve_panel_state_response can verify
		# the responder owns the request (anti-spoofing).
		_audit(plugin_id, EVENT_SCENE_DISPATCHED, {
			"panel_name": manifest_panel, "panel_key": panel_key, "channel": channel,
			"request_id": str(payload.get("request_id", "")),
		})
		_resolve_panel_state_response(plugin_id, panel_key, payload)
		return

	# --- 3. Validate panel ownership against manifest -------------------------
	if not _validate_panel_ownership(plugin_id, manifest_panel):
		_audit(plugin_id, EVENT_SCENE_DENIED, {
			"panel_name": manifest_panel,
			"panel_key": panel_key,
			"channel": channel,
			"reason": "panel_ownership_mismatch",
		})
		_deliver_error(panel_key, reply_id,
			PluginErrors.permission_denied(plugin_id,
				"Panel '%s' is not declared in the manifest of plugin '%s'" % [manifest_panel, plugin_id]))
		return

	# --- 4. Validate channel is in this panel's declared_channels -------------
	if not channel.begins_with("capability:") and not (channel in entry.channels):
		_audit(plugin_id, EVENT_SCENE_DENIED, {
			"panel_name": manifest_panel,
			"panel_key": panel_key,
			"channel": channel,
			"reason": "channel_not_in_panel_scope",
		})
		_deliver_error(panel_key, reply_id,
			PluginErrors.permission_denied(plugin_id,
				"Channel '%s' is not in the declared ipc_channels for panel '%s'" % [
					channel, manifest_panel
				]))
		return

	# --- 5. Validate channel against manifest's global ipc_messages allowlist --
	if not _validate_channel_declared(plugin_id, channel):
		_audit(plugin_id, EVENT_SCENE_DENIED, {
			"panel_name": manifest_panel,
			"panel_key": panel_key,
			"channel": channel,
			"reason": "channel_not_declared",
		})
		_deliver_error(panel_key, reply_id,
			PluginErrors.permission_denied(plugin_id,
				"Channel '%s' is not declared in the manifest of plugin '%s'" % [
					channel, plugin_id
				]))
		return

	# --- 6. Validate payload size ---------------------------------------------
	var payload_json := JSON.stringify(payload)
	if payload_json.length() > MAX_PAYLOAD_BYTES:
		_audit(plugin_id, EVENT_SCENE_DENIED, {
			"panel_name": manifest_panel,
			"panel_key": panel_key,
			"channel": channel,
			"reason": "payload_too_large",
			"scene_size": payload_json.length(),
		})
		_deliver_error(panel_key, reply_id,
			PluginErrors.payload_too_large(plugin_id, MAX_PAYLOAD_BYTES, payload_json.length()))
		return

	# --- 7. Dispatch ----------------------------------------------------------
	_audit(plugin_id, EVENT_SCENE_ALLOWED, {
		"panel_name": manifest_panel,
		"panel_key": panel_key,
		"channel": channel,
	})

	var result: Dictionary
	if channel.begins_with("capability:"):
		result = await _dispatch_to_capability_broker(plugin_id, channel, payload)
	else:
		result = await _dispatch_to_plugin_backend(plugin_id, channel, payload)

	_audit(plugin_id, EVENT_SCENE_DISPATCHED, {
		"panel_name": manifest_panel,
		"panel_key": panel_key,
		"channel": channel,
		"scene_success": result.get("success", false),
	})

	# --- 8. Deliver reply back to scene via $_MinervaIPC ----------------------
	# The await above may have outlived the registration; deliver only to the
	# generation that asked.
	_deliver_reply(panel_key, reply_id, result, generation)


# ---------------------------------------------------------------------------
# Inbound: plugin -> scene
# ---------------------------------------------------------------------------

## Push an async notification from the plugin backend to a specific panel.
##
## Called by PluginEventBroker when the plugin emits an event addressed to a
## named panel.
##
## Returns true if the panel is live and receive() was called.
## Returns false if the panel is not registered or its root has been freed;
## this is not an error — the plugin may push before a panel is opened.
func push_to_panel(
		plugin_id: String,
		panel_name: String,
		channel: String,
		payload: Dictionary
) -> bool:
	panel_name = _panel_key_for(plugin_id, panel_name)
	if not _panel_registry.has(panel_name):
		_audit(plugin_id, EVENT_SCENE_PUSH_MISS, {
			"panel_name": panel_name,
			"channel": channel,
			"reason": "not_registered",
		})
		return false

	var entry: _PanelEntry = _panel_registry[panel_name]

	# Spoof check: the plugin pushing must own the panel.
	if entry.plugin_id != plugin_id:
		_audit(plugin_id, EVENT_SCENE_DENIED, {
			"panel_name": panel_name,
			"channel": channel,
			"reason": "push_plugin_mismatch",
			"scene_expected": entry.plugin_id,
		})
		push_warning(
			("[PluginScenePanelBroker] push_to_panel: plugin '%s' tried to push to " +
			"panel '%s' owned by '%s'") % [plugin_id, panel_name, entry.plugin_id]
		)
		return false

	var panel_root: Node = entry.panel_ref.get_ref() as Node
	if panel_root == null:
		_audit(plugin_id, EVENT_SCENE_PUSH_MISS, {
			"panel_name": panel_name,
			"channel": channel,
			"reason": "panel_root_freed",
		})
		return false

	if not panel_root.has_method("receive"):
		push_warning(
			"[PluginScenePanelBroker] push_to_panel: panel '%s' has no `receive` method" % panel_name
		)
		_audit(plugin_id, EVENT_SCENE_PUSH_MISS, {
			"panel_name": panel_name,
			"channel": channel,
			"reason": "no_receive_method",
		})
		return false

	_audit(plugin_id, EVENT_SCENE_PUSH, {
		"panel_name": panel_name,
		"channel": channel,
	})
	panel_root.receive(channel, payload)
	return true


## Push a progress notification from the plugin backend to a specific panel.
##
## Progress notifications are an implicit, platform-managed channel — they do
## NOT need to be declared in the panel's ipc_channels or the manifest's
## ui.ipc_messages.  They are delivered via a direct method call on the scene
## root; the scene opts in by implementing `on_progress(request_id, phase, fraction)`.
##
## Called by the upstream MCP-server → broker integration layer when the
## plugin emits a `{"method":"progress","params":{"id":…,"phase":…,"fraction":…}}`
## notification (see Go-python-bridge-design.md §4).
##
## Parameters:
##   plugin_id  — the plugin that owns the panel (spoof check).
##   panel_name — registered panel name.
##   request_id — opaque correlation id echoed from the originating request
##                (e.g. "req_00017").  Passed through unchanged to the scene.
##   phase      — human-readable phase label (e.g. "tessellate", "export").
##   fraction   — completion fraction in [0.0, 1.0].
##
## Returns:
##   true   — panel is live and on_progress() was called.
##   false  — panel not registered, plugin mismatch, or scene lacks on_progress
##            (the last case is non-fatal: many scenes simply do not display
##            progress; it is logged with reason "progress_unsupported").
##
## TODO(integration): The upstream wiring from MinervaMCPServer / plugin MCP
## stdio transport to this method does not exist yet.  When the plugin-MCP-server
## protocol layer gains a `progress` notification channel, add a handler in
## MinervaMCPServer (or a dedicated PluginNotificationRouter) that parses
## `{"method":"progress","params":{…}}` and calls:
##   plugin_scene_panel_broker.push_progress(plugin_id, panel_name,
##       params["id"], params["phase"], params["fraction"])
## That wiring is deliberately out of scope for this task (broker-API only).
func push_progress(
		plugin_id: String,
		panel_name: String,
		request_id: String,
		phase: String,
		fraction: float
) -> bool:
	# --- panel not registered ------------------------------------------------
	panel_name = _panel_key_for(plugin_id, panel_name)
	if not _panel_registry.has(panel_name):
		_audit(plugin_id, EVENT_SCENE_PROGRESS_MISS, {
			"panel_name": panel_name,
			"request_id": request_id,
			"reason": "not_registered",
		})
		return false

	var entry: _PanelEntry = _panel_registry[panel_name]

	# --- spoof check: plugin must own the panel --------------------------------
	if entry.plugin_id != plugin_id:
		_audit(plugin_id, EVENT_SCENE_DENIED, {
			"panel_name": panel_name,
			"request_id": request_id,
			"reason": "progress_plugin_mismatch",
			"scene_expected": entry.plugin_id,
		})
		push_warning(
			("[PluginScenePanelBroker] push_progress: plugin '%s' tried to push progress to " +
			"panel '%s' owned by '%s'") % [plugin_id, panel_name, entry.plugin_id]
		)
		return false

	# --- scene root still alive? ----------------------------------------------
	var panel_root: Node = entry.panel_ref.get_ref() as Node
	if panel_root == null:
		_audit(plugin_id, EVENT_SCENE_PROGRESS_MISS, {
			"panel_name": panel_name,
			"request_id": request_id,
			"reason": "panel_root_freed",
		})
		return false

	# --- scene must implement on_progress (opt-in) ----------------------------
	if not panel_root.has_method("on_progress"):
		_audit(plugin_id, EVENT_SCENE_PROGRESS_MISS, {
			"panel_name": panel_name,
			"request_id": request_id,
			"reason": "progress_unsupported",
		})
		# Non-fatal: many scenes won't implement progress display.
		push_warning(
			("[PluginScenePanelBroker] push_progress: panel '%s' (plugin '%s') has no " +
			"`on_progress` method; progress notification dropped") % [panel_name, plugin_id]
		)
		return false

	# --- deliver ---------------------------------------------------------------
	_audit(plugin_id, EVENT_SCENE_PROGRESS, {
		"panel_name": panel_name,
		"request_id": request_id,
		"phase": phase,
		"fraction": fraction,
	})
	panel_root.on_progress(request_id, phase, fraction)
	return true


# ---------------------------------------------------------------------------
# DocumentBuffer attach/detach (DCR 019dfa66 §T5 — paired_dsl substrate)
# ---------------------------------------------------------------------------

## Look up the DocumentBuffer currently attached to a panel.
##
## Used by MCPDocTools to route writes through the buffer (rather than
## invoke_load) on paired_dsl panels — keeps the paired text editor in sync.
## Returns null if the panel isn't registered, has no buffer attached, or the
## plugin_id spoof-check fails.
func get_attached_buffer(plugin_id: String, panel_name: String) -> DocumentBuffer:
	panel_name = _panel_key_for(plugin_id, panel_name)
	if not _panel_registry.has(panel_name):
		return null
	var entry: _PanelEntry = _panel_registry[panel_name]
	if entry.plugin_id != plugin_id:
		return null
	return entry.attached_buffer


## Subscribe a registered panel to a DocumentBuffer.
##
## Wires buffer.text_changed → panel.receive("text_changed", {text, version})
## and pushes an initial "attach_buffer" notification with the current buffer
## state. Idempotent for the same panel; re-attaching to a different buffer
## detaches the previous one first.
##
## Used by the file-open dispatcher when a `render_mode: paired_dsl` panel
## opens — the panel renders the buffer text, and updates flow through the
## broker rather than the panel reading disk directly.
##
## Returns true on success, false if the panel is not registered, the spoof
## check fails, or the buffer is null.
func attach_buffer_to_panel(
		plugin_id: String,
		panel_name: String,
		buffer: DocumentBuffer
) -> bool:
	if buffer == null:
		_audit(plugin_id, EVENT_BUFFER_DENIED, {
			"panel_name": panel_name,
			"reason": "buffer_null",
		})
		return false

	panel_name = _panel_key_for(plugin_id, panel_name)
	if not _panel_registry.has(panel_name):
		_audit(plugin_id, EVENT_BUFFER_DENIED, {
			"panel_name": panel_name,
			"reason": "panel_not_registered",
		})
		return false

	var entry: _PanelEntry = _panel_registry[panel_name]
	if entry.plugin_id != plugin_id:
		_audit(plugin_id, EVENT_BUFFER_DENIED, {
			"panel_name": panel_name,
			"reason": "buffer_plugin_mismatch",
			"scene_expected": entry.plugin_id,
		})
		push_warning(
			("[PluginScenePanelBroker] attach_buffer_to_panel: plugin '%s' tried to attach " +
			"buffer to panel '%s' owned by '%s'") % [plugin_id, panel_name, entry.plugin_id]
		)
		return false

	# Same-buffer re-attach is a no-op: keeps the panel's local state and avoids
	# emitting a redundant attach_buffer notification that would reset its UI.
	if entry.attached_buffer == buffer:
		return true

	# If already attached (to a different buffer), tear it down first so signal
	# handles stay one-to-one.
	if entry.attached_buffer != null:
		_disconnect_buffer(entry)

	# Connect the buffer's text_changed signal to a closure that pushes to the
	# scene.  Capturing panel_name + plugin_id by value makes the handler safe
	# against later panel re-registration.
	var captured_panel_name: String = panel_name
	var captured_plugin_id: String = plugin_id
	var captured_document_id := buffer.document_id
	var handler := func(text: String, version: int) -> void:
		push_to_panel(captured_plugin_id, captured_panel_name, CHANNEL_TEXT_CHANGED, {
			"document_id": captured_document_id,
			"text": text,
			"version": version,
		})
	buffer.text_changed.connect(handler)
	# Bump the buffer's attachment refcount so DocumentRegistry knows a UI
	# surface is mirroring it.  The matching detach() runs in _disconnect_buffer.
	buffer.attach()
	entry.attached_buffer = buffer
	entry._buffer_text_changed_handler = handler
	var editor: Object = entry.editor_ref.get_ref() if entry.editor_ref != null else null
	if editor != null and editor.has_method("_on_shared_buffer_saved"):
		entry._buffer_saved_handler = editor._on_shared_buffer_saved
		buffer.saved.connect(entry._buffer_saved_handler)


	# Push the initial attach_buffer notification with the current buffer state.
	# Goes through push_to_panel so audit + alive-check are consistent with
	# subsequent text_changed pushes.
	push_to_panel(plugin_id, panel_name, CHANNEL_ATTACH_BUFFER, {
		"path":    buffer.file_path,
		"document_id": buffer.document_id,
		"text":    buffer.text,
		"version": buffer.version,
	})

	_audit(plugin_id, EVENT_BUFFER_ATTACHED, {
		"panel_name": panel_name,
		"path":       buffer.file_path,
		"version":    buffer.version,
	})
	return true


## Unsubscribe a panel from its attached DocumentBuffer.
##
## Disconnects the text_changed handler and pushes a final "detach_buffer"
## notification.  No-op if the panel is not registered or has no attached
## buffer.  Spoof-checks plugin_id against the panel owner.
func detach_buffer_from_panel(plugin_id: String, panel_name: String) -> void:
	panel_name = _panel_key_for(plugin_id, panel_name, false)
	if not _panel_registry.has(panel_name):
		return

	var entry: _PanelEntry = _panel_registry[panel_name]
	if entry.plugin_id != plugin_id:
		_audit(plugin_id, EVENT_BUFFER_DENIED, {
			"panel_name": panel_name,
			"reason": "detach_plugin_mismatch",
			"scene_expected": entry.plugin_id,
		})
		return

	if entry.attached_buffer == null:
		return

	var detach_path: String = entry.attached_buffer.file_path
	_disconnect_buffer(entry)

	# Best-effort detach notification; a freed panel ref is fine here.
	push_to_panel(plugin_id, panel_name, CHANNEL_DETACH_BUFFER, {
		"path": detach_path,
	})

	_audit(plugin_id, EVENT_BUFFER_DETACHED, {
		"panel_name": panel_name,
		"path":       detach_path,
	})


## Internal: drop the buffer signal connection on a panel entry.
## Safe to call when no buffer is attached.
func _disconnect_buffer(entry: _PanelEntry) -> void:
	if entry.attached_buffer == null:
		return
	if entry._buffer_text_changed_handler.is_valid():
		if entry.attached_buffer.text_changed.is_connected(entry._buffer_text_changed_handler):
			entry.attached_buffer.text_changed.disconnect(entry._buffer_text_changed_handler)
	if entry._buffer_saved_handler.is_valid() and entry.attached_buffer.saved.is_connected(entry._buffer_saved_handler):
		entry.attached_buffer.saved.disconnect(entry._buffer_saved_handler)
	entry._buffer_saved_handler = Callable()
	# Balance the attach() bump from attach_buffer_to_panel.
	entry.attached_buffer.detach()
	entry.attached_buffer = null
	entry._buffer_text_changed_handler = Callable()


# ---------------------------------------------------------------------------
# host_owned_save panel-state IPC (T6 R0)
# ---------------------------------------------------------------------------

## Request a plugin-scene panel's serialised state. Used by
## CapabilityBroker.host.documents.get_state when the editor is plugin-scene
## and has no canonical DocumentBuffer (state lives in panel UI memory).
##
## Returns one of:
##   {"success": true, "state": Dictionary}
##   {"success": false, "error_code": String, "error_message": String}
##   {"success": false, "error_code": "panel_not_registered"|"panel_root_freed"|"timeout"}
##
## Awaitable. Times out after PANEL_STATE_REQUEST_TIMEOUT_SEC if the panel
## never responds — never returns null, always a structured dict.
func request_panel_state(plugin_id: String, panel_name: String) -> Dictionary:
	# The blob store is keyed by the panel's registry key. CapabilityBroker
	# passes that key (Editor.plugin_panel_key); a plugin passing its manifest
	# panel name lands on the same store once _panel_key_for resolves it.
	panel_name = _panel_key_for(plugin_id, panel_name)
	var editor_name: String = panel_name
	var raw: Dictionary = await _request_panel_state_op(plugin_id, panel_name,
		CHANNEL_HOST_OWNED_SAVE_GET_REQUEST, {"op": "get"})
	if not raw.get("success", false):
		return raw
	# Strip any {__blob__: true, content_type, bytes} wrappers from the panel
	# state and replace them with {__blob_handle__, content_type} placeholders.
	# Plugins that don't use blob wrappers pass through unchanged.
	var panel_state: Dictionary = raw.get("state", {})
	var stripped: Variant = _strip_blobs_for_outbound(editor_name, panel_state, plugin_id)
	var result := raw.duplicate(true)
	result["state"] = stripped
	return result


## Apply a state dict to a plugin-scene panel. Symmetric with request_panel_state.
## Used by CapabilityBroker.host.documents.set_state for plugin-scene editors.
func apply_panel_state(plugin_id: String, panel_name: String, state: Dictionary) -> Dictionary:
	panel_name = _panel_key_for(plugin_id, panel_name)
	var editor_name: String = panel_name
	# Rehydrate any {__blob_handle__, content_type} placeholders back to
	# {__blob__: true, content_type, bytes} before forwarding to the panel.
	# Atomically fails if any handle is unknown. Plugins that don't use handles
	# pass through unchanged.
	var rehydrate_result: Dictionary = _rehydrate_blobs_for_inbound(editor_name, state, plugin_id)
	if not rehydrate_result.get("success", true):
		return rehydrate_result
	var rehydrated_state: Dictionary = rehydrate_result.get("state", state)

	var apply_result: Dictionary = await _request_panel_state_op(plugin_id, panel_name,
		CHANNEL_HOST_OWNED_SAVE_SET_REQUEST, {"op": "set", "state": rehydrated_state})

	# Transient +1 refs were added during rehydrate. Now that the panel has the
	# data, decrement them (net 0 change). The panel holds the bytes in its own
	# memory; the broker no longer needs the extra reference.
	if rehydrate_result.get("success", false):
		var resolved_handles: Array = rehydrate_result.get("_resolved_handles", [])
		for h in resolved_handles:
			_dec_blob_refcount(editor_name, h)

	return apply_result


## Internal: shared request/await/timeout machinery for both get and set.
func _request_panel_state_op(
		plugin_id: String,
		panel_name: String,
		channel: String,
		extra_payload: Dictionary
) -> Dictionary:
	# Pre-flight: panel must be registered AND alive before we even allocate
	# a request id. Spares the timeout path when the caller asks about a
	# panel that isn't open.
	if not _panel_registry.has(panel_name):
		return {
			"success": false,
			"error_code": "panel_not_registered",
			"error_message": "No registered panel named '%s'" % panel_name,
		}
	var entry: _PanelEntry = _panel_registry[panel_name]
	if entry.plugin_id != plugin_id:
		return {
			"success": false,
			"error_code": "panel_ownership_mismatch",
			"error_message": "Panel '%s' is owned by plugin '%s', not '%s'" % [
				panel_name, entry.plugin_id, plugin_id,
			],
		}
	if not _is_panel_alive(entry):
		return {
			"success": false,
			"error_code": "panel_root_freed",
			"error_message": "Panel root for '%s' has been freed" % panel_name,
		}

	_next_panel_state_request_id += 1
	var request_id := "panel-state-%d" % _next_panel_state_request_id
	var awaiter := _PanelStateAwaiter.new()
	awaiter.owner_plugin_id = plugin_id
	awaiter.owner_panel_name = panel_name
	_pending_panel_state[request_id] = awaiter

	var payload := extra_payload.duplicate(true)
	payload["request_id"] = request_id

	# Push to the panel. push_to_panel handles the alive-check + audit; if it
	# returns false (panel went away mid-flight), resolve immediately with
	# panel_root_freed rather than waiting on a doomed timeout.
	var pushed := push_to_panel(plugin_id, panel_name, channel, payload)
	if not pushed:
		_pending_panel_state.erase(request_id)
		return {
			"success": false,
			"error_code": "panel_root_freed",
			"error_message": "Push failed during panel-state request",
		}

	# Set up timeout. We use a SceneTreeTimer if a SceneTree is available
	# (production path); in headless tests where the timer can't fire, the
	# test can call _resolve_panel_state_response directly to short-circuit.
	var tree := Engine.get_main_loop()
	if tree is SceneTree:
		var timer := (tree as SceneTree).create_timer(PANEL_STATE_REQUEST_TIMEOUT_SEC)
		timer.timeout.connect(func():
			if _pending_panel_state.has(request_id):
				var pending: _PanelStateAwaiter = _pending_panel_state[request_id]
				_pending_panel_state.erase(request_id)
				pending.resolve({
					"success": false,
					"error_code": "timeout",
					"error_message": "Panel '%s' did not respond within %.1fs" % [
						panel_name, PANEL_STATE_REQUEST_TIMEOUT_SEC,
					],
				})
		)

	return await awaiter.completed


## Test-only: seed a pending panel-state awaiter so unit tests can exercise
## the resolver path (timeout fallback, spoofing rejection) without driving
## the full async public API. Production code MUST go through
## request_panel_state / apply_panel_state.
func _seed_pending_panel_state_for_test(
		request_id: String, plugin_id: String, panel_name: String) -> void:
	var awaiter := _PanelStateAwaiter.new()
	awaiter.owner_plugin_id = plugin_id
	awaiter.owner_panel_name = panel_name
	_pending_panel_state[request_id] = awaiter


## Internal: panel-side response dispatch. Called by handle_scene_request when
## the panel emits CHANNEL_HOST_OWNED_SAVE_RESPONSE. Verifies the responder is
## the panel we asked (anti-spoofing — see _PanelStateAwaiter docstring) and
## resolves the matching awaiter so the original caller can resume.
func _resolve_panel_state_response(
		responder_plugin_id: String,
		responder_panel_name: String,
		payload: Dictionary
) -> void:
	var request_id: String = str(payload.get("request_id", ""))
	if request_id.is_empty():
		push_warning("[PluginScenePanelBroker] host_owned_save.response missing request_id")
		return
	if not _pending_panel_state.has(request_id):
		# Late response after timeout, or a duplicate from a panel that
		# already responded once. Surface as a warning so a chatty/buggy
		# plugin shows up in the logs rather than silently dropping.
		push_warning(
			"[PluginScenePanelBroker] host_owned_save.response for unknown request_id '%s' (plugin '%s', panel '%s')" %
			[request_id, responder_plugin_id, responder_panel_name]
		)
		return
	var awaiter: _PanelStateAwaiter = _pending_panel_state[request_id]
	# Anti-spoofing: only the panel we sent the request to may resolve it.
	# This protects against a misbehaving plugin emitting a response with a
	# guessed/known request_id to inject state into another plugin's tab.
	if awaiter.owner_plugin_id != responder_plugin_id \
			or awaiter.owner_panel_name != responder_panel_name:
		_audit(responder_plugin_id, EVENT_SCENE_DENIED, {
			"panel_name": responder_panel_name,
			"channel": CHANNEL_HOST_OWNED_SAVE_RESPONSE,
			"reason": "request_owner_mismatch",
			"request_id": request_id,
			"awaiter_owner": "%s/%s" % [awaiter.owner_plugin_id, awaiter.owner_panel_name],
		})
		push_warning(
			("[PluginScenePanelBroker] host_owned_save.response from '%s/%s' " +
			"does not own request '%s' (owned by '%s/%s'); spoofing attempt rejected") % [
				responder_plugin_id, responder_panel_name, request_id,
				awaiter.owner_plugin_id, awaiter.owner_panel_name,
			]
		)
		return
	_pending_panel_state.erase(request_id)
	# Strip request_id from the payload before resolving so callers see a
	# clean result envelope.
	var result := payload.duplicate(true)
	result.erase("request_id")
	awaiter.resolve(result)


# ---------------------------------------------------------------------------
# host.fs.* — plugin file watcher (DCR §T7.5)
# ---------------------------------------------------------------------------

func _ensure_fs_signal_connected() -> void:
	if _fs_signal_connected:
		return
	FileWatcherService.get_instance().file_changed.connect(_on_fs_file_changed)
	FileWatcherService.get_instance().file_removed.connect(_on_fs_file_removed)
	_fs_signal_connected = true


func _handle_host_fs_watch(plugin_id: String, panel_name: String, payload: Dictionary) -> Dictionary:
	var path: String = str(payload.get("path", ""))
	if path.is_empty():
		return {"success": false, "error": "path_required"}
	# Resolve through PathResolver — failed resolution returns the error;
	# never silently drops (DoD bullet 4).
	var resolved := PathResolver.resolve(path)
	if not resolved.ok:
		return {"success": false, "error": str(resolved.error)}
	var abs_path: String = resolved.path

	_ensure_fs_signal_connected()
	var fw := FileWatcherService.get_instance()
	var owner_id := _fs_owner_id(plugin_id, panel_name)
	var watch_result := fw.watch(abs_path, owner_id)
	if not watch_result.ok:
		return {"success": false, "error": str(watch_result.error)}

	# Update the reverse map so file_changed can find the panel.
	if not _fs_path_subscribers.has(abs_path):
		_fs_path_subscribers[abs_path] = {}
	_fs_path_subscribers[abs_path][panel_name] = bool(payload.get("deletions", false))
	return {"success": true, "path": abs_path}


func _handle_host_fs_unwatch(plugin_id: String, panel_name: String, payload: Dictionary) -> Dictionary:
	var path: String = str(payload.get("path", ""))
	if path.is_empty():
		return {"success": false, "error": "path_required"}
	var resolved := PathResolver.resolve(path)
	if not resolved.ok:
		return {"success": false, "error": str(resolved.error)}
	var abs_path: String = resolved.path

	var owner_id := _fs_owner_id(plugin_id, panel_name)
	FileWatcherService.get_instance().unwatch(abs_path, owner_id)

	# Drop reverse-map entry. Multiple panels of the same plugin could share
	# the path; only this panel's subscription is removed here.
	if _fs_path_subscribers.has(abs_path):
		(_fs_path_subscribers[abs_path] as Dictionary).erase(panel_name)
		if (_fs_path_subscribers[abs_path] as Dictionary).is_empty():
			_fs_path_subscribers.erase(abs_path)
	return {"success": true, "path": abs_path}


func _on_fs_file_removed(path: String) -> void:
	_on_fs_file_changed(path, 0, 0)


func _on_fs_file_changed(path: String, mtime: int, size: int) -> void:
	if not _fs_path_subscribers.has(path):
		return
	var subscribers: Dictionary = _fs_path_subscribers[path]
	# Iterate keys snapshot — receive() may dispatch into plugin code that
	# unsubscribes synchronously, mutating the map.
	var panel_names: Array = subscribers.keys()
	var payload := {"path": path, "mtime": mtime, "size": size, "exists": mtime != 0}
	for panel_name_v in panel_names:
		var panel_name: String = str(panel_name_v)
		if mtime == 0 and not bool(subscribers.get(panel_name_v, false)):
			continue
		if not _panel_registry.has(panel_name):
			continue
		var entry: _PanelEntry = _panel_registry[panel_name]
		if not _is_panel_alive(entry):
			continue
		var panel_root = entry.panel_ref.get_ref()
		if panel_root == null:
			continue
		if panel_root.has_method("receive"):
			panel_root.receive(CHANNEL_HOST_FS_CHANGED, payload)


## Drop every host.fs.* subscription owned by a panel. Called from
## unregister_panel and unregister_plugin_panels so plugin teardown can't leak
## watches.
func _cleanup_fs_subscriptions(plugin_id: String, panel_name: String) -> void:
	# Drop all FileWatcherService rows for this owner (covers paths we may
	# have lost track of in the reverse map for any reason).
	FileWatcherService.get_instance().unwatch_all(_fs_owner_id(plugin_id, panel_name))

	# Walk the reverse map and prune.
	var paths_to_drop: Array[String] = []
	for path in _fs_path_subscribers.keys():
		var subs: Dictionary = _fs_path_subscribers[path]
		if subs.has(panel_name):
			subs.erase(panel_name)
			if subs.is_empty():
				paths_to_drop.append(str(path))
	for p in paths_to_drop:
		_fs_path_subscribers.erase(p)


# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------

## Returns true when the channel is listed in the plugin's manifest ui.ipc_messages.
## capability:* channels must also be in ui_ipc_messages (explicit allowlist).
func _validate_channel_declared(plugin_id: String, channel: String) -> bool:
	if plugin_manager == null:
		push_warning("[PluginScenePanelBroker] _validate_channel_declared: no plugin_manager set")
		return false

	var db = plugin_manager.get_db()  # PluginDB in production; untyped for duck-typing
	if db == null:
		return false

	var def = db.get_by_id(plugin_id)  # PluginDefinition in production; untyped for duck-typing
	if def == null:
		return false

	return channel in def.ui_ipc_messages


## Returns true when panel_name is listed in the plugin's manifest ui.panels.
func _validate_panel_ownership(plugin_id: String, panel_name: String) -> bool:
	if plugin_manager == null:
		push_warning("[PluginScenePanelBroker] _validate_panel_ownership: no plugin_manager set")
		return false

	var db = plugin_manager.get_db()  # PluginDB in production; untyped for duck-typing
	if db == null:
		return false

	var def = db.get_by_id(plugin_id)  # PluginDefinition in production; untyped for duck-typing
	if def == null:
		return false

	# After the manifest-parsing task (Round 3), `def.ui_panels` is
	# `Array[Dictionary]` of typed entries — `panel_name in def.ui_panels`
	# would always return false. Use the parallel `ui_panel_names: Array[String]`
	# kept in sync by `_from_dict_internal` for fast string lookups.
	return panel_name in def.ui_panel_names


# ---------------------------------------------------------------------------
# Dispatch helpers
# ---------------------------------------------------------------------------

func _dispatch_to_capability_broker(
		plugin_id: String,
		channel: String,
		payload: Dictionary
) -> Dictionary:
	var capability: String = channel.substr("capability:".length())
	if capability.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id,
			"capability channel has empty capability name (expected 'capability:<name>')")

	if capability_broker == null:
		push_warning("[PluginScenePanelBroker] _dispatch_to_capability_broker: no capability_broker set")
		return PluginErrors.schema_validation_failed(plugin_id,
			"Host capability broker is not available")

	return await capability_broker.dispatch(plugin_id, capability, payload)


func _dispatch_to_plugin_backend(
		plugin_id: String,
		channel: String,
		payload: Dictionary
) -> Dictionary:
	if plugin_manager == null:
		push_warning("[PluginScenePanelBroker] _dispatch_to_plugin_backend: no plugin_manager set")
		return PluginErrors.plugin_not_running(plugin_id)

	var db = plugin_manager.get_db()  # PluginDB in production; untyped for duck-typing
	if db == null:
		return PluginErrors.plugin_not_running(plugin_id)

	var def = db.get_by_id(plugin_id)  # PluginDefinition in production; untyped for duck-typing
	if def == null:
		return PluginErrors.plugin_not_running(plugin_id)

	if def.state != PluginDefinition.State.RUNNING:
		return PluginErrors.plugin_not_running(plugin_id)

	var conn: MCPServerConnection = plugin_manager.get_connection(plugin_id)
	if conn == null:
		return PluginErrors.plugin_not_running(plugin_id)

	# MCP tools/call: tool name = channel, arguments = payload. Use the generous
	# scene-backend budget — the default 120s strands long backend jobs.
	var call_result = await conn.call_tool(channel, payload, SCENE_BACKEND_CALL_TIMEOUT_SEC)

	if call_result == null:
		return PluginErrors.schema_validation_failed(plugin_id,
			"Plugin backend returned null for channel '%s'" % channel)

	if call_result is Dictionary:
		# A backend tool that already speaks the {success:...} reply envelope is
		# passed through verbatim — no double-wrap.
		if call_result.has("success"):
			return call_result
		# A worker-domain result carries an "ok" flag (ok:true, or ok:false with
		# a worker-error dict). The dispatch itself round-tripped, so wrap the
		# whole worker payload in the {success:true, result:...} scene-reply
		# envelope and let the panel inspect ok/error/result itself.
		#
		# Checked BEFORE "error": a worker-domain error is {ok:false, error:{…}}
		# — it has BOTH keys — and it must reach the panel as a worker result
		# (so the panel sees error.kind, e.g. "cancelled"), NOT be re-shaped into
		# a transport-level backend_error.
		if call_result.has("ok"):
			return PluginErrors.backend_success(call_result)
		# No "ok" but an "error": a connection-layer failure from call_tool
		# (timeout, subprocess exit, write failure) surfaces as
		# {error: <human-readable string>}. Re-shape it to the
		# {success:false, error_code, error_message} reply contract so the scene
		# sees the real reason instead of it being wrapped as a success.
		if call_result.has("error"):
			return PluginErrors.backend_error(plugin_id, str(call_result["error"]))
		# A dict with neither marker — the dispatch round-tripped; report success
		# and hand the payload through under "result".
		return PluginErrors.backend_success(call_result)

	# Non-dict result — the dispatch round-tripped; wrap it too.
	return PluginErrors.backend_success({"raw": call_result})


# ---------------------------------------------------------------------------
# Reply delivery helpers
# ---------------------------------------------------------------------------

## Deliver a successful result to the scene's MinervaIPC helper. A non-zero
## `generation` names the registration the reply belongs to; when the key now
## holds a different one, the reply is dropped and audited rather than handed
## to a panel that never sent the request.
func _deliver_reply(panel_name: String, reply_id: String, result: Dictionary,
		generation: int = 0) -> void:
	if reply_id.is_empty():
		return  # No reply requested — fire-and-forget call from the scene.

	var entry: _PanelEntry = _panel_registry.get(panel_name, null)
	if entry == null:
		return  # Panel was unregistered before reply arrived.

	if generation != 0 and _entry_generation(entry) != generation:
		_audit(entry.plugin_id, EVENT_SCENE_STALE_REGISTRATION, {
			"panel_name": entry.panel_name,
			"panel_key": panel_name,
			"reply_id": reply_id,
			"reason": "reply_for_superseded_registration",
		})
		push_warning(
			("[PluginScenePanelBroker] _deliver_reply: panel '%s' was re-registered while " +
			"reply '%s' was in flight; reply dropped") % [panel_name, reply_id]
		)
		return

	var helper: MinervaIPC = entry.ipc_helper
	if helper == null or not is_instance_valid(helper):
		push_warning(
			("[PluginScenePanelBroker] _deliver_reply: MinervaIPC helper for panel '%s' " +
			"is no longer valid") % panel_name
		)
		return

	helper._reply(reply_id, result)


## Deliver an error result to the scene's MinervaIPC helper (same path).
func _deliver_error(panel_name: String, reply_id: String, error: Dictionary,
		generation: int = 0) -> void:
	_deliver_reply(panel_name, reply_id, error, generation)


# ---------------------------------------------------------------------------
# Lifecycle helpers
# ---------------------------------------------------------------------------

## Check whether the panel root held by an entry is still alive.
func _is_panel_alive(entry: _PanelEntry) -> bool:
	var ref = entry.panel_ref.get_ref()
	return ref != null and is_instance_valid(ref as Object)


## The generation of a registration: its MinervaIPC helper's instance id. Every
## register_panel call creates a fresh helper, so the id changes exactly when
## the key is re-registered. 0 once the helper is gone.
func _entry_generation(entry: _PanelEntry) -> int:
	var helper: MinervaIPC = entry.ipc_helper
	if helper == null or not is_instance_valid(helper):
		return 0
	return helper.get_instance_id()


## Detach and free the MinervaIPC helper attached to an entry, if still valid.
func _detach_ipc_helper(entry: _PanelEntry) -> void:
	var helper: MinervaIPC = entry.ipc_helper
	if helper != null and is_instance_valid(helper):
		if helper.get_parent() != null:
			helper.get_parent().remove_child(helper)
		helper.queue_free()
	entry.ipc_helper = null


## Validate arguments to register_panel before proceeding.
func _validate_registration_args(
		panel_root: Node, plugin_id: String, panel_key: String
) -> bool:
	if panel_root == null or not is_instance_valid(panel_root):
		push_warning("[PluginScenePanelBroker] register_panel: panel_root is null or freed")
		return false
	if plugin_id.is_empty():
		push_warning("[PluginScenePanelBroker] register_panel: empty plugin_id")
		return false
	if panel_key.is_empty():
		push_warning("[PluginScenePanelBroker] register_panel: empty panel_key")
		return false
	return true


# ---------------------------------------------------------------------------
# Blob substitution walkers (Phase 5 R3)
#
# Outbound (get_state): strip {__blob__: true, content_type, bytes} wrappers
#   from the panel-returned state, store bytes in the R1 blob store, and
#   replace with {__blob_handle__, content_type} placeholders.
#
# Inbound (set_state): symmetric — replace {__blob_handle__, content_type}
#   placeholders with {__blob__: true, content_type, bytes} from the store.
#   Atomic: if any handle is unknown the entire walk is aborted.
#
# Opt-in contract: plugins that don't wrap blobs produce state with no
# {__blob__: true} dicts, so both walkers are no-ops for them. Malformed
# wrappers (right keys but wrong types) are treated as plain values and
# passed through — they were never opted in by the plugin.
#
# Refcount model (intentionally simple):
#   _strip_blobs_for_outbound: each stored blob starts at refcount 1 (the
#     outbound envelope holds the reference).
#   _rehydrate_blobs_for_inbound: each resolved handle is inc'd by 1
#     (transient reference for the apply call), stored in _resolved_handles
#     so apply_panel_state can dec them after the panel receives the bytes.
#   Net effect of a set_state round-trip: +1 then -1 → 0 change.
#   Editor close: _clear_blobs_for_editor drops all blobs regardless of count.
# ---------------------------------------------------------------------------

## Walk a Variant (Dictionary or Array, recursively) and strip any
## {__blob__: true, content_type: String, bytes: PackedByteArray} wrappers.
## Each wrapper is stored in the R1 blob store and replaced with a
## {__blob_handle__: String, content_type: String} placeholder.
##
## "Strip" is done by building a new value (Dictionary/Array) rather than
## mutating the original in place; this guarantees the panel's own copy is
## not affected if it's still holding a reference.
##
## Returns the transformed value (may be the same type as the input).
## Plain scalars, unknown shapes, and malformed wrappers (wrong types on the
## required keys) are returned unchanged.
func _strip_blobs_for_outbound(editor_name: String, value: Variant, plugin_id: String) -> Variant:
	if value is Dictionary:
		var d: Dictionary = value as Dictionary
		# Check for blob wrapper: needs all three keys with correct types.
		# We accept whole-number float for __blob__ because JSON.parse() can
		# round-trip booleans as floats in Godot 4 (true → 1.0).
		# `bytes` is accepted in either of two encodings:
		#   - PackedByteArray (in-process IPC; preserved for backward compat)
		#   - non-empty String (base64-encoded; required when the wrapper has
		#     survived a JSON.stringify/parse round-trip — see hint
		#     godot/json-stringify-packedbytearray-becomes-quoted-string).
		# The blob store always holds PackedByteArray internally; the original
		# encoding is recorded so rehydrate can emit the same shape the caller
		# sent in (symmetric round-trip per blob).
		var bytes_v: Variant = d.get("bytes", null)
		var bytes_is_pba: bool = bytes_v is PackedByteArray
		var bytes_is_b64_string: bool = bytes_v is String and not (bytes_v as String).is_empty()
		var is_blob_wrapper: bool = (
			d.has("__blob__") and d.has("content_type") and d.has("bytes")
			and (d["__blob__"] == true or d["__blob__"] == 1 or d["__blob__"] == 1.0)
			and d["content_type"] is String
			and (bytes_is_pba or bytes_is_b64_string)
		)
		if is_blob_wrapper:
			var bytes: PackedByteArray
			var encoding: String
			var decode_ok: bool = true
			if bytes_is_pba:
				bytes = bytes_v as PackedByteArray
				encoding = "bytes"
			else:
				bytes = Marshalls.base64_to_raw(bytes_v as String)
				encoding = "base64"
				# Base64 decode of a non-empty input that yields empty bytes
				# indicates invalid base64 — fall back to passthrough so junk
				# strings don't become 0-byte blobs that hide upstream bugs.
				if bytes.is_empty():
					decode_ok = false
			if decode_ok:
				var content_type: String = d["content_type"] as String
				var handle: String = _store_blob(editor_name, bytes, content_type, encoding)
				# _store_blob sets refcount = 1 (the outbound envelope holds it).
				return {"__blob_handle__": handle, "content_type": content_type}
		# Not a blob wrapper — recurse into all values.
		var out: Dictionary = {}
		for k in d.keys():
			out[k] = _strip_blobs_for_outbound(editor_name, d[k], plugin_id)
		return out
	elif value is Array:
		var arr: Array = value as Array
		var out_arr: Array = []
		out_arr.resize(arr.size())
		for i in arr.size():
			out_arr[i] = _strip_blobs_for_outbound(editor_name, arr[i], plugin_id)
		return out_arr
	# Scalar / other type — pass through untouched.
	return value


## Walk a Variant and rehydrate any {__blob_handle__: String, content_type: String}
## placeholders back to {__blob__: true, content_type: String, bytes: PackedByteArray}
## from the blob store.
##
## ATOMIC: builds a fully resolved copy before returning. If any handle is
## unknown the walk is aborted and {success: false, error_code: "unknown_blob_handle",
## handle: <h>, path: <json-pointer>} is returned. No partial result is ever
## returned.
##
## On success returns {success: true, state: <rehydrated>, _resolved_handles: [...]}
## where _resolved_handles is the list of handles that were inc'd (so the caller
## can dec them after the panel has received the bytes).
##
## Called by apply_panel_state before forwarding state to the panel.
## plugin_id is accepted for API symmetry with _strip_blobs_for_outbound (which
## threads it through recursion). The rehydrate path doesn't currently audit
## per-blob — symmetric audit would be redundant with apply_panel_state's
## outer audit. Leading underscore signals "intentional unused for API parity."
func _rehydrate_blobs_for_inbound(editor_name: String, state: Dictionary, _plugin_id: String) -> Dictionary:
	var resolved_handles: Array[String] = []
	var walk_result: Variant = _rehydrate_walk(editor_name, state, "", resolved_handles)
	if walk_result is Dictionary and (walk_result as Dictionary).has("__rehydrate_error__"):
		# Undo any refcount increments made before the failure (atomic guarantee).
		for h in resolved_handles:
			_dec_blob_refcount(editor_name, h)
		var err: Dictionary = walk_result as Dictionary
		return {
			"success": false,
			"error_code": "unknown_blob_handle",
			"handle": err.get("handle", ""),
			"path": err.get("path", ""),
			"error_message": "Unknown blob handle '%s' at path '%s'" % [
				err.get("handle", ""), err.get("path", ""),
			],
		}
	return {
		"success": true,
		"state": walk_result,
		"_resolved_handles": resolved_handles,
	}


## RFC 6901 §4 escape: in dictionary keys, `~` → `~0`, `/` → `/`. Order matters
## (decode is `~1` then `~0`; encode is the reverse — `~` first, then `/`).
## Used by the rehydrate walker so error paths remain unambiguous when plugin
## schemas contain keys with reserved characters.
static func _escape_pointer_token(token: String) -> String:
	return token.replace("~", "~0").replace("/", "~1")


## Internal recursive worker for _rehydrate_blobs_for_inbound.
## path is a JSON-pointer-style string (e.g. "/slides/2/tiles/0/image") for
## error messages, RFC 6901 escaped so keys containing `/` or `~` remain
## unambiguous. resolved_handles is appended to in place on each inc.
## Returns a sentinel dict {__rehydrate_error__: true, handle, path} on failure.
func _rehydrate_walk(
		editor_name: String,
		value: Variant,
		path: String,
		resolved_handles: Array
) -> Variant:
	if value is Dictionary:
		var d: Dictionary = value as Dictionary
		# Check for handle placeholder: needs both keys with correct types.
		var is_handle: bool = (
			d.has("__blob_handle__") and d.has("content_type")
			and d["__blob_handle__"] is String
			and d["content_type"] is String
			and not (d["__blob_handle__"] as String).is_empty()
		)
		if is_handle:
			var handle: String = d["__blob_handle__"] as String
			var rec: Dictionary = _get_blob_record(editor_name, handle)
			if not rec.get("found", false):
				return {"__rehydrate_error__": true, "handle": handle, "path": path}
			# Increment refcount: transient reference for the apply call.
			_inc_blob_refcount(editor_name, handle)
			resolved_handles.append(handle)
			# Emit in the encoding the original strip received: PackedByteArray
			# if the caller sent PBA, base64 String if the caller sent base64.
			# This keeps per-blob round-trips symmetric so plugins that store
			# images as base64 strings get strings back without re-encoding.
			var encoding: String = str(rec.get("encoding", "bytes"))
			var bytes_out: Variant
			if encoding == "base64":
				bytes_out = Marshalls.raw_to_base64(rec["bytes"] as PackedByteArray)
			else:
				bytes_out = rec["bytes"] as PackedByteArray
			return {
				"__blob__": true,
				"content_type": rec["content_type"] as String,
				"bytes": bytes_out,
			}
		# Not a handle placeholder — recurse into all values.
		# Walk path uses RFC 6901 JSON Pointer escaping so error envelopes
		# remain unambiguous when plugin schemas contain keys with `/` or `~`.
		var out: Dictionary = {}
		for k in d.keys():
			var child_path: String = path + "/" + _escape_pointer_token(str(k))
			var child_result: Variant = _rehydrate_walk(editor_name, d[k], child_path, resolved_handles)
			if child_result is Dictionary and (child_result as Dictionary).has("__rehydrate_error__"):
				return child_result
			out[k] = child_result
		return out
	elif value is Array:
		var arr: Array = value as Array
		var out_arr: Array = []
		out_arr.resize(arr.size())
		for i in arr.size():
			var child_path: String = path + "/" + str(i)
			var child_result: Variant = _rehydrate_walk(editor_name, arr[i], child_path, resolved_handles)
			if child_result is Dictionary and (child_result as Dictionary).has("__rehydrate_error__"):
				return child_result
			out_arr[i] = child_result
		return out_arr
	# Scalar — pass through.
	return value


# ---------------------------------------------------------------------------
# Internal blob store (Phase 5 R1 — substrate only; no capabilities wired yet)
#
# Keyed by (editor_name, handle). Handles are monotonic per editor ("blob-1",
# "blob-2", …) and are never reused even after GC. Public capabilities
# (host.documents.get_blob / put_blob) will be wired in R2+.
#
# Thread-safety: inherits the broker's single-threaded invariant (Godot main
# thread + T2 re-entrancy guard). No locking added here.
# ---------------------------------------------------------------------------

## The identity every blob-store operation is keyed by: the panel's registry
## key. Callers arrive holding different names for the same panel — the key
## itself from the panel-state path, the editor tab title from a capability
## call — and unless both land on the same store, a blob written by one is
## invisible to the other and its refcount never reaches zero. Only those two
## names are folded: a registry key, or the exact current tab title of one live
## panel. Looser aliases are deliberately NOT honoured here — a paired text
## editor is titled with the document's file name, which is also the render
## panel's bare-file-name alias, and folding it would hand two editors one
## store so that clearing either empties both. Any other name keeps a store of
## its own, which also covers editors that are not scene panels and headless
## tests with no registry.
func _blob_store_key(editor_name: String) -> String:
	if _panel_registry.has(editor_name):
		return editor_name
	var titled: String = ""
	for key in _panel_registry.keys():
		var entry: _PanelEntry = _panel_registry[key]
		if not _is_panel_alive(entry):
			continue
		if int(_entry_aliases(entry).get(editor_name, -1)) != _AliasTier.TITLE:
			continue
		if not titled.is_empty():
			return editor_name   # two live tabs share the title: neither owns it
		titled = str(key)
	return titled if not titled.is_empty() else editor_name


## Store a blob for the given editor.
##
## Pre:  editor_name non-empty; bytes non-null (may be empty); content_type
##       non-empty (e.g. "image/png").
## Post: A new entry is created in _blob_stores[editor_name] with refcount = 1.
##       The returned handle is unique and monotonic for this editor.
##
## Bytes are stored by reference (PackedByteArray is reference-typed in
## Godot 4). The caller MUST NOT mutate the byte array after passing it here.
##
## Returns: handle string, e.g. "blob-1".
##
## plugin_id is "" while capabilities are not yet wired (R1); R2+ will pass
## the dispatching plugin's id for audit attribution.
## `encoding` records the shape the caller sent bytes in ("bytes" for raw
## PackedByteArray; "base64" for a base64-encoded String). The store always
## holds PackedByteArray internally — this field only governs what the
## rehydrate walker emits back to a consumer, so a plugin that uses
## base64-strings in its panel state gets strings back rather than PBA.
func _store_blob(editor_name: String, bytes: PackedByteArray, content_type: String,
		encoding: String = "bytes") -> String:
	# Normalise to the one identity the store is keyed by (see _blob_store_key).
	editor_name = _blob_store_key(editor_name)
	if not _blob_stores.has(editor_name):
		_blob_stores[editor_name] = {}
	if not _next_blob_handle.has(editor_name):
		_next_blob_handle[editor_name] = 1

	var idx: int = _next_blob_handle[editor_name]
	_next_blob_handle[editor_name] = idx + 1

	var handle := "blob-%d" % idx
	_blob_stores[editor_name][handle] = {
		"bytes": bytes,
		"content_type": content_type,
		"refcount": 1,
		"encoding": encoding,
	}
	_audit("", PluginAuditLog.EVENT_BLOB_STORED, {
		"editor_name": editor_name,
		"handle": handle,
		"content_type": content_type,
		"bytes_len": bytes.size(),
		"encoding": encoding,
	})
	return handle


## Fetch a blob record without mutating the refcount.
##
## Pre:  editor_name non-empty; handle non-empty.
## Post: No state is modified.
##
## Returns a Dictionary:
##   {found: true,  bytes: PackedByteArray, content_type: String, refcount: int}
##   {found: false, bytes: PackedByteArray(), content_type: "", refcount: 0}
func _get_blob_record(editor_name: String, handle: String) -> Dictionary:
	# Normalise to the one identity the store is keyed by (see _blob_store_key).
	editor_name = _blob_store_key(editor_name)
	if not _blob_stores.has(editor_name):
		return {"found": false, "bytes": PackedByteArray(), "content_type": "", "refcount": 0, "encoding": "bytes"}
	var store: Dictionary = _blob_stores[editor_name]
	if not store.has(handle):
		return {"found": false, "bytes": PackedByteArray(), "content_type": "", "refcount": 0, "encoding": "bytes"}
	var entry: Dictionary = store[handle]
	return {
		"found": true,
		"bytes": entry["bytes"],
		"content_type": entry["content_type"],
		"refcount": entry["refcount"],
		"encoding": entry.get("encoding", "bytes"),
	}


## Increment the refcount for a stored blob.
##
## Pre:  The blob identified by (editor_name, handle) exists.
## Post: refcount is incremented by 1.
##
## Returns false if the handle is not found (caller's bug to surface upstream).
## Refcount has no maximum; if an upper bound is needed later, add it here.
func _inc_blob_refcount(editor_name: String, handle: String) -> bool:
	# Normalise to the one identity the store is keyed by (see _blob_store_key).
	editor_name = _blob_store_key(editor_name)
	if not _blob_stores.has(editor_name):
		return false
	var store: Dictionary = _blob_stores[editor_name]
	if not store.has(handle):
		return false
	store[handle]["refcount"] += 1
	return true


## Decrement the refcount for a stored blob. GCs the entry when it reaches 0.
##
## Pre:  The blob identified by (editor_name, handle) exists and refcount >= 1.
## Post: refcount is decremented by 1.
##       If refcount reaches 0, the entry is erased immediately (GC'd).
##
## Returns false if:
##   - The handle is not found (caller's bug).
##   - refcount is already 0 (underflow guard — entry is NOT further decremented).
func _dec_blob_refcount(editor_name: String, handle: String) -> bool:
	# Normalise to the one identity the store is keyed by (see _blob_store_key).
	editor_name = _blob_store_key(editor_name)
	if not _blob_stores.has(editor_name):
		return false
	var store: Dictionary = _blob_stores[editor_name]
	if not store.has(handle):
		return false
	var entry: Dictionary = store[handle]
	if entry["refcount"] <= 0:
		# Underflow guard: refuse to decrement below zero. The string is
		# composed first, then formatted, because `%` binds tighter than `+`
		# in GDScript and the naive `"a" + "b" % args` form formats only "b".
		push_warning(
			("[PluginScenePanelBroker] _dec_blob_refcount: handle '%s' in editor"
			+ " '%s' already at refcount 0 — underflow rejected"
			) % [handle, editor_name]
		)
		return false
	entry["refcount"] -= 1
	if entry["refcount"] == 0:
		var content_type: String = entry["content_type"]
		store.erase(handle)
		_audit("", PluginAuditLog.EVENT_BLOB_GC, {
			"editor_name": editor_name,
			"handle": handle,
			"content_type": content_type,
		})
	return true


## Drop all blobs for an editor (e.g. on editor close).
##
## Pre:  editor_name may or may not have any blobs.
## Post: All blob entries for the editor are erased. _blob_stores[editor_name]
##       is removed entirely (not left as an empty dict).
##       _next_blob_handle[editor_name] is intentionally NOT reset — handles
##       remain unique across the editor's lifetime even if it is reopened and
##       new blobs are stored.
##       Idempotent: calling on a missing or already-empty editor returns 0.
##
## Returns: count of blob entries dropped.
func _clear_blobs_for_editor(editor_name: String) -> int:
	# Normalise to the one identity the store is keyed by (see _blob_store_key).
	editor_name = _blob_store_key(editor_name)
	if not _blob_stores.has(editor_name):
		return 0
	var count: int = _blob_stores[editor_name].size()
	_blob_stores.erase(editor_name)
	if count > 0:
		_audit("", PluginAuditLog.EVENT_BLOBS_CLEARED, {
			"editor_name": editor_name,
			"count_dropped": count,
		})
	return count


## Return a snapshot of the editor's blob store for test introspection.
##
## Returns a Dictionary of {handle -> {content_type: String, refcount: int}}
## (bytes are NOT copied — this is for count/refcount inspection only).
## Returns an empty dict if the editor has no blobs.
##
## PRODUCTION CODE MUST NOT DEPEND ON THIS METHOD. It is test-only.
func _blob_store_snapshot(editor_name: String) -> Dictionary:
	# Normalise to the one identity the store is keyed by (see _blob_store_key).
	editor_name = _blob_store_key(editor_name)
	if not _blob_stores.has(editor_name):
		return {}
	var result: Dictionary = {}
	var store: Dictionary = _blob_stores[editor_name]
	for handle in store.keys():
		var entry: Dictionary = store[handle]
		result[handle] = {
			"content_type": entry["content_type"],
			"refcount": entry["refcount"],
			"encoding": entry.get("encoding", "bytes"),
		}
	return result


# ---------------------------------------------------------------------------
# Audit helper
# ---------------------------------------------------------------------------

func _audit(plugin_id: String, event_type: String, detail: Dictionary) -> void:
	if audit_log != null:
		audit_log.log_event(plugin_id, event_type, detail)


# ---------------------------------------------------------------------------
# Private inner class: panel registry entry
# ---------------------------------------------------------------------------

## Holds everything the broker needs to know about one registered panel.
class _PanelEntry extends RefCounted:
	## WeakRef to the scene root Control node.
	var panel_ref: WeakRef = null
	## Owning plugin id.
	var plugin_id: String = ""
	## Registry key: unique per OPEN panel instance, so two editors on the same
	## manifest panel each keep their own channels, IPC helper and buffer.
	var panel_key: String = ""
	## Panel name as declared in the manifest. Shared by every instance of it.
	var panel_name: String = ""
	## Channels this panel is allowed to use (from manifest panels[].ipc_channels).
	var channels: PackedStringArray = PackedStringArray()
	## The MinervaIPC helper node attached to panel_root.
	var ipc_helper: MinervaIPC = null
	## DocumentBuffer this panel is currently subscribed to via attach_buffer_to_panel.
	## null when no buffer is attached. Cleared on detach_buffer_from_panel and
	## on unregister_panel.
	var attached_buffer: DocumentBuffer = null
	## Callable connected to attached_buffer.text_changed; held so detach can
	## disconnect the exact same handle.
	var _buffer_text_changed_handler: Callable = Callable()
	var _buffer_saved_handler: Callable = Callable()
	## WeakRef to the owning Editor wrapper, or null when the caller did not
	## supply one. Read (never written) to answer "which document is this
	## panel showing" at lookup time, so a tab rename cannot go stale.
	var editor_ref: WeakRef = null

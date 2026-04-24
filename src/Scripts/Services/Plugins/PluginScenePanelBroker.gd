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
##   panel_name         — name as declared in the manifest's panels[].name.
##   declared_channels  — channels this panel is allowed to use, from
##                        the manifest's panels[].ipc_channels field.
##
## Attaches a MinervaIPC helper node as "$_MinervaIPC" on the panel root.
## Wires panel_root's `request` signal to handle_scene_request.
##
## Uses call_deferred for the first-registration trampoline so that requests
## emitted during _ready() queue behind _on_panel_loaded (design §5.3).
func register_panel(
		panel_root: Node,
		plugin_id: String,
		panel_name: String,
		declared_channels: PackedStringArray
) -> void:
	if not _validate_registration_args(panel_root, plugin_id, panel_name):
		return

	if _panel_registry.has(panel_name):
		var existing: _PanelEntry = _panel_registry[panel_name]
		var existing_owner: String = existing.plugin_id
		if existing_owner != plugin_id:
			push_warning(
				"[PluginScenePanelBroker] Panel '%s' was owned by '%s', re-assigning to '%s'" % [
					panel_name, existing_owner, plugin_id
				]
			)
		else:
			push_warning(
				"[PluginScenePanelBroker] Panel '%s' is already registered for plugin '%s'; re-registering" % [
					panel_name, plugin_id
				]
			)
		# Detach the old helper before overwriting.
		_detach_ipc_helper(existing)

	# Create and attach the MinervaIPC helper node.
	var ipc_helper := MinervaIPC.new()
	ipc_helper.name = MinervaIPC.HELPER_NODE_NAME
	panel_root.add_child(ipc_helper)

	# Build registry entry.
	var entry := _PanelEntry.new()
	entry.panel_ref   = weakref(panel_root)
	entry.plugin_id   = plugin_id
	entry.panel_name  = panel_name
	entry.channels    = declared_channels
	entry.ipc_helper  = ipc_helper
	_panel_registry[panel_name] = entry

	# Wire the scene's outbound `request` signal to the broker.
	# We use call_deferred so any `request` emitted during _ready() is
	# delivered after _on_panel_loaded returns (§5.3 trampoline).
	if panel_root.has_signal("request"):
		panel_root.request.connect(
			func(channel: String, payload: Dictionary, reply_id: String) -> void:
				call_deferred(
					"handle_scene_request",
					panel_name, channel, payload, reply_id
				)
		)
	else:
		push_warning(
			("[PluginScenePanelBroker] Panel '%s' (plugin '%s') has no `request` signal; " +
			"outbound IPC will not work") % [panel_name, plugin_id]
		)

	print(
		"[PluginScenePanelBroker] Registered panel '%s' -> plugin '%s' (%d channel(s))" % [
			panel_name, plugin_id, declared_channels.size()
		]
	)
	panel_registered.emit(plugin_id, panel_name)


## Unregister a single panel.
##
## Called by PluginScenePanelHost when a tab is closed or a plugin is stopped.
## Should be called inside the _on_panel_unload hook, before queue_free.
func unregister_panel(plugin_id: String, panel_name: String) -> void:
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

## Returns true if panel_name is registered with any plugin.
func is_panel_registered(panel_name: String) -> bool:
	return _panel_registry.has(panel_name)


## Returns the plugin_id that owns a panel, or "" if not registered.
func get_panel_owner(panel_name: String) -> String:
	if not _panel_registry.has(panel_name):
		return ""
	return (_panel_registry[panel_name] as _PanelEntry).plugin_id


# ---------------------------------------------------------------------------
# Outbound: scene -> plugin
# ---------------------------------------------------------------------------

## Handle a request emitted by a plugin scene panel.
##
## Parameters:
##   panel_name — the registered name of the panel that emitted the signal.
##   channel    — the declared channel, e.g. "cad.render_request" or
##                "capability:notes.create".
##   payload    — a Dictionary of call-specific arguments.
##   reply_id   — caller-generated ID; result is delivered to the scene's
##                $_MinervaIPC._reply(reply_id, result).
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
		panel_name: String,
		channel: String,
		payload: Dictionary,
		reply_id: String
) -> void:

	# --- 1. Basic input validation -------------------------------------------
	if panel_name.is_empty():
		push_warning("[PluginScenePanelBroker] handle_scene_request: empty panel_name")
		return

	if channel.is_empty():
		push_warning("[PluginScenePanelBroker] handle_scene_request: empty channel")
		return

	# --- 2. Resolve panel -> plugin -------------------------------------------
	if not _panel_registry.has(panel_name):
		_audit("", EVENT_SCENE_DENIED, {
			"panel_name": panel_name,
			"channel": channel,
			"reason": "panel_not_registered",
		})
		_deliver_error(panel_name, reply_id,
			PluginErrors.permission_denied("",
				"Panel '%s' is not registered with any plugin" % panel_name))
		return

	var entry: _PanelEntry = _panel_registry[panel_name]
	var plugin_id: String = entry.plugin_id

	# Guard: check that the panel root is still alive (weak ref).
	if not _is_panel_alive(entry):
		_audit(plugin_id, EVENT_SCENE_DENIED, {
			"panel_name": panel_name,
			"channel": channel,
			"reason": "panel_root_freed",
		})
		# No live panel to deliver to; log and return.
		push_warning(
			"[PluginScenePanelBroker] handle_scene_request: panel root for '%s' has been freed" % panel_name
		)
		return

	# --- 3. Validate panel ownership against manifest -------------------------
	if not _validate_panel_ownership(plugin_id, panel_name):
		_audit(plugin_id, EVENT_SCENE_DENIED, {
			"panel_name": panel_name,
			"channel": channel,
			"reason": "panel_ownership_mismatch",
		})
		_deliver_error(panel_name, reply_id,
			PluginErrors.permission_denied(plugin_id,
				"Panel '%s' is not declared in the manifest of plugin '%s'" % [panel_name, plugin_id]))
		return

	# --- 4. Validate channel is in this panel's declared_channels -------------
	if not channel.begins_with("capability:") and not (channel in entry.channels):
		_audit(plugin_id, EVENT_SCENE_DENIED, {
			"panel_name": panel_name,
			"channel": channel,
			"reason": "channel_not_in_panel_scope",
		})
		_deliver_error(panel_name, reply_id,
			PluginErrors.permission_denied(plugin_id,
				"Channel '%s' is not in the declared ipc_channels for panel '%s'" % [
					channel, panel_name
				]))
		return

	# --- 5. Validate channel against manifest's global ipc_messages allowlist --
	if not _validate_channel_declared(plugin_id, channel):
		_audit(plugin_id, EVENT_SCENE_DENIED, {
			"panel_name": panel_name,
			"channel": channel,
			"reason": "channel_not_declared",
		})
		_deliver_error(panel_name, reply_id,
			PluginErrors.permission_denied(plugin_id,
				"Channel '%s' is not declared in the manifest of plugin '%s'" % [
					channel, plugin_id
				]))
		return

	# --- 6. Validate payload size ---------------------------------------------
	var payload_json := JSON.stringify(payload)
	if payload_json.length() > MAX_PAYLOAD_BYTES:
		_audit(plugin_id, EVENT_SCENE_DENIED, {
			"panel_name": panel_name,
			"channel": channel,
			"reason": "payload_too_large",
			"scene_size": payload_json.length(),
		})
		_deliver_error(panel_name, reply_id,
			PluginErrors.payload_too_large(plugin_id, MAX_PAYLOAD_BYTES, payload_json.length()))
		return

	# --- 7. Dispatch ----------------------------------------------------------
	_audit(plugin_id, EVENT_SCENE_ALLOWED, {
		"panel_name": panel_name,
		"channel": channel,
	})

	var result: Dictionary
	if channel.begins_with("capability:"):
		result = await _dispatch_to_capability_broker(plugin_id, channel, payload)
	else:
		result = await _dispatch_to_plugin_backend(plugin_id, channel, payload)

	_audit(plugin_id, EVENT_SCENE_DISPATCHED, {
		"panel_name": panel_name,
		"channel": channel,
		"scene_success": result.get("success", false),
	})

	# --- 8. Deliver reply back to scene via $_MinervaIPC ----------------------
	_deliver_reply(panel_name, reply_id, result)


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

	return panel_name in def.ui_panels


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

	# MCP tools/call: tool name = channel, arguments = payload.
	var call_result = await conn.call_tool(channel, payload)

	if call_result == null:
		return PluginErrors.schema_validation_failed(plugin_id,
			"Plugin backend returned null for channel '%s'" % channel)

	if call_result is Dictionary:
		if call_result.has("success"):
			return call_result
		return PluginErrors.success(call_result)

	return PluginErrors.success({"raw": call_result})


# ---------------------------------------------------------------------------
# Reply delivery helpers
# ---------------------------------------------------------------------------

## Deliver a successful result to the scene's MinervaIPC helper.
func _deliver_reply(panel_name: String, reply_id: String, result: Dictionary) -> void:
	if reply_id.is_empty():
		return  # No reply requested — fire-and-forget call from the scene.

	var entry: _PanelEntry = _panel_registry.get(panel_name, null)
	if entry == null:
		return  # Panel was unregistered before reply arrived.

	var helper: MinervaIPC = entry.ipc_helper
	if helper == null or not is_instance_valid(helper):
		push_warning(
			("[PluginScenePanelBroker] _deliver_reply: MinervaIPC helper for panel '%s' " +
			"is no longer valid") % panel_name
		)
		return

	helper._reply(reply_id, result)


## Deliver an error result to the scene's MinervaIPC helper (same path).
func _deliver_error(panel_name: String, reply_id: String, error: Dictionary) -> void:
	_deliver_reply(panel_name, reply_id, error)


# ---------------------------------------------------------------------------
# Lifecycle helpers
# ---------------------------------------------------------------------------

## Check whether the panel root held by an entry is still alive.
func _is_panel_alive(entry: _PanelEntry) -> bool:
	var ref = entry.panel_ref.get_ref()
	return ref != null and is_instance_valid(ref as Object)


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
		panel_root: Node, plugin_id: String, panel_name: String
) -> bool:
	if panel_root == null or not is_instance_valid(panel_root):
		push_warning("[PluginScenePanelBroker] register_panel: panel_root is null or freed")
		return false
	if plugin_id.is_empty():
		push_warning("[PluginScenePanelBroker] register_panel: empty plugin_id")
		return false
	if panel_name.is_empty():
		push_warning("[PluginScenePanelBroker] register_panel: empty panel_name")
		return false
	return true


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
	## Panel name as declared in the manifest.
	var panel_name: String = ""
	## Channels this panel is allowed to use (from manifest panels[].ipc_channels).
	var channels: PackedStringArray = PackedStringArray()
	## The MinervaIPC helper node attached to panel_root.
	var ipc_helper: MinervaIPC = null

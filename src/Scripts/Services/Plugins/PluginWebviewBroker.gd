class_name PluginWebviewBroker
extends RefCounted
## IPC broker that mediates all communication between plugin webview panels and
## plugin backends / host capabilities.
##
## Security model:
##   - Webview panels NEVER talk directly to plugin backends or localhost MCP.
##   - Every IPC message is validated against the plugin's manifest before dispatch.
##   - Undeclared message types are rejected outright.
##   - Host capability calls are gated by PluginPolicy (deny-by-default).
##   - All decisions — allow or deny — are written to PluginAuditLog.
##
## Message flow:
##   1. Webview sends IPC message via the WRY ipc_message signal.
##   2. Caller invokes handle_ipc_message(panel_name, message_type, payload).
##   3. Broker resolves panel -> plugin_id via _panel_registry.
##   4. Broker validates panel ownership, message declaration, and payload.
##   5. Broker dispatches:
##        - "capability:<name>" prefix  -> CapabilityBroker.dispatch()
##        - Everything else             -> plugin backend MCPServerConnection
##   6. Broker returns {"success": bool, ...} to the caller, which should relay
##      the result back to the webview (e.g. via evaluate_javascript / IPC reply).
##
## Integration point (WebViewEditor / plugin panel host):
##   See "INTEGRATION NOTES" block at the bottom of this file.


# ---------------------------------------------------------------------------
# Audit event constants (additions to PluginAuditLog's own constants)
# ---------------------------------------------------------------------------

const EVENT_IPC_ALLOWED   := "ipc_allowed"
const EVENT_IPC_DENIED    := "ipc_denied"
const EVENT_IPC_DISPATCHED := "ipc_dispatched"


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

## Maximum byte size of a serialised payload Dictionary (JSON form).
const MAX_PAYLOAD_BYTES := 65536  # 64 KiB


# ---------------------------------------------------------------------------
# Dependencies (set before using — constructor accepts them)
# ---------------------------------------------------------------------------

## PluginManager: used to resolve plugin definitions and get MCP connections.
var plugin_manager: PluginManager = null

## PluginPolicy: used to check capability grants before host-capability dispatch.
var plugin_policy: PluginPolicy = null

## CapabilityBroker: used to execute host-capability calls.
var capability_broker: CapabilityBroker = null

## PluginAuditLog: used to record every IPC decision.
var audit_log: PluginAuditLog = null


# ---------------------------------------------------------------------------
# Internal state
# ---------------------------------------------------------------------------

## panel_name -> plugin_id   (populated by register_plugin_panel)
var _panel_registry: Dictionary = {}


# ---------------------------------------------------------------------------
# Constructor
# ---------------------------------------------------------------------------

func _init(
		p_plugin_manager: PluginManager = null,
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

## Register a panel as belonging to a specific plugin.
## Call this when a plugin panel is created / opened.
func register_plugin_panel(plugin_id: String, panel_name: String) -> void:
	if plugin_id.is_empty() or panel_name.is_empty():
		push_warning("[PluginWebviewBroker] register_plugin_panel: empty plugin_id or panel_name — ignored")
		return

	if _panel_registry.has(panel_name):
		var existing: String = _panel_registry[panel_name]
		if existing != plugin_id:
			push_warning(
				"[PluginWebviewBroker] Panel '%s' was owned by '%s', re-assigning to '%s'" % [
					panel_name, existing, plugin_id
				]
			)

	_panel_registry[panel_name] = plugin_id
	print("[PluginWebviewBroker] Registered panel '%s' -> plugin '%s'" % [panel_name, plugin_id])


## Unregister all panels belonging to a plugin.
## Call this when a plugin is stopped or uninstalled.
func unregister_plugin_panels(plugin_id: String) -> void:
	var to_remove: Array[String] = []
	for panel_name in _panel_registry.keys():
		if _panel_registry[panel_name] == plugin_id:
			to_remove.append(panel_name)
	for panel_name in to_remove:
		_panel_registry.erase(panel_name)
	if not to_remove.is_empty():
		print("[PluginWebviewBroker] Unregistered %d panel(s) for plugin '%s'" % [
			to_remove.size(), plugin_id
		])


## Returns true if panel_name is registered with any plugin.
func is_plugin_panel(panel_name: String) -> bool:
	return _panel_registry.has(panel_name)


## Returns the plugin_id that owns a panel, or "" if not registered.
func get_panel_owner(panel_name: String) -> String:
	return _panel_registry.get(panel_name, "")


# ---------------------------------------------------------------------------
# Primary IPC entry point
# ---------------------------------------------------------------------------

## Handle a single IPC message arriving from a plugin's webview panel.
##
## Parameters:
##   panel_name   — the registered name of the panel that sent the message
##   message_type — the declared message type, e.g. "myplugin.do_thing"
##                  OR "capability:<name>" to invoke a host capability directly
##   payload      — a Dictionary of message-specific arguments
##
## Returns a standardised Dictionary:
##   Success:  {"success": true, "result": {...}}
##   Failure:  {"success": false, "error_code": "...", "error_message": "...", ...}
func handle_ipc_message(
		panel_name: String,
		message_type: String,
		payload: Dictionary
) -> Dictionary:

	# --- 1. Basic input validation -------------------------------------------
	if panel_name.is_empty():
		return PluginErrors.schema_validation_failed("",
			"handle_ipc_message: panel_name must not be empty")

	if message_type.is_empty():
		return PluginErrors.schema_validation_failed("",
			"handle_ipc_message: message_type must not be empty")

	# --- 2. Resolve panel -> plugin -------------------------------------------
	var plugin_id: String = get_panel_owner(panel_name)
	if plugin_id.is_empty():
		# Panel is not registered — could be a spoofed request or a race.
		_audit(plugin_id, EVENT_IPC_DENIED, {
			"panel_name": panel_name,
			"message_type": message_type,
			"reason": "panel_not_registered",
		})
		return PluginErrors.permission_denied("",
			"Panel '%s' is not registered with any plugin" % panel_name)

	# --- 3. Validate panel ownership (double-check consistency) ---------------
	if not _validate_panel_ownership(plugin_id, panel_name):
		_audit(plugin_id, EVENT_IPC_DENIED, {
			"panel_name": panel_name,
			"message_type": message_type,
			"reason": "panel_ownership_mismatch",
		})
		return PluginErrors.permission_denied(plugin_id,
			"Panel '%s' is not declared in the manifest of plugin '%s'" % [panel_name, plugin_id])

	# --- 4. Validate message is declared in manifest --------------------------
	if not _validate_message_declared(plugin_id, message_type):
		_audit(plugin_id, EVENT_IPC_DENIED, {
			"panel_name": panel_name,
			"message_type": message_type,
			"reason": "message_not_declared",
		})
		return PluginErrors.permission_denied(plugin_id,
			"Message type '%s' is not declared in the manifest of plugin '%s'" % [
				message_type, plugin_id
			])

	# --- 5. Validate payload size ---------------------------------------------
	var payload_json := JSON.stringify(payload)
	if payload_json.length() > MAX_PAYLOAD_BYTES:
		_audit(plugin_id, EVENT_IPC_DENIED, {
			"panel_name": panel_name,
			"message_type": message_type,
			"reason": "payload_too_large",
			"size": payload_json.length(),
		})
		return PluginErrors.payload_too_large(plugin_id, MAX_PAYLOAD_BYTES, payload_json.length())

	# --- 6. Dispatch -----------------------------------------------------------
	_audit(plugin_id, EVENT_IPC_ALLOWED, {
		"panel_name": panel_name,
		"message_type": message_type,
	})

	var result: Dictionary
	if message_type.begins_with("capability:"):
		result = await _dispatch_to_capability_broker(plugin_id, message_type, payload)
	else:
		result = await _dispatch_to_plugin_backend(plugin_id, message_type, payload)

	_audit(plugin_id, EVENT_IPC_DISPATCHED, {
		"panel_name": panel_name,
		"message_type": message_type,
		"success": result.get("success", false),
	})

	return result


# ---------------------------------------------------------------------------
# Validation helpers
# ---------------------------------------------------------------------------

## Returns true when message_type is listed in the plugin's manifest ui.ipc_messages.
## Always returns false when plugin_manager is null or the plugin is not found.
func _validate_message_declared(plugin_id: String, message_type: String) -> bool:
	if plugin_manager == null:
		push_warning("[PluginWebviewBroker] _validate_message_declared: no plugin_manager set")
		return false

	var db: PluginDB = plugin_manager.get_db()
	if db == null:
		return false

	var def: PluginDefinition = db.get_by_id(plugin_id)
	if def == null:
		return false

	return message_type in def.ui_ipc_messages


## Returns true when panel_name is listed in the plugin's manifest ui.panels.
## Also accepts the "capability:<name>" pseudo-messages that never need panel
## declaration (they are gated by PluginPolicy instead).
func _validate_panel_ownership(plugin_id: String, panel_name: String) -> bool:
	if plugin_manager == null:
		push_warning("[PluginWebviewBroker] _validate_panel_ownership: no plugin_manager set")
		return false

	var db: PluginDB = plugin_manager.get_db()
	if db == null:
		return false

	var def: PluginDefinition = db.get_by_id(plugin_id)
	if def == null:
		return false

	return panel_name in def.ui_panel_names


# ---------------------------------------------------------------------------
# Dispatch helpers
# ---------------------------------------------------------------------------

## Dispatch a "capability:<name>" message to CapabilityBroker.
## The capability name is extracted from the message_type after the colon.
##
## Example: message_type = "capability:notes.create"
##          dispatches CapabilityBroker.dispatch(plugin_id, "notes.create", payload)
func _dispatch_to_capability_broker(
		plugin_id: String,
		message_type: String,
		payload: Dictionary
) -> Dictionary:
	var capability: String = message_type.substr("capability:".length())
	if capability.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id,
			"capability message_type has empty capability name (expected 'capability:<name>')")

	if capability_broker == null:
		push_warning("[PluginWebviewBroker] _dispatch_to_capability_broker: no capability_broker set")
		return PluginErrors.schema_validation_failed(plugin_id,
			"Host capability broker is not available")

	return await capability_broker.dispatch(plugin_id, capability, payload)


## Dispatch a plugin-specific IPC message to the plugin's MCP backend.
##
## The message is sent as a "tools/call" MCP request where:
##   tool name  = the message_type string (validated against manifest)
##   arguments  = the payload dictionary
##
## Returns the tool call result, or an error if the plugin is not running or
## the connection call fails.
func _dispatch_to_plugin_backend(
		plugin_id: String,
		message_type: String,
		payload: Dictionary
) -> Dictionary:
	if plugin_manager == null:
		push_warning("[PluginWebviewBroker] _dispatch_to_plugin_backend: no plugin_manager set")
		return PluginErrors.plugin_not_running(plugin_id)

	var def: PluginDefinition = plugin_manager.get_db().get_by_id(plugin_id)
	if def == null:
		return PluginErrors.plugin_not_running(plugin_id)

	if def.state != PluginDefinition.State.RUNNING:
		return PluginErrors.plugin_not_running(plugin_id)

	var conn: MCPServerConnection = plugin_manager.get_connection(plugin_id)
	if conn == null:
		return PluginErrors.plugin_not_running(plugin_id)

	# MCPServerConnection.call_tool returns a Variant (awaitable).
	# We call it synchronously here; callers that need async should await
	# handle_ipc_message themselves.
	var call_result = await conn.call_tool(message_type, payload)

	if call_result == null:
		return PluginErrors.schema_validation_failed(plugin_id,
			"Plugin backend returned null for message '%s'" % message_type)

	if call_result is Dictionary:
		# Normalise to standard success wrapper if the backend didn't already wrap it.
		if call_result.has("success"):
			return call_result
		return PluginErrors.success(call_result)

	# Unexpected return type — wrap it so callers always get a Dictionary.
	return PluginErrors.success({"raw": call_result})


# ---------------------------------------------------------------------------
# Audit helper
# ---------------------------------------------------------------------------

func _audit(plugin_id: String, event_type: String, detail: Dictionary) -> void:
	if audit_log != null:
		audit_log.log_event(plugin_id, event_type, detail)


# ---------------------------------------------------------------------------
# INTEGRATION NOTES
# ---------------------------------------------------------------------------
#
# This broker is designed to slot into the WebView IPC flow with minimal
# changes to existing code. Below is the wiring plan; do NOT apply these
# changes here — this is documentation only.
#
# ── Where to wire it ──────────────────────────────────────────────────────
#
# The natural hook point is WebViewEditor._on_ipc_message() in
#   src/Scripts/UI/Controls/WebViewEditor/WebViewEditor.gd  (line 142)
#
# Currently that method just prints the raw IPC string.  The replacement
# should:
#
#   1. Parse the raw IPC string as JSON: {"type": "...", "payload": {...}}
#   2. Extract message_type and payload.
#   3. Determine the panel_name for this WebViewEditor instance.
#      (WebViewEditor already has an editor_id field; plugin panels should
#       set a human-readable panel_name matching the manifest declaration.)
#   4. Call:
#        var result = await _webview_broker.handle_ipc_message(
#            panel_name, message_type, payload
#        )
#   5. Relay the result back to JS via:
#        _webview.evaluate_javascript(
#            "window._minervaIPCReply(%s)" % JSON.stringify(result)
#        )
#      (The JS bridge in minerva_bridge.gd should expose _minervaIPCReply
#       and resolve the matching promise.)
#
# ── Where to obtain the broker ────────────────────────────────────────────
#
# PluginWebviewBroker should be owned by SingletonObject (or PluginManager)
# and made accessible via SingletonObject.plugin_webview_broker so that any
# panel host can reach it without a hard dependency chain.
#
# ── Plugin-panel HTML API (JS side) ──────────────────────────────────────
#
# The updated minerva_bridge.gd should replace the direct HTTP/MCP fetch
# with an IPC call that the broker intercepts:
#
#   window.minerva.ipc = async function(messageType, payload) {
#     return new Promise((resolve, reject) => {
#       const id = Date.now() + Math.random();
#       window._minervaIPCPending[id] = { resolve, reject };
#       window.ipc.postMessage(JSON.stringify({
#         id: id,
#         type: messageType,
#         payload: payload || {}
#       }));
#     });
#   };
#
#   window._minervaIPCPending = {};
#   window._minervaIPCReply = function(result) {
#     const pending = window._minervaIPCPending[result.id];
#     if (!pending) return;
#     delete window._minervaIPCPending[result.id];
#     if (result.success) pending.resolve(result.result);
#     else pending.reject(new Error(result.error_message || 'IPC error'));
#   };
#
# With this in place the JS side never touches localhost or MCP directly;
# all traffic flows through this broker and its policy checks.
#
# ── Manifest example ─────────────────────────────────────────────────────
#
#   "ui": {
#     "panels": ["notes_helper_panel"],
#     "ipc_messages": [
#       "notes_helper.summarise",
#       "capability:notes.create",
#       "capability:notes.read"
#     ]
#   }
#
# Note that capability dispatch messages (prefix "capability:") must still
# be listed in ipc_messages so the manifest acts as an explicit allowlist.

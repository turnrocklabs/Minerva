class_name PluginEventBroker
extends RefCounted
## Generic broker for plugin-originated events and state updates.
##
## Plugins emit events (edge-triggered transitions) and state (latest snapshot)
## via JSON-RPC notifications on stdout. This broker validates, stores, and
## fans out those notifications to internal consumers via Godot signals.

## Emitted when any plugin sends an event notification.
signal plugin_event(plugin_id: String, event_name: String, payload: Dictionary)

## Emitted when any plugin sends a state update.
signal plugin_state_changed(plugin_id: String, state: Dictionary)

## Latest state per plugin: plugin_id -> Dictionary
var _plugin_states: Dictionary = {}

## Reference to PluginDB for manifest validation
var _plugin_db = null  # PluginDB

## Reference to PluginAuditLog for logging
var _audit_log = null  # PluginAuditLog


func _init(p_plugin_db = null, p_audit_log = null) -> void:
	_plugin_db = p_plugin_db
	_audit_log = p_audit_log


## Handle a plugin event notification (minerva/plugin_event).
## Validates event name against manifest declarations.
## Returns {"ok": true} or {"error": "..."}.
func handle_plugin_event(plugin_id: String, event_name: String, payload: Dictionary) -> Dictionary:
	# Validate plugin exists
	if _plugin_db != null:
		var def = _plugin_db.get_by_id(plugin_id)
		if def == null:
			return {"error": "Unknown plugin: %s" % plugin_id}

		# Validate event name is declared in manifest
		var declared := false
		for ev in def.events:
			if ev.get("name", "") == event_name:
				declared = true
				break
		if not declared:
			push_warning("[PluginEventBroker] Plugin '%s' emitted undeclared event '%s'" % [plugin_id, event_name])
			# Still process it (warn, don't reject) — allows development flexibility

	# Log to audit
	if _audit_log != null:
		_audit_log.log_event(plugin_id, "plugin_event", {
			"event": event_name,
			"payload_keys": payload.keys(),
		})

	# Emit signal for internal consumers
	plugin_event.emit(plugin_id, event_name, payload)

	return {"ok": true}


## Handle a plugin state update (minerva/plugin_state).
## Stores the latest state and emits signal.
## Returns {"ok": true} or {"error": "..."}.
func handle_plugin_state(plugin_id: String, state: Dictionary) -> Dictionary:
	if _plugin_db != null:
		var def = _plugin_db.get_by_id(plugin_id)
		if def == null:
			return {"error": "Unknown plugin: %s" % plugin_id}

	# Store latest state (overwrite previous)
	_plugin_states[plugin_id] = state.duplicate(true)

	# Log to audit (just the fact of update, not full state)
	if _audit_log != null:
		_audit_log.log_event(plugin_id, "plugin_state_update", {
			"state_keys": state.keys(),
		})

	# Emit signal
	plugin_state_changed.emit(plugin_id, state)

	return {"ok": true}


## Get the latest state for a plugin. Returns empty dict if no state received yet.
func get_plugin_state(plugin_id: String) -> Dictionary:
	return _plugin_states.get(plugin_id, {})


## Clear stored state for a plugin (call on plugin stop/removal).
func clear_plugin_state(plugin_id: String) -> void:
	_plugin_states.erase(plugin_id)

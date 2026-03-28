class_name PluginPolicy
extends RefCounted
## Policy engine for the Minerva plugin system.
##
## Manages per-plugin granted capabilities, separate from what is declared
## in the manifest. The manifest declares what a plugin WANTS; this class
## tracks what the USER has approved.
##
## Design principles:
## - Deny-by-default: if not explicitly granted, the check returns denied.
## - The user is the authority: grants are written by host UI, not auto-derived
##   from manifest declarations.
## - All decisions are logged via the policy_decision signal and PluginAuditLog.
## - Persistence: granted capabilities are saved to user://plugins/policy.json.

const POLICY_PATH := "user://plugins/policy.json"
const POLICY_VERSION := 1

## Emitted for every capability check, whether allowed or denied.
## plugin_id: the plugin being checked
## capability: the capability string (e.g. "notes.create")
## allowed: true if the check passed, false if denied
## reason: short machine-readable reason string (e.g. "granted", "not_granted")
signal policy_decision(plugin_id: String, capability: String, allowed: bool, reason: String)

## Reference to the PluginDB used to look up manifest-declared capabilities.
## Must be set before calling get_requested_capabilities().
var plugin_db: PluginDB = null

## Audit log reference. If set, policy decisions are appended here in addition
## to the policy_decision signal.
var audit_log: PluginAuditLog = null

## In-memory store: plugin_id -> Array[String] of granted capability strings
var _grants: Dictionary = {}


func _init(p_plugin_db: PluginDB = null, p_audit_log: PluginAuditLog = null) -> void:
	plugin_db = p_plugin_db
	audit_log = p_audit_log
	_ensure_data_dir()
	_load()


# ---------------------------------------------------------------------------
# Grant / Revoke
# ---------------------------------------------------------------------------

## Grant a capability to a plugin.
## Idempotent — granting an already-granted capability is a no-op.
func grant_capability(plugin_id: String, capability: String) -> void:
	if plugin_id.is_empty() or capability.is_empty():
		push_warning("[PluginPolicy] grant_capability: empty plugin_id or capability")
		return

	if not _grants.has(plugin_id):
		_grants[plugin_id] = []

	var caps: Array = _grants[plugin_id]
	if capability not in caps:
		caps.append(capability)
		_save()
		if audit_log != null:
			audit_log.log_event(plugin_id, PluginAuditLog.EVENT_CAPABILITY_GRANT,
				{"capability": capability})
		print("[PluginPolicy] Granted '%s' to plugin '%s'" % [capability, plugin_id])


## Revoke a capability from a plugin.
## Idempotent — revoking a non-existent grant is a no-op.
func revoke_capability(plugin_id: String, capability: String) -> void:
	if plugin_id.is_empty() or capability.is_empty():
		return

	if not _grants.has(plugin_id):
		return

	var caps: Array = _grants[plugin_id]
	var idx := caps.find(capability)
	if idx >= 0:
		caps.remove_at(idx)
		_save()
		if audit_log != null:
			audit_log.log_event(plugin_id, PluginAuditLog.EVENT_CAPABILITY_REVOKE,
				{"capability": capability})
		print("[PluginPolicy] Revoked '%s' from plugin '%s'" % [capability, plugin_id])


# ---------------------------------------------------------------------------
# Queries
# ---------------------------------------------------------------------------

## Returns true if the plugin has been explicitly granted the capability.
func is_capability_granted(plugin_id: String, capability: String) -> bool:
	if not _grants.has(plugin_id):
		return false
	return capability in _grants[plugin_id]


## Returns a copy of all capabilities granted to a plugin.
func get_granted_capabilities(plugin_id: String) -> Array:
	if not _grants.has(plugin_id):
		return []
	return _grants[plugin_id].duplicate()


## Returns the capabilities declared in the plugin's manifest (what it requested).
## Requires plugin_db to be set. Returns empty array if plugin is not found.
func get_requested_capabilities(plugin_id: String) -> Array:
	if plugin_db == null:
		push_warning("[PluginPolicy] get_requested_capabilities: plugin_db is not set")
		return []

	var def: PluginDefinition = plugin_db.get_by_id(plugin_id)
	if def == null:
		return []

	return Array(def.host_capabilities)


# ---------------------------------------------------------------------------
# Check API — used by CapabilityBroker and tool call dispatcher
# ---------------------------------------------------------------------------

## Check whether a specific capability is granted for a plugin.
##
## Returns {"allowed": true} on success.
## Returns {"allowed": false, "error_code": "capability_not_granted", ...} on denial.
##
## Always emits the policy_decision signal and logs to audit_log if set.
func check_capability(plugin_id: String, capability: String) -> Dictionary:
	var granted := is_capability_granted(plugin_id, capability)

	if granted:
		_record_decision(plugin_id, capability, true, "granted")
		return {"allowed": true}
	else:
		_record_decision(plugin_id, capability, false, "not_granted")
		return PluginErrors.capability_not_granted(plugin_id, capability)


## Check whether a plugin is allowed to make a specific tool call.
##
## Tool names follow the convention "minerva_<plugin_id>_<action>".
## This method validates the tool name prefix and then delegates to check_capability()
## using the capability named in args["capability"].
##
## If no "capability" key is present in args, the call is denied with
## schema_validation_failed to prevent ambiguous dispatch.
##
## Returns {"allowed": true} or a failure dict from PluginErrors.
func check_tool_call(plugin_id: String, tool_name: String, args: Dictionary) -> Dictionary:
	if plugin_id.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id,
			"plugin_id must not be empty")

	if tool_name.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id,
			"tool_name must not be empty")

	# Validate tool name prefix: must be "minerva_<plugin_id>_..."
	var expected_prefix := "minerva_%s_" % plugin_id
	if not tool_name.begins_with(expected_prefix):
		var detail := "Tool '%s' does not match expected prefix '%s'" % [tool_name, expected_prefix]
		_record_decision(plugin_id, tool_name, false, "invalid_tool_name")
		return PluginErrors.permission_denied(plugin_id, detail)

	# The caller must specify which capability this tool call exercises.
	if not args.has("capability"):
		_record_decision(plugin_id, tool_name, false, "schema_validation_failed")
		return PluginErrors.schema_validation_failed(plugin_id,
			"Tool call args must include 'capability' key to indicate the host capability being used")

	var capability: String = str(args["capability"])
	return check_capability(plugin_id, capability)


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

## Reload grants from disk. Called automatically in _init().
func _load() -> void:
	if not FileAccess.file_exists(POLICY_PATH):
		return

	var file := FileAccess.open(POLICY_PATH, FileAccess.READ)
	if not file:
		push_error("[PluginPolicy] Cannot open %s" % POLICY_PATH)
		return

	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("[PluginPolicy] Failed to parse %s" % POLICY_PATH)
		return

	var root: Dictionary = json.data if json.data is Dictionary else {}
	var grants_raw: Dictionary = root.get("grants", {})

	_grants.clear()
	for plugin_id in grants_raw.keys():
		var caps = grants_raw[plugin_id]
		if caps is Array:
			_grants[str(plugin_id)] = caps.duplicate()


func _save() -> void:
	var grants_out: Dictionary = {}
	for plugin_id in _grants.keys():
		grants_out[plugin_id] = _grants[plugin_id].duplicate()

	var data := {
		"version": POLICY_VERSION,
		"grants": grants_out,
	}

	var json := JSON.stringify(data, "\t")
	var file := FileAccess.open(POLICY_PATH, FileAccess.WRITE)
	if not file:
		push_error("[PluginPolicy] Cannot write %s: %s" % [POLICY_PATH, FileAccess.get_open_error()])
		return

	file.store_string(json)
	file.close()


func _ensure_data_dir() -> void:
	var dir := DirAccess.open("user://")
	if dir and not dir.dir_exists("plugins"):
		dir.make_dir("plugins")


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

func _record_decision(plugin_id: String, capability: String, allowed: bool, reason: String) -> void:
	policy_decision.emit(plugin_id, capability, allowed, reason)
	if audit_log != null:
		var event_type := PluginAuditLog.EVENT_POLICY_ALLOW if allowed else PluginAuditLog.EVENT_POLICY_DENY
		audit_log.log_event(plugin_id, event_type, {
			"capability": capability,
			"reason": reason,
		})

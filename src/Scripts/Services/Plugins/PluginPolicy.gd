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

## Rate limit tracking: plugin_id -> { capability -> { window_start: float, count: int, max_calls: int, window_seconds: float } }
## Default: 60 calls per 60 seconds per capability per plugin
var _rate_limits: Dictionary = {}

## Default rate limit config (can be overridden per plugin/capability)
var _default_rate_limit := {
	"max_calls": 60,
	"window_seconds": 60.0,
}


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
## Returns {"allowed": false, "error_code": "rate_limit_exceeded", ...} if rate limited.
##
## Supports mcp.proxy pattern matching:
##   - Exact: granted "mcp.proxy:minerva_create_note" matches request "mcp.proxy:minerva_create_note"
##   - Wildcard: granted "mcp.proxy:minerva_note_*" matches request "mcp.proxy:minerva_create_note"
##   - Universal: granted "mcp.proxy:*" matches any mcp.proxy:<tool> request
##
## Rate limiting is applied AFTER the grant check: if granted but rate-limited, returns rate_limit_exceeded.
## Always emits the policy_decision signal and logs to audit_log if set.
func check_capability(plugin_id: String, capability: String) -> Dictionary:
	var granted := is_capability_granted(plugin_id, capability)

	# If not an exact match, check mcp.proxy wildcard patterns
	if not granted and capability.begins_with("mcp.proxy:"):
		granted = _check_mcp_proxy_wildcards(plugin_id, capability)

	if granted:
		# Capability is granted. Now check rate limit.
		var rate_limit_result := check_rate_limit(plugin_id, capability)
		if rate_limit_result.get("allowed", false):
			_record_decision(plugin_id, capability, true, "granted")
			return {"allowed": true}
		else:
			# Rate limit exceeded
			_record_decision(plugin_id, capability, false, "rate_limit_exceeded")
			return rate_limit_result
	else:
		_record_decision(plugin_id, capability, false, "not_granted")
		return PluginErrors.capability_not_granted(plugin_id, capability)


## Check whether a plugin has exceeded its rate limit for a specific capability.
##
## Uses a sliding window counter: if current_time - window_start > window_seconds,
## the window resets. Otherwise, increments the counter.
##
## Returns {"allowed": true} on success.
## Returns PluginErrors.rate_limit_exceeded() if the limit is exceeded.
##
## Call this AFTER check_capability() returns allowed=true, to enforce that
## the plugin is both granted AND not rate-limited.
func check_rate_limit(plugin_id: String, capability: String) -> Dictionary:
	var current_time := Time.get_ticks_msec() / 1000.0

	# Initialize plugin entry if not present
	if not _rate_limits.has(plugin_id):
		_rate_limits[plugin_id] = {}

	var plugin_limits: Dictionary = _rate_limits[plugin_id]

	# Initialize capability entry if not present (use defaults)
	if not plugin_limits.has(capability):
		plugin_limits[capability] = {
			"window_start": current_time,
			"count": 0,
			"max_calls": _default_rate_limit["max_calls"],
			"window_seconds": _default_rate_limit["window_seconds"],
		}

	var limit_entry: Dictionary = plugin_limits[capability]
	var window_start: float = limit_entry["window_start"]
	var count: int = limit_entry["count"]
	var max_calls: int = limit_entry["max_calls"]
	var window_seconds: float = limit_entry["window_seconds"]

	# Check if window has expired
	if current_time - window_start > window_seconds:
		# Window reset: new window starts now
		limit_entry["window_start"] = current_time
		limit_entry["count"] = 1
		_record_rate_limit_decision(plugin_id, capability, true, "allowed")
		return {"allowed": true}

	# Check if we've exceeded the limit
	if count >= max_calls:
		_record_rate_limit_decision(plugin_id, capability, false, "rate_limit_exceeded")
		return PluginErrors.rate_limit_exceeded(plugin_id, capability)

	# Increment counter and allow
	limit_entry["count"] = count + 1
	_record_rate_limit_decision(plugin_id, capability, true, "allowed")
	return {"allowed": true}


## Set a custom rate limit for a specific plugin and capability.
## max_calls: maximum number of calls allowed in the window
## window_seconds: duration of the sliding window in seconds
## If the plugin/capability does not yet have tracking data, it is initialized.
func set_rate_limit(plugin_id: String, capability: String, max_calls: int, window_seconds: float) -> void:
	if plugin_id.is_empty() or capability.is_empty():
		push_warning("[PluginPolicy] set_rate_limit: empty plugin_id or capability")
		return

	if max_calls < 1:
		push_warning("[PluginPolicy] set_rate_limit: max_calls must be >= 1")
		return

	if window_seconds < 0.1:
		push_warning("[PluginPolicy] set_rate_limit: window_seconds must be >= 0.1")
		return

	if not _rate_limits.has(plugin_id):
		_rate_limits[plugin_id] = {}

	var plugin_limits: Dictionary = _rate_limits[plugin_id]
	var current_time := Time.get_ticks_msec() / 1000.0

	# Initialize or update
	if not plugin_limits.has(capability):
		plugin_limits[capability] = {
			"window_start": current_time,
			"count": 0,
			"max_calls": max_calls,
			"window_seconds": window_seconds,
		}
	else:
		# Update limits (preserve current window progress)
		plugin_limits[capability]["max_calls"] = max_calls
		plugin_limits[capability]["window_seconds"] = window_seconds

	print("[PluginPolicy] Set rate limit for '%s' / '%s': %d calls per %.1f seconds" % [
		plugin_id, capability, max_calls, window_seconds
	])

	if audit_log != null:
		audit_log.log_event(plugin_id, "rate_limit_set", {
			"capability": capability,
			"max_calls": max_calls,
			"window_seconds": window_seconds,
		})


## Get the current rate limit configuration for a plugin and capability.
## Returns a Dictionary with keys: max_calls, window_seconds, current_count, window_start
## If no custom limit is set, returns the default limits.
func get_rate_limit(plugin_id: String, capability: String) -> Dictionary:
	if not _rate_limits.has(plugin_id):
		return {
			"max_calls": _default_rate_limit["max_calls"],
			"window_seconds": _default_rate_limit["window_seconds"],
			"current_count": 0,
			"window_start": 0.0,
		}

	var plugin_limits: Dictionary = _rate_limits[plugin_id]
	if not plugin_limits.has(capability):
		return {
			"max_calls": _default_rate_limit["max_calls"],
			"window_seconds": _default_rate_limit["window_seconds"],
			"current_count": 0,
			"window_start": 0.0,
		}

	var entry: Dictionary = plugin_limits[capability]
	return {
		"max_calls": entry.get("max_calls", _default_rate_limit["max_calls"]),
		"window_seconds": entry.get("window_seconds", _default_rate_limit["window_seconds"]),
		"current_count": entry.get("count", 0),
		"window_start": entry.get("window_start", 0.0),
	}


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

## Check if any granted mcp.proxy wildcard pattern matches the requested capability.
## The requested capability must be in the form "mcp.proxy:<tool_name>".
## Granted patterns can be:
##   "mcp.proxy:*" — matches any mcp.proxy tool
##   "mcp.proxy:minerva_note_*" — matches any tool starting with "minerva_note_"
##   "mcp.proxy:minerva_create_note" — exact match (handled by is_capability_granted)
func _check_mcp_proxy_wildcards(plugin_id: String, capability: String) -> bool:
	if not _grants.has(plugin_id):
		return false

	var requested_tool: String = capability.substr("mcp.proxy:".length())
	if requested_tool.is_empty():
		return false
	var caps: Array = _grants[plugin_id]

	for granted_cap in caps:
		var gc: String = str(granted_cap)
		if not gc.begins_with("mcp.proxy:"):
			continue

		var granted_pattern: String = gc.substr("mcp.proxy:".length())

		# Universal wildcard
		if granted_pattern == "*":
			return true

		# Prefix wildcard: "minerva_note_*" matches "minerva_create_note" if
		# the tool starts with the prefix before the *
		if granted_pattern.ends_with("*"):
			var prefix: String = granted_pattern.left(granted_pattern.length() - 1)
			if requested_tool.begins_with(prefix):
				return true

		# Exact match already handled by is_capability_granted, but check here too
		# in case the grant was stored differently
		if granted_pattern == requested_tool:
			return true

	return false


func _record_decision(plugin_id: String, capability: String, allowed: bool, reason: String) -> void:
	policy_decision.emit(plugin_id, capability, allowed, reason)
	if audit_log != null:
		var event_type := PluginAuditLog.EVENT_POLICY_ALLOW if allowed else PluginAuditLog.EVENT_POLICY_DENY
		audit_log.log_event(plugin_id, event_type, {
			"capability": capability,
			"reason": reason,
		})


func _record_rate_limit_decision(plugin_id: String, capability: String, _allowed: bool, reason: String) -> void:
	## Log rate limit decision to audit log if available.
	## Does not emit policy_decision signal (that is reserved for grant/deny decisions).
	if audit_log != null:
		audit_log.log_event(plugin_id, "rate_limit_check", {
			"capability": capability,
			"reason": reason,
		})

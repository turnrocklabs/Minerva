class_name PluginAuditLog
extends RefCounted
## In-memory audit log for plugin system events.
## Maintains a ring buffer of timestamped events with filtering capabilities.


# ---------------------------------------------------------------------------
# Event type constants
# ---------------------------------------------------------------------------

const EVENT_POLICY_ALLOW = "policy_allow"
const EVENT_POLICY_DENY = "policy_deny"
const EVENT_PLUGIN_INSTALL = "plugin_install"
const EVENT_PLUGIN_REMOVE = "plugin_remove"
const EVENT_PLUGIN_START = "plugin_start"
const EVENT_PLUGIN_STOP = "plugin_stop"
const EVENT_PLUGIN_CRASH = "plugin_crash"
const EVENT_PLUGIN_RESTART = "plugin_restart"
const EVENT_CAPABILITY_GRANT = "capability_grant"
const EVENT_CAPABILITY_REVOKE = "capability_revoke"
## Fired by CapabilityBroker when a plugin capability request is dispatched
## and succeeds (after policy allows it).
const EVENT_CAPABILITY_DISPATCHED = "capability_dispatched"
## Fired by CapabilityBroker when a policy engine rejects a capability request
## (capability_not_granted, permission_denied, target_not_allowlisted,
## rate_limit_exceeded, confirmation_required).
const EVENT_CAPABILITY_DENIED = "capability_denied"
## Fired by CapabilityBroker when a capability is policy-granted but the broker
## itself fails to satisfy the request (editor_not_found, not_buffer_canonical,
## version_conflict, schema_validation_failed, unknown_capability,
## mcp_tool_error, secrets_error, etc.).
const EVENT_CAPABILITY_FAILED = "capability_failed"


# ---------------------------------------------------------------------------
# Configuration and state
# ---------------------------------------------------------------------------

## Maximum number of entries to keep in memory. Oldest entries are dropped when full.
var max_entries: int = 1000

## Ring buffer of audit entries (Array of Dictionary)
var _entries: Array[Dictionary] = []


# ---------------------------------------------------------------------------
# Signals
# ---------------------------------------------------------------------------

## Emitted when a new entry is added to the audit log.
signal entry_added(entry: Dictionary)


# ---------------------------------------------------------------------------
# Public methods
# ---------------------------------------------------------------------------

## Log an event to the audit trail.
## plugin_id: unique identifier of the plugin
## event_type: one of the EVENT_* constants above
## detail: additional context (optional)
func log_event(plugin_id: String, event_type: String, detail: Dictionary = {}) -> void:
	var entry := {
		"timestamp": Time.get_datetime_string_from_system(true),
		"plugin_id": plugin_id,
		"event_type": event_type,
		"detail": detail.duplicate(),
	}

	_entries.append(entry)

	# Drop oldest entry if we've exceeded max_entries (ring buffer behavior)
	if _entries.size() > max_entries:
		_entries.pop_front()

	entry_added.emit(entry)


## Get audit entries, optionally filtered by plugin_id and/or event_type.
## Returns up to 'limit' most recent entries (newest first).
func get_entries(plugin_id: String = "", event_type: String = "", limit: int = 50) -> Array:
	var filtered: Array[Dictionary] = []

	# Iterate backwards (most recent first)
	for i in range(_entries.size() - 1, -1, -1):
		if filtered.size() >= limit:
			break

		var entry: Dictionary = _entries[i]

		# Check filters
		if not plugin_id.is_empty() and entry.get("plugin_id") != plugin_id:
			continue

		if not event_type.is_empty() and entry.get("event_type") != event_type:
			continue

		filtered.append(entry)

	return filtered


## Convenience method: get all policy denial events.
## Returns up to 'limit' most recent denial entries (newest first).
func get_denial_history(plugin_id: String = "", limit: int = 20) -> Array:
	return get_entries(plugin_id, EVENT_POLICY_DENY, limit)


## Clear all entries from the audit log.
func clear() -> void:
	_entries.clear()


## Get total number of entries in the log.
func get_entry_count() -> int:
	return _entries.size()

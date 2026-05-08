class_name PluginErrors
extends RefCounted
## Structured error factories for plugin policy enforcement.
## Returns standardized Dictionary responses with error codes, messages, and metadata.


# ---------------------------------------------------------------------------
# Error code constants
# ---------------------------------------------------------------------------

const CODE_PERMISSION_DENIED = "permission_denied"
const CODE_CAPABILITY_NOT_GRANTED = "capability_not_granted"
const CODE_UNKNOWN_CAPABILITY = "unknown_capability"
const CODE_SCHEMA_VALIDATION_FAILED = "schema_validation_failed"
const CODE_PAYLOAD_TOO_LARGE = "payload_too_large"
const CODE_TARGET_NOT_ALLOWLISTED = "target_not_allowlisted"
const CODE_RATE_LIMIT_EXCEEDED = "rate_limit_exceeded"
const CODE_CONFIRMATION_REQUIRED = "confirmation_required"
const CODE_PLUGIN_NOT_RUNNING = "plugin_not_running"
const CODE_TOOL_NOT_FOUND = "tool_not_found"


# ---------------------------------------------------------------------------
# Factory methods
# ---------------------------------------------------------------------------

## Plugin tried to perform an action it doesn't have permission for.
static func permission_denied(plugin_id: String, detail: String = "") -> Dictionary:
	return {
		"success": false,
		"error_code": CODE_PERMISSION_DENIED,
		"error_message": "Permission denied",
		"plugin_id": plugin_id,
		"detail": detail,
	}


## Plugin requested a capability that hasn't been granted.
static func capability_not_granted(plugin_id: String, capability: String) -> Dictionary:
	return {
		"success": false,
		"error_code": CODE_CAPABILITY_NOT_GRANTED,
		"error_message": "Capability '%s' not granted to this plugin" % capability,
		"plugin_id": plugin_id,
		"capability": capability,
	}


## Request payload failed schema validation.
static func schema_validation_failed(plugin_id: String, detail: String) -> Dictionary:
	return {
		"success": false,
		"error_code": CODE_SCHEMA_VALIDATION_FAILED,
		"error_message": "Schema validation failed",
		"plugin_id": plugin_id,
		"detail": detail,
	}


## Request payload exceeds size limit.
static func payload_too_large(plugin_id: String, max_size: int, actual_size: int) -> Dictionary:
	return {
		"success": false,
		"error_code": CODE_PAYLOAD_TOO_LARGE,
		"error_message": "Payload too large: %d bytes (limit: %d bytes)" % [actual_size, max_size],
		"plugin_id": plugin_id,
		"max_size": max_size,
		"actual_size": actual_size,
	}


## Target (file, URL, etc.) is not in the allowlist.
static func target_not_allowlisted(plugin_id: String, target: String) -> Dictionary:
	return {
		"success": false,
		"error_code": CODE_TARGET_NOT_ALLOWLISTED,
		"error_message": "Target not allowlisted",
		"plugin_id": plugin_id,
		"target": target,
	}


## Plugin has exceeded its rate limit for this capability.
static func rate_limit_exceeded(plugin_id: String, capability: String) -> Dictionary:
	return {
		"success": false,
		"error_code": CODE_RATE_LIMIT_EXCEEDED,
		"error_message": "Rate limit exceeded for capability '%s'" % capability,
		"plugin_id": plugin_id,
		"capability": capability,
	}


## Action requires user confirmation before proceeding.
static func confirmation_required(plugin_id: String, capability: String, detail: String) -> Dictionary:
	return {
		"success": false,
		"error_code": CODE_CONFIRMATION_REQUIRED,
		"error_message": "User confirmation required",
		"plugin_id": plugin_id,
		"capability": capability,
		"detail": detail,
	}


## Plugin is not in a running state.
static func plugin_not_running(plugin_id: String) -> Dictionary:
	return {
		"success": false,
		"error_code": CODE_PLUGIN_NOT_RUNNING,
		"error_message": "Plugin is not running",
		"plugin_id": plugin_id,
	}


## Tool is not found (or not exposed by the plugin).
static func tool_not_found(plugin_id: String, tool_name: String) -> Dictionary:
	return {
		"success": false,
		"error_code": CODE_TOOL_NOT_FOUND,
		"error_message": "Tool '%s' not found" % tool_name,
		"plugin_id": plugin_id,
		"tool_name": tool_name,
	}


# ---------------------------------------------------------------------------
# Success helper
# ---------------------------------------------------------------------------

## Wrap a successful result in the standard response format.
static func success(result: Dictionary = {}) -> Dictionary:
	return {
		"success": true,
		"result": result,
	}

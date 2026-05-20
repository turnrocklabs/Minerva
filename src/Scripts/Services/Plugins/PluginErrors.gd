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
const CODE_EDITOR_NOT_FOUND = "editor_not_found"
const CODE_NOT_BUFFER_CANONICAL = "not_buffer_canonical"
const CODE_VERSION_CONFLICT = "version_conflict"
const CODE_OWNERSHIP_REQUIRED = "ownership_required"
const CODE_IO_ERROR = "io_error"
const CODE_FILESYSTEM_DISABLED = "filesystem_disabled"
const CODE_FORMAT_NOT_SUPPORTED = "format_not_supported"
const CODE_BLOB_NOT_FOUND = "blob_not_found"
const CODE_UNKNOWN_BLOB_HANDLE = "unknown_blob_handle"
const CODE_PATCH_FAILED = "patch_failed"
const CODE_MODEL_NOT_AVAILABLE = "model_not_available"
const CODE_MODEL_AMBIGUOUS = "model_ambiguous"
const CODE_PROVIDER_DISABLED = "provider_disabled"
const CODE_BUDGET_EXCEEDED = "budget_exceeded"
const CODE_PROVIDER_ERROR = "provider_error"
const CODE_BACKEND_ERROR = "plugin_backend_error"


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


## Editor with the given tab title was not found.
static func editor_not_found(plugin_id: String, editor_name: String) -> Dictionary:
	return {
		"success": false,
		"error_code": CODE_EDITOR_NOT_FOUND,
		"error_message": "Editor '%s' not found" % editor_name,
		"plugin_id": plugin_id,
		"editor_name": editor_name,
	}


## Editor exists but does not have a canonical DocumentBuffer (e.g. non-paired
## plugin-scene panel whose state lives in panel UI, not in a DocumentBuffer).
static func not_buffer_canonical(plugin_id: String, editor_name: String) -> Dictionary:
	return {
		"success": false,
		"error_code": CODE_NOT_BUFFER_CANONICAL,
		"error_message": "Editor '%s' is not buffer-canonical; use host_owned_save for state access" % editor_name,
		"plugin_id": plugin_id,
		"editor_name": editor_name,
	}


## Optimistic-concurrency version mismatch: caller supplied expected_version but
## the buffer has already been mutated past that version.
static func version_conflict(plugin_id: String, editor_name: String, expected: int, actual: int) -> Dictionary:
	return {
		"success": false,
		"error_code": CODE_VERSION_CONFLICT,
		"error_message": "Version conflict on editor '%s': expected %d, actual %d" % [editor_name, expected, actual],
		"plugin_id": plugin_id,
		"editor_name": editor_name,
		"expected_version": expected,
		"actual_version": actual,
	}


## Plugin holds the capability globally but the target editor belongs to a
## different plugin. Distinct from permission_denied so callers can tell
## "I don't have rights at all" from "I have rights but not for this editor."
static func ownership_required(plugin_id: String, editor_name: String, owner_plugin_id: String) -> Dictionary:
	return {
		"success": false,
		"error_code": CODE_OWNERSHIP_REQUIRED,
		"error_message": "Editor '%s' is owned by plugin '%s'; cross-plugin mutation requires explicit grant" % [editor_name, owner_plugin_id],
		"plugin_id": plugin_id,
		"editor_name": editor_name,
		"owner_plugin_id": owner_plugin_id,
	}


## Filesystem I/O failed (file not found, permission denied at OS level, disk full).
## The detail field carries the underlying error string for forensics.
static func io_error(plugin_id: String, path: String, detail: String) -> Dictionary:
	return {
		"success": false,
		"error_code": CODE_IO_ERROR,
		"error_message": "I/O error on '%s'" % path,
		"plugin_id": plugin_id,
		"path": path,
		"detail": detail,
	}


## Editor exists but doesn't support the requested export format. Distinct
## from schema_validation_failed because the request was well-formed; the
## editor type just doesn't know how to render itself in that format.
static func format_not_supported(plugin_id: String, editor_name: String, format: String, supported: Array) -> Dictionary:
	return {
		"success": false,
		"error_code": CODE_FORMAT_NOT_SUPPORTED,
		"error_message": "Editor '%s' does not support format '%s' (supported: %s)" % [editor_name, format, str(supported)],
		"plugin_id": plugin_id,
		"editor_name": editor_name,
		"format": format,
		"supported_formats": supported,
	}


## A blob handle was requested but is not present in the editor's blob store.
## Distinct from editor_not_found: the editor was found but the handle is unknown
## (was never stored, or was GC'd after its refcount reached zero).
static func blob_not_found(plugin_id: String, editor_name: String, blob_handle: String) -> Dictionary:
	return {
		"success": false,
		"error_code": CODE_BLOB_NOT_FOUND,
		"error_message": "Blob handle '%s' not found in editor '%s'" % [blob_handle, editor_name],
		"plugin_id": plugin_id,
		"editor_name": editor_name,
		"blob_handle": blob_handle,
	}


## A blob handle referenced in a patch_state op is not present in the editor's
## blob store. Reported before the patch is applied (pre-validation pass).
## op_index is the 0-based index of the offending op in the json_patch array.
static func unknown_blob_handle(
		plugin_id: String, editor_name: String, blob_handle: String, op_index: int
) -> Dictionary:
	return {
		"success": false,
		"error_code": CODE_UNKNOWN_BLOB_HANDLE,
		"error_message": "Unknown blob handle '%s' in patch op %d on editor '%s'" % [
			blob_handle, op_index, editor_name,
		],
		"plugin_id": plugin_id,
		"editor_name": editor_name,
		"blob_handle": blob_handle,
		"op_index": op_index,
	}


## JSON Patch application failed. op_index is the 0-based index of the failing
## op; op_error_code is one of JsonPatch's ERR_* constants.
static func patch_failed(
		plugin_id: String, editor_name: String,
		op_index: int, op_error_code: String, message: String
) -> Dictionary:
	return {
		"success": false,
		"error_code": CODE_PATCH_FAILED,
		"error_message": "Patch failed at op %d: %s" % [op_index, message],
		"plugin_id": plugin_id,
		"editor_name": editor_name,
		"op_index": op_index,
		"op_error_code": op_error_code,
	}


## Plugin declared a host.files.* capability but its manifest does not enable
## scoped filesystem access (permissions.filesystem.mode != "scoped_paths" or
## paths is empty). Distinct from capability_not_granted because the policy
## may have granted host.files.read in principle but the manifest itself
## doesn't carry the scoped paths the validator needs.
static func filesystem_disabled(plugin_id: String, capability: String) -> Dictionary:
	return {
		"success": false,
		"error_code": CODE_FILESYSTEM_DISABLED,
		"error_message": "Filesystem access not enabled in manifest (permissions.filesystem.mode must be 'scoped_paths')",
		"plugin_id": plugin_id,
		"capability": capability,
	}


# ---------------------------------------------------------------------------
# Success helper
# ---------------------------------------------------------------------------

## Requested model name was not found in any provider.
static func model_not_available(plugin_id: String, model: String) -> Dictionary:
	return {
		"success": false,
		"error_code": CODE_MODEL_NOT_AVAILABLE,
		"error_message": "Model '%s' is not available" % model,
		"plugin_id": plugin_id,
		"model": model,
	}


## Model name matches multiple providers and no provider hint was given.
static func model_ambiguous(plugin_id: String, model: String, candidates: Array) -> Dictionary:
	return {
		"success": false,
		"error_code": CODE_MODEL_AMBIGUOUS,
		"error_message": "Model '%s' is available from multiple providers; specify 'provider' to disambiguate" % model,
		"plugin_id": plugin_id,
		"model": model,
		"candidates": candidates,
	}


## Provider exists but is disabled or has no API key configured.
static func provider_disabled(plugin_id: String, provider: String) -> Dictionary:
	return {
		"success": false,
		"error_code": CODE_PROVIDER_DISABLED,
		"error_message": "Provider '%s' is disabled or not configured" % provider,
		"plugin_id": plugin_id,
		"provider": provider,
	}


## Plugin's hierarchical budget has been exceeded.
static func budget_exceeded(plugin_id: String, which_budget: String, budget: float, spent: float, period: String) -> Dictionary:
	return {
		"success": false,
		"error_code": CODE_BUDGET_EXCEEDED,
		"error_message": "Budget '%s' exceeded: spent $%.6f of $%.6f in period '%s'" % [which_budget, spent, budget, period],
		"plugin_id": plugin_id,
		"which_budget": which_budget,
		"budget": budget,
		"spent": spent,
		"period": period,
	}


## Provider returned an error during generate_content.
static func provider_error(plugin_id: String, provider: String, model: String, detail: String) -> Dictionary:
	return {
		"success": false,
		"error_code": CODE_PROVIDER_ERROR,
		"error_message": "Provider '%s' returned an error for model '%s'" % [provider, model],
		"plugin_id": plugin_id,
		"provider": provider,
		"model": model,
		"detail": detail,
	}


## A plugin backend tool call failed at the connection layer — a timeout,
## subprocess exit, or write failure surfaced by MCPServerConnection. `detail`
## is the human-readable error string; it is placed directly in error_message
## so a panel can show the user exactly what went wrong.
static func backend_error(plugin_id: String, detail: String) -> Dictionary:
	return {
		"success": false,
		"error_code": CODE_BACKEND_ERROR,
		"error_message": detail,
		"plugin_id": plugin_id,
	}


# ---------------------------------------------------------------------------
# Success helper
# ---------------------------------------------------------------------------

## Wrap a successful result in the standard response format.
## Successful capability/tool response.
##
## Returns the payload directly. The previous wrapping shape
## `{success: true, result: payload}` was vestigial — the MCP STDIO bridge
## (MCPServerConnection._handle_stdio_capability_request) passes the broker's
## return value verbatim into the JSON-RPC `result` field, so wrapping here
## produced `{jsonrpc, id, result: {success: true, result: <payload>}}` on the
## wire — plugins that read fields off the payload directly saw nothing.
##
## Error shape is unchanged: `{success: false, error_code, error_message, ...}`.
## Plugins distinguish errors by `success == false` (still present); successful
## responses simply lack any `success` field. Callers reading payload fields
## directly work as expected.
static func success(result: Dictionary = {}) -> Dictionary:
	return result

class_name CapabilityBroker
extends RefCounted
## Host capability broker for the Minerva plugin system.
##
## Routes mcp.proxy:<tool_name> capability requests to MinervaMCPServer's
## _execute_tool_impl(), gated by PluginPolicy.
##
## Return format (all public methods):
##   Success: {"success": true, "result": {...}}
##   Failure: {"success": false, "error_code": "...", "error_message": "...", ...}
##
## Design notes:
## - CapabilityBroker is stateless with respect to plugin identity; it delegates
##   all grant checks to PluginPolicy.
## - The mcp.proxy meta-capability routes to MinervaMCPServer._execute_tool_impl()
##   so individual capability handlers are not needed.
## - Non-mcp.proxy capabilities return "not_implemented" for now.

## Policy engine reference — required for capability gating.
var policy: PluginPolicy = null


func _init(p_policy: PluginPolicy = null) -> void:
	policy = p_policy


# ---------------------------------------------------------------------------
# Static helpers
# ---------------------------------------------------------------------------

## Validate that a requested path is within the allowed scopes.
## Normalizes both paths before comparison.
## Returns true if path is within any of the allowed_paths, false otherwise.
static func is_path_in_scope(path: String, allowed_paths: Array) -> bool:
	if allowed_paths.is_empty():
		return false

	# Normalize the requested path
	var abs_path: String = ProjectSettings.globalize_path(path) if path.begins_with("user://") else path
	abs_path = abs_path.simplify_path()

	# Check against each allowed path
	for allowed in allowed_paths:
		var abs_allowed: String = ProjectSettings.globalize_path(str(allowed)) if str(allowed).begins_with("user://") else str(allowed)
		abs_allowed = abs_allowed.simplify_path()

		# Check if the requested path is within the allowed path
		if abs_path.begins_with(abs_allowed):
			return true

	return false


# ---------------------------------------------------------------------------
# Public dispatch entry point
# ---------------------------------------------------------------------------

## Dispatch a capability call on behalf of a plugin.
##
## Steps:
## 1. Validate inputs.
## 2. Ask PluginPolicy whether the capability is granted.
## 3. For mcp.proxy:<tool>, call MinervaMCPServer._execute_tool_impl().
## 4. For other capabilities, return not_implemented.
##
## Returns {"success": true, "result": {...}} or a PluginErrors failure dict.
func dispatch(plugin_id: String, capability: String, args: Dictionary) -> Dictionary:
	if plugin_id.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id, "plugin_id must not be empty")

	if capability.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id, "capability must not be empty")

	# Gate: check with policy engine before any execution (deny-by-default)
	if policy != null:
		var check := policy.check_capability(plugin_id, capability)
		if not check.get("allowed", false):
			# Re-wrap as success=false (check_capability already uses PluginErrors format)
			return {
				"success": false,
				"error_code": check.get("error_code", PluginErrors.CODE_CAPABILITY_NOT_GRANTED),
				"error_message": check.get("error_message", "Capability not granted"),
				"plugin_id": plugin_id,
			}
	else:
		# No policy engine — fail closed
		push_warning("[CapabilityBroker] No policy engine set — denying dispatch of '%s' for plugin '%s'" % [capability, plugin_id])
		return PluginErrors.capability_not_granted(plugin_id, capability)

	# Route mcp.proxy:<tool_name> to MinervaMCPServer
	if capability.begins_with("mcp.proxy:"):
		return await _handle_mcp_proxy(plugin_id, capability, args)

	# Legacy / non-mcp.proxy capabilities — not yet implemented
	match capability:
		"network.none":
			# network.none is a deny marker — granting it is a configuration error
			return PluginErrors.permission_denied(plugin_id,
				"network.none is a deny marker and cannot be dispatched")
		_:
			return PluginErrors.schema_validation_failed(plugin_id,
				"Capability '%s' is not implemented. Use mcp.proxy:<tool_name> to call Minerva tools." % capability)


# ---------------------------------------------------------------------------
# mcp.proxy handler
# ---------------------------------------------------------------------------

## Route an mcp.proxy:<tool_name> capability to MinervaMCPServer._execute_tool_impl().
func _handle_mcp_proxy(plugin_id: String, capability: String, args: Dictionary) -> Dictionary:
	var tool_name: String = capability.substr("mcp.proxy:".length())

	if tool_name.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id,
			"mcp.proxy capability requires a tool name (e.g. mcp.proxy:minerva_create_note)")

	var minerva_server = _get_minerva_server()
	if minerva_server == null:
		return PluginErrors.schema_validation_failed(plugin_id,
			"mcp.proxy: MinervaMCPServer is not available")

	print("[CapabilityBroker] Plugin '%s' invoking mcp.proxy:%s" % [plugin_id, tool_name])

	var result: Dictionary = await minerva_server._execute_tool_impl(tool_name, args)

	# Wrap the MCP tool result in our standard success/failure format.
	# MinervaMCPServer tools return {"success": true/false, ...} or {"error": "..."}.
	if result.get("success", false) or (not result.has("error") and not result.has("error_code")):
		return PluginErrors.success(result)
	else:
		return {
			"success": false,
			"error_code": "mcp_tool_error",
			"error_message": result.get("error", "Unknown error from tool '%s'" % tool_name),
			"plugin_id": plugin_id,
			"tool_name": tool_name,
		}


# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

## Return the MinervaMCPServer instance from the autoload, or null.
func _get_minerva_server():
	var root = Engine.get_main_loop().root if Engine.get_main_loop() else null
	if root == null:
		return null
	var so = root.get_node_or_null("SingletonObject")
	if so == null:
		return null
	var mcp_mgr = so.get("mcp_manager") if "mcp_manager" in so else null
	if mcp_mgr == null:
		return null
	return mcp_mgr.get("minerva_server") if "minerva_server" in mcp_mgr else null

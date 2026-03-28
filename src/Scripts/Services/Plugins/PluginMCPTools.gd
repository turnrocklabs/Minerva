class_name PluginMCPTools
extends RefCounted
## MCP tool definitions and handlers for plugin management.
##
## Provides tools for LLMs to list, install, start, stop, and inspect plugins
## in the Minerva plugin system.


# ---------------------------------------------------------------------------
# Dependencies (injected via init)
# ---------------------------------------------------------------------------

var _plugin_manager = null  # PluginManager
var _plugin_policy = null   # PluginPolicy
var _audit_log = null       # PluginAuditLog


func _init(p_manager = null, p_policy = null, p_audit_log = null) -> void:
	_plugin_manager = p_manager
	_plugin_policy = p_policy
	_audit_log = p_audit_log


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Return an array of tool definition dictionaries suitable for MCP registration.
## Each tool dict has: name, description, input_schema.
func get_tool_definitions() -> Array:
	return [
		_get_plugin_list_tool_def(),
		_get_plugin_install_tool_def(),
		_get_plugin_remove_tool_def(),
		_get_plugin_start_tool_def(),
		_get_plugin_stop_tool_def(),
		_get_plugin_restart_tool_def(),
		_get_plugin_inspect_tool_def(),
	]


## Dispatch a tool call to the appropriate handler.
## Returns the result dictionary (success or error).
## Note: This function is async to support plugin lifecycle operations that require await.
func handle_tool_call(tool_name: String, args: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_plugin_list":
			return _handle_plugin_list(args)
		"minerva_plugin_install":
			return _handle_plugin_install(args)
		"minerva_plugin_remove":
			return await _handle_plugin_remove(args)
		"minerva_plugin_start":
			return await _handle_plugin_start(args)
		"minerva_plugin_stop":
			return await _handle_plugin_stop(args)
		"minerva_plugin_restart":
			return await _handle_plugin_restart(args)
		"minerva_plugin_inspect":
			return _handle_plugin_inspect(args)
		_:
			return {"error": "Unknown plugin management tool: %s" % tool_name}


# ---------------------------------------------------------------------------
# Tool Definitions
# ---------------------------------------------------------------------------

func _get_plugin_list_tool_def() -> Dictionary:
	return {
		"name": "minerva_plugin_list",
		"description": "List all installed plugins with their current status. Optionally filter by status.",
		"input_schema": {
			"type": "object",
			"properties": {
				"status": {
					"type": "string",
					"description": "Optional status filter (INSTALLED, STARTING, RUNNING, STOPPED, ERROR, CRASH_LOOP). If omitted, lists all plugins."
				}
			}
		}
	}


func _get_plugin_install_tool_def() -> Dictionary:
	return {
		"name": "minerva_plugin_install",
		"description": "Install a plugin from a manifest.json file. The manifest path should be an absolute path to manifest.json.",
		"input_schema": {
			"type": "object",
			"properties": {
				"manifest_path": {
					"type": "string",
					"description": "Absolute path to the plugin's manifest.json file"
				}
			},
			"required": ["manifest_path"]
		}
	}


func _get_plugin_remove_tool_def() -> Dictionary:
	return {
		"name": "minerva_plugin_remove",
		"description": "Remove an installed plugin. If the plugin is running, it will be stopped first.",
		"input_schema": {
			"type": "object",
			"properties": {
				"id": {
					"type": "string",
					"description": "The plugin ID to remove"
				}
			},
			"required": ["id"]
		}
	}


func _get_plugin_start_tool_def() -> Dictionary:
	return {
		"name": "minerva_plugin_start",
		"description": "Start a plugin (launch its process and establish MCP connection).",
		"input_schema": {
			"type": "object",
			"properties": {
				"id": {
					"type": "string",
					"description": "The plugin ID to start"
				}
			},
			"required": ["id"]
		}
	}


func _get_plugin_stop_tool_def() -> Dictionary:
	return {
		"name": "minerva_plugin_stop",
		"description": "Stop a running plugin gracefully.",
		"input_schema": {
			"type": "object",
			"properties": {
				"id": {
					"type": "string",
					"description": "The plugin ID to stop"
				}
			},
			"required": ["id"]
		}
	}


func _get_plugin_restart_tool_def() -> Dictionary:
	return {
		"name": "minerva_plugin_restart",
		"description": "Stop and then restart a plugin.",
		"input_schema": {
			"type": "object",
			"properties": {
				"id": {
					"type": "string",
					"description": "The plugin ID to restart"
				}
			},
			"required": ["id"]
		}
	}


func _get_plugin_inspect_tool_def() -> Dictionary:
	return {
		"name": "minerva_plugin_inspect",
		"description": "Get detailed information about a plugin: manifest details, granted vs requested capabilities, and recent audit log entries.",
		"input_schema": {
			"type": "object",
			"properties": {
				"id": {
					"type": "string",
					"description": "The plugin ID to inspect"
				}
			},
			"required": ["id"]
		}
	}


# ---------------------------------------------------------------------------
# Tool Handlers
# ---------------------------------------------------------------------------

func _handle_plugin_list(args: Dictionary) -> Dictionary:
	var plugin_manager = _get_plugin_manager()
	if plugin_manager == null:
		return {"error": "Plugin manager not available"}

	# Get all plugins first
	var all_plugins = plugin_manager.get_all_plugins()

	# Apply status filter if provided
	var status_filter = args.get("status", "")
	var filtered_plugins = all_plugins

	if not status_filter.is_empty():
		filtered_plugins = []
		for plugin_status in all_plugins:
			if plugin_status.get("state_name") == status_filter:
				filtered_plugins.append(plugin_status)

	return {
		"success": true,
		"plugin_count": filtered_plugins.size(),
		"plugins": filtered_plugins
	}


func _handle_plugin_install(args: Dictionary) -> Dictionary:
	var manifest_path = args.get("manifest_path", "")
	if manifest_path.is_empty():
		return {"error": "manifest_path is required"}

	var plugin_manager = _get_plugin_manager()
	if plugin_manager == null:
		return {"error": "Plugin manager not available"}

	var result = plugin_manager.install_plugin(manifest_path)
	return result


func _handle_plugin_remove(args: Dictionary) -> Dictionary:
	var id = args.get("id", "")
	if id.is_empty():
		return {"error": "id is required"}

	var plugin_manager = _get_plugin_manager()
	if plugin_manager == null:
		return {"error": "Plugin manager not available"}

	var result = await plugin_manager.remove_plugin(id)
	return result


func _handle_plugin_start(args: Dictionary) -> Dictionary:
	var id = args.get("id", "")
	if id.is_empty():
		return {"error": "id is required"}

	var plugin_manager = _get_plugin_manager()
	if plugin_manager == null:
		return {"error": "Plugin manager not available"}

	var result = await plugin_manager.start_plugin(id)
	return result


func _handle_plugin_stop(args: Dictionary) -> Dictionary:
	var id = args.get("id", "")
	if id.is_empty():
		return {"error": "id is required"}

	var plugin_manager = _get_plugin_manager()
	if plugin_manager == null:
		return {"error": "Plugin manager not available"}

	var result = await plugin_manager.stop_plugin(id)
	return result


func _handle_plugin_restart(args: Dictionary) -> Dictionary:
	var id = args.get("id", "")
	if id.is_empty():
		return {"error": "id is required"}

	var plugin_manager = _get_plugin_manager()
	if plugin_manager == null:
		return {"error": "Plugin manager not available"}

	var result = await plugin_manager.restart_plugin(id)
	return result


func _handle_plugin_inspect(args: Dictionary) -> Dictionary:
	var id = args.get("id", "")
	if id.is_empty():
		return {"error": "id is required"}

	var plugin_manager = _get_plugin_manager()
	if plugin_manager == null:
		return {"error": "Plugin manager not available"}

	var db = plugin_manager.get_db()
	var def = db.get_by_id(id)
	if def == null:
		return {"error": "Plugin '%s' not found" % id}

	# Build the inspection result
	var status = plugin_manager.get_plugin_status(id)
	if status.has("error"):
		return status

	# Get policy and audit info
	var policy = _get_plugin_policy()
	var audit_log = _get_plugin_audit_log()

	var granted_caps = []
	var requested_caps = []
	var recent_audit_entries = []

	if policy != null:
		granted_caps = policy.get_granted_capabilities(id)
		requested_caps = policy.get_requested_capabilities(id)

	if audit_log != null:
		recent_audit_entries = audit_log.get_entries(id, "", 10)

	return {
		"success": true,
		"id": id,
		"name": def.name,
		"version": def.version,
		"status": status,
		"manifest": {
			"id": def.id,
			"name": def.name,
			"version": def.version,
			"host_api_version": def.host_api_version,
			"transport": def.transport,
			"entrypoint": def.entrypoint,
			"args": def.args,
			"working_dir": def.working_dir,
			"autostart": def.autostart,
			"network_mode": def.network_mode,
			"filesystem_mode": def.filesystem_mode,
		},
		"capabilities": {
			"requested": requested_caps,
			"granted": granted_caps
		},
		"recent_audit_log": recent_audit_entries
	}


# ---------------------------------------------------------------------------
# Private Helpers
# ---------------------------------------------------------------------------

## Return the injected PluginManager reference.
func _get_plugin_manager() -> Variant:
	return _plugin_manager


## Return the injected PluginPolicy reference.
func _get_plugin_policy() -> Variant:
	return _plugin_policy


## Return the injected PluginAuditLog reference.
func _get_plugin_audit_log() -> Variant:
	return _audit_log

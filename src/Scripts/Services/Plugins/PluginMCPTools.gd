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
var _event_broker = null    # PluginEventBroker


func _init(p_manager = null, p_policy = null, p_audit_log = null, p_event_broker = null) -> void:
	_plugin_manager = p_manager
	_plugin_policy = p_policy
	_audit_log = p_audit_log
	_event_broker = p_event_broker
	_connect_build_activity_signals()


## G4.2 (DCR 019f69428fa0 round R3-UI): route setup-pipeline step boundaries
## to the visible activity surface. This class — not PluginManagerPanel — owns
## the routing because it is created once at plugin-system init and lives for
## the whole session (SingletonObject.plugin_mcp_tools), so MCP-triggered
## builds get logged even when the Plugin Manager panel was never opened.
## has_signal() guard: tests construct this class with mocks/null that may not
## carry the build signals.
func _connect_build_activity_signals() -> void:
	if _plugin_manager == null or not (_plugin_manager is Object):
		return
	if not (_plugin_manager as Object).has_signal("plugin_build_step_started"):
		return
	_plugin_manager.plugin_build_step_started.connect(_on_build_step_started_activity)
	_plugin_manager.plugin_build_step_finished.connect(_on_build_step_finished_activity)


func _on_build_step_started_activity(id: String, step_index: int, step_count: int, step_type: String) -> void:
	# Echo the step's manifest-declared content (argv for exec, package/output
	# for go_build, …) — the resolved argv only exists inside the executor and
	# is surfaced on failure via the envelope's resolved_argv.
	var step_detail := ""
	var pm = _get_plugin_manager()
	if pm != null:
		var def = pm.get_db().get_by_id(id)
		if def != null:
			var steps: Array = def.setup.get("steps", [])
			if step_index >= 0 and step_index < steps.size():
				step_detail = JSON.stringify(steps[step_index])
	_append_build_activity(id, "step %d/%d %s: started%s" % [
		step_index + 1, step_count, step_type,
		("  %s" % step_detail) if not step_detail.is_empty() else "",
	])


func _on_build_step_finished_activity(id: String, step_index: int, step_count: int, step_type: String, ok: bool, detail: Dictionary) -> void:
	if ok:
		_append_build_activity(id, "step %d/%d %s: OK" % [step_index + 1, step_count, step_type])
		return
	var lines := "step %d/%d %s: FAILED (exit=%s)" % [
		step_index + 1, step_count, step_type, str(detail.get("exit_code", "?")),
	]
	var argv: Array = detail.get("resolved_argv", [])
	if not argv.is_empty():
		lines += "\n  argv: %s" % JSON.stringify(argv)
	var stderr_tail: String = str(detail.get("stderr_tail", ""))
	if not stderr_tail.is_empty():
		lines += "\n  stderr: %s" % stderr_tail
	_append_build_activity(id, lines)


## Append one entry to the "Activity: Plugin Builds" editor tab. Reuse note:
## this deliberately copies PluginNotifyRouter._append_to_activity_log's
## mechanism (EditorPane._get_or_create_activity_log + code_edit append) —
## that helper is private to host.notify routing and hard-codes its own entry
## format, so a shared extraction would touch PluginNotifyRouter (out of this
## round's fence). The tab is a DEDICATED "Plugin Builds" one rather than the
## shared "Activity: MCP" tab because _get_or_create_activity_log keys tabs by
## its agent_id string (a distinct key = a distinct tab through the exact same
## code path, zero new mechanism) and build logs are bursty multi-line blocks
## that would drown interleaved tool-call traces.
static func _append_build_activity(plugin_id: String, message: String) -> void:
	var ep = null
	if SingletonObject != null and SingletonObject.get("editor_pane") != null:
		ep = SingletonObject.editor_pane
	if ep == null or not ep.has_method("_get_or_create_activity_log"):
		print("[PluginBuild:%s] %s" % [plugin_id, message])
		return

	var editor = ep._get_or_create_activity_log("Plugin Builds")
	if editor == null or editor.get("code_edit") == null:
		print("[PluginBuild:%s] %s" % [plugin_id, message])
		return

	var t := Time.get_time_dict_from_system()
	var entry := "── %02d:%02d:%02d  build %s ──\n%s\n" % [t.hour, t.minute, t.second, plugin_id, message]
	var ce = editor.code_edit
	if ce.text.is_empty():
		ce.text = entry
	else:
		ce.text += "\n" + entry
	ce.set_caret_line(ce.get_line_count() - 1)


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

## Return an array of tool definition dictionaries suitable for MCP registration.
## Each tool dict has: name, description, input_schema.
func get_tool_definitions() -> Array:
	return [
		_get_plugin_list_tool_def(),
		_get_plugin_install_tool_def(),
		_get_plugin_marketplace_install_tool_def(),
		_get_plugin_remove_tool_def(),
		_get_plugin_start_tool_def(),
		_get_plugin_stop_tool_def(),
		_get_plugin_restart_tool_def(),
		_get_plugin_reload_tool_def(),
		_get_plugin_inspect_tool_def(),
		_get_plugin_state_tool_def(),
		_get_plugin_help_tool_def(),
		_get_plugin_open_panel_tool_def(),
		_get_plugin_build_status_tool_def(),
		_get_plugin_setup_dry_run_tool_def(),
	]


## Dispatch a tool call to the appropriate handler.
## Returns the result dictionary (success or error).
## Note: This function is async to support plugin lifecycle operations that require await.
func handle_tool_call(tool_name: String, args: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_plugin_list":
			return _handle_plugin_list(args)
		"minerva_plugin_install":
			return await _handle_plugin_install(args)
		"minerva_plugin_marketplace_install":
			return await _handle_plugin_marketplace_install(args)
		"minerva_plugin_remove":
			return await _handle_plugin_remove(args)
		"minerva_plugin_start":
			return await _handle_plugin_start(args)
		"minerva_plugin_stop":
			return _handle_plugin_stop(args)
		"minerva_plugin_restart":
			return await _handle_plugin_restart(args)
		"minerva_plugin_reload":
			return await _handle_plugin_reload(args)
		"minerva_plugin_inspect":
			return _handle_plugin_inspect(args)
		"minerva_plugin_state":
			return _handle_plugin_state(args)
		"minerva_plugin_help":
			return _handle_plugin_help(args)
		"minerva_plugin_open_panel":
			return _handle_plugin_open_panel(args)
		"minerva_plugin_build_status":
			return _handle_plugin_build_status(args)
		"minerva_plugin_setup_dry_run":
			return _handle_plugin_setup_dry_run(args)
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


func _get_plugin_marketplace_install_tool_def() -> Dictionary:
	return {
		"name": "minerva_plugin_marketplace_install",
		"description": "Install a plugin from a marketplace tarball URL. Downloads the .tar.gz, verifies SHA256SUMS, extracts to user://plugins/<id>/, then registers via PluginManager (capability grants + skill seeding run, same as side-load). Returns {ok, plugin_id, manifest_path} on success.",
		"input_schema": {
			"type": "object",
			"properties": {
				"url": {
					"type": "string",
					"description": "HTTPS URL of the plugin tarball (.tar.gz). The archive must contain manifest.json, the platform binary, and SHA256SUMS."
				},
				"auto_confirm_skills": {
					"type": "boolean",
					"description": "If true, seed the plugin's skills without showing the interactive confirmation dialog. Pass true from headless/MCP contexts — otherwise a skill-bearing plugin installs but then deadlocks awaiting a dialog. Default: false."
				}
			},
			"required": ["url"]
		}
	}


func _get_plugin_remove_tool_def() -> Dictionary:
	return {
		"name": "minerva_plugin_remove",
		"description": "Remove an installed plugin. If the plugin is running, it will be stopped first. Optionally delete the plugin's data directory.",
		"input_schema": {
			"type": "object",
			"properties": {
				"id": {
					"type": "string",
					"description": "The plugin ID to remove"
				},
				"delete_data": {
					"type": "boolean",
					"description": "If true, also delete the plugin's data directory (user://plugins/data/<id>/). Default: false."
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
		"description": "Stop and then restart a plugin. Use this when a plugin process is misbehaving and needs to be restarted.",
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


func _get_plugin_reload_tool_def() -> Dictionary:
	return {
		"name": "minerva_plugin_reload",
		"description": "Reload a plugin after code changes — kill the current process, recompile/reinitialise, and reconnect. Use this when you have modified the plugin's source files and want Minerva to pick up the new code. Semantically different from restart (process misbehaving) — reload means 'I changed the code, load the new version'.",
		"input_schema": {
			"type": "object",
			"properties": {
				"id": {
					"type": "string",
					"description": "The plugin ID to reload"
				}
			},
			"required": ["id"]
		}
	}


func _get_plugin_state_tool_def() -> Dictionary:
	return {
		"name": "minerva_plugin_state",
		"description": "Get the latest state snapshot for a running plugin. Returns the most recent state the plugin has pushed.",
		"input_schema": {
			"type": "object",
			"properties": {
				"id": {
					"type": "string",
					"description": "The plugin ID to get state for"
				}
			},
			"required": ["id"]
		}
	}


func _get_plugin_help_tool_def() -> Dictionary:
	return {
		"name": "minerva_plugin_help",
		"description": "Get plugin documentation. Without an id (or id='system'), returns the plugin system guide: how to create, install, and use plugins in any language. With a plugin id, returns that plugin's help.md usage documentation. Call this before creating or using an unfamiliar plugin.",
		"input_schema": {
			"type": "object",
			"properties": {
				"id": {
					"type": "string",
					"description": "Plugin ID for plugin-specific help, or 'system' (or omit) for the plugin system guide"
				}
			}
		}
	}


func _get_plugin_inspect_tool_def() -> Dictionary:
	return {
		"name": "minerva_plugin_inspect",
		"description": "Inspect a plugin. LEAN by default (Epoch UX2 station 7): {id, name, version, status, tool_count, capabilities:{requested,granted}, recent_audit_count} — a large plugin's full manifest + tool schemas ran ~87KB and overflowed callers. Pass include:[\"manifest\",\"tools\",\"audit\"] (any subset, mirroring docket_get's include convention) for the full sections: manifest = the parsed manifest summary, tools = every tool definition with schemas (the big one), audit = the recent audit log entries.",
		"input_schema": {
			"type": "object",
			"properties": {
				"id": {
					"type": "string",
					"description": "The plugin ID to inspect"
				},
				"include": {
					"type": "array",
					"items": {"type": "string", "enum": ["manifest", "tools", "audit"]},
					"description": "Detail sections to include beyond the lean summary. Omit for the lean default."
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

	# auto_confirm_skills allows MCP callers (e.g. an LLM that has already
	# surfaced the skill list to the user in chat) to bypass the install dialog.
	# Defaults to false: a UI dialog will be shown and the call awaits user
	# input before returning.
	var auto_confirm := bool(args.get("auto_confirm_skills", false))
	var result = await plugin_manager.install_plugin(manifest_path, auto_confirm)
	return result


func _handle_plugin_marketplace_install(args: Dictionary) -> Dictionary:
	var url = args.get("url", "")
	if not (url is String) or (url as String).is_empty():
		return {"error": "url is required and must be a non-empty String"}

	var plugin_manager = _get_plugin_manager()
	if plugin_manager == null:
		return {"error": "Plugin manager not available"}

	# MarketplaceClient is a Node — instantiated, added to the tree, used,
	# and freed in one shot. Matches the call pattern in
	# MarketplaceBrowseDialog._on_install_pressed.
	# Thread auto_confirm_skills (same contract as minerva_plugin_install): when
	# true, skill seeding runs without the interactive dialog. MCP callers driving
	# a headless Minerva MUST pass true — otherwise a skill-bearing plugin's
	# install succeeds but then deadlocks awaiting a dialog no one can dismiss.
	var auto_confirm := bool(args.get("auto_confirm_skills", false))

	var MarketplaceClientCls = load("res://Scripts/Services/Plugins/MarketplaceClient.gd")
	var mc = MarketplaceClientCls.new()
	var tree = Engine.get_main_loop()
	if tree != null and tree.root != null:
		tree.root.add_child(mc)
	var result: Dictionary = await mc.install_from_url(url, plugin_manager, auto_confirm)
	if mc.is_inside_tree():
		mc.queue_free()
	return result


func _handle_plugin_remove(args: Dictionary) -> Dictionary:
	var id = args.get("id", "")
	if id.is_empty():
		return {"error": "id is required"}

	var delete_data = bool(args.get("delete_data", false))

	var plugin_manager = _get_plugin_manager()
	if plugin_manager == null:
		return {"error": "Plugin manager not available"}

	var result = await plugin_manager.remove_plugin(id, delete_data)
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

	var result = plugin_manager.stop_plugin(id)
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


func _handle_plugin_reload(args: Dictionary) -> Dictionary:
	var id = args.get("id", "")
	if id.is_empty():
		return {"error": "id is required"}

	var plugin_manager = _get_plugin_manager()
	if plugin_manager == null:
		return {"error": "Plugin manager not available"}

	# Reload == restart, but semantically signals "code was changed".
	# Returns status after restart so the caller can confirm the new process is up.
	var result = await plugin_manager.restart_plugin(id)
	if result.has("error"):
		return result

	var status = plugin_manager.get_plugin_status(id)
	return {
		"success": true,
		"message": "Plugin '%s' reloaded successfully." % id,
		"status": status,
	}


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

	# LEAN DEFAULT (Epoch UX2 station 7, docket 019fde56e6c3): the full reply
	# for a large plugin ran ~87KB on one line (74 tool schemas + manifest +
	# audit) and overflowed the calling agent's tool-result budget. The lean
	# summary answers "what is this plugin and is it healthy?"; the heavy
	# sections are opt-in via include (docket_get's include convention).
	var include: Array = args.get("include", []) if args.get("include", []) is Array else []
	var reply := {
		"success": true,
		"id": id,
		"name": def.name,
		"version": def.version,
		"status": status,
		"tool_count": (def.tools as Array).size() if def.tools is Array else 0,
		"capabilities": {
			"requested": requested_caps,
			"granted": granted_caps
		},
		"recent_audit_count": recent_audit_entries.size(),
	}
	if "manifest" in include:
		reply["manifest"] = {
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
		}
	if "tools" in include:
		reply["tools"] = def.tools
	if "audit" in include:
		reply["recent_audit_log"] = recent_audit_entries
	return reply


func _handle_plugin_state(args: Dictionary) -> Dictionary:
	var id = args.get("id", "")
	if id.is_empty():
		return {"error": "id is required"}

	var event_broker = _get_event_broker()
	if event_broker == null:
		return {"error": "Plugin event broker not available"}

	var state = event_broker.get_plugin_state(id)
	return {
		"success": true,
		"id": id,
		"state": state,
		"has_state": not state.is_empty(),
	}


func _handle_plugin_help(args: Dictionary) -> Dictionary:
	var id = args.get("id", "")

	# System guide: no id or id="system"
	if id.is_empty() or id == "system":
		return _get_system_guide()

	var plugin_manager = _get_plugin_manager()
	if plugin_manager == null:
		return {"error": "Plugin manager not available"}

	var db = plugin_manager.get_db()
	var def = db.get_by_id(id)
	if def == null:
		return {"error": "Plugin '%s' not found" % id}

	# Look for help.md in the plugin's directory
	var plugin_dir: String = def.data_directory
	if plugin_dir.begins_with("res://"):
		plugin_dir = ProjectSettings.globalize_path(plugin_dir)

	var help_path: String = plugin_dir.path_join("help.md")
	if not FileAccess.file_exists(help_path):
		# No help file — generate a basic summary from the manifest
		var tool_names: Array[String] = []
		for tool_entry in def.tools:
			tool_names.append(tool_entry.get("name", ""))
		return {
			"success": true,
			"id": id,
			"has_help_file": false,
			"message": "No help.md found for plugin '%s'. Use minerva_plugin_inspect for manifest details." % id,
			"tools": tool_names,
		}

	var content: String = FileAccess.get_file_as_string(help_path)
	return {
		"success": true,
		"id": id,
		"has_help_file": true,
		"help": content,
	}


func _get_system_guide() -> Dictionary:
	# Look for the system guide file in the plugins directory
	var guide_path := "res://plugins/plugin_system_guide.md"
	var global_path := ProjectSettings.globalize_path(guide_path)

	var content: String = ""
	if FileAccess.file_exists(global_path):
		content = FileAccess.get_file_as_string(global_path)
	elif FileAccess.file_exists(guide_path):
		content = FileAccess.get_file_as_string(guide_path)

	if content.is_empty():
		return {
			"success": false,
			"error": "Plugin system guide not found at %s" % guide_path,
		}

	return {
		"success": true,
		"id": "system",
		"help": content,
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


## Return the injected PluginEventBroker reference.
func _get_event_broker() -> Variant:
	return _event_broker


# ---------------------------------------------------------------------------
# Tool: minerva_plugin_open_panel
# ---------------------------------------------------------------------------
# Opens a plugin's godot_scene panel as an editor tab — the MCP equivalent
# of the user clicking the panel entry in the Plugin Manager UI. Needed for
# autonomous testing of panel-side behaviour (broker→signal→panel-handler
# wiring, multi-panel scenarios) where no human is available to click.

func _get_plugin_open_panel_tool_def() -> Dictionary:
	return {
		"name": "minerva_plugin_open_panel",
		"description": "Open a plugin's UI panel as an editor tab — the MCP equivalent of the Plugin Manager's panel-open button. Works for both godot_scene and html (CEF) panels (ui.panels[] in the manifest). Returns {success, plugin_id, panel_name, panel_kind, tab_title} or {error}.",
		"input_schema": {
			"type": "object",
			"properties": {
				"plugin_id": {"type": "string", "description": "Plugin id (e.g. 'scansort', 'codetools')."},
				"panel_name": {"type": "string", "description": "Panel name as declared in the plugin's manifest ui.panels[]. Defaults to the first godot_scene panel, else the first declared panel."},
				"tab_title": {"type": "string", "description": "Optional tab title. Defaults to '<plugin_id> · <panel_name>'."},
			},
			"required": ["plugin_id"],
		},
	}


func _handle_plugin_open_panel(args: Dictionary) -> Dictionary:
	var plugin_id: String = str(args.get("plugin_id", ""))
	if plugin_id.is_empty():
		return {"error": "plugin_id is required"}

	var pm = _get_plugin_manager()
	if pm == null:
		return {"error": "Plugin manager not available"}
	var def = pm.get_db().get_by_id(plugin_id)
	if def == null:
		return {"error": "Unknown plugin: %s" % plugin_id}

	# Resolve panel_name: caller-provided OR first godot_scene panel (back-compat),
	# else the first declared panel of any kind (so an html-only plugin like
	# codetools opens with no panel_name). Bug 019e9e351353.
	var panel_name: String = str(args.get("panel_name", ""))
	if panel_name.is_empty():
		for pd in def.ui_panels:
			if pd is Dictionary and pd.get("kind", "") == "godot_scene":
				panel_name = str(pd.get("name", ""))
				break
		if panel_name.is_empty():
			for pd in def.ui_panels:
				if pd is Dictionary and str(pd.get("name", "")) != "":
					panel_name = str(pd.get("name", ""))
					break
	if panel_name.is_empty():
		return {"error": "Plugin '%s' has no UI panels" % plugin_id}

	# Resolve the panel kind.
	var panel_kind: String = ""
	for pd in def.ui_panels:
		if pd is Dictionary and pd.get("name", "") == panel_name:
			panel_kind = str(pd.get("kind", ""))
			break
	if panel_kind.is_empty():
		return {"error": "Panel '%s' not found on plugin '%s'" % [panel_name, plugin_id]}

	var tab_title: String = str(args.get("tab_title", ""))
	if tab_title.is_empty():
		tab_title = "%s · %s" % [plugin_id, panel_name]

	if SingletonObject == null or SingletonObject.editor_pane == null:
		return {"error": "EditorPane unavailable"}

	match panel_kind:
		"godot_scene":
			var ep = SingletonObject.editor_pane
			if not ep.has_method("add_plugin_scene_editor"):
				return {"error": "EditorPane lacks add_plugin_scene_editor"}
			var editor = ep.add_plugin_scene_editor(plugin_id, panel_name, null, tab_title)
			if editor == null:
				return {"error": "add_plugin_scene_editor returned null"}
		"html":
			# Route html (CEF) panels through the same path the UI uses
			# (File→New → _open_plugin_panel_for_editor_item): resolves the html
			# source, registers the webview broker, injects __MINERVA_PANEL.
			# Bug 019e9e351353.
			if not SingletonObject.has_method("_open_plugin_panel_for_editor_item"):
				return {"error": "html panel open path unavailable"}
			SingletonObject._open_plugin_panel_for_editor_item(plugin_id, panel_name, tab_title)
		_:
			return {"error": "Panel '%s' on plugin '%s' has unsupported kind '%s'" % [panel_name, plugin_id, panel_kind]}

	return {
		"success": true,
		"plugin_id": plugin_id,
		"panel_name": panel_name,
		"panel_kind": panel_kind,
		"tab_title": tab_title,
	}


# ---------------------------------------------------------------------------
# Tools: minerva_plugin_build_status / minerva_plugin_setup_dry_run
# ---------------------------------------------------------------------------
# G4.3 (DCR 019f69428fa0, Docs/design/plugin-setup-pipeline.md §2/§3): expose
# the manifest-install setup pipeline's state machine to agents so an install
# can be polled — state name, live step while S_BUILDING, the full §2/§3
# failure envelope (incl. the `failures` array and exec_denied detail), and
# the last build log — all without filesystem access. Plus a side-effect-free
# dry-run render of any manifest's setup plan.

func _get_plugin_build_status_tool_def() -> Dictionary:
	return {
		"name": "minerva_plugin_build_status",
		"description": "Get a plugin's manifest-install setup-pipeline state. Returns state/state_name (BUILDING, BUILD_FAILED, NEEDS_BINARY, or a normal lifecycle state), live progress {step_index, step_count, step_type} while building, the full failure envelope on BUILD_FAILED/NEEDS_BINARY (including the per-tool `failures` array and `detail: exec_denied` when the user declined an exec step), and the step-by-step log of the most recent build. Poll this after minerva_plugin_install returns {building: true}.",
		"input_schema": {
			"type": "object",
			"properties": {
				"id": {
					"type": "string",
					"description": "The plugin ID to query"
				}
			},
			"required": ["id"]
		}
	}


func _get_plugin_setup_dry_run_tool_def() -> Dictionary:
	return {
		"name": "minerva_plugin_setup_dry_run",
		"description": "Render a plugin's `setup` stanza as a deterministic dry-run plan (the exact argv each step would execute) WITHOUT running anything — no subprocesses, no filesystem writes, no toolchain probing. Pass either the id of an installed plugin or the manifest_path of an installable manifest.json. Tool names in the rendered argv appear unresolved (e.g. 'go' rather than an absolute path) because no probe runs.",
		"input_schema": {
			"type": "object",
			"properties": {
				"id": {
					"type": "string",
					"description": "Installed plugin ID whose setup plan to render (mutually exclusive with manifest_path)"
				},
				"manifest_path": {
					"type": "string",
					"description": "Absolute path to a manifest.json to render (used when the plugin is not installed yet)"
				}
			}
		}
	}


func _handle_plugin_build_status(args: Dictionary) -> Dictionary:
	var id: String = str(args.get("id", ""))
	if id.is_empty():
		return {"error": "id is required"}

	var plugin_manager = _get_plugin_manager()
	if plugin_manager == null:
		return {"error": "Plugin manager not available"}

	var status: Dictionary = plugin_manager.get_plugin_status(id)
	if status.has("error"):
		return status

	var result: Dictionary = {
		"success": true,
		"id": id,
		"state": status.get("state", -1),
		"state_name": status.get("state_name", "UNKNOWN"),
		"building": int(status.get("state", -1)) == plugin_manager.S_BUILDING,
	}

	var progress: Dictionary = plugin_manager.get_build_progress(id)
	if not progress.is_empty():
		result["progress"] = progress

	var envelope: Dictionary = plugin_manager.get_setup_envelope(id)
	if not envelope.is_empty():
		result["envelope"] = envelope

	result["build_log"] = plugin_manager.get_build_log(id)
	return result


func _handle_plugin_setup_dry_run(args: Dictionary) -> Dictionary:
	var id: String = str(args.get("id", ""))
	var manifest_path: String = str(args.get("manifest_path", ""))
	if id.is_empty() and manifest_path.is_empty():
		return {"error": "Provide either id (installed plugin) or manifest_path"}

	var def = null  # PluginDefinition
	if not id.is_empty():
		var plugin_manager = _get_plugin_manager()
		if plugin_manager == null:
			return {"error": "Plugin manager not available"}
		def = plugin_manager.get_db().get_by_id(id)
		if def == null:
			return {"error": "Plugin '%s' not found" % id}
	else:
		if not FileAccess.file_exists(manifest_path):
			return {"error": "Manifest not found: %s" % manifest_path}
		var PluginDef = load("res://Scripts/Services/Plugins/PluginDefinition.gd")
		def = PluginDef.from_manifest(manifest_path)
		if def == null:
			return {"error": "Failed to parse manifest: %s" % manifest_path}

	if def.setup.is_empty():
		return {
			"success": true,
			"id": def.id,
			"has_setup": false,
			"plan": "(no setup stanza — plugin ships no native build step)",
		}

	var plugin_dir: String = ProjectSettings.globalize_path(def.data_directory)
	# tool_paths deliberately empty: SetupDryRun is contract-bound to be
	# side-effect-free (no probing), so tool names render unresolved.
	var plan: String = SetupDryRun.render(def.setup, plugin_dir, {})
	return {
		"success": true,
		"id": def.id,
		"has_setup": true,
		"plan": plan,
	}

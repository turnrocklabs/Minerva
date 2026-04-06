class_name MCPDocketTools
extends MCPToolModule
## MCP tool module for Docket integration.
## Delegates to DocketManager's ToolRegistry for all 30+ docket tools.
## Tools are registered with a "minerva_" prefix (e.g. docket_create → minerva_docket_create)
## so they pass the HTTP server's namespace filter. The prefix is stripped before
## delegating to DocketManager.call_tool() which expects the original names.

const DOCKET_PREFIX := "minerva_"

var _tool_names: Array[String] = []


func get_tool_names() -> Array[String]:
	# If tools weren't registered at startup (DocketManager was null), try now.
	if _tool_names.size() <= 1 and SingletonObject.docket_manager:
		register_tools()
	return _tool_names


func register_tools() -> void:
	var dm: DocketManager = SingletonObject.docket_manager
	if not dm:
		push_warning("MCPDocketTools: DocketManager not available, skipping registration")
		return
	# Guard against double-registration (lazy init may call this again)
	if _tool_names.size() > 1:
		return
	var definitions := dm.get_tool_definitions()
	for def: Dictionary in definitions:
		var docket_name: String = def.get("name", "")
		if docket_name.is_empty():
			continue
		var minerva_name: String = DOCKET_PREFIX + docket_name
		_tool_names.append(minerva_name)
		var desc: String = def.get("description", "")
		var schema: Dictionary = def.get("inputSchema", {})
		var category := _categorize(docket_name)
		server._register_tool(minerva_name, desc, schema, category)

	# Register Minerva-specific docket UI tools (discoverable via search)
	if "minerva_open_docket" not in _tool_names:
		_tool_names.append("minerva_open_docket")
	server._register_tool("minerva_open_docket",
		"Open a docket editor tab in Minerva. Optionally open a specific project docket by path.",
		{
			"type": "object",
			"properties": {
				"name": {"type": "string", "description": "Tab name for the docket editor. Default: 'Docket'"},
				"dct_path": {"type": "string", "description": "Optional: path to a .dct file to open."}
			},
		}
	, "docket")


## Strip the minerva_ prefix and delegate to DocketManager.
func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	if tool_name == "minerva_open_docket":
		return _open_docket_editor(arguments)
	var dm: DocketManager = SingletonObject.docket_manager
	if not dm:
		return MCPToolUtils.error("DocketManager not available")
	# Strip minerva_ prefix to get the original docket tool name
	var docket_name: String = tool_name.trim_prefix(DOCKET_PREFIX)

	# Policy protection: operations that decrease enforcement require human approval
	if await _requires_policy_approval(docket_name, arguments, dm):
		var approved := await _request_human_approval(docket_name, arguments, dm)
		if not approved:
			return MCPToolUtils.error("Policy modification denied — human approval required")

	var result := dm.call_tool(docket_name, arguments)
	if result.has("error"):
		return MCPToolUtils.error(str(result["error"]))

	# Cache invalidation: reload policy engine when a policy item is mutated
	if docket_name in ["docket_create", "docket_update", "docket_transition"]:
		_maybe_reload_policy(docket_name, arguments, result, dm)

	return result


func _open_docket_editor(args: Dictionary) -> Dictionary:
	var dct_path: String = args.get("dct_path", "")

	# Open project docket if path provided
	if not dct_path.is_empty():
		var dm: DocketManager = SingletonObject.docket_manager
		if dm:
			var open_result := dm.open_project(dct_path)
			if open_result.has("error"):
				return MCPToolUtils.error(str(open_result["error"]))

	SingletonObject.open_docket_tab()
	return {"success": true, "message": "Docket tab opened."}


## Reload the policy engine if the mutated item is a policy item.
## For docket_create the result includes the item type directly.
## For docket_update/docket_transition we fetch the item to check its type.
func _maybe_reload_policy(tool_name: String, arguments: Dictionary, result: Dictionary, dm: DocketManager) -> void:
	var item_type: String = ""

	var project: String = str(arguments.get("project", ""))

	if tool_name == "docket_create":
		item_type = result.get("type", "")
	else:
		# docket_update / docket_transition — look up the item to get its type
		var item_id: String = str(arguments.get("id", ""))
		if item_id.is_empty():
			return
		var get_args := {"id": item_id, "include": []}
		if not project.is_empty():
			get_args["project"] = project
		var item_result: Dictionary = dm.call_tool("docket_get", get_args)
		if item_result.has("error"):
			return
		item_type = str(item_result.get("type", ""))

	if item_type == "policy" and server and server.policy_engine:
		server.policy_engine.reload()


## Check if this operation requires human approval.
## Policy items have asymmetric gating: increasing enforcement is free,
## decreasing enforcement (suspend, archive, delete, edit rules) requires human approval.
func _requires_policy_approval(docket_name: String, arguments: Dictionary, dm: DocketManager) -> bool:
	# Only these operations can decrease enforcement
	if docket_name not in ["docket_transition", "docket_update", "docket_delete"]:
		return false

	# Look up the item to check if it's a policy
	var item_id: String = str(arguments.get("id", ""))
	if item_id.is_empty():
		return false
	var project: String = str(arguments.get("project", ""))
	var get_args := {"id": item_id, "include": []}
	if not project.is_empty():
		get_args["project"] = project
	var item_result: Dictionary = dm.call_tool("docket_get", get_args)
	if item_result.has("error"):
		return false
	if str(item_result.get("type", "")) != "policy":
		return false

	# For transitions: only downgrade transitions need approval
	if docket_name == "docket_transition":
		var target_status: String = str(arguments.get("to", ""))
		# Increasing enforcement: draft → proposed → active (no approval needed)
		if target_status in ["proposed", "active"]:
			return false
		# Decreasing enforcement: → suspended, → archived (approval needed)
		return true

	# docket_update on a policy: approval needed if description is being changed
	if docket_name == "docket_update":
		return arguments.has("description")

	# docket_delete on a policy: always needs approval
	if docket_name == "docket_delete":
		return true

	return false


## Show a Godot ConfirmationDialog and await the human's response.
## The dialog runs in the UI thread; the agent cannot bypass it.
func _request_human_approval(docket_name: String, arguments: Dictionary, dm: DocketManager) -> bool:
	var item_id: String = str(arguments.get("id", ""))
	var item_title := item_id

	# Try to get the policy title for a friendlier message
	var get_args := {"id": item_id, "include": []}
	var project: String = str(arguments.get("project", ""))
	if not project.is_empty():
		get_args["project"] = project
	var item_result: Dictionary = dm.call_tool("docket_get", get_args)
	if not item_result.has("error"):
		item_title = str(item_result.get("title", item_id))

	# Build the dialog message
	var action_desc: String
	match docket_name:
		"docket_transition":
			action_desc = "transition policy to '%s'" % str(arguments.get("to", "?"))
		"docket_update":
			action_desc = "modify policy rule content"
		"docket_delete":
			action_desc = "permanently delete policy"
		_:
			action_desc = "modify policy"

	var dialog := ConfirmationDialog.new()
	dialog.title = "Policy Modification — Human Approval Required"
	dialog.dialog_text = "An agent is requesting to %s:\n\n\"%s\"\n\nThis will decrease policy enforcement.\nOnly approve if you intended this change." % [action_desc, item_title]
	dialog.ok_button_text = "Approve"
	dialog.cancel_button_text = "Deny"
	dialog.initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_PRIMARY_SCREEN
	dialog.size = Vector2i(500, 200)

	# Add to scene tree and show
	var tree := Engine.get_main_loop()
	if tree == null or not tree is SceneTree:
		# Headless mode — deny by default (no UI to approve)
		return false
	(tree as SceneTree).root.add_child(dialog)
	dialog.popup_centered()

	# Await human response using Minerva's standard dialog pattern
	var result := [false]
	var done := [false]
	dialog.confirmed.connect(func():
		result[0] = true
		done[0] = true
	)
	dialog.canceled.connect(func():
		result[0] = false
		done[0] = true
	)
	while not done[0]:
		await (tree as SceneTree).process_frame

	dialog.queue_free()
	return result[0]


static func _categorize(tool_name: String) -> String:
	if tool_name.begins_with("docket_skill"):
		return "docket-skills"
	if tool_name.begins_with("docket_hint") or tool_name.begins_with("docket_quality"):
		return "docket-knowledge"
	if tool_name.begins_with("docket_project"):
		return "docket-projects"
	if tool_name.begins_with("docket_secret"):
		return "docket-vault"
	return "docket"

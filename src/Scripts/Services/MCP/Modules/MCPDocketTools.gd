class_name MCPDocketTools
extends MCPToolModule
## MCP tool module for Docket integration.
## Delegates to DocketManager's ToolRegistry for all 30+ docket tools.
## Skills (docket_skill_list, docket_skill_get) are always available via master docket.
## Other tools require a project docket to be loaded.

var _tool_names: Array[String] = []


func get_tool_names() -> Array[String]:
	return _tool_names


## Tools that are auto-activated (always available without search).
## Everything else is discoverable via minerva_tool_search.
const AUTO_ACTIVATE := ["docket_skill_list", "docket_skill_get", "minerva_open_docket"]


func register_tools() -> void:
	var dm: DocketManager = SingletonObject.docket_manager
	if not dm:
		push_warning("MCPDocketTools: DocketManager not available, skipping registration")
		return
	var definitions := dm.get_tool_definitions()
	for def: Dictionary in definitions:
		var tool_name: String = def.get("name", "")
		if tool_name.is_empty():
			continue
		_tool_names.append(tool_name)
		var desc: String = def.get("description", "")
		var schema: Dictionary = def.get("inputSchema", {})
		var category := _categorize(tool_name)
		# Register in search index (all tools discoverable)
		server._register_tool(tool_name, desc, schema, category)
		# Auto-activate only key tools
		if tool_name in AUTO_ACTIVATE:
			server.tool_budget_manager.activate_tool(tool_name, {"name": tool_name, "description": desc, "input_schema": schema})

	# Register Minerva-specific docket UI tools
	var open_desc := "Open a docket editor tab in Minerva. Optionally open a specific project docket by path."
	var open_schema := {
		"type": "object",
		"properties": {
			"name": {
				"type": "string",
				"description": "Tab name for the docket editor. Default: 'Docket'"
			},
			"dct_path": {
				"type": "string",
				"description": "Optional: path to a .dct file to open. If not provided, shows all loaded projects."
			}
		},
	}
	_tool_names.append("minerva_open_docket")
	server._register_tool("minerva_open_docket", open_desc, open_schema, "docket")
	server.tool_budget_manager.activate_tool("minerva_open_docket", {"name": "minerva_open_docket", "description": open_desc, "input_schema": open_schema})


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	if tool_name == "minerva_open_docket":
		return _open_docket_editor(arguments)
	var dm: DocketManager = SingletonObject.docket_manager
	if not dm:
		return MCPToolUtils.error("DocketManager not available")
	var result := dm.call_tool(tool_name, arguments)
	if result.has("error"):
		return MCPToolUtils.error(str(result["error"]))
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

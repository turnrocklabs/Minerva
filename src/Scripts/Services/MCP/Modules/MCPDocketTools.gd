class_name MCPDocketTools
extends MCPToolModule
## MCP tool module for Docket integration.
## Delegates to DocketManager's ToolRegistry for all 30+ docket tools.
## Skills (docket_skill_list, docket_skill_get) are always available via master docket.
## Other tools require a project docket to be loaded.

var _tool_names: Array[String] = []


func get_tool_names() -> Array[String]:
	return _tool_names


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
		# Categorize tools for Minerva's tool set system
		var category := _categorize(tool_name)
		server._register_tool(tool_name, desc, schema, category)


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	var dm: DocketManager = SingletonObject.docket_manager
	if not dm:
		return MCPToolUtils.error("DocketManager not available")
	var result := dm.call_tool(tool_name, arguments)
	if result.has("error"):
		return MCPToolUtils.error(str(result["error"]))
	return result


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

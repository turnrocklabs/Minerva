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


## Strip the minerva_ prefix and delegate to DocketManager.
func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	var dm: DocketManager = SingletonObject.docket_manager
	if not dm:
		return MCPToolUtils.error("DocketManager not available")
	# Strip minerva_ prefix to get the original docket tool name
	var docket_name: String = tool_name.trim_prefix(DOCKET_PREFIX)

	# Policy protection: operations that decrease enforcement require human approval
	if _requires_policy_approval(docket_name, arguments, dm):
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


## Check if this operation requires human approval (PolicyApproval): it
## would lower the enforcement of a policy item. An item that cannot be looked
## up is taken as not a policy.
func _requires_policy_approval(docket_name: String, arguments: Dictionary, dm: DocketManager) -> bool:
	if not docket_name in PolicyApproval.TOOLS:
		return false
	var item_id: String = str(arguments.get("id", ""))
	if item_id.is_empty():
		return false
	var item_result: Dictionary = dm.call_tool("docket_get", _get_args(arguments))
	if item_result.has("error"):
		return false
	return PolicyApproval.lowers_enforcement(docket_name, arguments, item_result)


## Asks a person to approve the change (PolicyApproval.request), naming the
## policy by its title when it can be read.
func _request_human_approval(docket_name: String, arguments: Dictionary, dm: DocketManager) -> bool:
	var item_title: String = str(arguments.get("id", ""))
	var item_result: Dictionary = dm.call_tool("docket_get", _get_args(arguments))
	if not item_result.has("error"):
		item_title = str(item_result.get("title", item_title))
	return await PolicyApproval.request(docket_name, arguments, item_title)


static func _get_args(arguments: Dictionary) -> Dictionary:
	var get_args := {"id": str(arguments.get("id", "")), "include": []}
	var project: String = str(arguments.get("project", ""))
	if not project.is_empty():
		get_args["project"] = project
	return get_args


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

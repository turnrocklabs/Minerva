extends SceneTree
## Exercises the captured registered schemas used by the CAD skill without
## starting a plugin process or touching a live document.

const FIXTURE := "res://test/fixtures/cad_modeling_tool_deps.json"

class ToolHistory extends RefCounted:
	var DisabledTools: Array[String] = []
	var ActiveSkills: Array[String] = []
	var AgentDefinitionId := ""
	var StaticToolMode := false


class RecoveryManager extends RefCounted:
	var manager
	func _init(real_manager) -> void:
		manager = real_manager
	func execute_tool(_name: String, _arguments: Dictionary,
			_caller_chat_id: String) -> Dictionary:
		return {"success": false, "error": "structured document",
			"error_code": "operation_unsupported", "retryable": false,
			"next_tool": "minerva_doc_write",
			"document_identity": {"document_id": "fixture-document"}}
	func activate_tools_for_workflow(names: Array[String], history = null) -> Dictionary:
		return manager.activate_tools_for_workflow(names, history)

var passed := 0
var failed := 0


func _initialize() -> void:
	_run.call_deferred()


func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)


func _tool_names(schemas: Array[Dictionary]) -> Array[String]:
	var names: Array[String] = []
	for schema: Dictionary in schemas:
		names.append(str(schema.get("name", schema.get("function", {}).get("name", ""))))
	return names


func _fixture_tool_set(name: String) -> String:
	if name.begins_with("minerva_cad_"):
		return "cad"
	if name.begins_with("minerva_doc_"):
		return "documents"
	return "editor"


func _register_fixture_tools(manager, server, fixture: Dictionary) -> void:
	for descriptor: Dictionary in fixture.get("tools", []):
		var definition = MCPToolDefinition.from_dict(descriptor, "minerva")
		definition.tool_set = _fixture_tool_set(definition.name)
		manager.tool_registry[definition.name] = definition
		var consumer_schema: Dictionary = definition.to_anthropic_format()
		server.tool_search_index.register_tool(definition.name,
			definition.description, consumer_schema, definition.tool_set)


func _run() -> void:
	await process_frame
	var manager = SingletonObject.get_mcp_manager()
	check("MCP manager is available", manager != null)
	if manager == null:
		quit(1)
		return
	manager.connect_minerva_server()
	var server = manager.minerva_server
	server.auto_tool_management = true
	server.tool_budget_manager.set_budget(10000)
	server.tool_budget_manager.set_max_idle_turns(0)
	server.tool_budget_manager.reset()

	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(FIXTURE))
	_register_fixture_tools(manager, server, fixture)
	var skill_module = null
	for module in server._modules:
		if module is MCPSkillTools:
			skill_module = module
			break
	check("real skill module is registered", skill_module != null)
	if skill_module == null:
		quit(1)
		return

	var activation: Dictionary = skill_module._activate_dependencies(fixture.tool_deps)
	check("all real CAD dependency schemas fit the calibrated default budget",
		activation.activated_tools.size() == fixture.tool_deps.size()
		and activation.unavailable_tools.is_empty()
		and activation.skipped_tools.is_empty()
		and server.tool_budget_manager.get_token_usage() <= 10000)

	var history := ToolHistory.new()
	var initial_tools: Array[Dictionary] = manager.get_tools_for_chat(history)
	var initial_names := _tool_names(initial_tools)
	check("model-facing tools retain the CAD document workflow",
		"minerva_doc_read" in initial_names and "minerva_doc_write" in initial_names
		and "minerva_doc_edit" in initial_names)

	var editor_search: Dictionary = server._tool_search({
		"query": "list editors", "category": "editor", "limit": 5})
	var after_search: Array[Dictionary] = manager.get_tools_for_chat(history)
	var after_names := _tool_names(after_search)
	check("subsequent editor discovery preserves read/write and becomes callable",
		"minerva_list_editors" in editor_search.get("activated", [])
		and "minerva_list_editors" in after_names
		and "minerva_doc_read" in after_names and "minerva_doc_write" in after_names)

	# Let the initial skill lease expire, then exercise the permanent-refusal
	# seam that explicitly restores its advertised read/write recovery path.
	manager.get_tools_for_chat(history)
	var ChatPaneScript = load("res://Scripts/UI/Views/ChatPane.gd")
	var Guard = load("res://Scripts/Services/MCP/MCPUnsupportedOperationGuard.gd")
	var recovery: Dictionary = await ChatPaneScript._execute_with_document_recovery(
		RecoveryManager.new(manager), Guard.new(), "minerva_doc_edit", {},
		{"document_id": "fixture-document"}, 0, "fixture-chat", history)
	var recovery_names := _tool_names(manager.get_tools_for_chat(history))
	check("advertised document recovery is present in the next provider lookup",
		recovery.get("recovery_available", false)
		and recovery.get("recovery_tools", []) == ["minerva_doc_read", "minerva_doc_write"]
		and "minerva_doc_read" in recovery_names
		and "minerva_doc_write" in recovery_names)

	var optimization_result: Dictionary = skill_module._apply_skill_optimization(
		{"tool_budget": 1}, MCPExecutionContext.create("internal", "fixture-chat"))
	check("skill optimization reports a budget reduction blocked by its leased workflow",
		(optimization_result.applied as Dictionary).is_empty()
		and (optimization_result.failures as Array).size() == 1
		and not optimization_result.failures[0].applied
		and server.tool_budget_manager.get_budget() == 10000)

	var document_recovery_tools: Array[String] = [
		"minerva_doc_read", "minerva_doc_write"]
	server._enabled_tool_sets = ["cad"]
	var excluded_recovery: Dictionary = manager.activate_tools_for_workflow(
		document_recovery_tools, history)
	var excluded_names := _tool_names(manager.get_tools_for_chat(history))
	check("recovery eligibility matches provider-facing tool-set filtering",
		not excluded_recovery.available and excluded_recovery.unavailable.size() == 2
		and "minerva_doc_read" not in excluded_names
		and "minerva_doc_write" not in excluded_names)
	server._enabled_tool_sets = []

	var normal_budget_manager = server.tool_budget_manager
	server.tool_budget_manager = ToolBudgetManager.new(1)
	history.StaticToolMode = true
	var static_recovery: Dictionary = manager.activate_tools_for_workflow(
		document_recovery_tools, history)
	var static_names := _tool_names(manager.get_tools_for_chat(history))
	check("static tool mode bypasses dynamic budget admission consistently",
		static_recovery.available and static_recovery.unavailable.is_empty()
		and "minerva_doc_read" in static_names and "minerva_doc_write" in static_names
		and server.tool_budget_manager.get_token_usage() == 0)
	history.StaticToolMode = false
	var refused: Dictionary = skill_module._activate_dependencies(fixture.tool_deps)
	check("constrained skill activation reports every registered dependency unavailable",
		refused.activated_tools.is_empty() and refused.skipped_tools.is_empty()
		and refused.unavailable_tools.size() == fixture.tool_deps.size()
		and server.tool_budget_manager.get_token_usage() <= 1)
	server.tool_budget_manager = normal_budget_manager

	print("=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)

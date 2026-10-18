class_name PluginReadiness
extends RefCounted
## One bounded, event-driven admission before dispatch; never retries a mutation.
var manager: PluginManager
var tools: PluginToolRegistry

func _init(plugin_manager: PluginManager, registry: PluginToolRegistry) -> void:
	manager = plugin_manager
	tools = registry

func _failure(message: String) -> Dictionary:
	return {"ok": false, "success": false, "error": message, "errors": [message]}

func _snapshot(provider: String, tool: String, context: MCPExecutionContext) -> Dictionary:
	if context.is_stopped():
		return _failure(str(context.stopped_result().error))
	if not is_instance_valid(manager):
		return _failure("provider_unavailable: " + provider)
	var status := manager.get_plugin_status(provider)
	if status.has("error"):
		return _failure("provider_not_found: " + provider)
	if status.get("ready", false):
		var issue := manager.dependency_contract_issue(context.plugin_id, tool, provider)
		if not issue.is_empty():
			return _failure(issue)
		if not tool.is_empty() and (tools == null or tools.get_tool_owner(tool) != provider):
			return _failure("provider_tool_unavailable: " + tool)
		return {"ok": true}
	var notice: String = status.get("notice", "")
	if notice.begins_with("provider tools unavailable:"):
		return _failure(notice)
	if status.get("state") not in [PluginDefinition.State.STARTING, PluginDefinition.State.RUNNING]:
		return _failure("provider_stopped: " + provider)
	return {}

func wait_for_provider(provider: String, timeout_seconds: float = 30.0,
		context: MCPExecutionContext = null, tool: String = "") -> Dictionary:
	if context == null:
		context = MCPExecutionContext.create("plugin_readiness")
	var initial := _snapshot(provider, tool, context)
	if not initial.is_empty():
		return initial
	if manager.get_tree() == null:
		return _failure("provider_unavailable: " + provider)
	var pending := MCPExecutionContext.Completion.new()
	var refresh := func(id: String) -> void:
		if id == provider:
			var value := _snapshot(provider, tool, context)
			if not value.is_empty():
				pending.finish(value)
	var stopped := func(id: String) -> void:
		if id == provider:
			pending.finish(_failure("provider_stopped: " + provider))
	var crashed := func(id: String) -> void:
		if id == provider:
			pending.finish(_failure("provider_crashed: " + provider))
	var cancelled := func() -> void: pending.finish(_failure(str(context.stopped_result().error)))
	var unavailable := func() -> void: pending.finish(_failure("provider_unavailable: " + provider))
	var expired := func() -> void: pending.finish(_failure("provider_ready_timeout: " + provider))
	manager.plugin_ready.connect(refresh)
	manager.plugin_status_changed.connect(refresh)
	manager.plugin_stopped.connect(stopped)
	manager.plugin_crashed.connect(crashed)
	manager.tree_exiting.connect(unavailable)
	context.lifetime.cancelled.connect(cancelled)
	var timer := Timer.new()
	timer.one_shot = true
	timer.ignore_time_scale = true
	timer.process_mode = Node.PROCESS_MODE_ALWAYS
	manager.add_child(timer)
	timer.timeout.connect(expired)
	timer.start(maxf(0.001, context.remaining_seconds(minf(timeout_seconds, 30.0))))
	refresh.call(provider)
	if not pending.done:
		await pending.finished
	if is_instance_valid(manager):
		manager.plugin_ready.disconnect(refresh)
		manager.plugin_status_changed.disconnect(refresh)
		manager.plugin_stopped.disconnect(stopped)
		manager.plugin_crashed.disconnect(crashed)
		manager.tree_exiting.disconnect(unavailable)
	context.lifetime.cancelled.disconnect(cancelled)
	if is_instance_valid(timer):
		timer.stop()
		timer.queue_free()
	return pending.result

func wait_for_tool(tool: String, context: MCPExecutionContext) -> Dictionary:
	if context.is_stopped():
		return _failure(str(context.stopped_result().error))
	if not is_instance_valid(manager):
		return _failure("plugin_manager_not_available")
	var provider := tools.get_tool_owner(tool) if tools != null else ""
	if provider.is_empty():
		var database: PluginDB = manager.get_db()
		var definitions: Array[PluginDefinition] = database.get_all()
		for definition: PluginDefinition in definitions:
			if tool.begins_with("minerva_" + definition.id + "_"):
				if not provider.is_empty():
					return _failure("ambiguous_provider_tool: " + tool)
				provider = definition.id
	if provider.is_empty():
		return {"ok": true}
	return await wait_for_provider(provider, 30.0, context, tool)

func _document_owner(handoff: PluginEditorHandoff, action: String, args: Dictionary) -> String:
	if action == "create":
		return str(args.get("plugin_id", ""))
	var path: Variant = args.get("path")
	if path is String and handoff.registry != null:
		var file_path: String = path
		return str(handoff.registry.resolve_file("." + file_path.get_extension()).get("plugin_id", ""))
	return ""

func handoff_when_ready(handoff: PluginEditorHandoff, action: String, args: Dictionary,
		context: MCPExecutionContext = null) -> Dictionary:
	if context != null and context.is_stopped():
		return _failure(str(context.stopped_result().error))
	var provider := _document_owner(handoff, action, args)
	if not provider.is_empty():
		var admitted := await wait_for_provider(provider, 30.0, context)
		if not admitted.get("ok", false):
			return admitted
		if provider != _document_owner(handoff, action, args):
			return _failure("document_owner_changed: " + provider)
	if not is_instance_valid(handoff.pane):
		return _failure("editor_pane not available")
	return handoff.handoff(action, args)

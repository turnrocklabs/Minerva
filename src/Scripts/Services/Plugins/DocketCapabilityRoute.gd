extends RefCounted
## Plugin secrets use the canonical hosted master through normal server admission.
const ExecutionContext = preload("res://Scripts/Services/MCP/MCPExecutionContext.gd")

static func secrets(server: MinervaMCPServer, plugin_id: String, capability: String, args: Dictionary,
		context: ExecutionContext) -> Dictionary:
	if context == null:
		context = ExecutionContext.create("plugin").for_plugin(plugin_id)
	var rest: String = capability.substr("secrets:".length())
	var sep: int = rest.find(":")
	if sep == -1:
		return PluginErrors.schema_validation_failed(plugin_id,
			"secrets capability must be 'secrets:<op>:<handle>' (op=get|set|delete)")

	var op: String = rest.substr(0, sep)
	var handle_suffix: String = rest.substr(sep + 1)
	if handle_suffix.is_empty():
		return PluginErrors.schema_validation_failed(plugin_id,
			"secrets capability requires a non-empty handle")

	var minerva_server = server
	if minerva_server == null:
		return PluginErrors.schema_validation_failed(plugin_id,
			"secrets: MinervaMCPServer is not available")

	# Namespace under "plugin/<id>/" so plugins cannot reach other plugins' handles.
	var docket_handle: String = "plugin/%s/%s" % [plugin_id, handle_suffix]
	var tool_args: Dictionary = {"handle": docket_handle}
	var tool_name: String

	match op:
		"get":
			tool_name = "minerva_docket_secret_get"
		"set":
			if not args.has("value"):
				return PluginErrors.schema_validation_failed(plugin_id,
					"secrets:set requires args.value")
			tool_args["value"] = str(args["value"])
			tool_name = "minerva_docket_secret_set"
		"delete":
			tool_name = "minerva_docket_secret_delete"
		_:
			return PluginErrors.schema_validation_failed(plugin_id,
				"Unknown secrets op '%s' (expected get|set|delete)" % op)


	var result: Dictionary = await _call(minerva_server, tool_name, tool_args, context)

	if result.has("error") or result.get("success", true) == false:
		# Distinguish "secret not found" (a normal "not yet set" state for plugins)
		# from real errors. The vault returns a string; sniff its prefix.
		var err: String = str(result.get("error", result.get("error_message", "Docket secret call failed")))
		if op == "get" and err.begins_with("Secret not found"):
			return PluginErrors.success({"handle": handle_suffix, "value": null, "exists": false})
		var failure := {
			"success": false,
			"error_code": "secrets_error",
			"error_message": err,
			"plugin_id": plugin_id,
			"operation": op,
			"handle": handle_suffix,
		}

		for field in ["sent", "stale", "unconfirmed", "outcome", "recovery"]:
			if result.has(field):
				failure[field] = result[field]
		return failure

	# Strip the namespace prefix from the returned handle so the plugin only
	# sees its own handle name, not the internal docket-side path.
	if result.has("handle"):
		var returned_handle: String = str(result["handle"])
		var prefix: String = "plugin/%s/" % plugin_id
		if returned_handle.begins_with(prefix):
			result["handle"] = returned_handle.substr(prefix.length())

	return PluginErrors.success(result)


static func _call(server: MinervaMCPServer, tool: String, arguments: Dictionary,
		context: ExecutionContext) -> Dictionary:
	var host: DocketHost = SingletonObject.docket_host
	if host == null:
		return {"error": "Docket is unavailable"}
	var target: Dictionary = await host.skill_target("")
	if target.get("status", "") != "ok":
		return {"error": target.get("message", "Docket master is unavailable")}
	if context.is_stopped():
		return context.stopped_result()
	arguments["project"] = str(target.project.name)
	var definition = server.mcp_manager.tool_registry.get(tool)
	if definition != null:
		arguments = MCPToolUtils.coerce_args_to_schema(arguments, definition.input_schema)
	var binding := {"tool": tool.trim_prefix("minerva_"),
		"arguments": arguments.duplicate(true), "target": target}
	var writing := not tool.ends_with("_get")
	var was_sent: bool = context.lifetime.dispatched
	var previous: Dictionary = context.lifetime.dispatch_recovery
	context.lifetime.dispatched = false
	if writing:
		context.lifetime.dispatch_recovery = {"outcome": "unknown", "sent": true,
			"unconfirmed": true, "tool": tool}
	var result: Dictionary = await server.call_tool(tool, arguments, context, binding)
	var sent: bool = context.lifetime.dispatched
	context.lifetime.dispatched = was_sent or sent
	context.lifetime.dispatch_recovery = previous
	var problem: String = await host.fresh_target_problem(target)
	if not problem.is_empty():
		result = {"error": problem, "stale": true}
	if result.has("error") or result.get("success", true) == false:
		result["sent"] = sent
		if sent and writing:
			result["outcome"] = "unknown"
			result["unconfirmed"] = true
	return result

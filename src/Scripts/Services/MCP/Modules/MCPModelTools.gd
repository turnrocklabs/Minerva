class_name MCPModelTools
extends MCPToolModule
## MCP tool module for Model management, Cost tracking, Meta (tool sets), and Utility tools.
## Combines _register_model_tools, _register_cost_tools, _register_meta_tools,
## and _register_utility_tools from MinervaMCPServer.


func get_tool_names() -> Array[String]:
	return [
		"minerva_list_models",
		"minerva_add_model",
		"minerva_update_model",
		"minerva_remove_model",
		"minerva_get_cost_summary",
		"minerva_get_chat_cost",
		"minerva_set_budget",
		"minerva_extend_budget",
		"minerva_list_tool_sets",
		"minerva_enable_tool_sets",
		"minerva_disable_tool_sets",
		"minerva_clock",
	]


func register_tools() -> void:
	# Model management tools
	server._register_tool("minerva_list_models",
		"List all registered AI models (built-in and user-added dynamic models), optionally filtered by provider. Returns model IDs, names, pricing, and whether each model is dynamic.",
		{
			"type": "object",
			"properties": {
				"provider": {
					"type": "string",
					"enum": ["anthropic", "openai", "google", "openrouter", "local"],
					"description": "Filter to only show models from this provider"
				},
				"dynamic_only": {
					"type": "boolean",
					"description": "If true, only show user-added dynamic models (default: false)"
				}
			},
			"required": []
		}
	, "models")

	server._register_tool("minerva_add_model",
		"Add a new dynamic model to a provider. The model will be available for use in chats immediately and persists across restarts.",
		{
			"type": "object",
			"properties": {
				"provider": {
					"type": "string",
					"enum": ["anthropic", "openai", "google", "openrouter", "local"],
					"description": "The provider to add the model to"
				},
				"model_name": {
					"type": "string",
					"description": "The API model ID (e.g., 'claude-opus-4-5', 'gpt-5.2', 'gemini-3-flash')"
				},
				"display_name": {
					"type": "string",
					"description": "Human-readable display name (defaults to model_name)"
				},
				"short_name": {
					"type": "string",
					"description": "Short abbreviation for the model (e.g., 'CO', 'G5'). Auto-generated if not provided."
				},
				"input_token_cost": {
					"type": "number",
					"description": "Cost per million input tokens in USD (default: 0)"
				},
				"output_token_cost": {
					"type": "number",
					"description": "Cost per million output tokens in USD (default: 0)"
				},
				"is_reasoning_model": {
					"type": "boolean",
					"description": "Whether this is a reasoning/thinking model (default: false)"
				}
			},
			"required": ["provider", "model_name"]
		}
	, "models")

	server._register_tool("minerva_update_model",
		"Update fields on an existing dynamic model. Only user-added dynamic models can be updated (not built-in models).",
		{
			"type": "object",
			"properties": {
				"model_id": {
					"type": "integer",
					"description": "The dynamic model ID to update"
				},
				"display_name": {
					"type": "string",
					"description": "New display name"
				},
				"short_name": {
					"type": "string",
					"description": "New short abbreviation"
				},
				"input_token_cost": {
					"type": "number",
					"description": "New cost per million input tokens in USD"
				},
				"output_token_cost": {
					"type": "number",
					"description": "New cost per million output tokens in USD"
				},
				"is_reasoning_model": {
					"type": "boolean",
					"description": "Whether this is a reasoning/thinking model"
				}
			},
			"required": ["model_id"]
		}
	, "models")

	server._register_tool("minerva_remove_model",
		"Remove a dynamic model. Only user-added dynamic models can be removed (not built-in models). The model will no longer appear in the model selector.",
		{
			"type": "object",
			"properties": {
				"model_id": {
					"type": "integer",
					"description": "The dynamic model ID to remove"
				}
			},
			"required": ["model_id"]
		}
	, "models")

	# Cost tracking tools
	server._register_tool("minerva_get_cost_summary",
		"Get a cost summary for API usage over a time period, optionally filtered by provider. Shows total cost, token counts, and breakdowns by provider and model.",
		{
			"type": "object",
			"properties": {
				"period": {
					"type": "string",
					"enum": ["today", "week", "month", "all"],
					"description": "Time period to summarize (default: today)"
				},
				"provider": {
					"type": "string",
					"description": "Filter to a specific provider name (e.g., 'Anthropic', 'OpenAI', 'Google')"
				}
			},
			"required": []
		}
	, "costs")

	server._register_tool("minerva_get_chat_cost",
		"Get the cost breakdown for a specific chat, including token counts, total cost, and budget status if a budget is set.",
		{
			"type": "object",
			"properties": {
				"chat_id": {
					"type": "string",
					"description": "The chat UUID to get costs for"
				}
			},
			"required": ["chat_id"]
		}
	, "costs")

	server._register_tool("minerva_set_budget",
		"Set a spending budget for a chat. When the budget is exceeded, API calls for that chat will be blocked until the budget is extended.",
		{
			"type": "object",
			"properties": {
				"chat_id": {
					"type": "string",
					"description": "The chat UUID to set a budget for"
				},
				"budget_usd": {
					"type": "number",
					"description": "Budget amount in USD (e.g., 5.0 for a $5 budget)"
				},
				"warn_pct": {
					"type": "number",
					"description": "Warning threshold as a fraction (default: 0.8 = warn at 80%)"
				},
				"period": {
					"type": "string",
					"enum": ["hour", "day", "week", "month"],
					"description": "Budget time period (default: day). Spend is calculated over a rolling window."
				}
			},
			"required": ["chat_id", "budget_usd"]
		}
	, "costs")

	server._register_tool("minerva_extend_budget",
		"Add additional funds to an existing chat budget. If no budget exists, creates one with the specified amount.",
		{
			"type": "object",
			"properties": {
				"chat_id": {
					"type": "string",
					"description": "The chat UUID to extend the budget for"
				},
				"additional_usd": {
					"type": "number",
					"description": "Amount in USD to add to the budget"
				}
			},
			"required": ["chat_id", "additional_usd"]
		}
	, "costs")

	# Meta tools (tool set management)
	server._register_tool("minerva_list_tool_sets",
		"List all available tool sets with their tool counts and enabled status. Tool sets group related tools (e.g., 'autocoder', 'spreadsheet', 'chat'). Use this to discover what sets are available before enabling/disabling them.",
		{
			"type": "object",
			"properties": {},
			"required": []
		}
	, "meta")

	server._register_tool("minerva_enable_tool_sets",
		"Enable specific tool sets for this session. Only tools from enabled sets (plus meta tools) will be available. Pass an empty array to re-enable all sets.",
		{
			"type": "object",
			"properties": {
				"sets": {
					"type": "array",
					"items": {"type": "string"},
					"description": "List of tool set names to enable (e.g., ['autocoder', 'chat']). Pass empty array to enable all sets."
				}
			},
			"required": ["sets"]
		}
	, "meta")

	server._register_tool("minerva_disable_tool_sets",
		"Disable specific tool sets for this session. Disabled sets' tools will not appear in tools/list and cannot be called.",
		{
			"type": "object",
			"properties": {
				"sets": {
					"type": "array",
					"items": {"type": "string"},
					"description": "List of tool set names to disable (e.g., ['pcb', 'video'])"
				}
			},
			"required": ["sets"]
		}
	, "meta")

	# Utility tools
	server._register_tool("minerva_clock",
		"Get a Unix timestamp. Three modes: (1) No arguments = current time. (2) delta_seconds = relative to now (negative for past, e.g. -300 for 5 minutes ago). (3) year/month/day/hour/minute/second = absolute date/time conversion.",
		{
			"type": "object",
			"properties": {
				"delta_seconds": {
					"type": "integer",
					"description": "Offset from current time in seconds. Negative for past (e.g. -300 = 5 minutes ago), positive for future (e.g. 3600 = 1 hour from now)."
				},
				"year": {
					"type": "integer",
					"description": "Year (e.g. 2026). Use year/month/day for absolute time conversion."
				},
				"month": {
					"type": "integer",
					"description": "Month (1-12)"
				},
				"day": {
					"type": "integer",
					"description": "Day of month (1-31)"
				},
				"hour": {
					"type": "integer",
					"description": "Hour (0-23), default 0"
				},
				"minute": {
					"type": "integer",
					"description": "Minute (0-59), default 0"
				},
				"second": {
					"type": "integer",
					"description": "Second (0-59), default 0"
				}
			},
			"required": []
		}
	, "utility")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_list_models": return _list_models(arguments)
		"minerva_add_model": return _add_model(arguments)
		"minerva_update_model": return _update_model(arguments)
		"minerva_remove_model": return _remove_model(arguments)
		"minerva_get_cost_summary": return _get_cost_summary(arguments)
		"minerva_get_chat_cost": return _get_chat_cost(arguments)
		"minerva_set_budget": return _set_budget(arguments)
		"minerva_extend_budget": return _extend_budget(arguments)
		"minerva_list_tool_sets": return _list_tool_sets(arguments)
		"minerva_enable_tool_sets": return _enable_tool_sets(arguments)
		"minerva_disable_tool_sets": return _disable_tool_sets(arguments)
		"minerva_clock": return _clock(arguments)
	return MCPToolUtils.error("Unknown tool: %s" % tool_name)


#region Model Handlers

func _get_provider_name_for_enum(provider_enum) -> String:
	match provider_enum:
		SingletonObject.API_PROVIDER.ANTHROPIC:
			return "anthropic"
		SingletonObject.API_PROVIDER.OPENAI:
			return "openai"
		SingletonObject.API_PROVIDER.GOOGLE:
			return "google"
		SingletonObject.API_PROVIDER.OPENROUTER:
			return "openrouter"
		SingletonObject.API_PROVIDER.LOCAL:
			return "local"
		SingletonObject.API_PROVIDER.CLAUDE_CODE:
			return "claude_code"
		SingletonObject.API_PROVIDER.TURNROCK:
			return "turnrock"
		_:
			return "unknown"


func _get_manager_for_provider_string(provider: String):
	match provider:
		"anthropic":
			return SingletonObject.anthropic_model_manager
		"openai":
			return SingletonObject.openai_model_manager
		"google":
			return SingletonObject.google_model_manager
		"openrouter":
			return SingletonObject.openrouter_model_manager
		"local":
			return SingletonObject.local_model_manager
		_:
			return null


func _list_models(args: Dictionary) -> Dictionary:
	var provider_filter: String = args.get("provider", "")
	var dynamic_only: bool = args.get("dynamic_only", false)
	var results: Array = []

	# Collect built-in models (unless dynamic_only is set)
	if not dynamic_only:
		for model_id in SingletonObject.API_MODEL_PROVIDER_SCRIPTS:
			if model_id >= SingletonObject.DYNAMIC_MODEL_ID_BASE:
				continue
			var provider_enum = SingletonObject.MODEL_TO_PROVIDER.get(model_id)
			if provider_enum == null:
				continue
			var provider_name: String = _get_provider_name_for_enum(provider_enum)
			if not provider_filter.is_empty() and provider_name != provider_filter:
				continue
			# Create a temporary provider instance to read its fields
			var script = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[model_id]
			if script == null:
				continue
			var provider_instance = script.new()
			var api_id: String = provider_instance.model_name
			if "api_model_id" in provider_instance and not provider_instance.api_model_id.is_empty():
				api_id = provider_instance.api_model_id
			results.append({
				"id": model_id,
				"provider": provider_name,
				"model_name": provider_instance.model_name,
				"api_model_id": api_id,
				"display_name": provider_instance.display_name,
				"short_name": provider_instance.short_name,
				"input_token_cost": provider_instance.input_token_cost,
				"output_token_cost": provider_instance.output_token_cost,
				"is_dynamic": false,
			})

	# Collect dynamic models from all managers
	var managers: Dictionary = {
		"anthropic": SingletonObject.anthropic_model_manager,
		"openai": SingletonObject.openai_model_manager,
		"google": SingletonObject.google_model_manager,
		"openrouter": SingletonObject.openrouter_model_manager,
		"local": SingletonObject.local_model_manager,
	}
	for prov_name in managers:
		if not provider_filter.is_empty() and prov_name != provider_filter:
			continue
		var manager = managers[prov_name]
		if manager == null:
			continue
		for config in manager.models:
			var model_name: String = config.get("model_name", config.get("api_model_id", ""))
			var api_model_id: String = config.get("api_model_id", model_name)
			results.append({
				"id": config.get("id", -1),
				"provider": prov_name,
				"model_name": model_name,
				"api_model_id": api_model_id,
				"display_name": config.get("display_name", model_name),
				"short_name": config.get("short_name", ""),
				"input_token_cost": config.get("input_token_cost", 0.0),
				"output_token_cost": config.get("output_token_cost", 0.0),
				"is_dynamic": true,
			})

	return {"success": true, "models": results, "count": results.size()}


func _add_model(args: Dictionary) -> Dictionary:
	var provider: String = args.get("provider", "")
	if provider.is_empty():
		return MCPToolUtils.error("provider is required")
	var model_name: String = args.get("model_name", "")
	if model_name.is_empty():
		return MCPToolUtils.error("model_name is required")

	var manager = _get_manager_for_provider_string(provider)
	if manager == null:
		return MCPToolUtils.error("Unknown provider: %s" % provider)

	var display_name: String = args.get("display_name", model_name)
	var short_name: String = args.get("short_name", "")
	if short_name.is_empty():
		# Auto-generate: first letter of each word, uppercase
		var parts: PackedStringArray = display_name.split(" ")
		for part in parts:
			if not part.is_empty():
				short_name += part[0].to_upper()
		if short_name.is_empty():
			short_name = model_name.left(2).to_upper()

	var config: Dictionary = {
		"model_name": model_name,
		"display_name": display_name,
		"short_name": short_name,
		"input_token_cost": args.get("input_token_cost", 0.0),
		"output_token_cost": args.get("output_token_cost", 0.0),
	}

	# Anthropic and OpenRouter need api_model_id
	if provider == "anthropic" or provider == "openrouter":
		config["api_model_id"] = model_name

	# Reasoning model flag (OpenAI, OpenRouter)
	if args.has("is_reasoning_model"):
		config["is_reasoning_model"] = args.get("is_reasoning_model", false)

	var model_id: int = manager.add_model(config)
	return {"success": true, "model_id": model_id, "message": "Model '%s' added to %s" % [display_name, provider]}


func _update_model(args: Dictionary) -> Dictionary:
	var model_id: int = args.get("model_id", -1)
	if model_id < 0:
		return MCPToolUtils.error("model_id is required")
	if model_id < SingletonObject.DYNAMIC_MODEL_ID_BASE:
		return MCPToolUtils.error("Cannot update built-in model (id %d). Only dynamic models can be updated." % model_id)

	var manager = SingletonObject.get_model_manager_for_id(model_id)
	if manager == null:
		return MCPToolUtils.error("No model manager found for model_id %d" % model_id)

	var existing: Dictionary = manager.get_model(model_id)
	if existing.is_empty():
		return MCPToolUtils.error("Model with id %d not found" % model_id)

	# Merge provided fields into existing config
	var updatable_fields: Array = ["display_name", "short_name", "input_token_cost", "output_token_cost", "is_reasoning_model"]
	var updated := false
	for field in updatable_fields:
		if args.has(field):
			existing[field] = args[field]
			updated = true

	if not updated:
		return MCPToolUtils.error("No updatable fields provided. Updatable fields: %s" % str(updatable_fields))

	manager.update_model(model_id, existing)
	return {"success": true, "model_id": model_id, "message": "Model %d updated" % model_id}


func _remove_model(args: Dictionary) -> Dictionary:
	var model_id: int = args.get("model_id", -1)
	if model_id < 0:
		return MCPToolUtils.error("model_id is required")
	if model_id < SingletonObject.DYNAMIC_MODEL_ID_BASE:
		return MCPToolUtils.error("Cannot remove built-in model (id %d). Only dynamic models can be removed." % model_id)

	var manager = SingletonObject.get_model_manager_for_id(model_id)
	if manager == null:
		return MCPToolUtils.error("No model manager found for model_id %d" % model_id)

	var existing: Dictionary = manager.get_model(model_id)
	if existing.is_empty():
		return MCPToolUtils.error("Model with id %d not found" % model_id)

	var display_name: String = existing.get("display_name", str(model_id))
	manager.remove_model(model_id)
	return {"success": true, "model_id": model_id, "message": "Model '%s' (id %d) removed" % [display_name, model_id]}

#endregion


#region Cost Handlers

func _get_cost_summary(args: Dictionary) -> Dictionary:
	if not SingletonObject.cost_tracker:
		return MCPToolUtils.error("Cost tracker not initialized")
	var period: String = args.get("period", "today")
	var provider_filter: String = args.get("provider", "")
	var summary: Dictionary = SingletonObject.cost_tracker.get_cost_summary(period, provider_filter)
	summary["success"] = true
	return summary


func _get_chat_cost(args: Dictionary) -> Dictionary:
	if not SingletonObject.cost_tracker:
		return MCPToolUtils.error("Cost tracker not initialized")
	var chat_id: String = args.get("chat_id", "")
	if chat_id.is_empty():
		return MCPToolUtils.error("chat_id is required")
	var result: Dictionary = SingletonObject.cost_tracker.get_cost_for_chat(chat_id)
	result["success"] = true
	result["chat_id"] = chat_id
	return result


func _set_budget(args: Dictionary) -> Dictionary:
	if not SingletonObject.cost_tracker:
		return MCPToolUtils.error("Cost tracker not initialized")
	var chat_id: String = args.get("chat_id", "")
	if chat_id.is_empty():
		return MCPToolUtils.error("chat_id is required")
	var budget_usd: float = args.get("budget_usd", 0.0)
	if budget_usd <= 0:
		return MCPToolUtils.error("budget_usd must be positive")
	var warn_pct: float = args.get("warn_pct", 0.8)
	var period: String = args.get("period", "day")
	if period not in SingletonObject.cost_tracker.BUDGET_PERIODS:
		return MCPToolUtils.error("Invalid period. Must be one of: hour, day, week, month")
	var previous: float = SingletonObject.cost_tracker.set_budget(chat_id, budget_usd, warn_pct, period)
	return {
		"success": true,
		"chat_id": chat_id,
		"budget_usd": budget_usd,
		"warn_pct": warn_pct,
		"period": period,
		"previous_budget": previous,
		"message": "Budget set to $%.2f/%s for chat %s" % [budget_usd, period, chat_id],
	}


func _extend_budget(args: Dictionary) -> Dictionary:
	if not SingletonObject.cost_tracker:
		return MCPToolUtils.error("Cost tracker not initialized")
	var chat_id: String = args.get("chat_id", "")
	if chat_id.is_empty():
		return MCPToolUtils.error("chat_id is required")
	var additional_usd: float = args.get("additional_usd", 0.0)
	if additional_usd <= 0:
		return MCPToolUtils.error("additional_usd must be positive")
	var new_total: float = SingletonObject.cost_tracker.extend_budget(chat_id, additional_usd)
	return {
		"success": true,
		"chat_id": chat_id,
		"added_usd": additional_usd,
		"new_total_budget": new_total,
		"message": "Budget extended by $%.2f to $%.2f for chat %s" % [additional_usd, new_total, chat_id],
	}

#endregion


#region Meta Handlers

func _list_tool_sets(_args: Dictionary) -> Dictionary:
	var sets: Dictionary = {}
	for tool_name in server.mcp_manager.tool_registry:
		var tool = server.mcp_manager.tool_registry[tool_name]
		if not tool.tool_set.is_empty():
			sets[tool.tool_set] = sets.get(tool.tool_set, 0) + 1

	var enabled_info: Array = server._enabled_tool_sets.duplicate()
	return {
		"success": true,
		"tool_sets": sets,
		"enabled_sets": enabled_info,
		"all_enabled": server._enabled_tool_sets.is_empty(),
		"message": "All sets enabled" if server._enabled_tool_sets.is_empty() else "Filtered to: %s" % str(server._enabled_tool_sets)
	}


func _enable_tool_sets(args: Dictionary) -> Dictionary:
	var sets: Array = args.get("sets", [])
	if sets.is_empty():
		# Empty array = enable all (clear filter)
		server._enabled_tool_sets = []
		return {"success": true, "enabled_sets": [], "all_enabled": true, "message": "All tool sets enabled"}

	server._enabled_tool_sets = sets.duplicate()
	return {
		"success": true,
		"enabled_sets": server._enabled_tool_sets.duplicate(),
		"all_enabled": false,
		"message": "Enabled tool sets: %s (meta tools always available)" % str(sets)
	}


func _disable_tool_sets(args: Dictionary) -> Dictionary:
	var sets_to_disable: Array = args.get("sets", [])
	if sets_to_disable.is_empty():
		return MCPToolUtils.error("sets array required and must not be empty")

	# If currently all-enabled, populate with all known sets minus the disabled ones
	if server._enabled_tool_sets.is_empty():
		var all_sets: Dictionary = {}
		for tool_name in server.mcp_manager.tool_registry:
			var tool = server.mcp_manager.tool_registry[tool_name]
			if tool.server_name == server.SERVER_NAME and not tool.tool_set.is_empty() and tool.tool_set != "meta":
				all_sets[tool.tool_set] = true
		server._enabled_tool_sets = []
		for set_name in all_sets:
			if set_name not in sets_to_disable:
				server._enabled_tool_sets.append(set_name)
	else:
		# Remove specified sets from enabled list
		for set_name in sets_to_disable:
			var idx = server._enabled_tool_sets.find(set_name)
			if idx >= 0:
				server._enabled_tool_sets.remove_at(idx)

	return {
		"success": true,
		"enabled_sets": server._enabled_tool_sets.duplicate(),
		"disabled": sets_to_disable,
		"message": "Disabled tool sets: %s" % str(sets_to_disable)
	}

#endregion


#region Utility Handlers

func _clock(arguments: Dictionary) -> Dictionary:
	var unix_now := int(Time.get_unix_time_from_system())

	# Mode 1: delta_seconds — relative to now
	if arguments.has("delta_seconds"):
		var delta := MCPToolUtils.coerce_int(arguments.get("delta_seconds", 0))
		var target_ts := unix_now + delta
		var delta_dt := Time.get_datetime_dict_from_unix_time(target_ts)
		return {
			"success": true,
			"unix_timestamp": target_ts,
			"datetime": "%04d-%02d-%02dT%02d:%02d:%02d" % [delta_dt.year, delta_dt.month, delta_dt.day, delta_dt.hour, delta_dt.minute, delta_dt.second],
			"timezone": "UTC",
			"now_unix": unix_now,
			"delta_seconds": delta
		}

	# Mode 2: absolute date/time
	if arguments.has("year"):
		var abs_dt := {
			"year": MCPToolUtils.coerce_int(arguments.get("year", 1970)),
			"month": MCPToolUtils.coerce_int(arguments.get("month", 1)),
			"day": MCPToolUtils.coerce_int(arguments.get("day", 1)),
			"hour": MCPToolUtils.coerce_int(arguments.get("hour", 0)),
			"minute": MCPToolUtils.coerce_int(arguments.get("minute", 0)),
			"second": MCPToolUtils.coerce_int(arguments.get("second", 0)),
		}
		var unix_ts := Time.get_unix_time_from_datetime_dict(abs_dt)
		return {
			"success": true,
			"unix_timestamp": int(unix_ts),
			"datetime": "%04d-%02d-%02dT%02d:%02d:%02d" % [abs_dt.year, abs_dt.month, abs_dt.day, abs_dt.hour, abs_dt.minute, abs_dt.second],
			"timezone": "UTC"
		}

	# Mode 3: no arguments — current local time
	var dt := Time.get_datetime_dict_from_system(false)
	var tz := Time.get_time_zone_from_system()
	var tz_name: String = tz.get("name", "Local")
	return {
		"success": true,
		"unix_timestamp": unix_now,
		"datetime": "%04d-%02d-%02dT%02d:%02d:%02d" % [dt.year, dt.month, dt.day, dt.hour, dt.minute, dt.second],
		"timezone": tz_name
	}

#endregion

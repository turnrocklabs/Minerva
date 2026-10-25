class_name MCPGenerationTools
extends MCPToolModule
## Inspect Core generation layers and per-model API reasoning with the shared resolver.


func get_tool_names() -> Array[String]:
	return ["minerva_get_generation_options", "minerva_set_generation_options"]


func register_tools() -> void:
	var properties := {
		"chat_id": {"type": "string", "description": "Chat to inspect/edit; mutually exclusive with model_spec"},
		"model_spec": ModelResolver.selection_schema(),
		"request_options": {"type": "object", "description": "Optional advertised generation overrides to preview: temperature, top_p, top_k, min_p, presence_penalty, frequency_penalty, repetition_penalty, seed, max_tokens, num_ctx, num_gpu, reasoning_effort, enable_thinking"}}
	server._register_tool("minerva_get_generation_options",
		"Inspect a model's supported generation schema, saved overrides, effective values and sources. Native-profile settings are per model; other Core models retain chat/model layers. API providers support per-model reasoning. Model reasoning preferences take precedence over replayed requests.",
		{"type": "object", "properties": properties}, "models")
	properties = properties.duplicate(true)
	properties.erase("request_options")
	properties["scope"] = {"type": "string", "enum": ["model", "chat"], "description": "Layer to replace; native-profile models use model scope, including with chat_id. Other Core models default to chat with chat_id, otherwise model"}
	properties["options"] = {"type": "object", "description": "Replace the explicit layer. Empty {} clears to inherited values. Model-only Context keys: context_window, auto_compact_at, max_output_tokens (when a maximum is published). Context budgets stay local; only a lowered output limit is sent. Other canonical keys: temperature, top_p, top_k, min_p, presence_penalty, frequency_penalty, repetition_penalty, seed, max_tokens, num_ctx, num_gpu, reasoning_effort, enable_thinking. Only advertised names/values are accepted; native aliases may be nested under options."}
	server._register_tool("minerva_set_generation_options",
		"Persist Core generation overrides or API model reasoning preferences. Only advertised options are accepted; zero is preserved. Use minerva_get_generation_options first. This replaces the layer, so include values you want to keep.",
		{"type": "object", "properties": properties, "required": ["options"]}, "models")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	var history: ChatHistory = null
	var provider: BaseProvider = null
	var owned := false
	if arguments.has("chat_id") and arguments.has("model_spec"):
		return GenerationOptions.failure("invalid_model_spec", "Specify chat_id or model_spec, not both")
	if arguments.has("chat_id"):
		history = MCPToolUtils.find_chat_by_id(str(arguments.chat_id))
		if history == null:
			return GenerationOptions.failure("model_not_available", "Chat not found")
		provider = history.provider
	elif arguments.get("model_spec") is Dictionary:
		var target := ModelResolver.create(arguments.model_spec)
		if not target.success:
			return target
		provider = target.provider
		owned = true
	else:
		return GenerationOptions.failure("invalid_model_spec", "Specify chat_id or model_spec")
	var result := _handle_options(tool_name, arguments, provider, history)
	if owned:
		provider.free()
	return result


func _handle_options(tool_name: String, args: Dictionary, provider: BaseProvider, history: ChatHistory) -> Dictionary:
	if history != null:
		history.retire_chat_generation()
	var checked := GenerationOptions.public_request(provider, args.get("request_options", {}))
	if not checked.success:
		return checked
	if tool_name == "minerva_set_generation_options":
		if not args.has("options"):
			return GenerationOptions.failure("invalid_generation_options", "options is required")
		var default_scope: String = "chat" if history != null and not GenerationOptions.has_native_profile(provider) else "model"
		var scope: String = str(args.get("scope", default_scope))
		var saved: Dictionary
		if scope == "chat" and history != null:
			saved = GenerationOptions.set_chat(history, args.options)
		elif scope == "model":
			saved = GenerationOptions.save_model(provider, args.options)
		else:
			return GenerationOptions.failure("invalid_generation_options", "Chat scope requires chat_id; scope must be model or chat")
		if not saved.success:
			return saved
	var request: Dictionary = checked.values
	var chat: Dictionary = history.GenerationOverrides if history != null else {}
	request[GenerationOptions.CHAT_LAYER] = chat
	var resolved := GenerationOptions.for_provider(provider, request)
	if not resolved.success:
		return {"success": true, "model_spec": ModelResolver.spec_for(provider), "schema": GenerationOptions.schema_for(provider),
			"model_options": GenerationOptions.saved_for(provider), "chat_options": chat.duplicate(true), "effective_error": resolved}
	var schema: Dictionary = resolved.schema
	schema = schema.duplicate(true)
	var context_schema: Dictionary = resolved.context_schema
	schema.merge(context_schema, true)
	var effective: Dictionary = resolved.values
	effective = effective.duplicate(true)
	var context: Dictionary = resolved.context
	effective.merge(context, true)
	var sources: Dictionary = resolved.sources
	sources = sources.duplicate(true)
	var model_options: Dictionary = resolved.model_options
	for key: String in context:
		sources[key] = "model" if model_options.has(key) else "default"
	return {"success": true, "model_spec": ModelResolver.spec_for(provider), "schema": schema,
		"model_options": GenerationOptions.saved_for(provider), "chat_options": chat.duplicate(true),
		"effective_options": effective, "sources": sources}

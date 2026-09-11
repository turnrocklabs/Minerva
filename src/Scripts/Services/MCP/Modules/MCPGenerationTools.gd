class_name MCPGenerationTools
extends MCPToolModule
## Inspect and replace explicit Core generation layers using the shared resolver.


func get_tool_names() -> Array[String]:
	return ["minerva_get_generation_options", "minerva_set_generation_options"]


func register_tools() -> void:
	var properties := {
		"chat_id": {"type": "string", "description": "Chat to inspect/edit; mutually exclusive with model_spec"},
		"model_spec": ModelResolver.selection_schema(),
		"request_options": {"type": "object", "description": "Optional generation-only request overrides to preview"}}
	server._register_tool("minerva_get_generation_options",
		"Inspect a Core chat model's supported generation schema, saved model/chat overrides, effective values and their sources. Precedence: defaults < model < chat < request.",
		{"type": "object", "properties": properties}, "models")
	properties = properties.duplicate(true)
	properties.erase("request_options")
	properties["scope"] = {"type": "string", "enum": ["model", "chat"], "description": "Layer to replace; defaults to chat with chat_id, otherwise model"}
	properties["options"] = {"type": "object", "description": "Replace the explicit layer. Empty {} clears to inherited values. Supported canonical keys: temperature, max_tokens, num_ctx, num_gpu; native aliases may be nested under options."}
	server._register_tool("minerva_set_generation_options",
		"Persist Core generation overrides for one model or chat. Only advertised options are accepted; zero is preserved. Use minerva_get_generation_options first. This replaces the layer, so include values you want to keep.",
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
	var checked := GenerationOptions.public_request(provider, args.get("request_options", {}))
	if not checked.success:
		return checked
	if tool_name == "minerva_set_generation_options":
		if not args.has("options"):
			return GenerationOptions.failure("invalid_generation_options", "options is required")
		var scope: String = str(args.get("scope", "chat" if history != null else "model"))
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
	return {"success": true, "model_spec": ModelResolver.spec_for(provider), "schema": resolved.schema,
		"model_options": GenerationOptions.saved_for(provider), "chat_options": chat.duplicate(true),
		"effective_options": resolved.values, "sources": resolved.sources}

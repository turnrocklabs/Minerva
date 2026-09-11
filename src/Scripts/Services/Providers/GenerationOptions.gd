class_name GenerationOptions
extends RefCounted
## Canonical generation options, resolved by logical option before wire serialization.

const CHAT_LAYER := "_chat_generation_options"
const MODEL_SECTION := "GenerationOptions"
const NATIVE := {"temperature": "temperature", "num_predict": "max_tokens", "num_ctx": "num_ctx", "num_gpu": "num_gpu"}
const PROTOCOL := ["messages", "tools", "tool_choice", "stream", "format", "response_format", "system"]


static func normalize(schema: Dictionary, raw: Variant, allow_protocol: bool = false) -> Dictionary:
	if not raw is Dictionary:
		return failure("invalid_generation_options", "Generation options must be an object")
	var values: Dictionary = {}
	for name in raw:
		if name == "options" or (allow_protocol and (name in PROTOCOL or name == CHAT_LAYER)):
			continue
		if not name in CoreModelDescriptor.LEGACY_OPTIONS:
			return failure("unsupported_generation_option", "Unsupported generation option: %s" % str(name).left(128))
		values[name] = raw[name]
	if raw.has("options"):
		if not raw.options is Dictionary:
			return failure("invalid_generation_options", "Native options must be an object")
		for name in raw.options:
			if not NATIVE.has(name):
				return failure("unsupported_generation_option", "Unsupported native generation option: %s" % str(name).left(128))
			values[NATIVE[name]] = raw.options[name]
	for name in values.keys():
		var value: Variant = values[name]
		# Host inherit sentinels never become engine values.
		if (value is int or value is float) and ((name == "num_ctx" and value == 0) or (name == "num_gpu" and value == -1)):
			values.erase(name)
			continue
		if not schema.has(name):
			return failure("unsupported_generation_option", "This model does not support %s" % name)
		var rule: Dictionary = schema[name]
		if not CoreModelDescriptor._number_matches(value, rule.type) \
				or (rule.type == "integer" and value is float and value >= 9223372036854775808.0) \
				or value < rule.get("minimum", -INF) or value > rule.get("maximum", INF):
			return failure("invalid_generation_option", "Invalid %s: expected a finite %s in the advertised range" % [name, rule.type])
		values[name] = int(value) if rule.type == "integer" else float(value)
	return {"success": true, "values": values}


static func resolve(schema: Dictionary, saved: Variant = {}, chat: Variant = {}, request: Variant = {}) -> Dictionary:
	var checked := CoreModelDescriptor.validate_options(schema)
	if not checked.diagnostics.is_empty():
		return failure("invalid_model_descriptor", "; ".join(checked.diagnostics))
	var values: Dictionary = {}
	var sources: Dictionary = {}
	for name in checked.options:
		if checked.options[name].has("default"):
			values[name] = checked.options[name].default
			sources[name] = "default"
	var layers := {"model": saved, "chat": chat, "request": request}
	for layer in layers:
		var normalized := normalize(checked.options, layers[layer], layer == "request")
		if not normalized.success:
			normalized["layer"] = layer
			return normalized
		for name in normalized.values:
			values[name] = normalized.values[name]
			sources[name] = layer
	return {"success": true, "values": values, "sources": sources, "schema": checked.options, "payload": serialize(values)}


static func serialize(values: Dictionary) -> Dictionary:
	var payload: Dictionary = {}
	var native: Dictionary = {}
	for name in values:
		if name in ["num_ctx", "num_gpu"]:
			native[name] = values[name]
		else:
			payload[name] = values[name]
	if not native.is_empty():
		payload["options"] = native
	return payload


static func schema_for(provider: CoreProvider) -> Dictionary:
	var offering := CoreModelCatalog.resolve(provider.get_model_spec())
	return offering.entry.generation_options if offering.success else {}


## A modern map (including {}) is authoritative; old maps seed the first edit only.
static func saved_for(provider: CoreProvider) -> Dictionary:
	var key := provider.get_model_settings_key()
	var config: ConfigFile = SingletonObject.config_file
	var modern: Dictionary = config.get_value("Models", MODEL_SECTION, {})
	if modern.has(key):
		return modern[key].duplicate(true) if modern[key] is Dictionary else {"invalid_saved_options": modern[key]}
	var legacy: Dictionary = {}
	var schema := schema_for(provider)
	for mapping in [["Contexts", "num_ctx"], ["NumGpu", "num_gpu"]]:
		var values: Dictionary = config.get_value("Models", mapping[0], {})
		if schema.has(mapping[1]) and values.has(key):
			var candidate := normalize(schema, {mapping[1]: values[key]})
			if candidate.success:
				legacy.merge(candidate.values, true)
	return legacy


static func for_provider(provider: CoreProvider, request: Dictionary = {}) -> Dictionary:
	var offering := CoreModelCatalog.resolve(provider.get_model_spec())
	if not offering.success:
		return failure(offering.error_code, offering.error_message)
	var result := resolve(offering.entry.generation_options, saved_for(provider), request.get(CHAT_LAYER, {}), request)
	if result.success:
		for name in PROTOCOL:
			if request.has(name):
				result.payload[name] = request[name]
	return result


## Persist the replacement before applying it in memory. Empty values mean inherit.
static func save_model(provider: CoreProvider, raw: Variant) -> Dictionary:
	var offering := CoreModelCatalog.resolve(provider.get_model_spec())
	if not offering.success:
		return failure(offering.error_code, offering.error_message)
	var normalized := normalize(offering.entry.generation_options, raw)
	if not normalized.success:
		return normalized
	var key := provider.get_model_settings_key()
	var config: ConfigFile = SingletonObject.config_file
	var updated := ConfigFile.new()
	var error := updated.parse(config.encode_to_text())
	if error != OK:
		return failure("persistence_error", "Could not read model settings")
	var modern: Dictionary = updated.get_value("Models", MODEL_SECTION, {}).duplicate(true)
	modern[key] = normalized.values
	updated.set_value("Models", MODEL_SECTION, modern)
	error = updated.save(SingletonObject._config_file_name)
	if error != OK:
		return failure("persistence_error", "Could not save model settings: %s" % error_string(error))
	config.set_value("Models", MODEL_SECTION, modern)
	return {"success": true, "values": normalized.values}


static func request_from_history(history: ChatHistory, through_item: ChatHistoryItem = null) -> Dictionary:
	var start := history.HistoryItemList.size() - 1
	if through_item != null:
		start = history.HistoryItemList.find(through_item)
	for index in range(start, -1, -1):
		var item := history.HistoryItemList[index]
		if item.Role == ChatHistoryItem.ChatRole.USER:
			return item.RequestMetadata.get("generation_options_request", {}).duplicate(true)
	return {}


## Preserve the existing non-Core sampling behavior at one shared call boundary.
static func chat_params(history: ChatHistory, provider: BaseProvider, request: Dictionary = {}) -> Dictionary:
	var params: Dictionary = {}
	if provider is CoreProvider:
		params = request.duplicate(true)
		params[CHAT_LAYER] = history.GenerationOverrides.duplicate(true)
	elif provider.PROVIDER == SingletonObject.API_PROVIDER.OPENAI and not provider is OpenAIImageProvider:
		params = {"temperature": history.Temperature, "top_p": history.TopP,
			"presence_penalty": history.PresencePenalty, "frequency_penalty": history.FrequencyPenalty}
		params.merge(request, true)
	return params


static func failure(code: String, message: String) -> Dictionary:
	return {"success": false, "error_code": code, "error": message, "error_message": message}


## Public APIs accept generation options only, never private layers or protocol data.
static func public_request(provider: BaseProvider, raw: Variant) -> Dictionary:
	if not provider is CoreProvider:
		return failure("unsupported_generation_options", "Structured generation options require a Core chat model")
	var offering := CoreModelCatalog.resolve(provider.get_model_spec())
	if not offering.success:
		return failure(offering.error_code, offering.error_message)
	return normalize(offering.entry.generation_options, raw)


static func set_chat(history: ChatHistory, raw: Variant) -> Dictionary:
	var checked := public_request(history.provider, raw)
	if not checked.success:
		return checked
	if checked.values.has("temperature"):
		history.Temperature = checked.values.temperature
	history.GenerationOverrides = checked.values.duplicate(true)
	return checked


static func broker_params(provider: BaseProvider, args: Dictionary) -> Dictionary:
	var raw := args.duplicate(true)
	for field in ["model", "model_spec", "provider", "messages"]:
		raw.erase(field)
	if provider is CoreProvider:
		return public_request(provider, raw)
	var values: Dictionary = {}
	for name in ["temperature", "max_tokens"]:
		if raw.has(name) and (raw[name] is int or raw[name] is float):
			values[name] = int(raw[name]) if name == "max_tokens" else float(raw[name])
	return {"success": true, "values": values}

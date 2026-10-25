class_name GenerationOptions
extends RefCounted
## Canonical generation options, resolved by logical option before wire serialization.

const CHAT_LAYER := "_chat_generation_options"
const MODEL_SECTION := "GenerationOptions"
const REASONING_KEYS: Array[String] = ["reasoning_effort", "enable_thinking"]
const NATIVE := {"temperature": "temperature", "num_predict": "max_tokens", "num_ctx": "num_ctx", "num_gpu": "num_gpu"}
const PROTOCOL := ["messages", "tools", "tool_choice", "stream", "format", "response_format", "system"]


static func normalize(schema: Dictionary, raw: Variant, allow_protocol: bool = false) -> Dictionary:
	if not raw is Dictionary:
		return failure("invalid_generation_options", "Generation options must be an object")
	var values: Dictionary = {}
	for name in raw:
		if name == "options" or (allow_protocol and (name in PROTOCOL or name == CHAT_LAYER)):
			continue
		if CoreModelDescriptor.option_type(str(name)).is_empty():
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
		if not rule.get("supported", true) or not rule.get("overridable", true):
			return failure("unsupported_generation_option", "This model does not allow overriding %s" % name)
		if not CoreModelDescriptor.value_matches(value, rule):
			return failure("invalid_generation_option", "Invalid %s: expected an advertised %s value" % [name, rule.type])
		if rule.type == "integer":
			values[name] = int(value)
		elif rule.type == "number":
			values[name] = float(value)
	var inactive := _check_inactive(schema, values)
	if not inactive.success:
		return inactive
	return {"success": true, "values": values}


static func resolve(schema: Dictionary, saved: Variant = {}, chat: Variant = {}, request: Variant = {},
		model: String = "this model", profile: Dictionary = {}) -> Dictionary:
	var checked := CoreModelDescriptor.validate_options(schema)
	var diagnostics: Array = checked.diagnostics
	if not diagnostics.is_empty():
		return failure("invalid_model_descriptor", "; ".join(diagnostics))
	var options: Dictionary = checked.options
	var reset := {"values": saved, "notice": ""}
	if saved is Dictionary:
		var saved_values: Dictionary = saved
		reset = ReasoningSelection.reset_saved(options, saved_values, model)
		# A newly published fixed setting cannot retain an old explicit override.
		# Use the same visible reset path as retired reasoning choices.
		var reset_values: Dictionary = reset.values
		for name: Variant in reset_values.keys():
			var rule: Dictionary = options.get(name, {})
			if not rule.get("overridable", true):
				reset_values.erase(name)
				if str(reset.notice).is_empty():
					reset.notice = "Saved %s is no longer overridable for %s. Using the model default." % [str(name), model]
	var values: Dictionary = {}
	var sources: Dictionary = {}
	for name: String in options:
		var rule: Dictionary = options[name]
		if rule.get("default") != null:
			values[name] = rule.default
			sources[name] = "default"
	var layers := {"model": reset.values, "chat": chat, "request": request}
	for layer in layers:
		var normalized := normalize(options, layers[layer], layer == "request")
		if not normalized.success:
			normalized["layer"] = layer
			normalized["error_message"] = "%s generation options: %s" % [layer.capitalize(), normalized.error_message]
			return normalized
		for name in normalized.values:
			if name in REASONING_KEYS and sources.get(name) == "model":
				continue
			values[name] = normalized.values[name]
			sources[name] = layer
	var mode := _apply_mode_defaults(options, profile, values, sources)
	var inactive := _check_inactive(options, values, sources)
	if not inactive.success:
		return inactive
	var explicit: Dictionary = values.duplicate(true)
	for name: String in values:
		if sources.get(name) == "default" and (not profile.is_empty() or name in REASONING_KEYS):
			explicit.erase(name)
	return {"success": true, "values": values, "sources": sources, "schema": options,
		"payload": serialize(explicit), "notice": reset.notice, "model_options": reset.values,
		"profile": profile.duplicate(true), "mode": mode}


## Recipes change inherited defaults, never a user's explicit sampler choices.
static func _apply_mode_defaults(schema: Dictionary, profile: Dictionary, values: Dictionary, sources: Dictionary) -> String:
	if profile.is_empty():
		return ""
	var modes: Dictionary = profile.get("per_mode_defaults", {})
	var mode: String = str(profile.get("default_mode", ""))
	if values.get("enable_thinking") == false and modes.has("nonthinking"):
		mode = "nonthinking"
	var defaults: Dictionary = modes.get(mode, {})
	for name: String in defaults:
		if not schema.has(name):
			continue
		var rule: Dictionary = schema[name]
		rule["default"] = defaults[name]
		if sources.has(name) and sources[name] != "default":
			continue
		if defaults[name] == null:
			values.erase(name)
			sources.erase(name)
		else:
			values[name] = defaults[name]
			sources[name] = "default"
	return mode


static func _check_inactive(schema: Dictionary, values: Dictionary, sources: Dictionary = {}) -> Dictionary:
	for name: String in values.keys():
		var rule: Dictionary = schema[name]
		var condition: Dictionary = rule.get("inactive_when", {})
		if condition.is_empty():
			continue
		var inactive := true
		for dependency: String in condition:
			inactive = inactive and values.has(dependency) and values[dependency] == condition[dependency]
		if not inactive:
			continue
		if sources.get(name) == "default":
			values.erase(name)
			sources.erase(name)
		else:
			return failure("invalid_generation_option", "%s is inactive for these generation settings" % name)
	return {"success": true}


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


static func _offering(provider: BaseProvider) -> Dictionary:
	if provider is CoreProvider:
		var core_provider := provider as CoreProvider
		return CoreModelCatalog.resolve(core_provider.get_model_spec())
	return {"success": true, "entry": {"generation_options": provider.reasoning_schema(), "generation_profile": {}}}


static func schema_for(provider: BaseProvider) -> Dictionary:
	var offering := _offering(provider)
	return offering.entry.generation_options if offering.success else {}


## A modern map (including {}) is authoritative; old maps seed the first edit only.
static func saved_for(provider: BaseProvider) -> Dictionary:
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


static func for_provider(provider: BaseProvider, request: Dictionary = {}) -> Dictionary:
	var offering := _offering(provider)
	if not offering.success:
		return failure(offering.error_code, offering.error_message)
	var entry: Dictionary = offering.entry
	var schema: Dictionary = entry.generation_options
	var profile: Dictionary = entry.get("generation_profile", {})
	var result := resolve(schema, saved_for(provider), request.get(CHAT_LAYER, {}), request, provider.display_name, profile)
	if result.success:
		var notice: String = str(result.notice)
		if not notice.is_empty():
			var cleaned: Dictionary = result.model_options
			var persisted := save_model(provider, cleaned)
			if not persisted.success:
				return persisted
			provider.notify_generation_options(notice)
			push_warning(notice)
		for name in PROTOCOL:
			if request.has(name):
				result.payload[name] = request[name]
	return result


## Persist the replacement before applying it in memory. Empty values mean inherit.
static func save_model(provider: BaseProvider, raw: Variant) -> Dictionary:
	var offering := _offering(provider)
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
	request = reasoning_request(provider, request)
	var params: Dictionary = {}
	if provider is CoreProvider:
		params = request.duplicate(true)
		params[CHAT_LAYER] = history.GenerationOverrides.duplicate(true)
	elif provider.PROVIDER == SingletonObject.API_PROVIDER.OPENAI and not provider is OpenAIImageProvider:
		params = {"temperature": history.Temperature, "top_p": history.TopP,
			"presence_penalty": history.PresencePenalty, "frequency_penalty": history.FrequencyPenalty}
		params.merge(request, true)
	else:
		for option: String in REASONING_KEYS:
			if request.has(option):
				params[option] = request[option]
	return params


## Replayed request intent is checked against its destination; model choices win.
static func reasoning_request(provider: BaseProvider, request: Dictionary) -> Dictionary:
	var filtered := request.duplicate(true)
	var schema := schema_for(provider)
	var saved := saved_for(provider)
	for name: String in REASONING_KEYS:
		if not filtered.has(name):
			continue
		var rule: Dictionary = schema.get(name, {})
		if saved.has(name) or rule.is_empty() or not CoreModelDescriptor.value_matches(filtered[name], rule):
			filtered.erase(name)
	if filtered.get("enable_thinking") == false or saved.get("enable_thinking") == false:
		filtered.erase("reasoning_effort")
	return filtered


static func failure(code: String, message: String) -> Dictionary:
	return {"success": false, "error_code": code, "error": message, "error_message": message}


## Public APIs accept generation options only, never private layers or protocol data.
static func public_request(provider: BaseProvider, raw: Variant) -> Dictionary:
	var offering := _offering(provider)
	if not offering.success:
		return failure(offering.error_code, offering.error_message)
	return normalize(offering.entry.generation_options, raw)


static func set_chat(history: ChatHistory, raw: Variant) -> Dictionary:
	if not history.provider is CoreProvider:
		return failure("model_only_generation_option", "API reasoning preferences are saved per model")
	var checked := public_request(history.provider, raw)
	if not checked.success:
		return checked
	var values: Dictionary = checked.values
	if values.has("reasoning_effort") or values.has("enable_thinking"):
		return failure("model_only_generation_option", "Reasoning preferences are saved per model")
	if values.has("temperature"):
		history.Temperature = values.temperature
	history.GenerationOverrides = values.duplicate(true)
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
			if name == "max_tokens":
				values[name] = int(raw[name])
			else:
				values[name] = float(raw[name])
	return {"success": true, "values": values}

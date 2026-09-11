class_name ModelResolver
extends RefCounted
## Shared chat model construction. Explicit selections never fall back to another model.


static func create(spec: Dictionary, for_plugin: bool = false) -> Dictionary:
	var provider: BaseProvider
	if spec.get("kind") == "core_action":
		var result := CoreModelCatalog.create_provider(spec)
		if not result.success:
			return _failure(result.error_code, result.error_message, spec)
		provider = result.provider
	else:
		var kind: String = str(spec.get("kind", ""))
		var raw_id: Variant = spec.get("model_id", -1)
		if kind not in ["builtin", "dynamic"] or not (raw_id is int or raw_id is float) \
				or not is_finite(float(raw_id)) or float(raw_id) != floor(float(raw_id)):
			return _failure("invalid_model_spec", "Expected a core_action, builtin or dynamic model spec", spec)
		var model_id := int(raw_id)
		if model_id == SingletonObject.API_MODEL_PROVIDERS.TURNROCK:
			return _failure("invalid_model_spec", "TurnRock requires a service/action model_spec", spec)
		if kind == "dynamic" and model_id >= SingletonObject.DYNAMIC_MODEL_ID_BASE:
			provider = SingletonObject.create_dynamic_provider(model_id)
		elif kind == "builtin" and model_id < SingletonObject.DYNAMIC_MODEL_ID_BASE \
				and SingletonObject.API_MODEL_PROVIDER_SCRIPTS.has(model_id):
			provider = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[model_id].new()
		if provider == null:
			return _failure("model_not_available", "The selected model is not registered", spec)
	if not SingletonObject.is_provider_enabled(provider.PROVIDER):
		provider.free()
		return _failure("provider_disabled", "The selected model provider is disabled", spec)
	if for_plugin and not SingletonObject.is_provider_allowed_for_plugins(provider.PROVIDER):
		provider.free()
		return _failure("provider_disabled", "Plugin use of the selected provider is disabled", spec)
	return {"success": true, "provider": provider, "model_spec": spec.duplicate(true)}


static func create_by_name(provider_key: String, model_name: String, for_plugin: bool = false) -> Dictionary:
	var matches: Array[Dictionary] = []
	var requested := model_name.to_lower()
	var target := SingletonObject.provider_from_key(provider_key) if not provider_key.is_empty() else -1
	if not provider_key.is_empty() and target < 0:
		return _failure("model_not_available", "Unknown provider: %s" % provider_key)
	if provider_key.is_empty() or target == SingletonObject.API_PROVIDER.TURNROCK:
		for entry in CoreModelCatalog.list_models(null, null, true):
			if str(entry.model_name).to_lower() == requested or str(entry.display).to_lower() == requested:
				matches.append(entry.model_spec)
	for id_base in SingletonObject._dynamic_provider_map:
		var entry: Dictionary = SingletonObject._dynamic_provider_map[id_base]
		if target >= 0 and int(entry.get("provider", -1)) != target:
			continue
		var manager = entry.get("manager")
		if manager == null:
			continue
		for config in manager.models:
			if str(config.get("model_name", "")).to_lower() == requested:
				matches.append({"kind": "dynamic", "model_id": int(config.get("id", -1))})
	for id in SingletonObject.API_MODEL_PROVIDER_SCRIPTS:
		if id >= SingletonObject.DYNAMIC_MODEL_ID_BASE or id == SingletonObject.API_MODEL_PROVIDERS.TURNROCK:
			continue
		if target >= 0 and SingletonObject.MODEL_TO_PROVIDER.get(id, -1) != target:
			continue
		var candidate: BaseProvider = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[id].new()
		if candidate.model_name.to_lower() == requested:
			matches.append({"kind": "builtin", "model_id": id})
		candidate.free()
	if matches.size() > 1:
		return _failure("model_ambiguous", "Multiple models match this name; use model_spec")
	if matches.is_empty():
		if target == SingletonObject.API_PROVIDER.TURNROCK:
			var reason := CoreModelCatalog.availability()
			if not reason.is_empty():
				return _failure(reason.code, reason.message)
		return _failure("model_not_available", "Model is not available: %s" % model_name)
	return create(matches[0], for_plugin)


static func spec_for(provider: BaseProvider) -> Dictionary:
	if provider == null:
		return {}
	if provider is CoreProvider:
		return provider.get_model_spec()
	if provider.has_meta("dynamic_model_id"):
		return {"kind": "dynamic", "model_id": int(provider.get_meta("dynamic_model_id"))}
	for id in SingletonObject.API_MODEL_PROVIDER_SCRIPTS:
		if id < SingletonObject.DYNAMIC_MODEL_ID_BASE and SingletonObject.API_MODEL_PROVIDER_SCRIPTS[id] == provider.get_script():
			return {"kind": "builtin", "model_id": id}
	return {}


## Restore identity even if discovery/authentication has not completed yet.
static func restore_core(spec: Dictionary) -> CoreProvider:
	var provider := CoreProvider.new()
	provider.set_chat_model_spec(spec)
	return provider


## Catalog rows retain stable specs plus supported model-management metadata.
static func catalog_models(key: String) -> Array:
	var target := SingletonObject.provider_from_key(key)
	if target < 0 or not SingletonObject.is_provider_enabled(target):
		return []
	if target == SingletonObject.API_PROVIDER.TURNROCK:
		return CoreModelCatalog.list_models()
	var rows: Array = []
	for id in SingletonObject.API_MODEL_PROVIDER_SCRIPTS:
		if id >= SingletonObject.DYNAMIC_MODEL_ID_BASE or SingletonObject.MODEL_TO_PROVIDER.get(id, -1) != target:
			continue
		var provider: BaseProvider = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[id].new()
		rows.append({"id": id, "name": provider.display_name, "display": provider.display_name,
			"provider": key, "model_name": provider.model_name, "is_dynamic": false,
			"model_spec": {"kind": "builtin", "model_id": id}})
		provider.free()
	for base in SingletonObject._dynamic_provider_map:
		var entry: Dictionary = SingletonObject._dynamic_provider_map[base]
		if int(entry.get("provider", -1)) != target or entry.get("manager") == null:
			continue
		for config in entry.manager.models:
			var id := int(config.get("id", -1))
			var name: String = str(config.get("model_name", config.get("api_model_id", "")))
			if name.is_empty():
				continue
			var label: String = str(config.get("display_name", name))
			var row := {"id": id, "name": label, "display": label, "provider": key,
				"model_name": name, "is_dynamic": true, "model_spec": {"kind": "dynamic", "model_id": id}}
			for field in ["provider_kind", "reasoning_effort", "supported_reasoning_levels", "reasoning_description",
				"supports_reasoning_summaries", "default_reasoning_summary", "support_verbosity", "default_verbosity",
				"additional_speed_tiers", "input_modalities", "supports_parallel_tool_calls", "supports_search_tool",
				"web_search_tool_type", "apply_patch_tool_type", "experimental_supported_tools", "priority", "catalog_key"]:
				if config.has(field):
					row[field] = config[field]
			row["supports_image_generation"] = "image" in config.get("input_modalities", [])
			rows.append(row)
	return rows


static func catalog_providers() -> Array:
	var providers: Array = []
	for value in SingletonObject.API_PROVIDER.values():
		var key: String = SingletonObject.provider_key(value)
		if not catalog_models(key).is_empty():
			providers.append({"key": key, "display": SingletonObject.get_provider_display_name(value)})
	return providers


static func list_models(key: String, for_plugin: bool = false) -> Array:
	var target := SingletonObject.provider_from_key(key)
	if for_plugin and (target < 0 or not SingletonObject.is_provider_allowed_for_plugins(target)):
		return []
	return catalog_models(key)


static func list_providers(for_plugin: bool = false) -> Array:
	var out: Array = []
	for entry in catalog_providers():
		if not for_plugin or SingletonObject.is_provider_allowed_for_plugins(SingletonObject.provider_from_key(entry.key)):
			out.append(entry)
	return out


## Discovery and socket events refresh after the Core mutation that emitted them.
static func watch_core_changes(callback: Callable) -> void:
	var core := CoreActionCatalog.core_node()
	if core == null:
		return
	for source: Object in [core, core.client]:
		if source == null:
			continue
		for definition in source.get_signal_list():
			if definition.name not in ["service_connected", "_services_fetch_completed", "http_connection_changed", "connection_closed", "connection_established"]:
				continue
			var adapted := callback.unbind(definition.args.size())
			if not source.is_connected(definition.name, adapted):
				source.connect(definition.name, adapted, CONNECT_DEFERRED)


static func _failure(code: String, message: String, spec: Dictionary = {}) -> Dictionary:
	return {"success": false, "error_code": code, "error_message": message, "error": message, "model_spec": spec}

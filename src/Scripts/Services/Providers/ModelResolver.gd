class_name ModelResolver
extends RefCounted
## Shared chat model construction. Explicit selections never fall back to another model.


static func selection_schema() -> Dictionary:
	return {"type": "object", "description": "Stable model_spec from minerva_list_models. Kinds: builtin/dynamic with model_id; core_action with service_client_id/action_name; plugin_provider with entry_key (plugin:<plugin_id>:<entry_id>). Plugin alias: {kind:plugin,plugin_id,entry_id}. Takes precedence over provider name/enum."}


static func create(spec: Dictionary, for_plugin: bool = false, allow_disabled: bool = false) -> Dictionary:
	var provider: BaseProvider
	if spec.get("kind") in ["plugin_provider", "plugin"]:
		if for_plugin:
			return _failure("provider_disabled", "Plugin chat providers cannot be used as plugin member models", spec)
		var identity := plugin_identity(spec)
		if not identity.success:
			return identity
		var entry := plugin_entry(identity.model_spec.entry_key)
		if entry.is_empty():
			return _failure("model_not_available", "Plugin chat entry is not registered", identity.model_spec)
		provider = PluginProvider.new().configure_from_entry(entry)
		return {"success": true, "provider": provider, "model_spec": identity.model_spec}
	if spec.get("kind") == "core_action":
		var result := CoreModelCatalog.create_provider(spec)
		if not result.success and allow_disabled and result.error_code == "provider_disabled":
			return {"success": true, "provider": restore_core(spec), "model_spec": spec.duplicate(true)}
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
	if for_plugin and not provider.supports_chat:
		provider.free()
		return _failure("not_chat_model", "The selected model is not a conversational model", spec)
	if not allow_disabled and not SingletonObject.is_provider_enabled(provider.PROVIDER):
		var label := SingletonObject.get_provider_display_name(provider.PROVIDER)
		provider.free()
		return _failure("provider_disabled", "%s is disabled" % label, spec)
	if for_plugin and not SingletonObject.is_provider_allowed_for_plugins(provider.PROVIDER):
		var label := SingletonObject.get_provider_display_name(provider.PROVIDER)
		provider.free()
		return _failure("provider_disabled", "Plugin use of %s is disabled. Allow this provider for plugins in Preferences." % label, spec)
	return {"success": true, "provider": provider, "model_spec": spec.duplicate(true)}


static func create_by_name(provider_key: String, model_name: String, for_plugin: bool = false, allow_disabled: bool = false) -> Dictionary:
	if model_name.begins_with("plugin:"):
		return create({"kind": "plugin_provider", "entry_key": model_name}, for_plugin, allow_disabled)
	var matches: Array[Dictionary] = []
	var display_matches: Array[Dictionary] = []
	var requested := model_name.to_lower()
	var target := SingletonObject.provider_from_key(provider_key) if not provider_key.is_empty() else -1
	if not provider_key.is_empty() and target < 0:
		return _failure("model_not_available", "Unknown provider: %s" % provider_key)
	if provider_key.is_empty() or target == SingletonObject.API_PROVIDER.TURNROCK:
		for entry in CoreModelCatalog.list_models(null, null, true):
			if str(entry.model_name).to_lower() == requested:
				matches.append(entry.model_spec)
			elif str(entry.display).to_lower() == requested:
				display_matches.append(entry.model_spec)
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
			elif str(config.get("display_name", "")).to_lower() == requested:
				display_matches.append({"kind": "dynamic", "model_id": int(config.get("id", -1))})
	for id in SingletonObject.API_MODEL_PROVIDER_SCRIPTS:
		if id >= SingletonObject.DYNAMIC_MODEL_ID_BASE or id == SingletonObject.API_MODEL_PROVIDERS.TURNROCK:
			continue
		if target >= 0 and SingletonObject.MODEL_TO_PROVIDER.get(id, -1) != target:
			continue
		var candidate: BaseProvider = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[id].new()
		if candidate.model_name.to_lower() == requested:
			matches.append({"kind": "builtin", "model_id": id})
		elif candidate.display_name.to_lower() == requested:
			display_matches.append({"kind": "builtin", "model_id": id})
		candidate.free()
	if matches.is_empty():
		matches = display_matches
	if matches.size() > 1:
		return _failure("model_ambiguous", "Multiple models match this name; use model_spec")
	if matches.is_empty():
		if target == SingletonObject.API_PROVIDER.TURNROCK:
			var reason := CoreModelCatalog.availability()
			if not reason.is_empty():
				return _failure(reason.code, reason.message)
		return _failure("model_not_available", "Model is not available: %s" % model_name)
	return create(matches[0], for_plugin, allow_disabled)


static func spec_for(provider: BaseProvider) -> Dictionary:
	if provider == null:
		return {}
	if provider is PluginProvider:
		return {"kind": "plugin_provider", "entry_key": provider.entry_key}
	if provider is CoreProvider:
		return provider.get_model_spec()
	if provider.has_meta("dynamic_model_id"):
		return {"kind": "dynamic", "model_id": int(provider.get_meta("dynamic_model_id"))}
	for id in SingletonObject.API_MODEL_PROVIDER_SCRIPTS:
		if id < SingletonObject.DYNAMIC_MODEL_ID_BASE and SingletonObject.API_MODEL_PROVIDER_SCRIPTS[id] == provider.get_script():
			return {"kind": "builtin", "model_id": id}
	return {}


static func copy_selection(provider: BaseProvider) -> Dictionary:
	var spec := spec_for(provider)
	if spec.get("kind") == "core_action":
		return {"success": true, "provider": restore_core(spec)}
	if spec.get("kind") == "plugin_provider":
		return {"success": true, "provider": restore_plugin(spec.entry_key)}
	return create(spec)


## Restore identity even if discovery/authentication has not completed yet.
static func restore_core(spec: Dictionary) -> CoreProvider:
	var provider := CoreProvider.new()
	provider.set_chat_model_spec(spec)
	return provider


## Canonicalize aliases once; entry IDs may contain colons, plugin IDs may not.
static func plugin_identity(spec: Dictionary) -> Dictionary:
	var key: Variant = spec.get("entry_key", "")
	if spec.get("kind") == "plugin":
		var plugin: Variant = spec.get("plugin_id")
		var entry: Variant = spec.get("entry_id")
		if not plugin is String or not entry is String or plugin.is_empty() or entry.is_empty() or ":" in plugin:
			return _failure("invalid_model_spec", "Plugin selection requires plugin_id and entry_id", spec)
		key = PluginChatProviderRegistry.make_key(plugin, entry)
	if not key is String:
		return _failure("invalid_model_spec", "Plugin entry_key must be a string", spec)
	var parts: PackedStringArray = key.split(":", true, 2)
	if parts.size() != 3 or parts[0] != "plugin" or parts[1].is_empty() or parts[2].is_empty():
		return _failure("invalid_model_spec", "Expected plugin:<plugin_id>:<entry_id>", spec)
	return {"success": true, "model_spec": {"kind": "plugin_provider", "entry_key": key},
		"plugin_id": parts[1], "entry_id": parts[2]}


static func plugin_entry(key: String) -> Dictionary:
	var registry = SingletonObject.plugin_chat_provider_registry
	return registry.get_entry(key) if registry != null else {}


## Saved identity remains addressable while its registration is absent.
static func restore_plugin(key: String) -> PluginProvider:
	var provider := PluginProvider.new()
	var entry := plugin_entry(key)
	if not entry.is_empty():
		return provider.configure_from_entry(entry)
	provider.entry_key = key
	provider.model_name = key
	provider.display_name = key
	var identity := plugin_identity({"kind": "plugin_provider", "entry_key": key})
	if identity.success:
		provider.plugin_id = identity.plugin_id
		provider.entry_id = identity.entry_id
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
		if not provider.supports_chat:
			provider.free()
			continue
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
	if key == "plugin":
		if for_plugin or SingletonObject.plugin_chat_provider_registry == null:
			return []
		var rows: Array = []
		for entry in SingletonObject.plugin_chat_provider_registry.list_entries():
			rows.append({"model_name": entry.key, "display": entry.display_name, "provider": "plugin",
				"plugin_id": entry.plugin_id, "entry_id": entry.entry_id,
				"model_spec": {"kind": "plugin_provider", "entry_key": entry.key}})
		return rows
	var target := SingletonObject.provider_from_key(key)
	if for_plugin and (target < 0 or not SingletonObject.is_provider_allowed_for_plugins(target)):
		return []
	return catalog_models(key)


static func list_providers(for_plugin: bool = false) -> Array:
	var out: Array = []
	for entry in catalog_providers():
		if not for_plugin or SingletonObject.is_provider_allowed_for_plugins(SingletonObject.provider_from_key(entry.key)):
			out.append(entry)
	if not for_plugin and not list_models("plugin").is_empty():
		out.append({"key": "plugin", "display": "Plugins"})
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


## Actual request refusals must reach the user as well as the calling tool.
## Reuse the single error window; catalog discovery does not call this method.
static func show_provider_refusal(code: String, message: String) -> void:
	if code != "provider_disabled":
		return
	if not is_instance_valid(SingletonObject.errorPopup) or not is_instance_valid(SingletonObject.errorTitle) or not is_instance_valid(SingletonObject.errorText):
		return # UI is not mounted in headless tools or during startup.
	SingletonObject.ErrorDisplay("Provider unavailable", "%s\n\nCheck the provider settings in Preferences, then try again." % message)


static func _failure(code: String, message: String, spec: Dictionary = {}) -> Dictionary:
	return {"success": false, "error_code": code, "error_message": message, "error": message, "model_spec": spec}

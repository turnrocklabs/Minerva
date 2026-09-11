class_name CoreModelCatalog
extends RefCounted
## Public Core chat offerings, stable resolution and availability for all callers.


static func settings_host() -> Node:
	var tree := Engine.get_main_loop() as SceneTree
	return tree.root.get_node_or_null("SingletonObject") if tree != null else null


static func settings_key(spec: Dictionary) -> String:
	if spec.get("kind") != "core_action" or not spec.get("service_client_id") is String \
			or not spec.get("action_name") is String:
		return ""
	if spec.service_client_id.is_empty() or spec.action_name.is_empty():
		return ""
	return "core_action:" + Marshalls.raw_to_base64(JSON.stringify(
		[spec.service_client_id, spec.action_name]).to_utf8_buffer())


## Default lists selectable offerings; include_unavailable also describes cached selections.
static func list_models(core: Node = null, host: Node = null, include_unavailable: bool = false) -> Array[Dictionary]:
	var pairs := CoreActionCatalog.action_pairs(core)
	var counts: Dictionary = {}
	for pair in pairs:
		var key := settings_key(CoreActionCatalog.spec_for(pair.service, pair.action))
		counts[key] = counts.get(key, 0) + 1
	var entries: Array[Dictionary] = []
	for pair in pairs:
		var descriptor := CoreModelDescriptor.describe(pair.service, pair.action)
		if not descriptor.eligible:
			continue
		var entry := _entry(pair, descriptor, core, host)
		if entry.settings_key.is_empty():
			_mark_unavailable(entry, "invalid_model_spec", "The model identity is incomplete")
		elif counts[entry.settings_key] != 1:
			_mark_unavailable(entry, "model_ambiguous", "Multiple Core actions advertise this exact model identity")
		if include_unavailable or entry.available:
			entries.append(entry)
	return entries


## Resolves only the requested tuple. Error responses retain that tuple unchanged.
static func resolve(spec: Dictionary, core: Node = null, host: Node = null) -> Dictionary:
	var key := settings_key(spec)
	if key.is_empty():
		return _failure(spec, "invalid_model_spec", "Core models require a nonempty service_client_id and action_name")
	var matches := CoreActionCatalog.find_matches(spec.service_client_id, spec.action_name, core)
	if matches.size() > 1:
		return _failure(spec, "model_ambiguous", "Multiple Core actions advertise this exact model identity")
	if matches.is_empty():
		var reason := availability(core, host)
		return _failure(spec, reason.code if not reason.is_empty() else "model_not_available",
			reason.message if not reason.is_empty() else "The selected Core action is not currently advertised")
	var pair: Dictionary = matches[0]
	var descriptor := CoreModelDescriptor.describe(pair.service, pair.action)
	if not descriptor.valid:
		return _failure(spec, "invalid_model_descriptor", "; ".join(descriptor.diagnostics))
	if not descriptor.eligible:
		return _failure(spec, "not_chat_model", "The selected Core action is a service operation, not a public chat model")
	var entry := _entry(pair, descriptor, core, host)
	if not entry.available:
		return _failure(spec, entry.unavailable_reason, entry.unavailable_message)
	return {"success": true, "entry": entry, "service": pair.service, "action": pair.action}


static func create_provider(spec: Dictionary, core: Node = null, host: Node = null) -> Dictionary:
	var result := resolve(spec, core, host)
	if not result.success:
		return result
	var provider := CoreProvider.new(result.service, result.action)
	provider.requires_chat_model = true
	result["provider"] = provider
	return result


static func availability(core: Node = null, host: Node = null) -> Dictionary:
	var settings := host if host != null else settings_host()
	if settings == null or not settings.is_provider_enabled(settings.provider_from_key("turnrock")):
		return {"code": "provider_disabled", "message": "TurnRock chat is disabled"}
	var node := core if core != null else CoreActionCatalog.core_node()
	if node == null or not ("client" in node) or node.client == null \
			or not node.client._connected or node.connecting or not node.registered:
		return {"code": "core_offline", "message": "Core is not connected and registered"}
	return {}


static func _entry(pair: Dictionary, descriptor: Dictionary, core: Node, host: Node) -> Dictionary:
	var spec := CoreActionCatalog.spec_for(pair.service, pair.action)
	var entry := {"model_name": pair.action.name, "display": CoreActionCatalog.display_for(pair.service, pair.action),
		"model_spec": spec, "settings_key": settings_key(spec), "generation_options": descriptor.generation_options,
		"legacy": descriptor.legacy, "diagnostics": descriptor.diagnostics, "available": true,
		"unavailable_reason": "", "unavailable_message": ""}
	if not descriptor.valid:
		_mark_unavailable(entry, "invalid_model_descriptor", "; ".join(descriptor.diagnostics))
	else:
		var reason := availability(core, host)
		if not reason.is_empty():
			_mark_unavailable(entry, reason.code, reason.message)
	return entry


static func _mark_unavailable(entry: Dictionary, code: String, message: String) -> void:
	entry.available = false
	entry.unavailable_reason = code
	entry.unavailable_message = message


static func _failure(spec: Dictionary, code: String, message: String) -> Dictionary:
	return {"success": false, "error_code": code, "error_message": message,
		"model_spec": spec.duplicate(true), "settings_key": settings_key(spec)}

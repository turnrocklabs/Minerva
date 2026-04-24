class_name ChatGPTModelManager
extends ProviderModelManager
## Discovers ChatGPT/Codex models available to the signed-in ChatGPT account.

const CHATGPT_MODELS_URL := "https://chatgpt.com/backend-api/codex/models"
const CLIENT_VERSION := "0.0.0"
const CHATGPT_MODEL_ID_BASE := 60000


func _init() -> void:
	super("user://chatgpt_models.json", CHATGPT_MODEL_ID_BASE)


func fetch_available_models(scene_tree: SceneTree) -> Dictionary:
	var chatgpt_auth := SingletonObject.ChatGPTProviderScript.get_auth()
	if not chatgpt_auth.is_authenticated():
		chatgpt_auth.load_tokens()
	if not chatgpt_auth.is_authenticated():
		return {"success": false, "error": "ChatGPT is not connected."}

	var token_valid: bool = await chatgpt_auth.ensure_valid_token(scene_tree)
	if not token_valid:
		return {"success": false, "error": "ChatGPT token expired. Please reconnect via Preferences."}

	var http := HTTPRequest.new()
	scene_tree.root.add_child(http)
	var url := "%s?client_version=%s" % [CHATGPT_MODELS_URL, CLIENT_VERSION.uri_encode()]
	var headers: Array[String] = [
		"Authorization: Bearer %s" % chatgpt_auth.access_token,
		"ChatGPT-Account-ID: %s" % chatgpt_auth.account_id,
		"originator: codex_cli_rs",
	]

	var err := http.request(url, headers, HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return {"success": false, "error": "Failed to start ChatGPT model discovery."}

	var result: Array = await http.request_completed
	http.queue_free()

	var response_code: int = result[1]
	var body: PackedByteArray = result[3]
	if response_code < 200 or response_code > 299:
		return {"success": false, "error": "ChatGPT model discovery failed (HTTP %d)." % response_code}

	var data = JSON.parse_string(body.get_string_from_utf8())
	if not data is Dictionary:
		return {"success": false, "error": "ChatGPT model discovery returned invalid JSON."}

	var remote_models: Array = data.get("models", [])
	if remote_models.is_empty():
		return {"success": false, "error": "ChatGPT model discovery returned no models."}

	var normalized := _normalize_models(remote_models)
	if normalized.is_empty():
		return {"success": false, "error": "No visible ChatGPT models were found."}

	return {"success": true, "models": normalized, "count": normalized.size()}


func refresh_from_account(scene_tree: SceneTree) -> Dictionary:
	var result: Dictionary = await fetch_available_models(scene_tree)
	if not result.get("success", false):
		return result
	var normalized: Array = result.get("models", [])
	_replace_discovered_models(normalized)
	return {"success": true, "count": normalized.size()}


func _normalize_models(remote_models: Array) -> Array[Dictionary]:
	var normalized: Array[Dictionary] = []
	for item in remote_models:
		if not item is Dictionary:
			continue
		var slug: String = str(item.get("slug", item.get("model", "")))
		if slug.is_empty():
			continue
		var visibility: String = str(item.get("visibility", "list")).to_lower()
		if visibility == "hide" or visibility == "none":
			continue

		var display_name: String = str(item.get("display_name", slug))
		var default_reasoning: String = str(item.get("default_reasoning_level", ""))
		var supported_reasoning: Array = item.get("supported_reasoning_levels", [])
		var default_summary := _normalize_reasoning_summary(str(item.get("default_reasoning_summary", "auto")))

		var base_config := {
			"model_name": slug,
			"display_name": display_name,
			"short_name": _generate_short_name(display_name),
			"input_token_cost": 0.0,
			"output_token_cost": 0.0,
			"is_reasoning_model": not supported_reasoning.is_empty() or not default_reasoning.is_empty(),
			"reasoning_effort": default_reasoning,
			"default_reasoning_level": default_reasoning,
			"supported_reasoning_levels": supported_reasoning,
			"description": str(item.get("description", "")),
			"supports_reasoning_summaries": bool(item.get("supports_reasoning_summaries", false)),
			"default_reasoning_summary": default_summary,
			"support_verbosity": bool(item.get("support_verbosity", false)),
			"default_verbosity": item.get("default_verbosity", null),
			"additional_speed_tiers": item.get("additional_speed_tiers", []),
			"input_modalities": item.get("input_modalities", ["text", "image"]),
			"visibility": visibility,
			"supported_in_api": bool(item.get("supported_in_api", false)),
			"priority": int(item.get("priority", 0)),
			"context_window": item.get("context_window", null),
			"max_context_window": item.get("max_context_window", null),
			"auto_compact_token_limit": item.get("auto_compact_token_limit", null),
			"supports_parallel_tool_calls": bool(item.get("supports_parallel_tool_calls", false)),
			"supports_search_tool": bool(item.get("supports_search_tool", false)),
			"web_search_tool_type": str(item.get("web_search_tool_type", "text")),
			"apply_patch_tool_type": item.get("apply_patch_tool_type", null),
			"experimental_supported_tools": item.get("experimental_supported_tools", []),
			"raw_model_info": item,
		}
		if supported_reasoning.is_empty():
			var config := base_config.duplicate(true)
			config["catalog_key"] = slug
			normalized.append(config)
		else:
			for preset in supported_reasoning:
				if not preset is Dictionary:
					continue
				var effort: String = str(preset.get("effort", ""))
				if effort.is_empty():
					continue
				var config := base_config.duplicate(true)
				config["catalog_key"] = "%s:%s" % [slug, effort]
				config["reasoning_effort"] = effort
				config["display_name"] = "%s (%s)" % [display_name, _title_case_effort(effort)]
				config["reasoning_description"] = str(preset.get("description", ""))
				normalized.append(config)

	normalized.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("priority", 0)) > int(b.get("priority", 0))
	)
	return normalized


func _replace_discovered_models(new_models: Array[Dictionary]) -> void:
	var ids_by_key := {}
	for existing in models:
		var existing_key: String = str(existing.get("catalog_key", existing.get("model_name", "")))
		ids_by_key[existing_key] = int(existing.get("id", 0))

	var refreshed: Array[Dictionary] = []
	for model in new_models:
		var config := model.duplicate(true)
		var catalog_key: String = str(config.get("catalog_key", config.get("model_name", "")))
		if ids_by_key.has(catalog_key):
			config["id"] = ids_by_key[catalog_key]
		else:
			config["id"] = _next_id
			_next_id += 1
		refreshed.append(config)

	models = refreshed
	save_config()
	models_changed.emit()


func _generate_short_name(display_name: String) -> String:
	var short := ""
	var words := display_name.replace("-", " ").replace(".", " ").split(" ")
	for word in words:
		if not word.is_empty() and word[0].to_upper() != word[0].to_lower():
			short += word[0].to_upper()
		if short.length() >= 4:
			break
	if short.is_empty():
		short = "CG"
	return short.left(5)


func _title_case_effort(effort: String) -> String:
	if effort == "xhigh":
		return "XHigh"
	return effort.substr(0, 1).to_upper() + effort.substr(1)


func _normalize_reasoning_summary(summary: String) -> String:
	var normalized := summary.strip_edges().to_lower()
	if normalized in ["concise", "detailed", "auto"]:
		return normalized
	return ""

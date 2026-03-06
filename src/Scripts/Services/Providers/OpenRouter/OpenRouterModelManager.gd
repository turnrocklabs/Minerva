class_name OpenRouterModelManager
extends ProviderModelManager
## OpenRouter-specific model manager with API model fetching.

const _CONFIG_PATH := "user://openrouter_models.json"
const _DYNAMIC_ID_BASE := 10000

const DEFAULTS := [
	{"api_model_id": "z-ai/glm-4.7", "display_name": "GLM-4.7", "short_name": "GLM",
	 "input_token_cost": 0.20, "output_token_cost": 0.60, "is_reasoning_model": true},
	{"api_model_id": "minimax/minimax-m2.1", "display_name": "Minimax M2.1", "short_name": "MM2",
	 "input_token_cost": 0.13, "output_token_cost": 0.40, "is_reasoning_model": false},
	{"api_model_id": "moonshotai/kimi-k2.5", "display_name": "Kimi K2.5", "short_name": "KK25",
	 "input_token_cost": 0.50, "output_token_cost": 2.80, "is_reasoning_model": false},
	{"api_model_id": "x-ai/grok-4.1-fast", "display_name": "Grok 4.1 Fast", "short_name": "G41F",
	 "input_token_cost": 0.20, "output_token_cost": 0.50, "is_reasoning_model": false},
]


func _init():
	super(_CONFIG_PATH, _DYNAMIC_ID_BASE, DEFAULTS)


## Convenience wrapper for backward compatibility
func get_model_by_api_id(api_model_id: String) -> Dictionary:
	return get_model_by_name("api_model_id", api_model_id)


## Fetch available models from the OpenRouter API.
## Returns an array of dictionaries with model info, or empty on failure.
func fetch_api_models(api_key: String) -> Array:
	if api_key.is_empty():
		push_warning("[OpenRouterModelManager] No API key provided for model fetch")
		return []

	var http := HTTPRequest.new()
	Engine.get_main_loop().root.add_child(http)

	var headers := [
		"Authorization: Bearer %s" % api_key,
		"HTTP-Referer: https://github.com/minerva-app",
		"X-Title: Minerva"
	]

	var err := http.request("https://openrouter.ai/api/v1/models", headers, HTTPClient.METHOD_GET)
	if err != OK:
		http.queue_free()
		return []

	var result: Array = await http.request_completed
	http.queue_free()

	var response_code: int = result[1]
	var body: PackedByteArray = result[3]

	if response_code < 200 or response_code > 299:
		push_warning("[OpenRouterModelManager] API returned %d" % response_code)
		return []

	var data = JSON.parse_string(body.get_string_from_utf8())
	if not data is Dictionary or not data.has("data"):
		return []

	var api_models: Array = []
	for model in data["data"]:
		if not model is Dictionary:
			continue

		var pricing = model.get("pricing", {})
		var prompt_price := 0.0
		var completion_price := 0.0

		# OpenRouter returns per-token prices as strings
		if pricing is Dictionary:
			var p_str = str(pricing.get("prompt", "0"))
			var c_str = str(pricing.get("completion", "0"))
			prompt_price = p_str.to_float() * 1_000_000.0
			completion_price = c_str.to_float() * 1_000_000.0

		var model_name: String = model.get("name", model.get("id", ""))
		var model_id: String = model.get("id", "")

		api_models.append({
			"api_model_id": model_id,
			"display_name": model_name,
			"short_name": _generate_short_name(model_name),
			"input_token_cost": snapped(prompt_price, 0.01),
			"output_token_cost": snapped(completion_price, 0.01),
			"is_reasoning_model": false,
			"context_length": model.get("context_length", 0),
		})

	return api_models


func _generate_short_name(name: String) -> String:
	var words := name.split(" ")
	var short := ""
	for w in words:
		if not w.is_empty():
			short += w[0].to_upper()
		if short.length() >= 4:
			break
	if short.is_empty():
		short = "OR"
	return short

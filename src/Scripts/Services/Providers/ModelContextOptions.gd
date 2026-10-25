class_name ModelContextOptions
extends RefCounted
## Minerva's model budget, separate from engine generation settings and num_ctx.

const WINDOW: int = 1000000
const KEYS: Array[String] = ["context_window", "auto_compact_at", "max_output_tokens"]


static func schema(maximum_output: int, window: int = WINDOW, minimum_output: int = 1) -> Dictionary:
	var result := {
		"context_window": {"type": "integer", "minimum": 2, "maximum": WINDOW, "default": WINDOW},
		"auto_compact_at": {"type": "integer", "minimum": 1, "maximum": window - 1,
			"default": maxi(1, int(float(window) * 0.2))}}
	if maximum_output > 0:
		result["max_output_tokens"] = {"type": "integer", "minimum": minimum_output,
			"maximum": maximum_output, "default": maximum_output}
	return result


static func resolve(saved: Dictionary, maximum_output: int, minimum_output: int = 1) -> Dictionary:
	var initial := schema(maximum_output, WINDOW, minimum_output)
	var window_value: Variant = saved.get("context_window", WINDOW)
	var window_rule: Dictionary = initial.context_window
	if not CoreModelDescriptor.value_matches(window_value, window_rule):
		return _failure("Context window must be a whole number from 2 to 1,000,000.")
	var window: int = window_value
	var definitions := schema(maximum_output, window, minimum_output)
	var values: Dictionary = {}
	var explicit: Dictionary = {}
	for key: String in KEYS:
		if not definitions.has(key):
			if saved.has(key):
				return _failure("This model publishes no maximum output limit.")
			continue
		var rule: Dictionary = definitions[key]
		var value: Variant = saved.get(key, rule.default)
		if not CoreModelDescriptor.value_matches(value, rule):
			return _failure("Auto-compact must be below the context window." if key == "auto_compact_at"
				else "Max output tokens must be a positive whole number within the model's maximum.")
		var numeric: int = value
		var inherited: int = rule.default
		values[key] = numeric
		if saved.has(key) and numeric != inherited:
			explicit[key] = numeric
	return {"success": true, "values": values, "explicit": explicit, "schema": definitions}


static func _failure(message: String) -> Dictionary:
	return {"success": false, "error_code": "invalid_context_options", "error_message": message}

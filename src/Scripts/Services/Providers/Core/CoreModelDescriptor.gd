class_name CoreModelDescriptor
extends RefCounted
## Validated public chat descriptors. Generic service schemas remain untouched.

const LEGACY_OPTIONS := {
	"temperature": {"type": "number", "default": 0.7, "minimum": 0, "maximum": 2},
	"max_tokens": {"type": "integer", "default": 4000, "minimum": 1},
	"num_ctx": {"type": "integer", "default": 40000, "minimum": 1},
	"num_gpu": {"type": "integer", "minimum": 0},
}


static func describe(service: Service, action: Action) -> Dictionary:
	var result := {"eligible": false, "legacy": false, "valid": true,
		"generation_options": {}, "diagnostics": []}
	if service == null or action == null:
		return result
	var metadata := action.model_metadata
	if metadata.has("chat_model"):
		if not metadata.chat_model is bool:
			result.valid = false
			result.diagnostics.append("chat_model must be a boolean")
			return result
		result.eligible = metadata.chat_model
	else:
		result.legacy = service.client_id == "model-chat"
		result.eligible = result.legacy
	if not result.eligible:
		return result
	if not metadata.has("generation_options"):
		if result.legacy:
			result.generation_options = LEGACY_OPTIONS.duplicate(true)
		else:
			result.valid = false
			result.diagnostics.append("Public chat descriptors require generation_options")
		return result
	var checked := validate_options(metadata.generation_options)
	result.valid = checked.diagnostics.is_empty()
	result.generation_options = checked.options
	result.diagnostics = checked.diagnostics
	return result


static func validate_options(raw: Variant) -> Dictionary:
	var options: Dictionary = {}
	var diagnostics: Array[String] = []
	if not raw is Dictionary:
		return {"options": options, "diagnostics": ["generation_options must be an object"]}
	for name in raw:
		if not name is String or not LEGACY_OPTIONS.has(name):
			diagnostics.append("Unsupported generation option: %s" % str(name).left(128))
			continue
		var definition: Variant = raw[name]
		if not definition is Dictionary or definition.get("type") != LEGACY_OPTIONS[name].type:
			diagnostics.append("Invalid type for generation option: %s" % name)
			continue
		var valid := true
		for field in definition:
			if field not in ["type", "default", "minimum", "maximum"]:
				valid = false
		for field in ["minimum", "maximum", "default"]:
			if definition.has(field) and not _number_matches(definition[field], definition.type):
				valid = false
		if valid:
			var lower: float = definition.get("minimum", LEGACY_OPTIONS[name].minimum)
			var upper: float = definition.get("maximum", 2 if name == "temperature" else INF)
			if lower < LEGACY_OPTIONS[name].minimum or lower > upper:
				valid = false
			if name == "temperature" and upper > 2:
				valid = false
			if definition.has("default") and (definition.default < lower or definition.default > upper):
				valid = false
		if not valid:
			diagnostics.append("Invalid constraints/default for generation option: %s" % name)
			continue
		options[name] = definition.duplicate(true)
		if not options[name].has("minimum"):
			options[name]["minimum"] = LEGACY_OPTIONS[name].minimum
		if name == "temperature" and not options[name].has("maximum"):
			options[name]["maximum"] = 2
	return {"options": options, "diagnostics": diagnostics}


static func _number_matches(value: Variant, type_name: String) -> bool:
	if not (value is int or value is float) or not is_finite(float(value)):
		return false
	return type_name == "number" or float(value) == floor(float(value))

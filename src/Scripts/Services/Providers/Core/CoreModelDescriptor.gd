class_name CoreModelDescriptor
extends RefCounted
## Validated public chat descriptors. Generic service schemas remain untouched.

const LEGACY_OPTIONS := {
	"temperature": {"type": "number", "default": 0.7, "minimum": 0, "maximum": 2},
	"max_tokens": {"type": "integer", "default": 4000, "minimum": 1},
	"num_ctx": {"type": "integer", "default": 40000, "minimum": 1},
	"num_gpu": {"type": "integer", "minimum": 0},
}
const REASONING_TYPES := {"reasoning_effort": "string", "enable_thinking": "boolean"}


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
	var options: Dictionary = checked.options
	var diagnostics: Array = checked.diagnostics
	if service.client_id == "model-chat" and metadata.has("generation_settings"):
		var native := reasoning_options(metadata.generation_settings)
		var native_options: Dictionary = native.options
		var native_diagnostics: Array = native.diagnostics
		options.merge(native_options, true)
		diagnostics.append_array(native_diagnostics)
	result.generation_options = options
	result.diagnostics = diagnostics
	result.valid = diagnostics.is_empty()
	return result


## Consume the additive native profile, keeping its names and values unchanged.
static func reasoning_options(raw: Variant) -> Dictionary:
	if not raw is Dictionary:
		return {"options": {}, "diagnostics": ["Invalid native generation_settings profile"]}
	var profile: Dictionary = raw
	if profile.get("version") != 1 or not profile.get("parameters") is Dictionary:
		return {"options": {}, "diagnostics": ["Invalid native generation_settings profile"]}
	var parameters: Dictionary = profile.parameters
	var options: Dictionary = {}
	for name: String in REASONING_TYPES:
		if not parameters.has(name):
			continue
		var raw_parameter: Variant = parameters[name]
		if not raw_parameter is Dictionary:
			return {"options": {}, "diagnostics": ["Invalid native generation setting: " + name]}
		var parameter: Dictionary = raw_parameter
		if not parameter.get("supported") is bool:
			return {"options": {}, "diagnostics": ["Invalid native generation setting: " + name]}
		if not parameter.supported:
			continue
		var rule: Dictionary = {}
		for field: String in ["type", "enum", "default", "inactive_when"]:
			if parameter.has(field):
				rule[field] = parameter[field]
		options[name] = rule
	return validate_options(options)


static func option_type(name: String) -> String:
	return str(LEGACY_OPTIONS[name].type) if LEGACY_OPTIONS.has(name) else str(REASONING_TYPES.get(name, ""))


static func validate_options(raw: Variant) -> Dictionary:
	var options: Dictionary = {}
	var diagnostics: Array[String] = []
	if not raw is Dictionary:
		return {"options": options, "diagnostics": ["generation_options must be an object"]}
	var definitions: Dictionary = raw
	for raw_name: Variant in definitions:
		if not raw_name is String or option_type(str(raw_name)).is_empty():
			diagnostics.append("Unsupported generation option: %s" % str(raw_name).left(128))
			continue
		var name: String = str(raw_name)
		var raw_definition: Variant = definitions[name]
		if not raw_definition is Dictionary:
			diagnostics.append("Invalid type for generation option: %s" % name)
			continue
		var definition: Dictionary = raw_definition
		var type_name := option_type(name)
		if definition.get("type") != type_name:
			diagnostics.append("Invalid type for generation option: %s" % name)
			continue
		var valid := true
		if name in REASONING_TYPES:
			for field: Variant in definition:
				if field not in ["type", "enum", "default", "inactive_when"]:
					valid = false
			var choices: Variant = definition.get("enum")
			if not choices is Array:
				valid = false
			else:
				var enum_values: Array = choices
				if enum_values.is_empty():
					valid = false
				var seen: Array = []
				for choice: Variant in enum_values:
					if not _type_matches(choice, type_name) or choice in seen:
						valid = false
					seen.append(choice)
			if definition.has("default") and not value_matches(definition.default, definition):
				valid = false
			if definition.has("inactive_when"):
				var raw_condition: Variant = definition.inactive_when
				if not raw_condition is Dictionary:
					valid = false
				else:
					var condition: Dictionary = raw_condition
					if name != "reasoning_effort" or condition.size() != 1 or not condition.get("enable_thinking") is bool:
						valid = false
			if valid:
				options[name] = definition.duplicate(true)
			else:
				diagnostics.append("Invalid constraints/default for generation option: %s" % name)
			continue
		for field in definition:
			if field not in ["type", "default", "minimum", "maximum"]:
				valid = false
		for field in ["minimum", "maximum", "default"]:
			if definition.has(field) and not _number_matches(definition[field], definition.type):
				valid = false
		if valid:
			var lower: float = definition.get("minimum", LEGACY_OPTIONS[name].minimum)
			var default_upper := INF
			if name == "temperature":
				default_upper = 2.0
			var upper: float = definition.get("maximum", default_upper)
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


static func _type_matches(value: Variant, type_name: String) -> bool:
	if type_name == "string":
		return value is String
	if type_name == "boolean":
		return value is bool
	return _number_matches(value, type_name)


static func value_matches(value: Variant, rule: Dictionary) -> bool:
	if not _type_matches(value, str(rule.type)):
		return false
	if rule.has("enum") and (not rule.enum is Array or value not in rule.enum):
		return false
	if rule.type in ["number", "integer"]:
		return not (rule.type == "integer" and value is float and value >= 9223372036854775808.0) \
			and value >= rule.get("minimum", -INF) and value <= rule.get("maximum", INF)
	return true


static func _number_matches(value: Variant, type_name: String) -> bool:
	if not (value is int or value is float) or not is_finite(float(value)):
		return false
	return type_name == "number" or float(value) == floor(float(value))

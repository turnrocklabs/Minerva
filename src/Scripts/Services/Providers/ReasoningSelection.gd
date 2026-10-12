class_name ReasoningSelection
extends RefCounted
## Validate a saved chat override against the currently selected model.

static func validate(effort: String, levels: Array) -> String:
	if effort.is_empty():
		return ""
	var native_effort := "none" if effort == "off" else effort
	return effort if native_effort in levels else ""


static func reset_message(effort: String, model: String) -> String:
	return "Reasoning effort '%s' is unavailable for %s; using Default." % [effort, model]

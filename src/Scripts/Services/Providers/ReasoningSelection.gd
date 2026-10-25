class_name ReasoningSelection
extends RefCounted
## Model reasoning choices and presentation order; no storage or scene access.

const EFFORT_ORDER: Dictionary[String, int] = {"none": 0, "off": 0, "minimal": 1,
	"low": 2, "medium": 3, "high": 4, "xhigh": 5, "max": 6}


## Intensity ordering is presentation only; unknown native names keep their order.
static func ordered_levels(advertised: Array) -> Array[String]:
	var levels: Array[String] = []
	var known := true
	for level: String in advertised:
		levels.append(level)
		known = known and EFFORT_ORDER.has(level)
	if known:
		levels.sort_custom(func(a: String, b: String) -> bool: return EFFORT_ORDER[a] < EFFORT_ORDER[b])
	return levels

static func validate(effort: String, levels: Array) -> String:
	if effort.is_empty():
		return ""
	var native_effort := "none" if effort == "off" else effort
	return effort if native_effort in levels else ""


static func reset_message(effort: String, model: String) -> String:
	return "Reasoning effort '%s' is unavailable for %s; using Default." % [effort, model]


## Saved preferences reset on capability changes; request intent is validated separately.
static func reset_saved(schema: Dictionary, saved: Dictionary, model: String) -> Dictionary:
	var values := saved.duplicate(true)
	var notice := ""
	for name: String in ["reasoning_effort", "enable_thinking"]:
		if not values.has(name):
			continue
		var rule: Dictionary = schema.get(name, {})
		if rule.is_empty() or not CoreModelDescriptor.value_matches(values[name], rule):
			if notice.is_empty():
				notice = reset_message(str(values[name]), model)
			values.erase(name)
	return {"values": values, "notice": notice}

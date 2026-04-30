class_name AnnotationTrustManager
extends RefCounted
## Runtime fail-containment state for plugin-provided annotation extensions.

var RENDER_THROW_THRESHOLD := 5
var RESOLVER_THROW_THRESHOLD := 5
var APPLY_TOOL_THROW_THRESHOLD := 3
var THROW_WINDOW_SECONDS := 60
var SUSPENSION_COOLDOWN_SECONDS := 300

var _history: Array = []
var _suspensions: Dictionary = {}


func record_render_throw(kind: String, error: String) -> void:
	_record("render", kind, error, RENDER_THROW_THRESHOLD)


func record_resolver_throw(plugin: String, anchor_type: String, error: String) -> void:
	_record("resolver", "%s/%s" % [plugin, anchor_type], error, RESOLVER_THROW_THRESHOLD)


func record_apply_tool_throw(tool_id: String, phase: String, error: String) -> void:
	_record("apply_tool", tool_id, "%s: %s" % [phase, error], APPLY_TOOL_THROW_THRESHOLD)


func is_kind_suspended(kind: String) -> bool:
	return _is_suspended("render", kind)


func is_anchor_type_suspended(plugin: String, anchor_type: String) -> bool:
	return _is_suspended("resolver", "%s/%s" % [plugin, anchor_type])


func is_apply_tool_suspended(tool_id: String) -> bool:
	return _is_suspended("apply_tool", tool_id)


func resume_kind(kind: String) -> void:
	_resume("render", kind)


func resume_anchor_type(plugin: String, anchor_type: String) -> void:
	_resume("resolver", "%s/%s" % [plugin, anchor_type])


func resume_apply_tool(tool_id: String) -> void:
	_resume("apply_tool", tool_id)


func get_suspensions() -> Array:
	var result: Array = []
	for key in _suspensions.keys():
		result.append((_suspensions[key] as Dictionary).duplicate(true))
	return result


func get_throw_history(window_sec: int = 60) -> Array:
	if window_sec <= 0:
		return []
	var cutoff := Time.get_unix_time_from_system() - float(window_sec)
	var result: Array = []
	for entry in _history:
		if entry is Dictionary and float(entry.get("at", 0.0)) >= cutoff:
			result.append((entry as Dictionary).duplicate(true))
	return result


func _record(surface: String, name: String, error: String, threshold: int) -> void:
	var now := Time.get_unix_time_from_system()
	var entry := {
		"type": surface,
		"name": name,
		"error": error,
		"at": now,
	}
	_history.append(entry)

	var recent := _recent_for(surface, name, THROW_WINDOW_SECONDS)
	if recent.size() >= threshold:
		_suspend(surface, name, recent)


func _recent_for(surface: String, name: String, window_sec: int) -> Array:
	var cutoff := Time.get_unix_time_from_system() - float(window_sec)
	var result: Array = []
	for entry in _history:
		if not entry is Dictionary:
			continue
		if entry.get("type", "") == surface and entry.get("name", "") == name and float(entry.get("at", 0.0)) >= cutoff:
			result.append(entry)
	return result


func _suspension_key(surface: String, name: String) -> String:
	return "%s:%s" % [surface, name]


func _suspend(surface: String, name: String, recent: Array) -> void:
	var key := _suspension_key(surface, name)
	var samples: Array = []
	for entry in recent:
		if entry is Dictionary:
			samples.append(str(entry.get("error", "")))
			if samples.size() >= 5:
				break
	_suspensions[key] = {
		"type": surface,
		"name": name,
		"throw_count": recent.size(),
		"suspended_at": Time.get_unix_time_from_system(),
		"error_samples": samples,
	}


func _is_suspended(surface: String, name: String) -> bool:
	return _suspensions.has(_suspension_key(surface, name))


func _resume(surface: String, name: String) -> void:
	_suspensions.erase(_suspension_key(surface, name))


class_name MCPAnnotationsTools
extends RefCounted

const AnnotationKindScript = preload("res://Scripts/Services/Annotations/AnnotationKind.gd")
const AnnotationLifecycleScript = preload("res://Scripts/Services/Annotations/AnnotationLifecycle.gd")

var _annotation_store: Object = null
var _anchor_registry: Object = null
var _apply_hooks: Dictionary = {}
var _hook_errors: Array = []


func set_annotation_store(store: Object) -> void:
	_annotation_store = store


func set_anchor_registry(registry: Object) -> void:
	_anchor_registry = registry


func query(filters: Dictionary = {}) -> Dictionary:
	var annotations := _get_all_annotations()
	var filtered: Array = []
	for annotation in annotations:
		if annotation is Dictionary and _matches_filters(annotation, filters):
			filtered.append(_project_annotation(annotation, filters))
	var total := filtered.size()
	var truncated := total > 100
	if truncated:
		filtered = filtered.slice(0, 100)
	return {
		"annotations": filtered,
		"total": total,
		"truncated": truncated,
	}


func repair_anchor(annotation_id: String, new_anchor: Variant = null) -> Dictionary:
	var annotation := _get_annotation(annotation_id)
	if annotation.is_empty():
		return {"ok": false, "error": "annotation not found: %s" % annotation_id}
	var repaired: Variant = new_anchor
	if repaired == null:
		if _anchor_registry == null:
			return {"ok": false, "error": "anchor registry not set"}
		if _anchor_registry.has_method("repair"):
			repaired = _anchor_registry.repair(annotation.get("anchor", {}), null)
		elif _anchor_registry.has_method("repair_for"):
			repaired = _anchor_registry.repair_for(annotation.get("anchor", {}), null)
	if not repaired is Dictionary:
		return {"ok": false, "needs_retarget": true}
	annotation["anchor"] = (repaired as Dictionary).duplicate(true)
	annotation["lifecycle"] = "open"
	_update_annotation(annotation)
	return {"ok": true, "annotation": _project_annotation(annotation, {"status": "any"})}


func update_status(annotation_id: String, lifecycle: String, patch: Dictionary = {}) -> Dictionary:
	var annotation := _get_annotation(annotation_id)
	if annotation.is_empty():
		return {"ok": false, "error": "annotation not found: %s" % annotation_id}
	var current := str(annotation.get("lifecycle", ""))
	if lifecycle == "stale":
		return {"ok": false, "error": "stale is substrate-only", "from": current, "to": lifecycle}
	if not AnnotationLifecycleScript.can_transition(current, lifecycle):
		return {"ok": false, "error": "illegal lifecycle transition: %s -> %s" % [current, lifecycle], "from": current, "to": lifecycle}
	var required_error := _validate_status_payload(lifecycle, patch)
	if not required_error.is_empty():
		return {"ok": false, "error": required_error, "from": current, "to": lifecycle}
	for key in patch.keys():
		annotation[key] = patch[key]
	annotation["lifecycle"] = lifecycle
	_update_annotation(annotation)
	if lifecycle == "applied":
		_fire_apply_hooks(annotation)
	return {"ok": true, "annotation": _project_annotation(annotation, {"status": "any"})}


func register_apply_hook(plugin: String, kind: String, callable_name: String) -> Dictionary:
	if kind.strip_edges().is_empty():
		return {"ok": false, "error": "kind is required"}
	_register_hook(kind, {"plugin": plugin, "callable_name": callable_name})
	return {"ok": true}


func register_apply_hook_callable(kind: String, hook: Callable) -> Dictionary:
	if not hook.is_valid():
		return {"ok": false, "error": "hook callable is invalid"}
	_register_hook(kind, hook)
	return {"ok": true}


func get_hook_errors() -> Array:
	return _hook_errors.duplicate(true)


func _get_all_annotations() -> Array:
	if _annotation_store != null and _annotation_store.has_method("get_all"):
		var result: Variant = _annotation_store.get_all()
		if result is Array:
			return result
	return []


func _get_annotation(annotation_id: String) -> Dictionary:
	if _annotation_store != null and _annotation_store.has_method("get_by_id"):
		var result: Variant = _annotation_store.get_by_id(annotation_id)
		if result is Dictionary:
			return (result as Dictionary).duplicate(true)
	for annotation in _get_all_annotations():
		if annotation is Dictionary and str((annotation as Dictionary).get("id", "")) == annotation_id:
			return (annotation as Dictionary).duplicate(true)
	return {}


func _update_annotation(annotation: Dictionary) -> void:
	if _annotation_store != null and _annotation_store.has_method("update"):
		_annotation_store.update(annotation)


func _matches_filters(annotation: Dictionary, filters: Dictionary) -> bool:
	var lifecycle := str(annotation.get("lifecycle", ""))
	var status := str(filters.get("status", ""))
	if status.is_empty():
		if lifecycle != "open" and lifecycle != "applied":
			return false
	elif status != "any" and lifecycle != status:
		return false
	if filters.has("anchor_type"):
		var anchor: Dictionary = annotation.get("anchor", {})
		var expected := str(filters["anchor_type"])
		var actual := "%s/%s" % [str(anchor.get("plugin", "")), str(anchor.get("type", ""))]
		if expected.ends_with("/*"):
			if not actual.begins_with(expected.substr(0, expected.length() - 1)):
				return false
		elif actual != expected:
			return false
	if filters.has("kind") and str(annotation.get("kind", "")) != str(filters["kind"]):
		return false
	if filters.has("author_kind") and str(annotation.get("author", {}).get("kind", "")) != str(filters["author_kind"]):
		return false
	if filters.has("author_id") and str(annotation.get("author", {}).get("id", "")) != str(filters["author_id"]):
		return false
	if filters.has("text"):
		var needle := str(filters["text"]).to_lower()
		var haystack := "%s %s" % [str(annotation.get("summary", "")), str(annotation.get("kind_payload", {}))]
		if not haystack.to_lower().contains(needle):
			return false
	var time_range: Dictionary = filters.get("time_range", {})
	if time_range.has("after") and str(annotation.get("created_at", "")) <= str(time_range["after"]):
		return false
	if time_range.has("before") and str(annotation.get("created_at", "")) >= str(time_range["before"]):
		return false
	return true


func _project_annotation(annotation: Dictionary, filters: Dictionary) -> Dictionary:
	var projected := annotation.duplicate(true)
	projected["stale"] = str(projected.get("lifecycle", "")) == "stale"
	if filters.has("capabilities"):
		projected["chat_context"] = AnnotationKindScript.new().to_chat_context(projected, filters.get("capabilities", {}))
	return projected


func _validate_status_payload(lifecycle: String, patch: Dictionary) -> String:
	if lifecycle == "applied":
		if not patch.has("applied") or not patch["applied"] is Dictionary:
			return "applied object is required"
		var applied: Dictionary = patch["applied"]
		if not applied.has("links") or not applied["links"] is Array:
			return "applied.links is required"
	if lifecycle == "resolved":
		if not patch.has("resolved") or not patch["resolved"] is Dictionary:
			return "resolved object is required"
		var resolved: Dictionary = patch["resolved"]
		if not resolved.has("by") or not resolved["by"] is Dictionary:
			return "resolved.by is required"
	return ""


func _register_hook(kind: String, hook: Variant) -> void:
	if not _apply_hooks.has(kind):
		_apply_hooks[kind] = []
	_apply_hooks[kind].append(hook)


func _fire_apply_hooks(annotation: Dictionary) -> void:
	var kind := str(annotation.get("kind", ""))
	var hooks: Array = _apply_hooks.get(kind, [])
	for hook in hooks:
		if hook is Callable:
			var result: Variant = (hook as Callable).call(str(annotation.get("id", "")))
			if result is Dictionary and result.get("ok", true) == false:
				_hook_errors.append({"annotation_id": annotation.get("id", ""), "kind": kind, "error": result.get("error", "hook failed")})

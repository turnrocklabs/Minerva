class_name AnnotationSidebarModel
extends RefCounted

signal retarget_picker_requested(annotation_id: String)
signal annotation_repaired(annotation_id: String, new_anchor: Dictionary)

var _annotations: Array = []
var _anchor_registry: Object = null
var _kind_registry: Object = null
var _show_broken_only := false


func set_annotations(annotations: Array) -> void:
	_annotations = annotations.duplicate(true)


func set_anchor_registry(registry: Object) -> void:
	_anchor_registry = registry


## Optional kind registry (AnnotationRegistry, duck-typed). When set, the
## review sidebar excludes workflow-class annotations (AnnotationKind.
## workflow_class — pcb-ui-native-cluster §4); those list in the separate
## WorkflowAnnotationList surface instead. Without a registry the model is
## unchanged (everything passes).
func set_kind_registry(registry: Object) -> void:
	_kind_registry = registry


func set_show_broken_only(value: bool) -> void:
	_show_broken_only = value


func is_broken_section_visible() -> bool:
	return get_broken_count() > 0


func get_broken_count() -> int:
	return get_broken_entries().size()


func get_broken_entries() -> Array:
	var result: Array = []
	for annotation in _annotations:
		if not annotation is Dictionary:
			continue
		var ann := annotation as Dictionary
		if _is_workflow_class(ann):
			continue
		if not _is_stale(ann):
			continue
		result.append({
			"id": str(ann.get("id", "")),
			"ref": str(ann.get("ref", "")),  # citeable ref (C<n>) — DCR 019e9f602391 P3
			"summary": str(ann.get("summary", "")),
			"last_view": str(ann.get("view_context", "")),
			"display_index": int(ann.get("_display_index", 0)),
			"anchor_label": str(ann.get("_anchor_label", "")),
			"repair_available": true,
			"annotation": ann.duplicate(true),
		})
	return result


func get_visible_annotations() -> Array:
	var result: Array = []
	for annotation in _annotations:
		if not annotation is Dictionary:
			if not _show_broken_only:
				result.append(annotation)
			continue
		var ann := annotation as Dictionary
		if _is_workflow_class(ann):
			continue
		if _show_broken_only and not _is_stale(ann):
			continue
		result.append(ann.duplicate(true))
	return result


func trigger_repair(annotation_id: String) -> Dictionary:
	var index := _find_index(annotation_id)
	if index < 0:
		return {"ok": false, "error": "annotation not found: %s" % annotation_id}
	var annotation: Dictionary = _annotations[index]
	var anchor: Dictionary = annotation.get("anchor", {})
	var repaired: Variant = null
	if _anchor_registry != null:
		if _anchor_registry.has_method("repair"):
			repaired = _anchor_registry.repair(anchor, null)
		elif _anchor_registry.has_method("repair_for"):
			repaired = _anchor_registry.repair_for(anchor, null)
	if repaired is Dictionary:
		annotation["anchor"] = (repaired as Dictionary).duplicate(true)
		annotation["lifecycle"] = "open"
		_annotations[index] = annotation
		annotation_repaired.emit(annotation_id, annotation["anchor"])
		return {"ok": true, "annotation": annotation.duplicate(true)}
	retarget_picker_requested.emit(annotation_id)
	return {"ok": false, "needs_retarget": true}


func _find_index(annotation_id: String) -> int:
	for i in range(_annotations.size()):
		var annotation: Variant = _annotations[i]
		if annotation is Dictionary and str((annotation as Dictionary).get("id", "")) == annotation_id:
			return i
	return -1


func _is_stale(annotation: Dictionary) -> bool:
	return str(annotation.get("lifecycle", "")) == "stale" or bool(annotation.get("stale", false))


## True when the annotation's registered kind declares workflow_class.
## Unknown kinds (or no registry) are NOT workflow-class.
func _is_workflow_class(annotation: Dictionary) -> bool:
	if _kind_registry == null or not _kind_registry.has_method("get_annotation_kind"):
		return false
	var kind: Variant = _kind_registry.get_annotation_kind(StringName(str(annotation.get("kind", ""))))
	if kind == null or not (kind is Object):
		return false
	return bool((kind as Object).get("workflow_class"))

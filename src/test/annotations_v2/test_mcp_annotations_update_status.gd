extends SceneTree

const MCPAnnotationsToolsScript = preload("res://Scripts/Services/MCP/Modules/MCPAnnotationsTools.gd")

var _pass_count := 0
var _fail_count := 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_mcp_annotations_update_status ===\n")
	test_legal_transitions()
	test_illegal_transitions()
	test_required_fields_enforced()
	test_payloads_persisted_in_result()
	test_result_shape()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


func _make_ann(id: String, lifecycle: String) -> Dictionary:
	return {
		"id": id,
		"kind": "text",
		"schema_version": 2,
		"anchor": {"plugin": "core", "type": "text.range", "id": {"start": 0, "end": 10}, "snapshot": {"position": [0.0, 0.0]}},
		"kind_payload": {"text": "comment"},
		"lifecycle": lifecycle,
		"author": {"kind": "human"},
		"view_context": "editor:main",
		"visible_in_views": ["main"],
		"summary": "Test comment.",
		"created_at": "2026-04-29T17:00:00Z",
		"updated_at": "2026-04-29T17:00:00Z",
		"applied": null,
		"resolved": null,
	}


func _tools(annotations: Array) -> Object:
	var tools := MCPAnnotationsToolsScript.new()
	tools.set_annotation_store(_MockStore.new(annotations))
	return tools


func _ai_author() -> Dictionary:
	return {"kind": "ai", "model": "claude-sonnet-4-6"}


func _human_author() -> Dictionary:
	return {"kind": "human", "id": "user_1"}


func test_legal_transitions() -> void:
	check("open -> applied succeeds", _tools([_make_ann("ann", "open")]).update_status("ann", "applied", {"applied": {"by": _ai_author(), "links": [{"kind": "text.edit", "id": "edit_42"}]}}).get("ok", false))
	check("open -> resolved succeeds", _tools([_make_ann("ann", "open")]).update_status("ann", "resolved", {"resolved": {"by": _human_author()}}).get("ok", false))
	check("applied -> resolved succeeds", _tools([_make_ann("ann", "applied")]).update_status("ann", "resolved", {"resolved": {"by": _human_author()}}).get("ok", false))
	check("resolved -> open succeeds", _tools([_make_ann("ann", "resolved")]).update_status("ann", "open", {}).get("ok", false))
	check("stale -> open succeeds", _tools([_make_ann("ann", "stale")]).update_status("ann", "open", {}).get("ok", false))


func test_illegal_transitions() -> void:
	check("applied -> open illegal", not _tools([_make_ann("ann", "applied")]).update_status("ann", "open", {}).get("ok", true))
	check("resolved -> applied illegal", not _tools([_make_ann("ann", "resolved")]).update_status("ann", "applied", {"applied": {"by": _ai_author(), "links": []}}).get("ok", true))
	check("stale -> applied illegal", not _tools([_make_ann("ann", "stale")]).update_status("ann", "applied", {"applied": {"by": _ai_author(), "links": []}}).get("ok", true))
	check("stale -> resolved illegal", not _tools([_make_ann("ann", "stale")]).update_status("ann", "resolved", {"resolved": {"by": _human_author()}}).get("ok", true))
	var result: Dictionary = _tools([_make_ann("ann", "open")]).update_status("ann", "stale", {})
	check("user-initiated open -> stale rejected", not result.get("ok", true))
	check("illegal result has from/to", result.has("from") and result.has("to"))


func test_required_fields_enforced() -> void:
	check("applied object required", not _tools([_make_ann("ann", "open")]).update_status("ann", "applied", {}).get("ok", true))
	check("applied.links required", not _tools([_make_ann("ann", "open")]).update_status("ann", "applied", {"applied": {"by": _ai_author()}}).get("ok", true))
	check("resolved.by required", not _tools([_make_ann("ann", "open")]).update_status("ann", "resolved", {"resolved": {"note": "done"}}).get("ok", true))


func test_payloads_persisted_in_result() -> void:
	var applied := {"by": _ai_author(), "links": [{"kind": "text.edit", "id": "e1"}]}
	var applied_result: Dictionary = _tools([_make_ann("ann", "open")]).update_status("ann", "applied", {"applied": applied})
	check("applied object persisted", applied_result.get("annotation", {}).get("applied", null) != null)
	var resolved := {"by": _human_author(), "note": "User verified"}
	var resolved_result: Dictionary = _tools([_make_ann("ann", "open")]).update_status("ann", "resolved", {"resolved": resolved})
	check("resolved object persisted", resolved_result.get("annotation", {}).get("resolved", null) != null)


func test_result_shape() -> void:
	var result: Dictionary = _tools([_make_ann("ann_001", "open")]).update_status("ann_001", "resolved", {"resolved": {"by": _human_author()}})
	check("legal transition ok=true", result.get("ok", false))
	check("result includes annotation", result.has("annotation"))
	check("result annotation id correct", result.get("annotation", {}).get("id", "") == "ann_001")
	check("result annotation lifecycle updated", result.get("annotation", {}).get("lifecycle", "") == "resolved")
	var bad: Dictionary = _tools([_make_ann("ann_002", "applied")]).update_status("ann_002", "open", {})
	check("illegal transition ok=false", not bad.get("ok", true))
	check("illegal transition has error", str(bad.get("error", "")).length() > 0)


class _MockStore extends RefCounted:
	var _annotations: Array
	func _init(annotations: Array) -> void: _annotations = annotations
	func get_all() -> Array: return _annotations
	func get_by_id(id: String) -> Variant:
		for a in _annotations:
			if a.get("id", "") == id:
				return a
		return null
	func update(annotation: Dictionary) -> void:
		for i in range(_annotations.size()):
			if _annotations[i].get("id", "") == annotation.get("id", ""):
				_annotations[i] = annotation
				return

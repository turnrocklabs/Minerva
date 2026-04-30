extends SceneTree

const MCPAnnotationsToolsScript = preload("res://Scripts/Services/MCP/Modules/MCPAnnotationsTools.gd")

var _pass_count := 0
var _fail_count := 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_mcp_annotations_apply_hook ===\n")
	test_register_apply_hook_returns_ok()
	test_hook_fires_after_status_transition_to_applied()
	test_hook_receives_annotation_id()
	test_hook_fires_after_status_persisted()
	test_hook_failure_does_not_roll_back_status()
	test_hook_failure_is_logged_not_propagated()
	test_multiple_hooks_for_same_kind_all_fire()
	test_hook_not_fired_for_different_kind()
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


func _make_ann(id: String, kind: String, lifecycle: String) -> Dictionary:
	return {
		"id": id,
		"kind": kind,
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


func _apply_patch() -> Dictionary:
	return {"applied": {"by": {"kind": "ai"}, "links": [{"kind": "edit", "id": "e1"}]}}


func test_register_apply_hook_returns_ok() -> void:
	var tools := _tools([])
	check("MCPAnnotationsTools has register_apply_hook method", tools.has_method("register_apply_hook"))
	check("register_apply_hook returns ok=true", tools.register_apply_hook("myplugin", "text", "my_apply_callback").get("ok", false))


func test_hook_fires_after_status_transition_to_applied() -> void:
	var hook_fired := [false]
	var tools := _tools([_make_ann("ann_001", "text", "open")])
	tools.register_apply_hook_callable("text", func(_ann_id): hook_fired[0] = true)
	tools.update_status("ann_001", "applied", _apply_patch())
	check("apply hook fires when status transitions to applied", hook_fired[0])


func test_hook_receives_annotation_id() -> void:
	var received_id := [""]
	var tools := _tools([_make_ann("ann_hook_test", "text", "open")])
	tools.register_apply_hook_callable("text", func(ann_id): received_id[0] = ann_id)
	tools.update_status("ann_hook_test", "applied", _apply_patch())
	check("hook receives correct annotation id", received_id[0] == "ann_hook_test")


func test_hook_fires_after_status_persisted() -> void:
	var store := _MockStore.new([_make_ann("ann_001", "text", "open")])
	var lifecycle_in_hook := [""]
	var tools := MCPAnnotationsToolsScript.new()
	tools.set_annotation_store(store)
	tools.register_apply_hook_callable("text", func(ann_id):
		var ann = store.get_by_id(ann_id)
		if ann != null:
			lifecycle_in_hook[0] = ann.get("lifecycle", "")
	)
	tools.update_status("ann_001", "applied", _apply_patch())
	check("hook fires after status persisted", lifecycle_in_hook[0] == "applied")


func test_hook_failure_does_not_roll_back_status() -> void:
	var store := _MockStore.new([_make_ann("ann_001", "text", "open")])
	var tools := MCPAnnotationsToolsScript.new()
	tools.set_annotation_store(store)
	tools.register_apply_hook_callable("text", func(_ann_id): return {"ok": false, "error": "hook failed"})
	var result: Dictionary = tools.update_status("ann_001", "applied", _apply_patch())
	check("transition still returns ok=true when hook reports failure", result.get("ok", false))
	check("status persisted even if hook failed", store.get_by_id("ann_001").get("lifecycle", "") == "applied")


func test_hook_failure_is_logged_not_propagated() -> void:
	var tools := _tools([_make_ann("ann_001", "text", "open")])
	tools.register_apply_hook_callable("text", func(_ann_id): return {"ok": false, "error": "hook failed"})
	tools.update_status("ann_001", "applied", _apply_patch())
	check("hook failure logged", tools.get_hook_errors().size() == 1)


func test_multiple_hooks_for_same_kind_all_fire() -> void:
	var fired := [0]
	var tools := _tools([_make_ann("ann_001", "text", "open")])
	tools.register_apply_hook_callable("text", func(_id): fired[0] += 1)
	tools.register_apply_hook_callable("text", func(_id): fired[0] += 1)
	tools.update_status("ann_001", "applied", _apply_patch())
	check("both hooks fire", fired[0] == 2)


func test_hook_not_fired_for_different_kind() -> void:
	var fired := [false]
	var tools := _tools([_make_ann("ann_001", "text", "open")])
	tools.register_apply_hook_callable("arrow", func(_id): fired[0] = true)
	tools.update_status("ann_001", "applied", _apply_patch())
	check("hook for different kind not fired", not fired[0])


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

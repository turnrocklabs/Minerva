extends SceneTree

const MCPAnnotationsToolsScript = preload("res://Scripts/Services/MCP/Modules/MCPAnnotationsTools.gd")

var _pass_count := 0
var _fail_count := 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_broken_anchor_mcp ===\n")
	test_mcp_query_includes_stale_field_for_open_annotation()
	test_mcp_query_includes_stale_field_true_for_stale_annotation()
	test_mcp_query_stale_field_false_for_non_stale()
	test_mcp_query_status_stale_returns_only_stale()
	test_mcp_query_status_stale_excludes_open()
	test_mcp_query_status_stale_excludes_applied()
	test_mcp_repair_anchor_tool_exists()
	test_mcp_repair_anchor_null_new_anchor_calls_plugin_repair()
	test_mcp_repair_anchor_non_null_directly_retargets()
	test_mcp_repair_anchor_unknown_id_returns_error()
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


func _make_annotation(id: String, lifecycle: String) -> Dictionary:
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
		"summary": "Comment id=%s" % id,
		"created_at": "2026-04-29T17:00:00Z",
		"updated_at": "2026-04-29T17:00:00Z",
	}


func _make_mcp_tools(annotations: Array) -> Object:
	var tools := MCPAnnotationsToolsScript.new()
	tools.set_annotation_store(_MockAnnotationStore.new(annotations))
	return tools


func test_mcp_query_includes_stale_field_for_open_annotation() -> void:
	var annotations: Array = _make_mcp_tools([_make_annotation("ann_001", "open")]).query({}).get("annotations", [])
	check("query result has annotations array", annotations.size() > 0)
	if annotations.size() > 0:
		check("open annotation has stale field", annotations[0].has("stale"))


func test_mcp_query_includes_stale_field_true_for_stale_annotation() -> void:
	var annotations: Array = _make_mcp_tools([_make_annotation("ann_stale", "stale")]).query({"status": "any"}).get("annotations", [])
	check("stale annotation has stale=true in query output", annotations.size() == 1 and annotations[0].get("stale", false))


func test_mcp_query_stale_field_false_for_non_stale() -> void:
	var annotations: Array = _make_mcp_tools([_make_annotation("ann_open", "open")]).query({}).get("annotations", [])
	check("open annotation has stale=false", annotations.size() == 1 and annotations[0].get("stale", true) == false)


func test_mcp_query_status_stale_returns_only_stale() -> void:
	var result: Dictionary = _make_mcp_tools([_make_annotation("ann_open", "open"), _make_annotation("ann_stale", "stale"), _make_annotation("ann_applied", "applied")]).query({"status": "stale"})
	var annotations: Array = result.get("annotations", [])
	check("status=stale filter returns 1 annotation", annotations.size() == 1)
	if annotations.size() == 1:
		check("returned annotation is stale one", annotations[0].get("id", "") == "ann_stale")


func test_mcp_query_status_stale_excludes_open() -> void:
	var annotations: Array = _make_mcp_tools([_make_annotation("ann_open", "open"), _make_annotation("ann_stale_1", "stale")]).query({"status": "stale"}).get("annotations", [])
	var has_open := false
	for ann in annotations:
		has_open = has_open or ann.get("lifecycle", "") == "open"
	check("status=stale excludes open annotations", not has_open)


func test_mcp_query_status_stale_excludes_applied() -> void:
	var annotations: Array = _make_mcp_tools([_make_annotation("ann_applied", "applied"), _make_annotation("ann_stale", "stale")]).query({"status": "stale"}).get("annotations", [])
	var has_applied := false
	for ann in annotations:
		has_applied = has_applied or ann.get("lifecycle", "") == "applied"
	check("status=stale excludes applied annotations", not has_applied)


func test_mcp_repair_anchor_tool_exists() -> void:
	check("MCPAnnotationsTools has repair_anchor method", MCPAnnotationsToolsScript.new().has_method("repair_anchor"))


func test_mcp_repair_anchor_null_new_anchor_calls_plugin_repair() -> void:
	var repair_called := [false]
	var tools := _make_mcp_tools([_make_annotation("ann_stale", "stale")])
	tools.set_anchor_registry(_MockRegistry.new(repair_called))
	tools.repair_anchor("ann_stale", null)
	check("repair_anchor with null new_anchor calls plugin repair()", repair_called[0])


func test_mcp_repair_anchor_non_null_directly_retargets() -> void:
	var tools := _make_mcp_tools([_make_annotation("ann_stale", "stale")])
	var new_anchor := {"plugin": "core", "type": "text.range", "id": {"start": 50, "end": 75}, "snapshot": {"position": [5.0, 10.0]}}
	var result: Dictionary = tools.repair_anchor("ann_stale", new_anchor)
	check("repair_anchor with non-null new_anchor returns ok=true", result.get("ok", false))


func test_mcp_repair_anchor_unknown_id_returns_error() -> void:
	var result: Dictionary = _make_mcp_tools([]).repair_anchor("nonexistent_id", null)
	check("repair_anchor unknown id returns ok=false", result.get("ok", true) == false)


class _MockAnnotationStore extends RefCounted:
	var _annotations: Array
	func _init(annotations: Array) -> void: _annotations = annotations
	func get_all() -> Array: return _annotations
	func get_by_id(id: String) -> Variant:
		for ann in _annotations:
			if ann.get("id", "") == id:
				return ann
		return null
	func update(annotation: Dictionary) -> void:
		for i in range(_annotations.size()):
			if _annotations[i].get("id", "") == annotation.get("id", ""):
				_annotations[i] = annotation
				return


class _MockRegistry extends RefCounted:
	var _called_arr: Array
	func _init(arr: Array) -> void: _called_arr = arr
	func validate_anchor(_anchor: Dictionary) -> Array: return []
	func repair_for(_anchor: Dictionary, _host: Object) -> Variant:
		_called_arr[0] = true
		return null

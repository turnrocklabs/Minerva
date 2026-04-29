extends SceneTree
## Contract tests for broken/stale anchor MCP surface (task #4).
## Run: godot --headless --path src --script test/annotations_v2/test_broken_anchor_mcp.gd
##
## RED in Round 1 — MCPAnnotationsTools v2 does not exist yet.

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_broken_anchor_mcp ===\n")

	print("-- MCPAnnotationsTools: class existence --")
	test_mcp_tools_class_exists()

	print("\n-- mcp query: stale field in default output --")
	test_mcp_query_includes_stale_field_for_open_annotation()
	test_mcp_query_includes_stale_field_true_for_stale_annotation()
	test_mcp_query_stale_field_false_for_non_stale()

	print("\n-- mcp query: status=stale filter --")
	test_mcp_query_status_stale_returns_only_stale()
	test_mcp_query_status_stale_excludes_open()
	test_mcp_query_status_stale_excludes_applied()

	print("\n-- mcp repair tool --")
	test_mcp_repair_anchor_tool_exists()
	test_mcp_repair_anchor_null_new_anchor_calls_plugin_repair()
	test_mcp_repair_anchor_non_null_directly_retargets()
	test_mcp_repair_anchor_unknown_id_returns_error()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ── Assertion helpers ─────────────────────────────────────────────────────────

func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


# ── Fixtures ──────────────────────────────────────────────────────────────────

func _make_annotation(id: String, lifecycle: String) -> Dictionary:
	return {
		"id": id,
		"kind": "text",
		"schema_version": 2,
		"anchor": {
			"plugin": "core",
			"type": "text.range",
			"id": {"start": 0, "end": 10},
			"snapshot": {"position": [0.0, 0.0], "text": "sample", "document_revision": 1}
		},
		"kind_payload": {"text": "comment"},
		"lifecycle": lifecycle,
		"author": {"kind": "human"},
		"view_context": "editor:main",
		"visible_in_views": ["main"],
		"summary": "Comment id=%s" % id,
		"created_at": "2026-04-29T17:00:00Z",
		"updated_at": "2026-04-29T17:00:00Z"
	}


func _make_mcp_tools(annotations: Array) -> Variant:
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		return null
	var tools = ClassDB.instantiate("MCPAnnotationsTools")
	if tools == null or not tools.has_method("set_annotation_store"):
		return null
	tools.set_annotation_store(_MockAnnotationStore.new(annotations))
	return tools


# ── Class existence ───────────────────────────────────────────────────────────

func test_mcp_tools_class_exists() -> void:
	print("test_mcp_tools_class_exists:")
	check("MCPAnnotationsTools class exists",
		ClassDB.class_exists("MCPAnnotationsTools"))


# ── stale field in query output tests ────────────────────────────────────────

func test_mcp_query_includes_stale_field_for_open_annotation() -> void:
	print("test_mcp_query_includes_stale_field_for_open_annotation:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_mcp_tools([_make_annotation("ann_001", "open")])
	if tools == null or not tools.has_method("query"):
		check("MCPAnnotationsTools instantiable with query method", false)
		return
	var result = tools.query({})
	var annotations = result.get("annotations", [])
	check("query result has annotations array", annotations.size() > 0)
	if annotations.size() > 0:
		check("open annotation has stale field", "stale" in annotations[0])


func test_mcp_query_includes_stale_field_true_for_stale_annotation() -> void:
	print("test_mcp_query_includes_stale_field_true_for_stale_annotation:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_mcp_tools([_make_annotation("ann_stale", "stale")])
	if tools == null or not tools.has_method("query"):
		check("MCPAnnotationsTools instantiable with query method", false)
		return
	var result = tools.query({"status": "any"})
	var annotations = result.get("annotations", [])
	var found_stale := false
	for ann in annotations:
		if ann.get("id", "") == "ann_stale":
			found_stale = ann.get("stale", false) == true
	check("stale annotation has stale=true in query output", found_stale)


func test_mcp_query_stale_field_false_for_non_stale() -> void:
	print("test_mcp_query_stale_field_false_for_non_stale:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_mcp_tools([_make_annotation("ann_open", "open")])
	if tools == null or not tools.has_method("query"):
		check("MCPAnnotationsTools instantiable with query method", false)
		return
	var result = tools.query({})
	var annotations = result.get("annotations", [])
	if annotations.size() > 0:
		check("open annotation has stale=false", annotations[0].get("stale", true) == false)
	else:
		check("annotations present", false)


# ── status=stale filter tests ─────────────────────────────────────────────────

func test_mcp_query_status_stale_returns_only_stale() -> void:
	print("test_mcp_query_status_stale_returns_only_stale:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_mcp_tools([
		_make_annotation("ann_open", "open"),
		_make_annotation("ann_stale", "stale"),
		_make_annotation("ann_applied", "applied")
	])
	if tools == null or not tools.has_method("query"):
		check("MCPAnnotationsTools instantiable with query method", false)
		return
	var result = tools.query({"status": "stale"})
	var annotations = result.get("annotations", [])
	check("status=stale filter returns 1 annotation", annotations.size() == 1)
	if annotations.size() > 0:
		check("returned annotation is stale one", annotations[0].get("id", "") == "ann_stale")


func test_mcp_query_status_stale_excludes_open() -> void:
	print("test_mcp_query_status_stale_excludes_open:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_mcp_tools([
		_make_annotation("ann_open", "open"),
		_make_annotation("ann_stale_1", "stale"),
		_make_annotation("ann_stale_2", "stale")
	])
	if tools == null or not tools.has_method("query"):
		check("MCPAnnotationsTools instantiable with query method", false)
		return
	var result = tools.query({"status": "stale"})
	var annotations = result.get("annotations", [])
	var has_open := false
	for ann in annotations:
		if ann.get("lifecycle", "") == "open":
			has_open = true
	check("status=stale excludes open annotations", not has_open)


func test_mcp_query_status_stale_excludes_applied() -> void:
	print("test_mcp_query_status_stale_excludes_applied:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_mcp_tools([
		_make_annotation("ann_applied", "applied"),
		_make_annotation("ann_stale", "stale")
	])
	if tools == null or not tools.has_method("query"):
		check("MCPAnnotationsTools instantiable with query method", false)
		return
	var result = tools.query({"status": "stale"})
	var annotations = result.get("annotations", [])
	var has_applied := false
	for ann in annotations:
		if ann.get("lifecycle", "") == "applied":
			has_applied = true
	check("status=stale excludes applied annotations", not has_applied)


# ── repair tool tests ─────────────────────────────────────────────────────────

func test_mcp_repair_anchor_tool_exists() -> void:
	print("test_mcp_repair_anchor_tool_exists:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = ClassDB.instantiate("MCPAnnotationsTools")
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	check("MCPAnnotationsTools has repair_anchor method",
		tools.has_method("repair_anchor"))


func test_mcp_repair_anchor_null_new_anchor_calls_plugin_repair() -> void:
	print("test_mcp_repair_anchor_null_new_anchor_calls_plugin_repair:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var repair_called := [false]
	var tools = _make_mcp_tools([_make_annotation("ann_stale", "stale")])
	if tools == null or not tools.has_method("repair_anchor") or not tools.has_method("set_anchor_registry"):
		check("MCPAnnotationsTools has repair_anchor and set_anchor_registry", false)
		return
	var mock_registry = _MockRegistry.new(repair_called)
	tools.set_anchor_registry(mock_registry)
	tools.repair_anchor("ann_stale", null)
	check("repair_anchor with null new_anchor calls plugin repair()", repair_called[0])


func test_mcp_repair_anchor_non_null_directly_retargets() -> void:
	print("test_mcp_repair_anchor_non_null_directly_retargets:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_mcp_tools([_make_annotation("ann_stale", "stale")])
	if tools == null or not tools.has_method("repair_anchor"):
		check("MCPAnnotationsTools instantiable with repair_anchor", false)
		return
	var new_anchor := {
		"plugin": "core", "type": "text.range",
		"id": {"start": 50, "end": 75},
		"snapshot": {"position": [5.0, 10.0], "text": "new text", "document_revision": 2}
	}
	var result = tools.repair_anchor("ann_stale", new_anchor)
	check("repair_anchor with non-null new_anchor returns ok=true",
		result.get("ok", false) == true)


func test_mcp_repair_anchor_unknown_id_returns_error() -> void:
	print("test_mcp_repair_anchor_unknown_id_returns_error:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_mcp_tools([])
	if tools == null or not tools.has_method("repair_anchor"):
		check("MCPAnnotationsTools instantiable with repair_anchor", false)
		return
	var result = tools.repair_anchor("nonexistent_id", null)
	check("repair_anchor unknown id → ok=false", result.get("ok", true) == false)


# ── Mock helpers ──────────────────────────────────────────────────────────────

class _MockAnnotationStore extends RefCounted:
	var _annotations: Array

	func _init(annotations: Array) -> void:
		_annotations = annotations

	func get_all() -> Array:
		return _annotations

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

	func _init(arr: Array) -> void:
		_called_arr = arr

	func validate_anchor(_anchor: Dictionary) -> Array:
		return []

	func repair_for(anchor: Dictionary, _host) -> Variant:
		_called_arr[0] = true
		return null

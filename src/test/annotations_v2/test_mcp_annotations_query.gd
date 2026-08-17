extends SceneTree

const MCPAnnotationsToolsScript = preload("res://Scripts/Services/MCP/Modules/MCPAnnotationsTools.gd")

var _pass_count := 0
var _fail_count := 0


func _init() -> void:
	print("[tags: unit,integration]")
	print("=== test_mcp_annotations_query ===\n")
	test_query_no_filters_returns_open_and_applied()
	test_query_status_filters()
	test_query_anchor_type_filters()
	test_query_kind_filter()
	test_query_author_filters()
	test_query_text_filters()
	test_query_time_range_filters()
	test_query_capabilities_projection()
	test_query_truncation()
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


func _make_ann(id: String, lifecycle: String, anchor_plugin: String, anchor_type: String, kind: String, author_kind: String, summary: String, created_at: String) -> Dictionary:
	# These fields are String-or-null by design. A ternary can't express that
	# (its branches would be mutually incompatible types), so branch explicitly.
	var author_id: Variant = null
	if author_kind == "human":
		author_id = "user_%s" % id
	var author_model: Variant = null
	if author_kind == "ai":
		author_model = "claude-sonnet"
	return {
		"id": id,
		"kind": kind,
		"schema_version": 2,
		"anchor": {"plugin": anchor_plugin, "type": anchor_type, "id": 1, "snapshot": {"position": [0.0, 0.0]}},
		"kind_payload": {"text": summary},
		"lifecycle": lifecycle,
		"author": {"kind": author_kind, "id": author_id, "model": author_model},
		"view_context": "editor:main",
		"visible_in_views": ["main"],
		"summary": summary,
		"created_at": created_at,
		"updated_at": created_at,
	}


func _sample_annotations() -> Array:
	return [
		_make_ann("ann_001", "open", "core", "text.range", "text", "human", "Fix typo here", "2026-04-29T10:00:00Z"),
		_make_ann("ann_002", "applied", "core", "graphics.region", "arrow", "ai", "Highlight this region", "2026-04-29T11:00:00Z"),
		_make_ann("ann_003", "resolved", "cad", "edge", "cad_edge_note", "human", "Fillet this edge", "2026-04-29T12:00:00Z"),
		_make_ann("ann_004", "stale", "core", "text.range", "text", "human", "Old broken comment", "2026-04-29T09:00:00Z"),
		_make_ann("ann_005", "open", "pcb", "net", "pcb_net_hint", "ai", "Route this net", "2026-04-29T13:00:00Z"),
	]


func _tools(annotations: Array) -> Object:
	var tools := MCPAnnotationsToolsScript.new()
	tools.set_annotation_store(_MockStore.new(annotations))
	return tools


func test_query_no_filters_returns_open_and_applied() -> void:
	var annotations: Array = _tools(_sample_annotations()).query({}).get("annotations", [])
	var lifecycles := annotations.map(func(ann): return ann.get("lifecycle", ""))
	check("no filter default includes open", "open" in lifecycles)
	check("no filter default includes applied", "applied" in lifecycles)
	check("no filter default excludes resolved", not "resolved" in lifecycles)
	check("no filter default excludes stale", not "stale" in lifecycles)


func test_query_status_filters() -> void:
	var tools := _tools(_sample_annotations())
	check("status=any returns all 5", tools.query({"status": "any"}).get("total", 0) == 5)
	check("status=open returns 2", tools.query({"status": "open"}).get("annotations", []).size() == 2)
	check("status=applied returns 1", tools.query({"status": "applied"}).get("annotations", []).size() == 1)
	check("status=resolved returns 1", tools.query({"status": "resolved"}).get("annotations", []).size() == 1)


func test_query_anchor_type_filters() -> void:
	var tools := _tools(_sample_annotations())
	check("anchor_type=core/text.range returns 2", tools.query({"status": "any", "anchor_type": "core/text.range"}).get("annotations", []).size() == 2)
	check("anchor_type=core/* returns 3", tools.query({"status": "any", "anchor_type": "core/*"}).get("annotations", []).size() == 3)
	check("anchor_type=cad/* returns 1", tools.query({"status": "any", "anchor_type": "cad/*"}).get("annotations", []).size() == 1)


func test_query_kind_filter() -> void:
	check("kind=text filter returns 2", _tools(_sample_annotations()).query({"status": "any", "kind": "text"}).get("annotations", []).size() == 2)


func test_query_author_filters() -> void:
	var tools := _tools(_sample_annotations())
	check("author_kind=human returns 3", tools.query({"status": "any", "author_kind": "human"}).get("annotations", []).size() == 3)
	check("author_kind=ai returns 2", tools.query({"status": "any", "author_kind": "ai"}).get("annotations", []).size() == 2)
	check("author_id filter returns 1", tools.query({"status": "any", "author_id": "user_ann_001"}).get("annotations", []).size() == 1)


func test_query_text_filters() -> void:
	var tools := _tools(_sample_annotations())
	check("text=Fillet finds payload/summary", tools.query({"status": "any", "text": "Fillet"}).get("annotations", []).size() == 1)
	check("text=region finds summary", tools.query({"status": "any", "text": "region"}).get("annotations", []).size() >= 1)
	check("text filter case-insensitive", tools.query({"status": "any", "text": "fillet"}).get("total", 0) == tools.query({"status": "any", "text": "FILLET"}).get("total", 0))


func test_query_time_range_filters() -> void:
	var tools := _tools(_sample_annotations())
	check("time_range.after filters by created_at", tools.query({"status": "any", "time_range": {"after": "2026-04-29T11:30:00Z"}}).get("annotations", []).size() == 2)
	check("time_range.before filters by created_at", tools.query({"status": "any", "time_range": {"before": "2026-04-29T10:30:00Z"}}).get("annotations", []).size() == 2)


func test_query_capabilities_projection() -> void:
	var caps := {"multimodal": false, "max_tokens": 32000, "supported_block_types": ["text", "structured_json"]}
	var annotations: Array = _tools([_sample_annotations()[0]]).query({"capabilities": caps}).get("annotations", [])
	check("chat_context field present when capabilities provided", annotations.size() == 1 and annotations[0].has("chat_context"))
	check("chat_context omitted when capabilities absent", not _tools([_sample_annotations()[0]]).query({}).get("annotations", [])[0].has("chat_context"))


func test_query_truncation() -> void:
	var many_anns := []
	for i in range(110):
		many_anns.append(_make_ann("ann_%03d" % i, "open", "core", "text.range", "text", "human", "Comment %d" % i, "2026-04-29T10:00:00Z"))
	var result: Dictionary = _tools(many_anns).query({"status": "open"})
	check("truncated result has at most 100 annotations", result.get("annotations", []).size() == 100)
	check("truncated=true when results exceed 100", result.get("truncated", false))
	check("total reflects full count", result.get("total", 0) == 110)
	check("truncated=false below limit", not _tools(_sample_annotations()).query({"status": "any"}).get("truncated", true))


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

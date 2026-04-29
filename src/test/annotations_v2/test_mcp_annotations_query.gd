extends SceneTree
## Contract tests for minerva_annotations_query MCP tool (task #8).
## Run: godot --headless --path src --script test/annotations_v2/test_mcp_annotations_query.gd
##
## RED in Round 1 — MCPAnnotationsTools v2 query does not exist yet.

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit,integration]")
	print("=== test_mcp_annotations_query ===\n")

	print("-- query: basic filter shapes --")
	test_query_no_filters_returns_open_and_applied()
	test_query_status_any_returns_all()
	test_query_status_open_returns_only_open()
	test_query_status_applied_returns_only_applied()
	test_query_status_resolved_returns_only_resolved()

	print("\n-- query: anchor_type filter --")
	test_query_anchor_type_exact_match()
	test_query_anchor_type_wildcard_core()
	test_query_anchor_type_wildcard_cad()

	print("\n-- query: kind filter --")
	test_query_kind_filter()

	print("\n-- query: author filters --")
	test_query_author_kind_human()
	test_query_author_kind_ai()
	test_query_author_id_filter()

	print("\n-- query: text filter --")
	test_query_text_searches_payload()
	test_query_text_searches_summary()
	test_query_text_case_insensitive()

	print("\n-- query: time_range filter --")
	test_query_time_range_after()
	test_query_time_range_before()

	print("\n-- query: capabilities projection --")
	test_query_with_capabilities_adds_chat_context()
	test_query_without_capabilities_no_chat_context()

	print("\n-- query: truncation --")
	test_query_truncated_when_over_100()
	test_query_truncated_field_true_when_truncated()
	test_query_truncated_field_false_when_not_truncated()
	test_query_total_reflects_full_count()

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


func check_eq(description: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s — expected %s, got %s" % [description, str(expected), str(actual)])


# ── Fixtures ──────────────────────────────────────────────────────────────────

func _make_ann(id: String, lifecycle: String, anchor_plugin: String, anchor_type: String,
		kind: String, author_kind: String, summary: String, created_at: String) -> Dictionary:
	return {
		"id": id,
		"kind": kind,
		"schema_version": 2,
		"anchor": {
			"plugin": anchor_plugin,
			"type": anchor_type,
			"id": 1,
			"snapshot": {"position": [0.0, 0.0]}
		},
		"kind_payload": {"text": summary},
		"lifecycle": lifecycle,
		"author": {"kind": author_kind, "id": "user_%s" % id if author_kind == "human" else null,
			"model": "claude-sonnet" if author_kind == "ai" else null},
		"view_context": "editor:main",
		"visible_in_views": ["main"],
		"summary": summary,
		"created_at": created_at,
		"updated_at": created_at
	}


func _make_tools(annotations: Array) -> Variant:
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		return null
	var tools = ClassDB.instantiate("MCPAnnotationsTools")
	if tools == null:
		return null
	tools.set_annotation_store(_MockStore.new(annotations))
	return tools


func _sample_annotations() -> Array:
	return [
		_make_ann("ann_001", "open",     "core", "text.range",    "text",    "human", "Fix typo here",          "2026-04-29T10:00:00Z"),
		_make_ann("ann_002", "applied",  "core", "graphics.region","arrow", "ai",    "Highlight this region",  "2026-04-29T11:00:00Z"),
		_make_ann("ann_003", "resolved", "cad",  "edge",          "cad_edge_note", "human", "Fillet this edge", "2026-04-29T12:00:00Z"),
		_make_ann("ann_004", "stale",    "core", "text.range",    "text",    "human", "Old broken comment",     "2026-04-29T09:00:00Z"),
		_make_ann("ann_005", "open",     "pcb",  "net",           "pcb_net_hint", "ai", "Route this net",      "2026-04-29T13:00:00Z"),
	]


# ── Basic filter tests ────────────────────────────────────────────────────────

func test_query_no_filters_returns_open_and_applied() -> void:
	print("test_query_no_filters_returns_open_and_applied:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools(_sample_annotations())
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.query({})
	var annotations = result.get("annotations", [])
	var lifecycles := []
	for ann in annotations:
		lifecycles.append(ann.get("lifecycle", ""))
	check("no filter default includes open",  "open" in lifecycles)
	check("no filter default includes applied", "applied" in lifecycles)
	check("no filter default excludes resolved", not ("resolved" in lifecycles))
	check("no filter default excludes stale", not ("stale" in lifecycles))


func test_query_status_any_returns_all() -> void:
	print("test_query_status_any_returns_all:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools(_sample_annotations())
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.query({"status": "any"})
	check_eq("status=any returns all 5 annotations", result.get("total", 0), 5)


func test_query_status_open_returns_only_open() -> void:
	print("test_query_status_open_returns_only_open:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools(_sample_annotations())
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.query({"status": "open"})
	var annotations = result.get("annotations", [])
	var all_open := true
	for ann in annotations:
		if ann.get("lifecycle", "") != "open":
			all_open = false
	check("status=open returns only open", all_open)
	check_eq("status=open returns 2 annotations", annotations.size(), 2)


func test_query_status_applied_returns_only_applied() -> void:
	print("test_query_status_applied_returns_only_applied:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools(_sample_annotations())
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.query({"status": "applied"})
	var annotations = result.get("annotations", [])
	check_eq("status=applied returns 1 annotation", annotations.size(), 1)


func test_query_status_resolved_returns_only_resolved() -> void:
	print("test_query_status_resolved_returns_only_resolved:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools(_sample_annotations())
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.query({"status": "resolved"})
	var annotations = result.get("annotations", [])
	check_eq("status=resolved returns 1 annotation", annotations.size(), 1)


# ── Anchor type filter tests ──────────────────────────────────────────────────

func test_query_anchor_type_exact_match() -> void:
	print("test_query_anchor_type_exact_match:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools(_sample_annotations())
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.query({"status": "any", "anchor_type": "core/text.range"})
	var annotations = result.get("annotations", [])
	check("anchor_type=core/text.range returns 2 matches", annotations.size() == 2)
	for ann in annotations:
		check("each result has core/text.range anchor",
			ann.get("anchor", {}).get("type", "") == "text.range" and
			ann.get("anchor", {}).get("plugin", "") == "core")


func test_query_anchor_type_wildcard_core() -> void:
	print("test_query_anchor_type_wildcard_core:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools(_sample_annotations())
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.query({"status": "any", "anchor_type": "core/*"})
	var annotations = result.get("annotations", [])
	check("anchor_type=core/* returns 3 core anchors", annotations.size() == 3)


func test_query_anchor_type_wildcard_cad() -> void:
	print("test_query_anchor_type_wildcard_cad:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools(_sample_annotations())
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.query({"status": "any", "anchor_type": "cad/*"})
	var annotations = result.get("annotations", [])
	check("anchor_type=cad/* returns 1 cad annotation", annotations.size() == 1)


# ── Kind filter ───────────────────────────────────────────────────────────────

func test_query_kind_filter() -> void:
	print("test_query_kind_filter:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools(_sample_annotations())
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.query({"status": "any", "kind": "text"})
	var annotations = result.get("annotations", [])
	check("kind=text filter returns 2 text annotations", annotations.size() == 2)


# ── Author filters ────────────────────────────────────────────────────────────

func test_query_author_kind_human() -> void:
	print("test_query_author_kind_human:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools(_sample_annotations())
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.query({"status": "any", "author_kind": "human"})
	var annotations = result.get("annotations", [])
	check("author_kind=human returns 3 human-authored", annotations.size() == 3)


func test_query_author_kind_ai() -> void:
	print("test_query_author_kind_ai:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools(_sample_annotations())
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.query({"status": "any", "author_kind": "ai"})
	var annotations = result.get("annotations", [])
	check("author_kind=ai returns 2 ai-authored", annotations.size() == 2)


func test_query_author_id_filter() -> void:
	print("test_query_author_id_filter:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools(_sample_annotations())
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.query({"status": "any", "author_id": "user_ann_001"})
	var annotations = result.get("annotations", [])
	check("author_id filter returns only matching author", annotations.size() == 1)


# ── Text filter ───────────────────────────────────────────────────────────────

func test_query_text_searches_payload() -> void:
	print("test_query_text_searches_payload:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools(_sample_annotations())
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.query({"status": "any", "text": "Fillet"})
	var annotations = result.get("annotations", [])
	check("text=Fillet finds 1 annotation", annotations.size() == 1)


func test_query_text_searches_summary() -> void:
	print("test_query_text_searches_summary:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools(_sample_annotations())
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.query({"status": "any", "text": "region"})
	var annotations = result.get("annotations", [])
	check("text=region finds annotation via summary", annotations.size() >= 1)


func test_query_text_case_insensitive() -> void:
	print("test_query_text_case_insensitive:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools(_sample_annotations())
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result_lower = tools.query({"status": "any", "text": "fillet"})
	var result_upper = tools.query({"status": "any", "text": "FILLET"})
	check("text filter case-insensitive",
		result_lower.get("total", 0) == result_upper.get("total", 0))


# ── Time range filter ─────────────────────────────────────────────────────────

func test_query_time_range_after() -> void:
	print("test_query_time_range_after:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools(_sample_annotations())
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.query({"status": "any", "time_range": {"after": "2026-04-29T11:30:00Z"}})
	var annotations = result.get("annotations", [])
	# Created after 11:30: ann_003 (12:00), ann_005 (13:00) = 2
	check("time_range.after filters by created_at", annotations.size() == 2)


func test_query_time_range_before() -> void:
	print("test_query_time_range_before:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools(_sample_annotations())
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.query({"status": "any", "time_range": {"before": "2026-04-29T10:30:00Z"}})
	var annotations = result.get("annotations", [])
	# Created before 10:30: ann_001 (10:00), ann_004 (09:00) = 2
	check("time_range.before filters by created_at", annotations.size() == 2)


# ── Capabilities projection ───────────────────────────────────────────────────

func test_query_with_capabilities_adds_chat_context() -> void:
	print("test_query_with_capabilities_adds_chat_context:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools([_sample_annotations()[0]])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.query({
		"capabilities": {
			"multimodal": false,
			"max_tokens": 32000,
			"supported_block_types": ["text", "structured_json"]
		}
	})
	var annotations = result.get("annotations", [])
	if annotations.size() > 0:
		check("annotation has chat_context field when capabilities provided",
			annotations[0].has("chat_context"))
		check("chat_context is non-empty array",
			annotations[0].get("chat_context", []).size() > 0)
	else:
		check("annotations present", false)


func test_query_without_capabilities_no_chat_context() -> void:
	print("test_query_without_capabilities_no_chat_context:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools([_sample_annotations()[0]])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.query({})
	var annotations = result.get("annotations", [])
	if annotations.size() > 0:
		check("annotation has no chat_context when capabilities not provided",
			not annotations[0].has("chat_context"))
	else:
		check("annotations present", false)


# ── Truncation tests ──────────────────────────────────────────────────────────

func test_query_truncated_when_over_100() -> void:
	print("test_query_truncated_when_over_100:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var many_anns := []
	for i in range(150):
		many_anns.append(_make_ann("ann_%03d" % i, "open", "core", "text.range",
			"text", "human", "Comment %d" % i, "2026-04-29T10:00:00Z"))
	var tools = _make_tools(many_anns)
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.query({"status": "open"})
	var annotations = result.get("annotations", [])
	check("truncated result has at most 100 annotations", annotations.size() <= 100)
	check("truncated=true when results exceed 100", result.get("truncated", false) == true)


func test_query_truncated_field_true_when_truncated() -> void:
	print("test_query_truncated_field_true_when_truncated:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var many_anns := []
	for i in range(101):
		many_anns.append(_make_ann("ann_%03d" % i, "open", "core", "text.range",
			"text", "human", "Comment %d" % i, "2026-04-29T10:00:00Z"))
	var tools = _make_tools(many_anns)
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.query({"status": "open"})
	check("truncated field present in result", result.has("truncated"))
	check("truncated=true when 101 results", result.get("truncated", false) == true)


func test_query_truncated_field_false_when_not_truncated() -> void:
	print("test_query_truncated_field_false_when_not_truncated:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools(_sample_annotations())
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.query({"status": "any"})
	check("truncated=false when results < 100", result.get("truncated", true) == false)


func test_query_total_reflects_full_count() -> void:
	print("test_query_total_reflects_full_count:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var many_anns := []
	for i in range(110):
		many_anns.append(_make_ann("ann_%03d" % i, "open", "core", "text.range",
			"text", "human", "Comment %d" % i, "2026-04-29T10:00:00Z"))
	var tools = _make_tools(many_anns)
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.query({"status": "open"})
	check_eq("total reflects full count (110) not truncated count",
		result.get("total", 0), 110)


# ── Mock helpers ──────────────────────────────────────────────────────────────

class _MockStore extends RefCounted:
	var _annotations: Array

	func _init(annotations: Array) -> void:
		_annotations = annotations

	func get_all() -> Array: return _annotations
	func get_by_id(id: String) -> Variant:
		for a in _annotations:
			if a.get("id", "") == id: return a
		return null
	func update(annotation: Dictionary) -> void:
		for i in range(_annotations.size()):
			if _annotations[i].get("id", "") == annotation.get("id", ""):
				_annotations[i] = annotation
				return

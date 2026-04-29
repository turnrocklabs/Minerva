extends SceneTree
## Contract tests for minerva_annotations_update_status MCP tool (task #8).
## Run: godot --headless --path src --script test/annotations_v2/test_mcp_annotations_update_status.gd
##
## RED in Round 1 — MCPAnnotationsTools.update_status does not exist yet.

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_mcp_annotations_update_status ===\n")

	print("-- legal transitions --")
	test_transition_open_to_applied_with_links()
	test_transition_open_to_resolved_with_by()
	test_transition_applied_to_resolved_with_by()
	test_transition_resolved_to_open()
	test_transition_stale_to_open()

	print("\n-- illegal transitions --")
	test_transition_applied_to_open_illegal()
	test_transition_resolved_to_applied_illegal()
	test_transition_stale_to_applied_illegal()
	test_transition_stale_to_resolved_illegal()
	test_transition_user_initiated_stale_illegal()

	print("\n-- required fields enforcement --")
	test_applied_requires_applied_object()
	test_applied_requires_links_in_applied()
	test_resolved_requires_resolved_by()
	test_applied_object_persisted_in_result()
	test_resolved_object_persisted_in_result()

	print("\n-- result shape --")
	test_legal_transition_returns_ok_true()
	test_illegal_transition_returns_ok_false_with_error()
	test_result_includes_updated_annotation()

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

func _make_ann(id: String, lifecycle: String) -> Dictionary:
	return {
		"id": id,
		"kind": "text",
		"schema_version": 2,
		"anchor": {
			"plugin": "core", "type": "text.range",
			"id": {"start": 0, "end": 10},
			"snapshot": {"position": [0.0, 0.0], "text": "sample", "document_revision": 1}
		},
		"kind_payload": {"text": "comment"},
		"lifecycle": lifecycle,
		"author": {"kind": "human"},
		"view_context": "editor:main",
		"visible_in_views": ["main"],
		"summary": "Test comment.",
		"created_at": "2026-04-29T17:00:00Z",
		"updated_at": "2026-04-29T17:00:00Z",
		"applied": null,
		"resolved": null
	}


func _make_tools(annotations: Array) -> Variant:
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		return null
	var tools = ClassDB.instantiate("MCPAnnotationsTools")
	if tools == null:
		return null
	tools.set_annotation_store(_MockStore.new(annotations))
	return tools


func _ai_author() -> Dictionary:
	return {"kind": "ai", "model": "claude-sonnet-4-6"}


func _human_author() -> Dictionary:
	return {"kind": "human", "id": "user_1"}


# ── Legal transitions ─────────────────────────────────────────────────────────

func test_transition_open_to_applied_with_links() -> void:
	print("test_transition_open_to_applied_with_links:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools([_make_ann("ann_001", "open")])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.update_status("ann_001", "applied", {
		"applied": {
			"by": _ai_author(),
			"links": [{"kind": "text.edit", "id": "edit_42"}]
		}
	})
	check("open → applied transition succeeds", result.get("ok", false) == true)
	var ann = result.get("annotation", {})
	check("updated annotation lifecycle=applied", ann.get("lifecycle", "") == "applied")


func test_transition_open_to_resolved_with_by() -> void:
	print("test_transition_open_to_resolved_with_by:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools([_make_ann("ann_001", "open")])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.update_status("ann_001", "resolved", {
		"resolved": {"by": _human_author(), "note": "Done manually"}
	})
	check("open → resolved transition succeeds", result.get("ok", false) == true)


func test_transition_applied_to_resolved_with_by() -> void:
	print("test_transition_applied_to_resolved_with_by:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools([_make_ann("ann_001", "applied")])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.update_status("ann_001", "resolved", {
		"resolved": {"by": _human_author()}
	})
	check("applied → resolved transition succeeds", result.get("ok", false) == true)


func test_transition_resolved_to_open() -> void:
	print("test_transition_resolved_to_open:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools([_make_ann("ann_001", "resolved")])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.update_status("ann_001", "open", {})
	check("resolved → open (reopen) transition succeeds", result.get("ok", false) == true)


func test_transition_stale_to_open() -> void:
	print("test_transition_stale_to_open:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools([_make_ann("ann_001", "stale")])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.update_status("ann_001", "open", {})
	check("stale → open (repair) transition succeeds", result.get("ok", false) == true)


# ── Illegal transitions ───────────────────────────────────────────────────────

func test_transition_applied_to_open_illegal() -> void:
	print("test_transition_applied_to_open_illegal:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools([_make_ann("ann_001", "applied")])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.update_status("ann_001", "open", {})
	check("applied → open is illegal", result.get("ok", true) == false)
	check("illegal transition returns error field", result.has("error"))


func test_transition_resolved_to_applied_illegal() -> void:
	print("test_transition_resolved_to_applied_illegal:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools([_make_ann("ann_001", "resolved")])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.update_status("ann_001", "applied", {
		"applied": {"by": _ai_author(), "links": []}
	})
	check("resolved → applied is illegal", result.get("ok", true) == false)


func test_transition_stale_to_applied_illegal() -> void:
	print("test_transition_stale_to_applied_illegal:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools([_make_ann("ann_001", "stale")])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.update_status("ann_001", "applied", {
		"applied": {"by": _ai_author(), "links": []}
	})
	check("stale → applied is illegal", result.get("ok", true) == false)


func test_transition_stale_to_resolved_illegal() -> void:
	print("test_transition_stale_to_resolved_illegal:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools([_make_ann("ann_001", "stale")])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.update_status("ann_001", "resolved", {
		"resolved": {"by": _human_author()}
	})
	check("stale → resolved is illegal (must repair first)", result.get("ok", true) == false)


func test_transition_user_initiated_stale_illegal() -> void:
	print("test_transition_user_initiated_stale_illegal:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools([_make_ann("ann_001", "open")])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	# User-initiated → stale is rejected; stale is substrate-only
	var result = tools.update_status("ann_001", "stale", {})
	check("user-initiated open → stale is rejected by MCP", result.get("ok", true) == false)


# ── Required fields enforcement ───────────────────────────────────────────────

func test_applied_requires_applied_object() -> void:
	print("test_applied_requires_applied_object:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools([_make_ann("ann_001", "open")])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	# Missing 'applied' object when transitioning to applied
	var result = tools.update_status("ann_001", "applied", {})
	check("open → applied without applied object → rejected", result.get("ok", true) == false)


func test_applied_requires_links_in_applied() -> void:
	print("test_applied_requires_links_in_applied:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools([_make_ann("ann_001", "open")])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	# applied.links is required
	var result = tools.update_status("ann_001", "applied", {
		"applied": {"by": _ai_author()}  # missing links
	})
	check("applied object without links → rejected", result.get("ok", true) == false)


func test_resolved_requires_resolved_by() -> void:
	print("test_resolved_requires_resolved_by:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools([_make_ann("ann_001", "open")])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	# resolved.by is required
	var result = tools.update_status("ann_001", "resolved", {
		"resolved": {"note": "done"}  # missing by
	})
	check("resolved object without by → rejected", result.get("ok", true) == false)


func test_applied_object_persisted_in_result() -> void:
	print("test_applied_object_persisted_in_result:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools([_make_ann("ann_001", "open")])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var applied_obj := {"by": _ai_author(), "links": [{"kind": "text.edit", "id": "e1"}]}
	var result = tools.update_status("ann_001", "applied", {"applied": applied_obj})
	if result.get("ok", false):
		var ann = result.get("annotation", {})
		check("applied object persisted in result annotation", ann.has("applied") and ann["applied"] != null)
	else:
		check("transition succeeded to check applied object", false)


func test_resolved_object_persisted_in_result() -> void:
	print("test_resolved_object_persisted_in_result:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools([_make_ann("ann_001", "open")])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var resolved_obj := {"by": _human_author(), "note": "User verified"}
	var result = tools.update_status("ann_001", "resolved", {"resolved": resolved_obj})
	if result.get("ok", false):
		var ann = result.get("annotation", {})
		check("resolved object persisted in result annotation",
			ann.has("resolved") and ann["resolved"] != null)
	else:
		check("transition succeeded to check resolved object", false)


# ── Result shape tests ────────────────────────────────────────────────────────

func test_legal_transition_returns_ok_true() -> void:
	print("test_legal_transition_returns_ok_true:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools([_make_ann("ann_001", "open")])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.update_status("ann_001", "resolved", {"resolved": {"by": _human_author()}})
	check("legal transition result has ok=true", result.get("ok", false) == true)
	check("legal transition result has annotation key", result.has("annotation"))


func test_illegal_transition_returns_ok_false_with_error() -> void:
	print("test_illegal_transition_returns_ok_false_with_error:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools([_make_ann("ann_001", "applied")])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.update_status("ann_001", "open", {})
	check("illegal transition result has ok=false", result.get("ok", true) == false)
	check("illegal transition result has error string", result.get("error", "").length() > 0)
	check("illegal transition result has from field", result.has("from"))
	check("illegal transition result has to field", result.has("to"))


func test_result_includes_updated_annotation() -> void:
	print("test_result_includes_updated_annotation:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools([_make_ann("ann_001", "open")])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.update_status("ann_001", "resolved", {"resolved": {"by": _human_author()}})
	if result.get("ok", false):
		var ann = result.get("annotation", {})
		check("result annotation has id", ann.has("id"))
		check("result annotation id correct", ann.get("id", "") == "ann_001")
		check("result annotation lifecycle updated", ann.get("lifecycle", "") == "resolved")
	else:
		check("transition succeeded", false)


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

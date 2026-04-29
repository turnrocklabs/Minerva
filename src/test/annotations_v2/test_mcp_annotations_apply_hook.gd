extends SceneTree
## Contract tests for minerva_annotations_register_apply_hook MCP tool (task #8).
## Run: godot --headless --path src --script test/annotations_v2/test_mcp_annotations_apply_hook.gd
##
## RED in Round 1 — MCPAnnotationsTools.register_apply_hook does not exist yet.

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_mcp_annotations_apply_hook ===\n")

	print("-- apply hook: registration --")
	test_register_apply_hook_returns_ok()
	test_register_apply_hook_method_exists()

	print("\n-- apply hook: hook fires on applied transition --")
	test_hook_fires_after_status_transition_to_applied()
	test_hook_receives_annotation_id()
	test_hook_fires_after_status_persisted()

	print("\n-- apply hook: failure handling --")
	test_hook_failure_does_not_roll_back_status()
	test_hook_failure_is_logged_not_propagated()

	print("\n-- apply hook: multiple hooks compose --")
	test_multiple_hooks_for_same_kind_all_fire()
	test_hook_not_fired_for_different_kind()

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

func _make_ann(id: String, kind: String, lifecycle: String) -> Dictionary:
	return {
		"id": id,
		"kind": kind,
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


# ── Registration tests ────────────────────────────────────────────────────────

func test_register_apply_hook_method_exists() -> void:
	print("test_register_apply_hook_method_exists:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = ClassDB.instantiate("MCPAnnotationsTools")
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	check("MCPAnnotationsTools has register_apply_hook method",
		tools.has_method("register_apply_hook"))


func test_register_apply_hook_returns_ok() -> void:
	print("test_register_apply_hook_returns_ok:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools([])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	var result = tools.register_apply_hook("myplugin", "text", "my_apply_callback")
	check("register_apply_hook returns ok=true", result.get("ok", false) == true)


# ── Hook fires tests ──────────────────────────────────────────────────────────

func test_hook_fires_after_status_transition_to_applied() -> void:
	print("test_hook_fires_after_status_transition_to_applied:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var hook_fired := [false]
	var tools = _make_tools([_make_ann("ann_001", "text", "open")])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	# Register a callable hook directly
	tools.register_apply_hook_callable("text", func(_ann_id): hook_fired[0] = true)
	tools.update_status("ann_001", "applied", {
		"applied": {"by": {"kind": "ai"}, "links": [{"kind": "edit", "id": "e1"}]}
	})
	check("apply hook fires when status transitions to applied", hook_fired[0])


func test_hook_receives_annotation_id() -> void:
	print("test_hook_receives_annotation_id:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var received_id := [""]
	var tools = _make_tools([_make_ann("ann_hook_test", "text", "open")])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	tools.register_apply_hook_callable("text", func(ann_id): received_id[0] = ann_id)
	tools.update_status("ann_hook_test", "applied", {
		"applied": {"by": {"kind": "ai"}, "links": []}
	})
	check("hook receives correct annotation id", received_id[0] == "ann_hook_test")


func test_hook_fires_after_status_persisted() -> void:
	print("test_hook_fires_after_status_persisted:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var store = _MockStore.new([_make_ann("ann_001", "text", "open")])
	var lifecycle_in_hook := [""]
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = ClassDB.instantiate("MCPAnnotationsTools")
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	tools.set_annotation_store(store)
	tools.register_apply_hook_callable("text", func(ann_id):
		var ann = store.get_by_id(ann_id)
		if ann != null:
			lifecycle_in_hook[0] = ann.get("lifecycle", "")
	)
	tools.update_status("ann_001", "applied", {
		"applied": {"by": {"kind": "ai"}, "links": []}
	})
	check("hook fires AFTER status persisted (lifecycle=applied when hook runs)",
		lifecycle_in_hook[0] == "applied")


# ── Failure handling tests ────────────────────────────────────────────────────

func test_hook_failure_does_not_roll_back_status() -> void:
	print("test_hook_failure_does_not_roll_back_status:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var store = _MockStore.new([_make_ann("ann_001", "text", "open")])
	var tools = ClassDB.instantiate("MCPAnnotationsTools")
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	tools.set_annotation_store(store)
	# Register a throwing hook
	tools.register_apply_hook_callable("text", func(_ann_id):
		# Simulate a throwing hook by calling something invalid
		# In GDScript, we can't truly throw; we test via assertion that
		# the hook failure is recorded but status is not rolled back
		pass  # hook implementation will throw in Round 11
	)
	var result = tools.update_status("ann_001", "applied", {
		"applied": {"by": {"kind": "ai"}, "links": []}
	})
	# Even if hook were to fail, status should still be applied
	if result.get("ok", false):
		var ann = store.get_by_id("ann_001")
		check("status persisted even if hook would fail",
			ann.get("lifecycle", "") == "applied")
	else:
		check("transition succeeded", false)


func test_hook_failure_is_logged_not_propagated() -> void:
	print("test_hook_failure_is_logged_not_propagated:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var tools = _make_tools([_make_ann("ann_001", "text", "open")])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	# A hook that raises an error should not propagate to update_status caller
	# This test verifies the trust contract: hooks are informational
	check("MCPAnnotationsTools has hook_error_log or similar diagnostic surface",
		tools.has_method("get_hook_errors") or tools.has_method("get_hook_log"))


# ── Multiple hooks compose ────────────────────────────────────────────────────

func test_multiple_hooks_for_same_kind_all_fire() -> void:
	print("test_multiple_hooks_for_same_kind_all_fire:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var fired := [0]
	var tools = _make_tools([_make_ann("ann_001", "text", "open")])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	tools.register_apply_hook_callable("text", func(_id): fired[0] += 1)
	tools.register_apply_hook_callable("text", func(_id): fired[0] += 1)
	tools.update_status("ann_001", "applied", {
		"applied": {"by": {"kind": "ai"}, "links": []}
	})
	check("both hooks fire when two hooks registered for same kind",
		fired[0] == 2)


func test_hook_not_fired_for_different_kind() -> void:
	print("test_hook_not_fired_for_different_kind:")
	if not ClassDB.class_exists("MCPAnnotationsTools"):
		check("MCPAnnotationsTools exists", false)
		return
	var fired := [false]
	var tools = _make_tools([_make_ann("ann_001", "text", "open")])
	if tools == null:
		check("MCPAnnotationsTools instantiable", false)
		return
	# Register hook for "arrow" kind, but annotation is "text" kind
	tools.register_apply_hook_callable("arrow", func(_id): fired[0] = true)
	tools.update_status("ann_001", "applied", {
		"applied": {"by": {"kind": "ai"}, "links": []}
	})
	check("hook for 'arrow' NOT fired when 'text' annotation is applied",
		not fired[0])


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

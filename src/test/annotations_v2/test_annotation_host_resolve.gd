extends SceneTree
## Behavioral tests for AnnotationHost.resolve_anchor + anchor_screen_rect (task #3).
## Run: godot --headless --path src --script test/annotations_v2/test_annotation_host_resolve.gd

const AnnotationHostScript = preload("res://Scripts/Services/Annotations/AnnotationHost.gd")

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_annotation_host_resolve ===\n")

	print("-- resolve_anchor: default implementation --")
	test_resolve_anchor_default_returns_stale_true()
	test_resolve_anchor_default_position_from_snapshot()
	test_resolve_anchor_default_bounds_zero_size()
	test_resolve_anchor_default_view_metadata_empty()
	test_resolve_anchor_default_accepts_vector3_snapshot()
	test_resolve_anchor_default_missing_snapshot_returns_zero()

	print("\n-- resolve_anchor: override behavior --")
	test_resolve_anchor_override_returns_custom_position()
	test_resolve_anchor_override_can_return_stale_false()
	test_resolve_anchor_view_metadata_round_trips()

	print("\n-- anchor_screen_rect: behavior --")
	test_anchor_screen_rect_default_delegates_to_resolve()
	test_anchor_screen_rect_uses_view_context()

	print("\n-- register_anchor_resolver helper --")
	test_register_anchor_resolver_callable()
	test_registered_resolver_array_position_normalized()
	test_registered_resolver_bad_result_falls_back_stale()
	test_has_anchor_resolver_for_unknown_false()
	test_has_anchor_resolver_for_registered_true()

	print("\n-- negative: no resolver -> stale with snapshot position --")
	test_no_resolver_returns_stale_with_snapshot_pos()

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


func check_eq(description: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s - expected %s, got %s" % [description, str(expected), str(actual)])


func _host() -> RefCounted:
	return AnnotationHostScript.new()


func _anchor_with_snapshot_pos(x: float, y: float) -> Dictionary:
	return {
		"plugin": "core",
		"type": "text.range",
		"id": {"start": 0, "end": 10},
		"snapshot": {
			"position": [x, y],
			"text": "test",
			"document_revision": 1
		}
	}


func test_resolve_anchor_default_returns_stale_true() -> void:
	print("test_resolve_anchor_default_returns_stale_true:")
	var result: Dictionary = _host().resolve_anchor(_anchor_with_snapshot_pos(50.0, 100.0))
	check("default resolve_anchor returns stale=true", result.get("stale", false) == true)


func test_resolve_anchor_default_position_from_snapshot() -> void:
	print("test_resolve_anchor_default_position_from_snapshot:")
	var result: Dictionary = _host().resolve_anchor(_anchor_with_snapshot_pos(50.0, 100.0))
	var pos: Vector2 = result.get("position", Vector2.ZERO)
	check_eq("default resolve uses snapshot.position x", pos.x, 50.0)
	check_eq("default resolve uses snapshot.position y", pos.y, 100.0)


func test_resolve_anchor_default_bounds_zero_size() -> void:
	print("test_resolve_anchor_default_bounds_zero_size:")
	var result: Dictionary = _host().resolve_anchor(_anchor_with_snapshot_pos(10.0, 20.0))
	var bounds: Variant = result.get("bounds", null)
	check("default resolve_anchor returns bounds", bounds is Rect2)
	if bounds is Rect2:
		check("default bounds has zero size", bounds.size == Vector2.ZERO)


func test_resolve_anchor_default_view_metadata_empty() -> void:
	print("test_resolve_anchor_default_view_metadata_empty:")
	var result: Dictionary = _host().resolve_anchor(_anchor_with_snapshot_pos(0.0, 0.0))
	var meta: Variant = result.get("view_metadata", null)
	check("default view_metadata is empty dict", meta is Dictionary and meta.is_empty())


func test_resolve_anchor_default_accepts_vector3_snapshot() -> void:
	print("test_resolve_anchor_default_accepts_vector3_snapshot:")
	var anchor := _anchor_with_snapshot_pos(0.0, 0.0)
	anchor["snapshot"]["position"] = Vector3(11.0, 12.0, 13.0)
	var pos: Vector2 = _host().resolve_anchor(anchor).get("position", Vector2.ZERO)
	check_eq("Vector3 snapshot x preserved", pos.x, 11.0)
	check_eq("Vector3 snapshot y preserved", pos.y, 12.0)


func test_resolve_anchor_default_missing_snapshot_returns_zero() -> void:
	print("test_resolve_anchor_default_missing_snapshot_returns_zero:")
	var anchor := {"plugin": "cad", "type": "edge", "id": 1}
	var result: Dictionary = _host().resolve_anchor(anchor)
	check_eq("missing snapshot position is zero", result.get("position", Vector2.INF), Vector2.ZERO)
	check("missing snapshot is stale", result.get("stale", false))


func test_resolve_anchor_override_returns_custom_position() -> void:
	print("test_resolve_anchor_override_returns_custom_position:")
	var result: Dictionary = _MockHost.new().resolve_anchor(_anchor_with_snapshot_pos(0.0, 0.0))
	var pos: Vector2 = result.get("position", Vector2.ZERO)
	check_eq("overridden resolve_anchor returns custom x", pos.x, 200.0)
	check_eq("overridden resolve_anchor returns custom y", pos.y, 300.0)


func test_resolve_anchor_override_can_return_stale_false() -> void:
	print("test_resolve_anchor_override_can_return_stale_false:")
	var result: Dictionary = _MockHost.new().resolve_anchor(_anchor_with_snapshot_pos(0.0, 0.0))
	check("overridden resolve_anchor can return stale=false", result.get("stale", true) == false)


func test_resolve_anchor_view_metadata_round_trips() -> void:
	print("test_resolve_anchor_view_metadata_round_trips:")
	var result: Dictionary = _MockHost.new().resolve_anchor(_anchor_with_snapshot_pos(0.0, 0.0))
	var meta: Dictionary = result.get("view_metadata", {})
	check_eq("view_metadata pane name round-trips", meta.get("pane", ""), "iso")
	check_eq("view_metadata leader_offset round-trips", meta.get("leader_offset", Vector2.ZERO), Vector2(10.0, -10.0))


func test_anchor_screen_rect_default_delegates_to_resolve() -> void:
	print("test_anchor_screen_rect_default_delegates_to_resolve:")
	var rect: Rect2 = _host().anchor_screen_rect(_anchor_with_snapshot_pos(30.0, 40.0), "editor:main")
	check_eq("default anchor_screen_rect position matches snapshot", rect.position, Vector2(30.0, 40.0))
	check_eq("default anchor_screen_rect size is zero", rect.size, Vector2.ZERO)


func test_anchor_screen_rect_uses_view_context() -> void:
	print("test_anchor_screen_rect_uses_view_context:")
	var rect: Rect2 = _MockHost.new().anchor_screen_rect(_anchor_with_snapshot_pos(0.0, 0.0), "iso")
	check("anchor_screen_rect accepts view_context", rect is Rect2)


func test_register_anchor_resolver_callable() -> void:
	print("test_register_anchor_resolver_callable:")
	var host := _host()
	var called := [false]
	var mock_callable := func(_anchor: Dictionary) -> Dictionary:
		called[0] = true
		return {"position": Vector2(99.0, 88.0), "bounds": Rect2(99.0, 88.0, 5.0, 6.0), "stale": false, "view_metadata": {}}
	host.register_anchor_resolver("core/text.range", mock_callable)
	var result: Dictionary = host.resolve_anchor(_anchor_with_snapshot_pos(0.0, 0.0))
	check("registered callable invoked during resolve", called[0])
	check_eq("registered callable result position used", result.get("position", Vector2.ZERO), Vector2(99.0, 88.0))
	check_eq("registered callable result bounds used", result.get("bounds", Rect2()).size, Vector2(5.0, 6.0))


func test_registered_resolver_array_position_normalized() -> void:
	print("test_registered_resolver_array_position_normalized:")
	var host := _host()
	host.register_anchor_resolver("core/text.range", func(_anchor: Dictionary) -> Dictionary:
		return {"position": [7.0, 8.0], "stale": false}
	)
	var result: Dictionary = host.resolve_anchor(_anchor_with_snapshot_pos(0.0, 0.0))
	check_eq("array position normalized to Vector2", result.get("position", Vector2.ZERO), Vector2(7.0, 8.0))
	check_eq("missing bounds defaults to point at position", result.get("bounds", Rect2()).position, Vector2(7.0, 8.0))


func test_registered_resolver_bad_result_falls_back_stale() -> void:
	print("test_registered_resolver_bad_result_falls_back_stale:")
	var host := _host()
	host.register_anchor_resolver("core/text.range", func(_anchor: Dictionary) -> Variant:
		return null
	)
	var result: Dictionary = host.resolve_anchor(_anchor_with_snapshot_pos(3.0, 4.0))
	check("bad resolver result falls back stale", result.get("stale", false))
	check_eq("bad resolver result falls back to snapshot", result.get("position", Vector2.ZERO), Vector2(3.0, 4.0))


func test_has_anchor_resolver_for_unknown_false() -> void:
	print("test_has_anchor_resolver_for_unknown_false:")
	check("has_anchor_resolver_for unknown returns false", not _host().has_anchor_resolver_for("nonexistent/type"))


func test_has_anchor_resolver_for_registered_true() -> void:
	print("test_has_anchor_resolver_for_registered_true:")
	var host := _host()
	host.register_anchor_resolver("core/text.range", func(_anchor: Dictionary) -> Dictionary:
		return {"position": Vector2.ZERO, "bounds": Rect2(), "stale": false, "view_metadata": {}}
	)
	check("has_anchor_resolver_for registered returns true", host.has_anchor_resolver_for("core/text.range"))


func test_no_resolver_returns_stale_with_snapshot_pos() -> void:
	print("test_no_resolver_returns_stale_with_snapshot_pos:")
	var anchor := {
		"plugin": "cad",
		"type": "edge",
		"id": 5,
		"snapshot": {"position": [77.0, 88.0]}
	}
	var result: Dictionary = _host().resolve_anchor(anchor)
	check("unregistered anchor returns stale=true", result.get("stale", false) == true)
	check_eq("unregistered anchor position from snapshot", result.get("position", Vector2.ZERO), Vector2(77.0, 88.0))


class _MockHost extends AnnotationHost:
	func resolve_anchor(_anchor: Dictionary) -> Dictionary:
		return {
			"position": Vector2(200.0, 300.0),
			"bounds": Rect2(200.0, 300.0, 20.0, 10.0),
			"stale": false,
			"view_metadata": {"pane": "iso", "leader_offset": Vector2(10.0, -10.0)}
		}

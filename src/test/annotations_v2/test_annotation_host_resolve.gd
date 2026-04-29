extends SceneTree
## Contract tests for AnnotationHost.resolve_anchor + anchor_screen_rect (task #3).
## Run: godot --headless --path src --script test/annotations_v2/test_annotation_host_resolve.gd
##
## RED in Round 1 — AnnotationHost v2 methods do not exist yet.

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

	print("\n-- resolve_anchor: override behavior --")
	test_resolve_anchor_override_returns_custom_position()
	test_resolve_anchor_override_can_return_stale_false()
	test_resolve_anchor_view_metadata_round_trips()

	print("\n-- anchor_screen_rect: behavior --")
	test_anchor_screen_rect_default_delegates_to_resolve()
	test_anchor_screen_rect_uses_view_context()

	print("\n-- register_anchor_resolver helper --")
	test_register_anchor_resolver_callable()
	test_has_anchor_resolver_for_unknown_false()
	test_has_anchor_resolver_for_registered_true()

	print("\n-- negative: no resolver → stale with snapshot position --")
	test_no_resolver_returns_stale_with_snapshot_pos()

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


# ── Default implementation tests ──────────────────────────────────────────────

func test_resolve_anchor_default_returns_stale_true() -> void:
	print("test_resolve_anchor_default_returns_stale_true:")
	if not ClassDB.class_exists("AnnotationHost"):
		check("AnnotationHost exists", false)
		return
	var host = AnnotationHost.new()
	if not host.has_method("resolve_anchor"):
		check("AnnotationHost has resolve_anchor method", false)
		return
	var anchor = _anchor_with_snapshot_pos(50.0, 100.0)
	var result = host.resolve_anchor(anchor)
	check("default resolve_anchor returns stale=true", result.get("stale", false) == true)


func test_resolve_anchor_default_position_from_snapshot() -> void:
	print("test_resolve_anchor_default_position_from_snapshot:")
	if not ClassDB.class_exists("AnnotationHost"):
		check("AnnotationHost exists", false)
		return
	var host = AnnotationHost.new()
	if not host.has_method("resolve_anchor"):
		check("AnnotationHost has resolve_anchor method", false)
		return
	var anchor = _anchor_with_snapshot_pos(50.0, 100.0)
	var result = host.resolve_anchor(anchor)
	var pos = result.get("position", Vector2.ZERO)
	check("default resolve uses snapshot.position x", pos.x == 50.0)
	check("default resolve uses snapshot.position y", pos.y == 100.0)


func test_resolve_anchor_default_bounds_zero_size() -> void:
	print("test_resolve_anchor_default_bounds_zero_size:")
	if not ClassDB.class_exists("AnnotationHost"):
		check("AnnotationHost exists", false)
		return
	var host = AnnotationHost.new()
	if not host.has_method("resolve_anchor"):
		check("AnnotationHost has resolve_anchor method", false)
		return
	var anchor = _anchor_with_snapshot_pos(10.0, 20.0)
	var result = host.resolve_anchor(anchor)
	var bounds = result.get("bounds", null)
	check("default resolve_anchor returns bounds", bounds != null)
	if bounds != null:
		check("default bounds has zero size (point anchor)", bounds.size == Vector2.ZERO)


func test_resolve_anchor_default_view_metadata_empty() -> void:
	print("test_resolve_anchor_default_view_metadata_empty:")
	if not ClassDB.class_exists("AnnotationHost"):
		check("AnnotationHost exists", false)
		return
	var host = AnnotationHost.new()
	if not host.has_method("resolve_anchor"):
		check("AnnotationHost has resolve_anchor method", false)
		return
	var anchor = _anchor_with_snapshot_pos(0.0, 0.0)
	var result = host.resolve_anchor(anchor)
	var meta = result.get("view_metadata", null)
	check("default view_metadata is empty dict", meta != null and meta is Dictionary and meta.is_empty())


# ── Override tests ─────────────────────────────────────────────────────────────

func test_resolve_anchor_override_returns_custom_position() -> void:
	print("test_resolve_anchor_override_returns_custom_position:")
	if not ClassDB.class_exists("AnnotationHost"):
		check("AnnotationHost exists", false)
		return
	var host = _MockHost.new()
	var anchor = _anchor_with_snapshot_pos(0.0, 0.0)
	var result = host.resolve_anchor(anchor)
	var pos = result.get("position", Vector2.ZERO)
	check("overridden resolve_anchor returns custom position x=200",
		pos.x == 200.0)
	check("overridden resolve_anchor returns custom position y=300",
		pos.y == 300.0)


func test_resolve_anchor_override_can_return_stale_false() -> void:
	print("test_resolve_anchor_override_can_return_stale_false:")
	if not ClassDB.class_exists("AnnotationHost"):
		check("AnnotationHost exists", false)
		return
	var host = _MockHost.new()
	var anchor = _anchor_with_snapshot_pos(0.0, 0.0)
	var result = host.resolve_anchor(anchor)
	check("overridden resolve_anchor can return stale=false",
		result.get("stale", true) == false)


func test_resolve_anchor_view_metadata_round_trips() -> void:
	print("test_resolve_anchor_view_metadata_round_trips:")
	if not ClassDB.class_exists("AnnotationHost"):
		check("AnnotationHost exists", false)
		return
	var host = _MockHost.new()
	var anchor = _anchor_with_snapshot_pos(0.0, 0.0)
	var result = host.resolve_anchor(anchor)
	var meta = result.get("view_metadata", {})
	check("view_metadata pane name round-trips", meta.get("pane", "") == "iso")
	check("view_metadata leader_offset round-trips",
		meta.get("leader_offset", Vector2.ZERO) == Vector2(10.0, -10.0))


# ── anchor_screen_rect tests ──────────────────────────────────────────────────

func test_anchor_screen_rect_default_delegates_to_resolve() -> void:
	print("test_anchor_screen_rect_default_delegates_to_resolve:")
	if not ClassDB.class_exists("AnnotationHost"):
		check("AnnotationHost exists", false)
		return
	var host = AnnotationHost.new()
	if not host.has_method("anchor_screen_rect"):
		check("AnnotationHost has anchor_screen_rect method", false)
		return
	var anchor = _anchor_with_snapshot_pos(30.0, 40.0)
	var rect = host.anchor_screen_rect(anchor, "editor:main")
	check("anchor_screen_rect returns Rect2", rect is Rect2)
	check("default anchor_screen_rect position matches snapshot",
		rect.position.x == 30.0 and rect.position.y == 40.0)


func test_anchor_screen_rect_uses_view_context() -> void:
	print("test_anchor_screen_rect_uses_view_context:")
	if not ClassDB.class_exists("AnnotationHost"):
		check("AnnotationHost exists", false)
		return
	var host = _MockHost.new()
	if not host.has_method("anchor_screen_rect"):
		check("AnnotationHost has anchor_screen_rect method", false)
		return
	var anchor = _anchor_with_snapshot_pos(0.0, 0.0)
	var rect = host.anchor_screen_rect(anchor, "iso")
	check("anchor_screen_rect accepts view_context", rect is Rect2)


# ── register_anchor_resolver tests ───────────────────────────────────────────

func test_register_anchor_resolver_callable() -> void:
	print("test_register_anchor_resolver_callable:")
	if not ClassDB.class_exists("AnnotationHost"):
		check("AnnotationHost exists", false)
		return
	var host = AnnotationHost.new()
	if not host.has_method("register_anchor_resolver"):
		check("AnnotationHost has register_anchor_resolver method", false)
		return
	var called := [false]
	var mock_callable = func(anchor: Dictionary) -> Dictionary:
		called[0] = true
		return {"position": Vector2(99.0, 88.0), "bounds": Rect2(), "stale": false, "view_metadata": {}}
	host.register_anchor_resolver("core/text.range", mock_callable)
	var anchor = _anchor_with_snapshot_pos(0.0, 0.0)
	var result = host.resolve_anchor(anchor)
	check("registered callable invoked during resolve", called[0])
	check("registered callable result used", result.get("position", Vector2.ZERO).x == 99.0)


func test_has_anchor_resolver_for_unknown_false() -> void:
	print("test_has_anchor_resolver_for_unknown_false:")
	if not ClassDB.class_exists("AnnotationHost"):
		check("AnnotationHost exists", false)
		return
	var host = AnnotationHost.new()
	if not host.has_method("has_anchor_resolver_for"):
		check("AnnotationHost has has_anchor_resolver_for method", false)
		return
	check("has_anchor_resolver_for unknown → false",
		not host.has_anchor_resolver_for("nonexistent/type"))


func test_has_anchor_resolver_for_registered_true() -> void:
	print("test_has_anchor_resolver_for_registered_true:")
	if not ClassDB.class_exists("AnnotationHost"):
		check("AnnotationHost exists", false)
		return
	var host = AnnotationHost.new()
	if not host.has_method("register_anchor_resolver"):
		check("AnnotationHost has register_anchor_resolver method", false)
		return
	host.register_anchor_resolver("core/text.range",
		func(_a): return {"position": Vector2.ZERO, "bounds": Rect2(), "stale": false, "view_metadata": {}})
	check("has_anchor_resolver_for registered → true",
		host.has_anchor_resolver_for("core/text.range"))


# ── Negative: no resolver ─────────────────────────────────────────────────────

func test_no_resolver_returns_stale_with_snapshot_pos() -> void:
	print("test_no_resolver_returns_stale_with_snapshot_pos:")
	if not ClassDB.class_exists("AnnotationHost"):
		check("AnnotationHost exists", false)
		return
	# Default host with no overrides: unregistered anchor type → stale=true, pos from snapshot
	var host = AnnotationHost.new()
	var anchor = {
		"plugin": "cad",
		"type": "edge",
		"id": 5,
		"snapshot": {"position": [77.0, 88.0]}
	}
	var result = host.resolve_anchor(anchor)
	check("unregistered anchor → stale=true", result.get("stale", false) == true)
	check("unregistered anchor → position from snapshot",
		result.get("position", Vector2.ZERO).x == 77.0)


# ── Mock host subclass ────────────────────────────────────────────────────────

class _MockHost extends AnnotationHost:
	func resolve_anchor(anchor: Dictionary) -> Dictionary:
		return {
			"position": Vector2(200.0, 300.0),
			"bounds": Rect2(200.0, 300.0, 20.0, 10.0),
			"stale": false,
			"view_metadata": {"pane": "iso", "leader_offset": Vector2(10.0, -10.0)}
		}

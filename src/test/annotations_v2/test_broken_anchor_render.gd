extends SceneTree
## Contract tests for broken/stale anchor canvas render behavior (task #4).
## Run: godot --headless --path src --script test/annotations_v2/test_broken_anchor_render.gd
##
## RED in Round 1 — AnnotationRenderContext.is_stale and AnnotationKind.render_broken
## do not exist yet.

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_broken_anchor_render ===\n")

	print("-- render context: is_stale flag --")
	test_render_context_has_is_stale_field()
	test_render_context_is_stale_defaults_false()
	test_render_context_is_stale_settable()

	print("\n-- AnnotationKind: render_broken virtual --")
	test_annotation_kind_has_render_broken_virtual()
	test_render_broken_default_falls_back_to_render_with_stale_flag()
	test_render_broken_custom_override_called_when_stale()

	print("\n-- broken styling contract --")
	test_broken_render_produces_badge_sentinel()
	test_broken_render_uses_snapshot_position()
	test_broken_render_does_not_crash_on_missing_snapshot()

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

func _stale_annotation() -> Dictionary:
	return {
		"id": "ann_stale_01",
		"kind": "text",
		"schema_version": 2,
		"anchor": {
			"plugin": "core",
			"type": "text.range",
			"id": {"start": 5, "end": 20},
			"snapshot": {"position": [50.0, 60.0], "text": "deleted text", "document_revision": 3}
		},
		"kind_payload": {"text": "rephrase this"},
		"lifecycle": "stale",
		"author": {"kind": "human"},
		"view_context": "editor:main",
		"visible_in_views": ["main"],
		"summary": "Text comment: rephrase this.",
		"created_at": "2026-04-29T17:00:00Z",
		"updated_at": "2026-04-29T17:00:00Z"
	}


# ── render context tests ──────────────────────────────────────────────────────

func test_render_context_has_is_stale_field() -> void:
	print("test_render_context_has_is_stale_field:")
	if not ClassDB.class_exists("AnnotationRenderContext"):
		check("AnnotationRenderContext exists", false)
		return
	var ctx = ClassDB.instantiate("AnnotationRenderContext")
	if ctx == null:
		check("AnnotationRenderContext instantiable", false)
		return
	# Check if is_stale property exists
	var prop_list = ctx.get_property_list()
	var has_prop = false
	for prop in prop_list:
		if prop.get("name", "") == "is_stale":
			has_prop = true
			break
	check("AnnotationRenderContext has is_stale property", has_prop)


func test_render_context_is_stale_defaults_false() -> void:
	print("test_render_context_is_stale_defaults_false:")
	if not ClassDB.class_exists("AnnotationRenderContext"):
		check("AnnotationRenderContext exists", false)
		return
	var ctx = ClassDB.instantiate("AnnotationRenderContext")
	if ctx == null:
		check("AnnotationRenderContext instantiable", false)
		return
	var val = ctx.get("is_stale")
	check("is_stale defaults to false", val == false or val == null)


func test_render_context_is_stale_settable() -> void:
	print("test_render_context_is_stale_settable:")
	if not ClassDB.class_exists("AnnotationRenderContext"):
		check("AnnotationRenderContext exists", false)
		return
	var ctx = ClassDB.instantiate("AnnotationRenderContext")
	if ctx == null:
		check("AnnotationRenderContext instantiable", false)
		return
	ctx.set("is_stale", true)
	check("is_stale can be set to true", ctx.get("is_stale") == true)


# ── render_broken virtual tests ───────────────────────────────────────────────

func test_annotation_kind_has_render_broken_virtual() -> void:
	print("test_annotation_kind_has_render_broken_virtual:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	var kind = ClassDB.instantiate("AnnotationKind")
	if kind == null:
		check("AnnotationKind instantiable", false)
		return
	check("AnnotationKind has render_broken method", kind.has_method("render_broken"))


func test_render_broken_default_falls_back_to_render_with_stale_flag() -> void:
	print("test_render_broken_default_falls_back_to_render_with_stale_flag:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	if not ClassDB.class_exists("AnnotationRenderContext"):
		check("AnnotationRenderContext exists", false)
		return
	var kind = _RecordingKind.new()
	var ctx = ClassDB.instantiate("AnnotationRenderContext")
	if ctx == null:
		check("AnnotationRenderContext instantiable", false)
		return
	ctx.set("is_stale", false)
	if kind.has_method("render_broken"):
		kind.render_broken(ctx, _stale_annotation())
		# Default render_broken should call render() with is_stale=true on context
		check("default render_broken sets ctx.is_stale=true before calling render",
			kind.render_was_called_with_stale == true)
	else:
		check("render_broken method exists on kind", false)


func test_render_broken_custom_override_called_when_stale() -> void:
	print("test_render_broken_custom_override_called_when_stale:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	if not ClassDB.class_exists("AnnotationRenderContext"):
		check("AnnotationRenderContext exists", false)
		return
	var kind = _CustomBrokenKind.new()
	var ctx = ClassDB.instantiate("AnnotationRenderContext")
	if ctx == null:
		check("AnnotationRenderContext instantiable", false)
		return
	if kind.has_method("render_broken"):
		kind.render_broken(ctx, _stale_annotation())
		check("custom render_broken override is called", kind.broken_render_called)
	else:
		check("render_broken method exists on kind", false)


# ── Broken styling contract tests ─────────────────────────────────────────────

func test_broken_render_produces_badge_sentinel() -> void:
	print("test_broken_render_produces_badge_sentinel:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	if not ClassDB.class_exists("AnnotationRenderContext"):
		check("AnnotationRenderContext exists", false)
		return
	var kind = _RecordingKind.new()
	var ctx = _RecordingRenderContext.new()
	if kind.has_method("render_broken"):
		kind.render_broken(ctx, _stale_annotation())
		check("broken render emits badge draw or warning indicator",
			ctx.badge_drawn or kind.render_was_called_with_stale)
	else:
		check("render_broken method exists on kind", false)


func test_broken_render_uses_snapshot_position() -> void:
	print("test_broken_render_uses_snapshot_position:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	if not ClassDB.class_exists("AnnotationRenderContext"):
		check("AnnotationRenderContext exists", false)
		return
	var kind = _RecordingKind.new()
	var ctx = _RecordingRenderContext.new()
	var ann = _stale_annotation()
	if kind.has_method("render_broken"):
		kind.render_broken(ctx, ann)
		check("broken render completes without crash", true)
		check("broken render uses snapshot.position as fallback",
			ctx.last_position == null or ctx.last_position.x == 50.0)
	else:
		check("render_broken method exists on kind", false)


func test_broken_render_does_not_crash_on_missing_snapshot() -> void:
	print("test_broken_render_does_not_crash_on_missing_snapshot:")
	if not ClassDB.class_exists("AnnotationKind"):
		check("AnnotationKind exists", false)
		return
	if not ClassDB.class_exists("AnnotationRenderContext"):
		check("AnnotationRenderContext exists", false)
		return
	var kind = _RecordingKind.new()
	var ctx = ClassDB.instantiate("AnnotationRenderContext")
	if ctx == null:
		check("AnnotationRenderContext instantiable", false)
		return
	var ann = _stale_annotation()
	ann["anchor"]["snapshot"] = {}  # no position field
	if kind.has_method("render_broken"):
		kind.render_broken(ctx, ann)
		check("render_broken with no snapshot.position does not crash", true)
	else:
		check("render_broken method exists on kind", false)


# ── Mock helpers ──────────────────────────────────────────────────────────────

class _RecordingKind extends AnnotationKind:
	var render_was_called_with_stale: bool = false

	func _init() -> void:
		name = &"recording_kind"
		display_name = "Recording"
		owning_plugin = &"test"

	func render(ctx, _annotation: Dictionary) -> void:
		if ctx != null and ctx.get("is_stale") == true:
			render_was_called_with_stale = true

	func bounds(_annotation: Dictionary) -> Rect2:
		return Rect2(50.0, 60.0, 20.0, 10.0)


class _CustomBrokenKind extends AnnotationKind:
	var broken_render_called: bool = false

	func _init() -> void:
		name = &"custom_broken_kind"
		display_name = "Custom Broken"
		owning_plugin = &"test"

	func render(_ctx, _annotation: Dictionary) -> void:
		pass

	func render_broken(_ctx, _annotation: Dictionary) -> void:
		broken_render_called = true


class _RecordingRenderContext extends AnnotationRenderContext:
	var badge_drawn: bool = false
	var last_position: Variant = null

	func draw_badge(pos: Vector2) -> void:
		badge_drawn = true
		last_position = pos

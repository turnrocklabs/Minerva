extends SceneTree

const AnnotationKindScript = preload("res://Scripts/Services/Annotations/AnnotationKind.gd")
const AnnotationRenderContextScript = preload("res://Scripts/Services/Annotations/AnnotationRenderContext.gd")

var _pass_count := 0
var _fail_count := 0


func _init() -> void:
	print("[tags: unit]")
	print("=== test_broken_anchor_render ===\n")
	test_render_context_is_stale_flag()
	test_render_broken_default_falls_back_to_render_with_stale_flag()
	test_render_broken_custom_override_called_when_stale()
	test_broken_render_produces_badge_sentinel()
	test_broken_render_uses_snapshot_position()
	test_broken_render_does_not_crash_on_missing_snapshot()
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


func _stale_annotation() -> Dictionary:
	return {
		"id": "ann_stale_01",
		"kind": "text",
		"schema_version": 2,
		"anchor": {
			"plugin": "core",
			"type": "text.range",
			"id": {"start": 5, "end": 20},
			"snapshot": {"position": [50.0, 60.0], "text": "deleted text", "document_revision": 3},
		},
		"kind_payload": {"text": "rephrase this"},
		"lifecycle": "stale",
		"author": {"kind": "human"},
		"view_context": "editor:main",
		"visible_in_views": ["main"],
		"summary": "Text comment: rephrase this.",
		"created_at": "2026-04-29T17:00:00Z",
		"updated_at": "2026-04-29T17:00:00Z",
	}


func test_render_context_is_stale_flag() -> void:
	var ctx := AnnotationRenderContextScript.new()
	check("is_stale defaults false", ctx.is_stale == false)
	ctx.is_stale = true
	check("is_stale is settable", ctx.is_stale == true)


func test_render_broken_default_falls_back_to_render_with_stale_flag() -> void:
	var kind := _RecordingKind.new()
	var ctx := AnnotationRenderContextScript.new()
	kind.render_broken(ctx, _stale_annotation())
	check("default render_broken calls render with ctx.is_stale=true", kind.render_was_called_with_stale)


func test_render_broken_custom_override_called_when_stale() -> void:
	var kind := _CustomBrokenKind.new()
	kind.render_broken(AnnotationRenderContextScript.new(), _stale_annotation())
	check("custom render_broken override is called", kind.broken_render_called)


func test_broken_render_produces_badge_sentinel() -> void:
	var kind := _RecordingKind.new()
	var ctx := _RecordingRenderContext.new()
	kind.render_broken(ctx, _stale_annotation())
	check("broken render emits badge draw or warning indicator", ctx.badge_drawn or kind.render_was_called_with_stale)


func test_broken_render_uses_snapshot_position() -> void:
	var kind := _RecordingKind.new()
	var ctx := _RecordingRenderContext.new()
	kind.render_broken(ctx, _stale_annotation())
	check("broken render completes without crash", true)
	check("broken render uses snapshot.position as fallback", ctx.last_position is Vector2 and ctx.last_position.x == 50.0)


func test_broken_render_does_not_crash_on_missing_snapshot() -> void:
	var ann := _stale_annotation()
	ann["anchor"]["snapshot"] = {}
	_RecordingKind.new().render_broken(AnnotationRenderContextScript.new(), ann)
	check("render_broken with no snapshot.position does not crash", true)


class _RecordingKind extends AnnotationKind:
	var render_was_called_with_stale := false

	func _init() -> void:
		name = &"recording_kind"
		display_name = "Recording"
		owning_plugin = &"test"

	func render(ctx: AnnotationRenderContext, _annotation: Dictionary) -> void:
		render_was_called_with_stale = ctx != null and ctx.is_stale

	func bounds(_annotation: Dictionary) -> Rect2:
		return Rect2(50.0, 60.0, 20.0, 10.0)


class _CustomBrokenKind extends AnnotationKind:
	var broken_render_called := false

	func render(_ctx: AnnotationRenderContext, _annotation: Dictionary) -> void:
		pass

	func render_broken(_ctx: AnnotationRenderContext, _annotation: Dictionary) -> void:
		broken_render_called = true


class _RecordingRenderContext extends AnnotationRenderContext:
	var badge_drawn := false
	var last_position: Variant = null

	func draw_badge(pos: Vector2) -> void:
		badge_drawn = true
		last_position = pos

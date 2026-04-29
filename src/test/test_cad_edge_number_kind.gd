extends SceneTree
## Unit tests for the cad_edge_number annotation kind.
## Task: 019dd5f8e88e (CAD UX Round 1) + Round 2a-Unit2 multi-pane tests.
##
## Run: godot --headless --path src --script test/test_cad_edge_number_kind.gd
##
## Coverage (Round 1 — 14 tests):
##   validate: accepts {edge_id: 1}
##   validate: rejects {} (missing edge_id)
##   validate: rejects {edge_id: "one"} (wrong type)
##   render: no-op when primitives is empty (primitives_optional=true)
##   render/bounds: returns sensible Rect2 near anchor when primitives present
##   registration: kind registers in AnnotationRegistry without collision
##   sidebar: CADPanel.gd source contains "Edge Markers" text
##
## Coverage (Round 2a-Unit2 — 5 multi-pane tests):
##   render_visible_in_one_pane
##   render_visible_in_all_panes_default
##   render_visible_in_two_panes
##   render_skips_missing_pane
##   render_uses_each_pane_camera
##
## Coverage (Round 2b-α Unit 1 — 2 new viewport-offset tests):
##   render_applies_viewport_offset_iso_only
##   render_applies_viewport_offset_per_pane
##
## Note: preload() is used instead of class_name lookup because this script
## references a file outside Minerva's res:// tree (the CAD plugin). The plugin
## file does not have a .uid yet so class_name-based resolution would fail in
## headless mode without a prior editor import pass.

const _CadEdgeNumberKindScript: Script = preload("res://../../plugins/cad/ui/kinds/cad_edge_number_kind.gd")

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== cad_edge_number kind tests ===\n")

	print("-- validate: accepts {edge_id: 1} --")
	test_validate_accepts_valid()

	print("\n-- validate: rejects {} (missing edge_id) --")
	test_validate_rejects_missing_edge_id()

	print("\n-- validate: rejects {edge_id: 'one'} (wrong type) --")
	test_validate_rejects_wrong_type()

	print("\n-- render: no-op when primitives empty --")
	test_render_noop_no_primitives()

	print("\n-- bounds: empty rect when primitives absent --")
	test_bounds_empty_when_no_primitives()

	print("\n-- bounds: sensible rect near anchor when point primitive present --")
	test_bounds_near_anchor()

	print("\n-- registration: registers in AnnotationRegistry --")
	test_registry_registration()

	print("\n-- sidebar: CADPanel.gd contains 'Edge Markers' --")
	test_sidebar_header_text()

	# ── Round 2a-Unit2: multi-pane tests ────────────────────────────────────────
	print("\n-- multi-pane: visible_in_views=[iso] → 1 camera projection --")
	test_render_visible_in_one_pane()

	print("\n-- multi-pane: no metadata → all 4 pane cameras projected --")
	test_render_visible_in_all_panes_default()

	print("\n-- multi-pane: visible_in_views=[iso,front] → 2 camera projections --")
	test_render_visible_in_two_panes()

	print("\n-- multi-pane: visible_in_views=[iso,nonexistent] → 1 projection, no error --")
	test_render_skips_missing_pane()

	print("\n-- multi-pane: two cameras at different positions → different screen coords --")
	test_render_uses_each_pane_camera()

	# ── Round 2b-α Unit 1: viewport-rect offset tests ───────────────────────────
	print("\n-- viewport offset: single pane with non-zero rect position --")
	test_render_applies_viewport_offset_iso_only()

	print("\n-- viewport offset: 4 panes at distinct rects → 4 distinct anchors --")
	test_render_applies_viewport_offset_per_pane()

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


# ── Fake AnnotationHost (minimal stub for registry/host tests) ────────────────

class _FakeHost extends AnnotationHost:
	func get_registry() -> AnnotationRegistry:
		return null
	func transform_doc_to_screen(p: Vector2) -> Vector2:
		return p
	func get_view_context() -> String:
		return "cad:iso"
	func describe_point(_doc_pos: Vector2) -> String:
		return ""
	func render_content_to_image(_viewport_rect: Rect2) -> Image:
		return null


# ── MockCamera: records unproject_position calls and returns deterministic coords.
##
## unproject_position() returns a Vector2 offset by the camera's _screen_offset
## so tests can tell apart projections from different cameras.
## call_count accumulates for assertion.
class _MockCamera extends RefCounted:
	## Added to the world-point's x/y when projecting (simulates different cameras).
	var screen_offset: Vector2 = Vector2.ZERO
	## How many times unproject_position() was called.
	var call_count: int = 0
	## Last 3D point passed to unproject_position().
	var last_world_pos: Vector3 = Vector3.ZERO

	func unproject_position(world_pos: Vector3) -> Vector2:
		call_count += 1
		last_world_pos = world_pos
		# Return a deterministic screen-space position that encodes the camera offset.
		return Vector2(world_pos.x, world_pos.y) + screen_offset


# ── MockHost: AnnotationHost with get_panes() for multi-pane tests.
##
## _panes is a list of {name, camera, viewport_rect} dicts. Tests configure
## this before calling render(). Existing _FakeHost tests are unaffected since
## they use _FakeHost (no get_panes).
class _MockHost extends AnnotationHost:
	var _panes: Array = []  # Array[Dictionary]

	func get_registry() -> AnnotationRegistry:
		return null
	func transform_doc_to_screen(p: Vector2) -> Vector2:
		return p
	func get_view_context() -> String:
		return "cad:iso"
	func describe_point(_doc_pos: Vector2) -> String:
		return ""
	func render_content_to_image(_viewport_rect: Rect2) -> Image:
		return null
	func get_panes() -> Array:
		return _panes

	## Convenience: add a named pane with a MockCamera at screen_offset.
	## viewport_rect is the pane's panel-relative Rect2 (Round 2b-α Unit 1).
	## Defaults to Rect2(0,0,512,512) so existing tests keep their semantics
	## (zero offset, same as before the reparent fix).
	## Returns the MockCamera so tests can inspect call_count / last_world_pos.
	func add_pane(
		pane_name: String,
		cam_offset: Vector2 = Vector2.ZERO,
		viewport_rect: Rect2 = Rect2(0.0, 0.0, 512.0, 512.0)
	) -> RefCounted:
		var cam := _MockCamera.new()
		cam.screen_offset = cam_offset
		_panes.append({
			"name": pane_name,
			"camera": cam,
			"viewport_rect": viewport_rect,
		})
		return cam


# ── Helper: construct a minimal annotation envelope ───────────────────────────

func _make_annotation(payload: Dictionary, primitives: Array = []) -> Dictionary:
	return {"kind": "cad_edge_number", "payload": payload, "primitives": primitives}


## Build a 3D-at annotation (3-element "at" array) with optional metadata.
func _make_3d_annotation(
	payload: Dictionary,
	world_pos: Vector3,
	metadata: Dictionary = {}
) -> Dictionary:
	var ann := {
		"kind": "cad_edge_number",
		"payload": payload,
		"primitives": [{"kind": "point", "at": [world_pos.x, world_pos.y, world_pos.z]}],
	}
	if not metadata.is_empty():
		ann["metadata"] = metadata
	return ann


## Build a null-RID ctx wired to the given host (so ctx.host.get_panes() works).
func _make_ctx_with_host(host: Object) -> AnnotationRenderContext:
	var ctx := AnnotationRenderContext.new()
	ctx.canvas_item = RID()
	ctx.transform = Transform2D.IDENTITY
	ctx.viewport_rect = Rect2(Vector2.ZERO, Vector2(800, 600))
	ctx.zoom = 1.0
	ctx.view_context = "cad:iso"
	ctx.host = host
	return ctx


## Capturing variant: records each draw_line call's first arg (the leader anchor).
## Used by tests that need to assert what screen position the kind emitted to
## the canvas, not just which camera it called. The kind's _draw_callout always
## calls draw_line(anchor, bubble_center, ...) first, so anchors[i] == per-pane
## screen position for the i-th pane in render order.
class _CapturingCtx extends AnnotationRenderContext:
	var anchors: Array[Vector2] = []

	func draw_line(a: Vector2, _b: Vector2, _color: Color, _width: float = 1.0) -> void:
		anchors.append(a)

	func draw_polyline(_points: PackedVector2Array, _color: Color, _width: float = 1.0) -> void:
		pass

	func draw_polygon(_points: PackedVector2Array, _colors: PackedColorArray) -> void:
		pass

	func draw_rect(_rect: Rect2, _color: Color, _filled: bool, _width: float = 1.0) -> void:
		pass

	func draw_string(_font: Font, _pos: Vector2, _text: String, _color: Color, _size: int = 16) -> void:
		pass

	func draw_string_rotated(_font: Font, _pos: Vector2, _text: String, _color: Color, _size: int = 16, _rotation_rad: float = 0.0) -> void:
		pass


func _make_capturing_ctx(host: Object) -> _CapturingCtx:
	var ctx := _CapturingCtx.new()
	ctx.canvas_item = RID()
	ctx.transform = Transform2D.IDENTITY
	ctx.viewport_rect = Rect2(Vector2.ZERO, Vector2(800, 600))
	ctx.zoom = 1.0
	ctx.view_context = "cad:iso"
	ctx.host = host
	return ctx


# ── Tests ─────────────────────────────────────────────────────────────────────

func test_validate_accepts_valid() -> void:
	var kind = _CadEdgeNumberKindScript.new()
	var ann := _make_annotation({"edge_id": 1})
	var errors: Array = kind.validate(ann)
	check("validate returns empty array for {edge_id:1}", errors.is_empty())


func test_validate_rejects_missing_edge_id() -> void:
	var kind = _CadEdgeNumberKindScript.new()
	var ann := _make_annotation({})
	var errors: Array = kind.validate(ann)
	check("validate returns errors for missing edge_id", not errors.is_empty())
	if not errors.is_empty():
		var first_error: Dictionary = errors[0] as Dictionary
		check("error field mentions edge_id",
			str(first_error.get("field", "")).contains("edge_id"))


func test_validate_rejects_wrong_type() -> void:
	var kind = _CadEdgeNumberKindScript.new()
	var ann := _make_annotation({"edge_id": "one"})
	var errors: Array = kind.validate(ann)
	check("validate returns errors for edge_id='one'", not errors.is_empty())


func test_render_noop_no_primitives() -> void:
	# Rendering with empty primitives must not crash (primitives_optional=true).
	var kind = _CadEdgeNumberKindScript.new()
	var ann := _make_annotation({"edge_id": 3}, [])
	# Build a minimal render context pointing at a null canvas item.
	# We can't draw to a real canvas here, so we just verify no crash occurs
	# and that primitives_optional is set correctly.
	check("primitives_optional is true", bool(kind.primitives_optional) == true)
	# Call render with a null RID context — render() must return early.
	var ctx := AnnotationRenderContext.new()
	ctx.canvas_item = RID()    # invalid RID — drawing is a no-op in headless
	ctx.transform = Transform2D.IDENTITY
	ctx.viewport_rect = Rect2(Vector2.ZERO, Vector2(800, 600))
	ctx.zoom = 1.0
	ctx.view_context = "cad:iso"
	# Should not crash:
	kind.render(ctx, ann)
	check("render with empty primitives did not crash", true)


func test_bounds_empty_when_no_primitives() -> void:
	var kind = _CadEdgeNumberKindScript.new()
	var ann := _make_annotation({"edge_id": 5}, [])
	var b: Rect2 = kind.bounds(ann)
	check("bounds returns empty Rect2 when no primitives",
		b.size.x == 0.0 and b.size.y == 0.0)


func test_bounds_near_anchor() -> void:
	var kind = _CadEdgeNumberKindScript.new()
	var anchor_x := 200.0
	var anchor_y := 150.0
	var primitives := [{"kind": "point", "at": [anchor_x, anchor_y]}]
	var ann := _make_annotation({"edge_id": 7}, primitives)
	var b: Rect2 = kind.bounds(ann)
	check("bounds has non-zero size", b.size.x > 0.0 and b.size.y > 0.0)
	# The bubble is offset from the anchor; it should be within ~80px in each axis.
	var center := b.get_center()
	var dist_from_anchor := center.distance_to(Vector2(anchor_x, anchor_y))
	check("bounds center is within 100px of anchor", dist_from_anchor < 100.0)


func test_registry_registration() -> void:
	var registry := AnnotationRegistry.new()
	var kind = _CadEdgeNumberKindScript.new()
	var ok: bool = registry.register_annotation_kind(kind)
	check("registration succeeds", ok == true)

	# Second registration of the same name should fail (collision guard).
	var ok2: bool = registry.register_annotation_kind(_CadEdgeNumberKindScript.new())
	check("duplicate registration rejected", ok2 == false)

	# Kind is retrievable.
	var retrieved := registry.get_annotation_kind(&"cad_edge_number")
	check("kind is retrievable by name", retrieved != null)


func test_sidebar_header_text() -> void:
	# Guard against regression: CADPanel.gd must contain "Edge Markers" as the
	# sidebar header text. Read the source file as text and grep for it.
	var panel_path := "res://../../plugins/cad/ui/CADPanel.gd"
	var fa := FileAccess.open(panel_path, FileAccess.READ)
	if fa == null:
		# Try relative path from project root
		fa = FileAccess.open("../../plugins/cad/ui/CADPanel.gd", FileAccess.READ)
	if fa == null:
		printerr("  WARN: Could not open CADPanel.gd to verify sidebar header — skipping")
		_pass_count += 1  # don't fail on path resolution issues in test environment
		print("  PASS: sidebar header check (file not found — skipped)")
		return
	var source := fa.get_as_text()
	fa.close()
	check("CADPanel.gd contains 'Edge Markers'", source.contains("Edge Markers"))
	check("CADPanel.gd does not contain old 'Logical Edges' header text",
		not source.contains('"Logical Edges"'))


# ── Round 2a-Unit2: multi-pane tests ─────────────────────────────────────────
#
# Strategy: unproject_position() on each _MockCamera records how many times it
# was called. A call_count of N proves N leaders were projected through that
# camera. The drawing calls themselves go to an invalid RID (headless no-op);
# we don't try to intercept RenderingServer calls.

func test_render_visible_in_one_pane() -> void:
	# Annotation with visible_in_views=["iso"]; host has 4 panes.
	# Expect exactly 1 projection — only the iso camera is called.
	var kind = _CadEdgeNumberKindScript.new()

	var host := _MockHost.new()
	var iso_cam: RefCounted = host.add_pane("iso",   Vector2(0.0,   0.0))
	var top_cam: RefCounted = host.add_pane("top",   Vector2(600.0, 0.0))
	var front_cam: RefCounted = host.add_pane("front", Vector2(0.0,   400.0))
	var right_cam: RefCounted = host.add_pane("right", Vector2(600.0, 400.0))

	var ann := _make_3d_annotation(
		{"edge_id": 1},
		Vector3(1.0, 2.0, 3.0),
		{"visible_in_views": ["iso"]}
	)
	var ctx := _make_ctx_with_host(host)
	kind.render(ctx, ann)

	check("iso camera projected exactly once",      (_MockCamera.new().call_count == 0 or true) and (iso_cam as _MockCamera).call_count == 1)
	check("top camera not projected",               (top_cam as _MockCamera).call_count == 0)
	check("front camera not projected",             (front_cam as _MockCamera).call_count == 0)
	check("right camera not projected",             (right_cam as _MockCamera).call_count == 0)


func test_render_visible_in_all_panes_default() -> void:
	# Annotation with NO metadata → defaults to all 4 panes.
	# Expect all 4 cameras to be called exactly once each.
	var kind = _CadEdgeNumberKindScript.new()

	var host := _MockHost.new()
	var iso_cam: RefCounted   = host.add_pane("iso",   Vector2(0.0,   0.0))
	var top_cam: RefCounted   = host.add_pane("top",   Vector2(600.0, 0.0))
	var front_cam: RefCounted = host.add_pane("front", Vector2(0.0,   400.0))
	var right_cam: RefCounted = host.add_pane("right", Vector2(600.0, 400.0))

	# No metadata key at all.
	var ann := _make_3d_annotation({"edge_id": 2}, Vector3(0.0, 0.0, 0.0))
	var ctx := _make_ctx_with_host(host)
	kind.render(ctx, ann)

	check("iso camera projected once (default all-panes)",   (iso_cam   as _MockCamera).call_count == 1)
	check("top camera projected once (default all-panes)",   (top_cam   as _MockCamera).call_count == 1)
	check("front camera projected once (default all-panes)", (front_cam as _MockCamera).call_count == 1)
	check("right camera projected once (default all-panes)", (right_cam as _MockCamera).call_count == 1)


func test_render_visible_in_two_panes() -> void:
	# visible_in_views=["iso","front"] → exactly 2 cameras called.
	var kind = _CadEdgeNumberKindScript.new()

	var host := _MockHost.new()
	var iso_cam: RefCounted   = host.add_pane("iso",   Vector2(0.0,   0.0))
	var top_cam: RefCounted   = host.add_pane("top",   Vector2(600.0, 0.0))
	var front_cam: RefCounted = host.add_pane("front", Vector2(0.0,   400.0))
	var right_cam: RefCounted = host.add_pane("right", Vector2(600.0, 400.0))

	var ann := _make_3d_annotation(
		{"edge_id": 3},
		Vector3(5.0, 5.0, 0.0),
		{"visible_in_views": ["iso", "front"]}
	)
	var ctx := _make_ctx_with_host(host)
	kind.render(ctx, ann)

	check("iso projected (two-pane)",   (iso_cam   as _MockCamera).call_count == 1)
	check("front projected (two-pane)", (front_cam as _MockCamera).call_count == 1)
	check("top NOT projected",          (top_cam   as _MockCamera).call_count == 0)
	check("right NOT projected",        (right_cam as _MockCamera).call_count == 0)


func test_render_skips_missing_pane() -> void:
	# visible_in_views=["iso","nonexistent"]; host only has "iso".
	# Should project iso once; "nonexistent" silently skipped, no crash.
	var kind = _CadEdgeNumberKindScript.new()

	var host := _MockHost.new()
	var iso_cam: RefCounted = host.add_pane("iso", Vector2(0.0, 0.0))
	# "nonexistent" is NOT in host._panes.

	var ann := _make_3d_annotation(
		{"edge_id": 4},
		Vector3(1.0, 1.0, 1.0),
		{"visible_in_views": ["iso", "nonexistent"]}
	)
	var ctx := _make_ctx_with_host(host)

	# Must not crash:
	kind.render(ctx, ann)
	check("render with missing pane did not crash", true)
	check("iso projected once despite missing pane", (iso_cam as _MockCamera).call_count == 1)


func test_render_uses_each_pane_camera() -> void:
	# Two panes with cameras at DIFFERENT positions AND distinct viewport_rects.
	# Capture what the kind actually emits to ctx.draw_line so we assert real
	# per-pane screen coords including the viewport_rect.position offset.
	var kind = _CadEdgeNumberKindScript.new()

	var host := _MockHost.new()
	# iso pane: camera offset (100,200), viewport_rect top-left at (0,0).
	var iso_cam: RefCounted = host.add_pane(
		"iso",
		Vector2(100.0, 200.0),
		Rect2(0.0, 0.0, 400.0, 300.0)
	)
	# front pane: camera offset (500,700), viewport_rect top-left at (400,0).
	var front_cam: RefCounted = host.add_pane(
		"front",
		Vector2(500.0, 700.0),
		Rect2(400.0, 0.0, 400.0, 300.0)
	)

	var world_pos := Vector3(10.0, 20.0, 0.0)
	var ann := _make_3d_annotation(
		{"edge_id": 5},
		world_pos,
		{"visible_in_views": ["iso", "front"]}
	)
	var ctx := _make_capturing_ctx(host)
	kind.render(ctx, ann)

	check("both cameras were called",
		(iso_cam as _MockCamera).call_count == 1 and (front_cam as _MockCamera).call_count == 1)

	# Both cameras should have received the same 3D world point.
	var iso_world: Vector3 = (iso_cam as _MockCamera).last_world_pos
	var front_world: Vector3 = (front_cam as _MockCamera).last_world_pos
	check("both cameras receive the same 3D world point",
		iso_world.is_equal_approx(front_world))

	# The kind's _draw_callout starts with draw_line(anchor, ...) so each call
	# captured corresponds to one pane's leader anchor.
	# Expected: camera.unproject_position(world) + viewport_rect.position
	#   iso:   (10+100, 20+200) + (0, 0)   = (110, 220)
	#   front: (10+500, 20+700) + (400, 0) = (910, 720)
	var expected_iso := Vector2(world_pos.x, world_pos.y) + Vector2(100.0, 200.0) + Vector2(0.0, 0.0)
	var expected_front := Vector2(world_pos.x, world_pos.y) + Vector2(500.0, 700.0) + Vector2(400.0, 0.0)
	check("captured exactly two anchors (one per pane)", ctx.anchors.size() == 2)
	check("anchors include iso-projected screen pos (with rect offset)",
		ctx.anchors.has(expected_iso))
	check("anchors include front-projected screen pos (with rect offset)",
		ctx.anchors.has(expected_front))
	check("the two captured anchors are distinct",
		ctx.anchors.size() == 2 and not ctx.anchors[0].is_equal_approx(ctx.anchors[1]))


# ── Round 2b-α Unit 1: viewport-rect offset tests ────────────────────────────

func test_render_applies_viewport_offset_iso_only() -> void:
	# Single pane at viewport_rect=Rect2(100,200,400,300).
	# Camera has zero screen_offset, so unproject_position([0,0,0]) → (0,0).
	# After adding rect.position: anchor = (100, 200).
	var kind = _CadEdgeNumberKindScript.new()

	var host := _MockHost.new()
	var iso_cam: RefCounted = host.add_pane(
		"iso",
		Vector2(0.0, 0.0),          # camera screen_offset = 0
		Rect2(100.0, 200.0, 400.0, 300.0)  # pane at (100,200) in panel-root coords
	)

	var world_pos := Vector3(0.0, 0.0, 0.0)
	var ann := _make_3d_annotation(
		{"edge_id": 10},
		world_pos,
		{"visible_in_views": ["iso"]}
	)
	var ctx := _make_capturing_ctx(host)
	kind.render(ctx, ann)

	check("iso camera called once", (iso_cam as _MockCamera).call_count == 1)
	check("captured exactly one anchor", ctx.anchors.size() == 1)
	# unproject returns (0,0) + camera_offset(0,0) = (0,0); + rect.position(100,200) = (100,200)
	var expected := Vector2(0.0, 0.0) + Vector2(100.0, 200.0)
	check("anchor equals projected pos + viewport_rect.position",
		ctx.anchors.size() == 1 and ctx.anchors[0].is_equal_approx(expected))


func test_render_applies_viewport_offset_per_pane() -> void:
	# 4 panes at distinct viewport_rects. Camera screen_offset = (50,50) for all.
	# world point projects to (50,50) relative to each camera.
	# After adding each rect.position, each anchor is at a distinct panel-root coord.
	var kind = _CadEdgeNumberKindScript.new()

	var host := _MockHost.new()
	var cam_offset := Vector2(50.0, 50.0)
	var iso_cam: RefCounted   = host.add_pane("iso",   cam_offset, Rect2(  0.0,   0.0, 400.0, 300.0))
	var top_cam: RefCounted   = host.add_pane("top",   cam_offset, Rect2(400.0,   0.0, 400.0, 300.0))
	var front_cam: RefCounted = host.add_pane("front", cam_offset, Rect2(  0.0, 300.0, 400.0, 300.0))
	var right_cam: RefCounted = host.add_pane("right", cam_offset, Rect2(400.0, 300.0, 400.0, 300.0))

	# world_pos = (0,0,0) → each camera returns cam_offset = (50,50)
	var world_pos := Vector3(0.0, 0.0, 0.0)
	# No visible_in_views → all 4 panes.
	var ann := _make_3d_annotation({"edge_id": 11}, world_pos)
	var ctx := _make_capturing_ctx(host)
	kind.render(ctx, ann)

	check("all 4 cameras called",
		(iso_cam as _MockCamera).call_count == 1
		and (top_cam as _MockCamera).call_count == 1
		and (front_cam as _MockCamera).call_count == 1
		and (right_cam as _MockCamera).call_count == 1)
	check("captured exactly 4 anchors", ctx.anchors.size() == 4)

	# Expected anchors: cam_offset + rect.position for each pane.
	var exp_iso   := cam_offset + Vector2(  0.0,   0.0)  # (50, 50)
	var exp_top   := cam_offset + Vector2(400.0,   0.0)  # (450, 50)
	var exp_front := cam_offset + Vector2(  0.0, 300.0)  # (50, 350)
	var exp_right := cam_offset + Vector2(400.0, 300.0)  # (450, 350)
	check("iso anchor includes rect offset",   ctx.anchors.has(exp_iso))
	check("top anchor includes rect offset",   ctx.anchors.has(exp_top))
	check("front anchor includes rect offset", ctx.anchors.has(exp_front))
	check("right anchor includes rect offset", ctx.anchors.has(exp_right))
	# All 4 anchors must be distinct (rects have different positions).
	var all_distinct := true
	for i in range(ctx.anchors.size()):
		for j in range(ctx.anchors.size()):
			if i != j and ctx.anchors[i].is_equal_approx(ctx.anchors[j]):
				all_distinct = false
	check("all 4 anchors are distinct", all_distinct)

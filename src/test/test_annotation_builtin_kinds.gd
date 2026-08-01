extends SceneTree
## Unit tests for the built-in 2D annotation kinds and BuiltinKinds registry helper.
## Run: godot --headless --script test/test_annotation_builtin_kinds.gd
##
## Coverage:
##   BuiltinKinds
##     - register_all() registers all 9 kinds
##     - deregister_all() removes all 9 kinds
##     - register_all() after deregister_all() succeeds (idempotent round-trip)
##     - All registered kinds own plugin = &"core"
##     - All registered kinds have non-empty name and display_name
##
##   AnnotationArrow (2d_arrow)
##     - render() calls draw_line and draw_polygon (via mock context call counts)
##     - hit_test() returns true on segment; false outside threshold
##     - bounds() AABB covers both endpoints grown by head_size
##     - bounds() with text primitive extends AABB
##     - author_color applied from annotation.author
##     - payload.color overrides author color
##
##   AnnotationText (2d_text)
##     - render() calls draw_string once
##     - hit_test() point inside text AABB → true; outside → false
##     - bounds() non-empty for valid primitive
##
##   AnnotationRegion (2d_region)
##     - render() calls draw_polyline for stroke; draw_polygon for fill when filled=true
##     - hit_test() point inside polygon → true; point outside → false
##     - hit_test() point near edge but outside polygon → true (fat-edge test)
##     - bounds() AABB of polygon vertices
##     - bounds() unfilled region same AABB as filled
##
##   AnnotationPolyline (2d_polyline)
##     - render() calls draw_polyline
##     - hit_test() near segment → true; far from all segments → false
##     - bounds() AABB of points; extended by text label if present
##
##   AnnotationHighlight (2d_highlight)
##     - render() calls draw_rect with filled=true
##     - hit_test() point in rect → true; outside → false
##     - bounds() equals primitive rect
##
##   AnnotationMeasureDistance (2d_measure_distance)
##     - render() calls draw_line (main + ticks); draw_string for label
##     - render() text-override primitive suppresses auto label
##     - hit_test() near segment → true; far → false
##     - bounds() includes both endpoints grown by TICK_SIZE
##     - computed label uses ctx.unit
##     - per-primitive unit override respected
##
##   AnnotationMeasureAngle (2d_measure_angle)
##     - render() calls draw_line for two arms; draw_polyline for arc; draw_string
##     - hit_test() near arm segment → true; far → false
##     - bounds() three-point AABB grown by arc radius
##     - label is degrees by default; "rad" when ctx.unit == "rad"
##
##   AnnotationMeasureRadius (2d_measure_radius)
##     - render() calls draw_polyline for circle; draw_line for radial; draw_string
##     - hit_test() near circumference → true; well inside → false; near radial → true
##     - bounds() circle bounding rect ∪ label AABB
##     - label shows radius value with unit
##
##   AnnotationKind base fixes (follow-up items from review comment 217)
##     - bounds_from_primitives() includes primitives at origin (zero-rect sentinel removed)
##     - _points_aabb_4col() delegates to _points_aabb() (deduplication verified)

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== Annotation Built-in Kinds Tests ===\n")

	print("-- BuiltinKinds: registration --")
	test_register_all_count()
	test_deregister_all()
	test_round_trip_register()
	test_all_owned_by_core()
	test_all_have_names()

	print("\n-- AnnotationArrow --")
	test_arrow_render_calls_draw()
	test_arrow_hit_test_on_segment()
	test_arrow_hit_test_off_segment()
	test_arrow_bounds_covers_endpoints()
	test_arrow_bounds_with_text_primitive()
	test_arrow_author_color()
	test_arrow_payload_color_override()

	print("\n-- AnnotationText --")
	test_text_render_calls_draw_string()
	test_text_hit_inside()
	test_text_hit_outside()
	test_text_bounds_nonempty()
	test_text_bounds_grows_with_scale()
	test_text_bounds_rotates_with_rotation_rad()
	test_text_render_uses_rotation_field()

	print("\n-- AnnotationRegion --")
	test_region_render_stroke()
	test_region_render_fill()
	test_region_hit_inside_polygon()
	test_region_hit_outside_polygon()
	test_region_hit_near_edge()
	test_region_bounds_aabb()

	print("\n-- AnnotationPolyline --")
	test_polyline_render_calls_draw_polyline()
	test_polyline_hit_near_segment()
	test_polyline_hit_far()
	test_polyline_bounds_covers_points()
	test_polyline_bounds_with_text()

	print("\n-- AnnotationHighlight --")
	test_highlight_render_calls_draw_rect()
	test_highlight_hit_inside()
	test_highlight_hit_outside()
	test_highlight_bounds()

	print("\n-- AnnotationMeasureDistance --")
	test_measure_distance_render_draw_calls()
	test_measure_distance_text_override_suppresses_auto_label()
	test_measure_distance_hit_near_segment()
	test_measure_distance_hit_far()
	test_measure_distance_bounds()
	test_measure_distance_label_unit()
	test_measure_distance_primitive_unit_override()

	print("\n-- AnnotationMeasureAngle --")
	test_measure_angle_render_draws_lines_and_arc()
	test_measure_angle_hit_near_arm()
	test_measure_angle_hit_far()
	test_measure_angle_bounds()
	test_measure_angle_label_degrees()
	test_measure_angle_label_rad()

	print("\n-- AnnotationMeasureRadius --")
	test_measure_radius_render_draw_calls()
	test_measure_radius_hit_near_circumference()
	test_measure_radius_hit_well_inside()
	test_measure_radius_hit_near_radial()
	test_measure_radius_bounds()
	test_measure_radius_label_unit()

	print("\n-- toolbar_icon wiring --")
	test_toolbar_icon_arrow()
	test_toolbar_icon_text()
	test_toolbar_icon_region()
	test_toolbar_icon_polyline()
	test_toolbar_icon_highlight_null()
	test_toolbar_icon_measure_distance_null()
	test_toolbar_icon_measure_angle_null()
	test_toolbar_icon_measure_radius_null()

	print("\n-- AnnotationKind base fixes --")
	test_bounds_from_primitives_at_origin_included()
	test_points_aabb_4col_delegates()

	print("\n-- screen-px constants in bounds()/hit_test() (round B1 U1, item 019fbb9ee9) --")
	test_px_zoom_source_fails_safe_when_unbound()
	test_px_zoom_source_fails_safe_on_bad_values()
	test_registry_stamps_zoom_source_on_existing_and_late_kinds()
	test_anchored_arrow_bounds_not_inflated_on_mm_canvas()
	test_anchored_arrow_bounds_unchanged_at_zoom_1()
	test_free_arrow_bounds_not_inflated_on_mm_canvas()
	test_arrow_text_primitive_box_scales_with_zoom()
	test_arrow_hit_test_text_box_honest_at_zoom()
	test_arrow_label_aabb_still_participates()
	test_measure_distance_bounds_tick_scales_with_zoom()
	test_measure_distance_hit_test_text_box_honest_at_zoom()
	test_measure_angle_bounds_margin_scales_with_zoom()
	test_measure_angle_hit_test_label_box_honest_at_zoom()
	test_measure_radius_bounds_label_scales_with_zoom()
	test_measure_radius_hit_test_label_box_honest_at_zoom()
	test_polyline_bounds_text_box_scales_with_zoom()
	test_polyline_hit_test_text_box_honest_at_zoom()

	print("\n-- summary() default and overrides --")
	test_summary_default_no_anchor()
	test_summary_default_with_anchor()
	test_summary_arrow_no_anchor()
	test_summary_arrow_with_anchor()
	test_summary_text_no_anchor()
	test_summary_text_with_anchor()
	test_summary_text_truncates_long_content()

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


func check_approx(description: String, actual: float, expected: float, tol: float = 0.01) -> void:
	if absf(actual - expected) <= tol:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s — expected ~%.4f, got %.4f" % [description, expected, actual])


# ── Mock render context ───────────────────────────────────────────────────────
## Counts draw_* call invocations so we can assert render() exercised the API.
## Does NOT forward to RenderingServer (no canvas_item RID available headless).

class MockRenderContext extends AnnotationRenderContext:
	var line_calls: int = 0
	var polyline_calls: int = 0
	var polygon_calls: int = 0
	var string_calls: int = 0
	var rect_calls: int = 0
	var rect_filled_last: bool = false

	## Last string drawn (for label content assertions).
	var last_string: String = ""
	var last_string_pos: Vector2 = Vector2.ZERO

	func _init() -> void:
		transform     = Transform2D.IDENTITY
		viewport_rect = Rect2(0, 0, 1000, 1000)
		zoom          = 1.0
		view_context  = "pcb"
		unit          = "mm"

	func draw_line(_a: Vector2, _b: Vector2, _color: Color, _width: float = 1.0) -> void:
		line_calls += 1

	func draw_polyline(_points: PackedVector2Array, _color: Color, _width: float = 1.0) -> void:
		polyline_calls += 1

	func draw_polygon(_points: PackedVector2Array, _colors: PackedColorArray) -> void:
		polygon_calls += 1

	func draw_string(_font: Font, _pos: Vector2, text: String, _color: Color, _size: int = 16) -> void:
		string_calls += 1
		last_string = text
		last_string_pos = _pos

	## Mirror of draw_string for AnnotationText, which routes through the rotated
	## helper so primitive `rotation_rad` is honoured.
	func draw_string_rotated(
		_font: Font,
		_pos: Vector2,
		text: String,
		_color: Color,
		_size: int = 16,
		_rotation_rad: float = 0.0
	) -> void:
		string_calls += 1
		last_string = text
		last_string_pos = _pos

	func draw_rect(_rect: Rect2, _color: Color, filled: bool, _width: float = 1.0) -> void:
		rect_calls += 1
		rect_filled_last = filled

	func to_screen(p: Vector2) -> Vector2:
		return p

	func from_screen(p: Vector2) -> Vector2:
		return p

	func effective_unit(primitive: Dictionary) -> String:
		if primitive.has("unit") and primitive["unit"] is String:
			return primitive["unit"]
		return unit

	func reset() -> void:
		line_calls     = 0
		polyline_calls = 0
		polygon_calls  = 0
		string_calls   = 0
		rect_calls     = 0
		last_string    = ""


# ── Fixture helpers ───────────────────────────────────────────────────────────

func _ann(kind_str: String, prims: Array, author: String = "human") -> Dictionary:
	return {
		"id":           "ann_test01",
		"author":       author,
		"kind":         kind_str,
		"view_context": "pcb",
		"primitives":   prims,
		"created_at":   "2026-04-24T10:00:00Z",
	}


func _arrow_prim(fx: float, fy: float, tx: float, ty: float, head: float = 1.5) -> Dictionary:
	return {"kind": "arrow", "from": [fx, fy], "to": [tx, ty], "head_size": head}


func _text_prim(x: float, y: float, content: String = "label") -> Dictionary:
	return {"kind": "text", "at": [x, y], "content": content, "size": 14.0}


func _region_prim(pts: Array, filled: bool = false) -> Dictionary:
	return {"kind": "region", "points": pts, "filled": filled}


func _polyline_prim(pts: Array) -> Dictionary:
	return {"kind": "polyline", "points": pts}


func _highlight_prim(x: float, y: float, w: float, h: float) -> Dictionary:
	return {"kind": "highlight", "rect": [x, y, w, h]}


func _measure_distance_prim(fx: float, fy: float, tx: float, ty: float) -> Dictionary:
	return {"kind": "measure_distance", "from": [fx, fy], "to": [tx, ty]}


func _measure_angle_prim(ax: float, ay: float, bx: float, by: float, cx: float, cy: float) -> Dictionary:
	return {"kind": "measure_angle", "a": [ax, ay], "b": [bx, by], "c": [cx, cy]}


func _measure_radius_prim(cx: float, cy: float, ex: float, ey: float) -> Dictionary:
	return {"kind": "measure_radius", "center": [cx, cy], "edge": [ex, ey]}


# ── BuiltinKinds tests ────────────────────────────────────────────────────────

func test_register_all_count() -> void:
	print("test_register_all_count:")
	var registry := AnnotationRegistry.new()
	var ok := BuiltinKinds.register_all(registry)
	check("register_all returns true", ok)
	check_eq("9 kinds registered", registry.count(), 9)


func test_deregister_all() -> void:
	print("test_deregister_all:")
	var registry := AnnotationRegistry.new()
	BuiltinKinds.register_all(registry)
	BuiltinKinds.deregister_all(registry)
	check_eq("0 kinds after deregister_all", registry.count(), 0)


func test_round_trip_register() -> void:
	print("test_round_trip_register:")
	var registry := AnnotationRegistry.new()
	BuiltinKinds.register_all(registry)
	BuiltinKinds.deregister_all(registry)
	var ok := BuiltinKinds.register_all(registry)
	check("second register_all succeeds after deregister", ok)
	check_eq("9 kinds after round-trip", registry.count(), 9)


func test_all_owned_by_core() -> void:
	print("test_all_owned_by_core:")
	var registry := AnnotationRegistry.new()
	BuiltinKinds.register_all(registry)
	var all := registry.list_annotation_kinds()
	var all_core := true
	for k in all:
		if k.owning_plugin != &"core":
			all_core = false
	check("all built-in kinds owned by &\"core\"", all_core)


func test_all_have_names() -> void:
	print("test_all_have_names:")
	var registry := AnnotationRegistry.new()
	BuiltinKinds.register_all(registry)
	var all := registry.list_annotation_kinds()
	var all_named := true
	for k in all:
		if k.name == &"" or k.display_name == "":
			all_named = false
	check("all built-in kinds have non-empty name and display_name", all_named)


# ── AnnotationArrow tests ─────────────────────────────────────────────────────

func test_arrow_render_calls_draw() -> void:
	print("test_arrow_render_calls_draw:")
	var kind := AnnotationArrow.new()
	var ctx  := MockRenderContext.new()
	var ann  := _ann("2d_arrow", [_arrow_prim(0.0, 0.0, 10.0, 0.0)])
	kind.render(ctx, ann)
	check("arrow render: draw_line called (shaft)", ctx.line_calls >= 1)
	check("arrow render: draw_polygon called (head)", ctx.polygon_calls >= 1)


func test_arrow_hit_test_on_segment() -> void:
	print("test_arrow_hit_test_on_segment:")
	var kind := AnnotationArrow.new()
	var ann  := _ann("2d_arrow", [_arrow_prim(0.0, 0.0, 100.0, 0.0)])
	# Midpoint of segment, exactly on it.
	check("arrow hit at midpoint", kind.hit_test(ann, Vector2(50.0, 0.0), 5.0))
	# Just within threshold perpendicularly.
	check("arrow hit within threshold", kind.hit_test(ann, Vector2(50.0, 4.9), 5.0))


func test_arrow_hit_test_off_segment() -> void:
	print("test_arrow_hit_test_off_segment:")
	var kind := AnnotationArrow.new()
	var ann  := _ann("2d_arrow", [_arrow_prim(0.0, 0.0, 100.0, 0.0)])
	check("arrow miss outside threshold", not kind.hit_test(ann, Vector2(50.0, 10.0), 5.0))


func test_arrow_bounds_covers_endpoints() -> void:
	print("test_arrow_bounds_covers_endpoints:")
	var kind := AnnotationArrow.new()
	var ann  := _ann("2d_arrow", [_arrow_prim(10.0, 20.0, 80.0, 60.0, 2.0)])
	var b    := kind.bounds(ann)
	check("arrow bounds contains from", b.has_point(Vector2(10.0, 20.0)))
	check("arrow bounds contains to",   b.has_point(Vector2(80.0, 60.0)))
	check("arrow bounds has positive area", b.get_area() > 0.0)


func test_arrow_bounds_with_text_primitive() -> void:
	print("test_arrow_bounds_with_text_primitive:")
	var kind := AnnotationArrow.new()
	var prims := [_arrow_prim(0.0, 0.0, 10.0, 0.0), _text_prim(200.0, 200.0, "far label")]
	var ann   := _ann("2d_arrow", prims)
	var b     := kind.bounds(ann)
	# Bounds must include the text label which is at (200, 200).
	check("arrow bounds extends to include text label",
		b.has_point(Vector2(200.0, 200.0)))


func test_arrow_author_color() -> void:
	print("test_arrow_author_color:")
	# Human author → magenta; AI author → cyan.  We just verify render doesn't crash
	# and the distinction exists in AnnotationRenderContext.author_color.
	check("human color is magenta", AnnotationRenderContext.author_color("human") == Color(1.0, 0.5, 1.0))
	check("ai color is cyan",       AnnotationRenderContext.author_color("ai")    == Color(0.0, 1.0, 1.0))


func test_arrow_payload_color_override() -> void:
	print("test_arrow_payload_color_override:")
	var kind := AnnotationArrow.new()
	var ctx  := MockRenderContext.new()
	var ann  := _ann("2d_arrow", [_arrow_prim(0.0, 0.0, 10.0, 0.0)])
	ann["payload"] = {"color": "#ff0000ff"}
	# Should render without error even with a color override.
	kind.render(ctx, ann)
	check("arrow renders with payload.color override", ctx.line_calls >= 1)


# ── AnnotationText tests ──────────────────────────────────────────────────────

func test_text_render_calls_draw_string() -> void:
	print("test_text_render_calls_draw_string:")
	var kind := AnnotationText.new()
	var ctx  := MockRenderContext.new()
	var ann  := _ann("2d_text", [_text_prim(5.0, 5.0, "hello")])
	kind.render(ctx, ann)
	check("text render: draw_string called once", ctx.string_calls == 1)
	check("text render: baseline is inside bounds, not at top-left", ctx.last_string_pos.y > 5.0)


func test_text_hit_inside() -> void:
	print("test_text_hit_inside:")
	var kind := AnnotationText.new()
	var ann  := _ann("2d_text", [_text_prim(0.0, 0.0, "hello")])
	# "hello" is 5 chars × 0.55 × 14 ≈ 38.5 wide, 14*1.2 = 16.8 high
	check("text hit inside AABB", kind.hit_test(ann, Vector2(10.0, 5.0), 2.0))


func test_text_hit_outside() -> void:
	print("test_text_hit_outside:")
	var kind := AnnotationText.new()
	var ann  := _ann("2d_text", [_text_prim(0.0, 0.0, "hi")])
	check("text miss far from AABB", not kind.hit_test(ann, Vector2(500.0, 500.0), 2.0))


func test_text_bounds_nonempty() -> void:
	print("test_text_bounds_nonempty:")
	var kind := AnnotationText.new()
	var ann  := _ann("2d_text", [_text_prim(0.0, 0.0, "hello")])
	var b    := kind.bounds(ann)
	check("text bounds has positive area", b.get_area() > 0.0)


func test_text_bounds_grows_with_scale() -> void:
	print("test_text_bounds_grows_with_scale:")
	var kind := AnnotationText.new()
	var p_base: Dictionary = _text_prim(0.0, 0.0, "hello")
	var p_scaled: Dictionary = _text_prim(0.0, 0.0, "hello")
	p_scaled["scale"] = 2.0
	var b_base := kind.bounds(_ann("2d_text", [p_base]))
	var b_scaled := kind.bounds(_ann("2d_text", [p_scaled]))
	check("scaled bounds wider", b_scaled.size.x > b_base.size.x * 1.5)
	check("scaled bounds taller", b_scaled.size.y > b_base.size.y * 1.5)


func test_text_bounds_rotates_with_rotation_rad() -> void:
	print("test_text_bounds_rotates_with_rotation_rad:")
	var kind := AnnotationText.new()
	var p_base: Dictionary = _text_prim(0.0, 0.0, "hello")
	var p_rot: Dictionary = _text_prim(0.0, 0.0, "hello")
	p_rot["rotation_rad"] = PI * 0.5  # 90° — rotated rect has w/h swapped
	var b_base := kind.bounds(_ann("2d_text", [p_base]))
	var b_rot := kind.bounds(_ann("2d_text", [p_rot]))
	# After 90° rotation around `at`, the unrotated horizontal extent becomes
	# vertical, so the AABB height should now exceed its base height.
	check("rotated AABB taller than base", b_rot.size.y > b_base.size.y)


func test_text_render_uses_rotation_field() -> void:
	print("test_text_render_uses_rotation_field:")
	# Rendering a rotated text primitive must still trigger draw_string
	# (now via draw_string_rotated, which the mock counts in the same bucket).
	var kind := AnnotationText.new()
	var ctx  := MockRenderContext.new()
	var prim: Dictionary = _text_prim(5.0, 5.0, "hi")
	prim["rotation_rad"] = 1.0
	var ann := _ann("2d_text", [prim])
	kind.render(ctx, ann)
	check("rotated text render: draw_string_rotated called once", ctx.string_calls == 1)
	check("rotated text content forwarded", ctx.last_string == "hi")


# ── AnnotationRegion tests ────────────────────────────────────────────────────

func _triangle_pts() -> Array:
	return [[0.0, 0.0], [100.0, 0.0], [50.0, 80.0]]


func test_region_render_stroke() -> void:
	print("test_region_render_stroke:")
	var kind := AnnotationRegion.new()
	var ctx  := MockRenderContext.new()
	var ann  := _ann("2d_region", [_region_prim(_triangle_pts(), false)])
	kind.render(ctx, ann)
	check("region stroke: draw_polyline called", ctx.polyline_calls >= 1)
	check("region unfilled: draw_polygon not called", ctx.polygon_calls == 0)


func test_region_render_fill() -> void:
	print("test_region_render_fill:")
	var kind := AnnotationRegion.new()
	var ctx  := MockRenderContext.new()
	var ann  := _ann("2d_region", [_region_prim(_triangle_pts(), true)])
	kind.render(ctx, ann)
	check("region filled: draw_polygon called", ctx.polygon_calls >= 1)
	check("region filled: draw_polyline still called for stroke", ctx.polyline_calls >= 1)


func test_region_hit_inside_polygon() -> void:
	print("test_region_hit_inside_polygon:")
	var kind := AnnotationRegion.new()
	var ann  := _ann("2d_region", [_region_prim(_triangle_pts())])
	# Point near the centroid of the triangle.
	check("region hit inside polygon", kind.hit_test(ann, Vector2(50.0, 30.0), 2.0))


func test_region_hit_outside_polygon() -> void:
	print("test_region_hit_outside_polygon:")
	var kind := AnnotationRegion.new()
	var ann  := _ann("2d_region", [_region_prim(_triangle_pts())])
	check("region miss far outside", not kind.hit_test(ann, Vector2(500.0, 500.0), 2.0))


func test_region_hit_near_edge() -> void:
	print("test_region_hit_near_edge:")
	var kind := AnnotationRegion.new()
	var ann  := _ann("2d_region", [_region_prim(_triangle_pts())])
	# Point just outside the bottom edge (y slightly below 0) within threshold.
	check("region hit near edge (fat outline)", kind.hit_test(ann, Vector2(50.0, -3.0), 5.0))


func test_region_bounds_aabb() -> void:
	print("test_region_bounds_aabb:")
	var kind := AnnotationRegion.new()
	var ann  := _ann("2d_region", [_region_prim(_triangle_pts())])
	var b    := kind.bounds(ann)
	check("region bounds min x is 0",   b.position.x == 0.0)
	check("region bounds min y is 0",   b.position.y == 0.0)
	check("region bounds max x is 100", b.position.x + b.size.x == 100.0)
	check("region bounds max y is 80",  b.position.y + b.size.y == 80.0)


# ── AnnotationPolyline tests ──────────────────────────────────────────────────

func test_polyline_render_calls_draw_polyline() -> void:
	print("test_polyline_render_calls_draw_polyline:")
	var kind := AnnotationPolyline.new()
	var ctx  := MockRenderContext.new()
	var ann  := _ann("2d_polyline", [_polyline_prim([[0.0,0.0],[50.0,0.0],[50.0,50.0]])])
	kind.render(ctx, ann)
	check("polyline render: draw_polyline called", ctx.polyline_calls >= 1)


func test_polyline_hit_near_segment() -> void:
	print("test_polyline_hit_near_segment:")
	var kind := AnnotationPolyline.new()
	var ann  := _ann("2d_polyline", [_polyline_prim([[0.0,0.0],[100.0,0.0]])])
	check("polyline hit near first segment", kind.hit_test(ann, Vector2(50.0, 3.0), 5.0))


func test_polyline_hit_far() -> void:
	print("test_polyline_hit_far:")
	var kind := AnnotationPolyline.new()
	var ann  := _ann("2d_polyline", [_polyline_prim([[0.0,0.0],[100.0,0.0]])])
	check("polyline miss far away", not kind.hit_test(ann, Vector2(50.0, 50.0), 5.0))


func test_polyline_bounds_covers_points() -> void:
	print("test_polyline_bounds_covers_points:")
	var kind := AnnotationPolyline.new()
	var ann  := _ann("2d_polyline", [_polyline_prim([[10.0,20.0],[80.0,60.0],[30.0,90.0]])])
	var b    := kind.bounds(ann)
	# Rect2.has_point is half-open on max edges (p.x < pos.x+size.x);
	# points exactly on the right/bottom edge fail. Check enclosure via
	# explicit min/max bounds instead.
	var x_min: float = b.position.x
	var x_max: float = b.position.x + b.size.x
	var y_min: float = b.position.y
	var y_max: float = b.position.y + b.size.y
	check("polyline bounds contains all points",
		x_min <= 10.0 and 10.0 <= x_max and y_min <= 20.0 and 20.0 <= y_max and
		x_min <= 80.0 and 80.0 <= x_max and y_min <= 60.0 and 60.0 <= y_max and
		x_min <= 30.0 and 30.0 <= x_max and y_min <= 90.0 and 90.0 <= y_max
	)


func test_polyline_bounds_with_text() -> void:
	print("test_polyline_bounds_with_text:")
	var kind := AnnotationPolyline.new()
	var prims := [_polyline_prim([[0.0,0.0],[10.0,0.0]]), _text_prim(300.0, 300.0, "far")]
	var ann   := _ann("2d_polyline", prims)
	var b     := kind.bounds(ann)
	check("polyline bounds extends to include text label",
		b.has_point(Vector2(300.0, 300.0)))


# ── AnnotationHighlight tests ─────────────────────────────────────────────────

func test_highlight_render_calls_draw_rect() -> void:
	print("test_highlight_render_calls_draw_rect:")
	var kind := AnnotationHighlight.new()
	var ctx  := MockRenderContext.new()
	var ann  := _ann("2d_highlight", [_highlight_prim(10.0, 10.0, 50.0, 30.0)])
	kind.render(ctx, ann)
	check("highlight render: draw_rect called", ctx.rect_calls == 1)
	check("highlight render: draw_rect is filled", ctx.rect_filled_last == true)


func test_highlight_hit_inside() -> void:
	print("test_highlight_hit_inside:")
	var kind := AnnotationHighlight.new()
	var ann  := _ann("2d_highlight", [_highlight_prim(0.0, 0.0, 100.0, 50.0)])
	check("highlight hit inside rect", kind.hit_test(ann, Vector2(50.0, 25.0), 2.0))


func test_highlight_hit_outside() -> void:
	print("test_highlight_hit_outside:")
	var kind := AnnotationHighlight.new()
	var ann  := _ann("2d_highlight", [_highlight_prim(0.0, 0.0, 100.0, 50.0)])
	check("highlight miss outside rect", not kind.hit_test(ann, Vector2(200.0, 200.0), 2.0))


func test_highlight_bounds() -> void:
	print("test_highlight_bounds:")
	var kind := AnnotationHighlight.new()
	var ann  := _ann("2d_highlight", [_highlight_prim(5.0, 10.0, 60.0, 40.0)])
	var b    := kind.bounds(ann)
	check_approx("highlight bounds x",     b.position.x, 5.0)
	check_approx("highlight bounds y",     b.position.y, 10.0)
	check_approx("highlight bounds width", b.size.x,     60.0)
	check_approx("highlight bounds height", b.size.y,    40.0)


# ── AnnotationMeasureDistance tests ──────────────────────────────────────────

func test_measure_distance_render_draw_calls() -> void:
	print("test_measure_distance_render_draw_calls:")
	var kind := AnnotationMeasureDistance.new()
	var ctx  := MockRenderContext.new()
	var ann  := _ann("2d_measure_distance", [_measure_distance_prim(0.0, 0.0, 30.0, 0.0)])
	kind.render(ctx, ann)
	# Main line + 2 end tick lines = at least 3 draw_line calls; 1 draw_string for label.
	check("measure_distance render: draw_line called (line+ticks)", ctx.line_calls >= 3)
	check("measure_distance render: draw_string called (label)",    ctx.string_calls >= 1)


func test_measure_distance_text_override_suppresses_auto_label() -> void:
	print("test_measure_distance_text_override_suppresses_auto_label:")
	var kind  := AnnotationMeasureDistance.new()
	var ctx   := MockRenderContext.new()
	var prims := [
		_measure_distance_prim(0.0, 0.0, 30.0, 0.0),
		_text_prim(15.0, -5.0, "custom label"),
	]
	var ann := _ann("2d_measure_distance", prims)
	kind.render(ctx, ann)
	# 1 draw_string for the custom text primitive, auto label suppressed.
	check_eq("measure_distance: exactly 1 draw_string when text override present",
		ctx.string_calls, 1)
	check("measure_distance: text label content matches override",
		ctx.last_string == "custom label")


func test_measure_distance_hit_near_segment() -> void:
	print("test_measure_distance_hit_near_segment:")
	var kind := AnnotationMeasureDistance.new()
	var ann  := _ann("2d_measure_distance", [_measure_distance_prim(0.0, 0.0, 100.0, 0.0)])
	check("measure_distance hit near segment", kind.hit_test(ann, Vector2(50.0, 4.0), 5.0))


func test_measure_distance_hit_far() -> void:
	print("test_measure_distance_hit_far:")
	var kind := AnnotationMeasureDistance.new()
	var ann  := _ann("2d_measure_distance", [_measure_distance_prim(0.0, 0.0, 100.0, 0.0)])
	check("measure_distance miss far", not kind.hit_test(ann, Vector2(50.0, 50.0), 5.0))


func test_measure_distance_bounds() -> void:
	print("test_measure_distance_bounds:")
	var kind := AnnotationMeasureDistance.new()
	var ann  := _ann("2d_measure_distance", [_measure_distance_prim(10.0, 20.0, 90.0, 20.0)])
	var b    := kind.bounds(ann)
	check("measure_distance bounds covers from", b.has_point(Vector2(10.0, 20.0)))
	check("measure_distance bounds covers to",   b.has_point(Vector2(90.0, 20.0)))


func test_measure_distance_label_unit() -> void:
	print("test_measure_distance_label_unit:")
	var kind := AnnotationMeasureDistance.new()
	var ctx  := MockRenderContext.new()
	ctx.unit  = "in"
	var ann  := _ann("2d_measure_distance", [_measure_distance_prim(0.0, 0.0, 25.4, 0.0)])
	kind.render(ctx, ann)
	check("measure_distance label contains unit", "in" in ctx.last_string)


func test_measure_distance_primitive_unit_override() -> void:
	print("test_measure_distance_primitive_unit_override:")
	var kind := AnnotationMeasureDistance.new()
	var ctx  := MockRenderContext.new()
	ctx.unit  = "mm"
	var prim := _measure_distance_prim(0.0, 0.0, 10.0, 0.0)
	prim["unit"] = "cm"
	var ann  := _ann("2d_measure_distance", [prim])
	kind.render(ctx, ann)
	check("measure_distance: per-primitive unit override used in label", "cm" in ctx.last_string)


# ── AnnotationMeasureAngle tests ──────────────────────────────────────────────

func test_measure_angle_render_draws_lines_and_arc() -> void:
	print("test_measure_angle_render_draws_lines_and_arc:")
	var kind := AnnotationMeasureAngle.new()
	var ctx  := MockRenderContext.new()
	# Right-angle: a=(10,0), b=(0,0), c=(0,10).
	var ann  := _ann("2d_measure_angle", [_measure_angle_prim(10.0, 0.0, 0.0, 0.0, 0.0, 10.0)])
	kind.render(ctx, ann)
	check("measure_angle render: draw_line called for two arms", ctx.line_calls >= 2)
	check("measure_angle render: draw_polyline called for arc",  ctx.polyline_calls >= 1)
	check("measure_angle render: draw_string called for label",  ctx.string_calls >= 1)


func test_measure_angle_hit_near_arm() -> void:
	print("test_measure_angle_hit_near_arm:")
	var kind := AnnotationMeasureAngle.new()
	# a at (100,0), b at (0,0), c at (0,100)
	var ann  := _ann("2d_measure_angle", [_measure_angle_prim(100.0, 0.0, 0.0, 0.0, 0.0, 100.0)])
	# Point on segment b→a (arm along x axis) within threshold.
	check("measure_angle hit near arm b→a", kind.hit_test(ann, Vector2(50.0, 3.0), 5.0))


func test_measure_angle_hit_far() -> void:
	print("test_measure_angle_hit_far:")
	var kind := AnnotationMeasureAngle.new()
	var ann  := _ann("2d_measure_angle", [_measure_angle_prim(100.0, 0.0, 0.0, 0.0, 0.0, 100.0)])
	check("measure_angle miss far", not kind.hit_test(ann, Vector2(300.0, 300.0), 5.0))


func test_measure_angle_bounds() -> void:
	print("test_measure_angle_bounds:")
	var kind := AnnotationMeasureAngle.new()
	var ann  := _ann("2d_measure_angle", [_measure_angle_prim(10.0, 0.0, 0.0, 0.0, 0.0, 10.0)])
	var b    := kind.bounds(ann)
	# Bounds must contain all three points.
	check("measure_angle bounds contains a", b.has_point(Vector2(10.0, 0.0)))
	check("measure_angle bounds contains b", b.has_point(Vector2(0.0, 0.0)))
	check("measure_angle bounds contains c", b.has_point(Vector2(0.0, 10.0)))


func test_measure_angle_label_degrees() -> void:
	print("test_measure_angle_label_degrees:")
	var kind := AnnotationMeasureAngle.new()
	var ctx  := MockRenderContext.new()
	ctx.unit  = "mm"  # non-rad unit → degrees
	var ann  := _ann("2d_measure_angle", [_measure_angle_prim(10.0, 0.0, 0.0, 0.0, 0.0, 10.0)])
	kind.render(ctx, ann)
	check("measure_angle label contains degree symbol", "°" in ctx.last_string)


func test_measure_angle_label_rad() -> void:
	print("test_measure_angle_label_rad:")
	var kind := AnnotationMeasureAngle.new()
	var ctx  := MockRenderContext.new()
	ctx.unit  = "rad"
	var ann  := _ann("2d_measure_angle", [_measure_angle_prim(10.0, 0.0, 0.0, 0.0, 0.0, 10.0)])
	kind.render(ctx, ann)
	check("measure_angle label contains 'rad'", "rad" in ctx.last_string)


# ── AnnotationMeasureRadius tests ─────────────────────────────────────────────

func test_measure_radius_render_draw_calls() -> void:
	print("test_measure_radius_render_draw_calls:")
	var kind := AnnotationMeasureRadius.new()
	var ctx  := MockRenderContext.new()
	var ann  := _ann("2d_measure_radius", [_measure_radius_prim(0.0, 0.0, 20.0, 0.0)])
	kind.render(ctx, ann)
	check("measure_radius render: draw_polyline for circle", ctx.polyline_calls >= 1)
	check("measure_radius render: draw_line for radial",     ctx.line_calls >= 1)
	check("measure_radius render: draw_string for label",    ctx.string_calls >= 1)


func test_measure_radius_hit_near_circumference() -> void:
	print("test_measure_radius_hit_near_circumference:")
	var kind := AnnotationMeasureRadius.new()
	# Center (0,0), edge (20,0) → radius=20. Point at (20,3) is 3 units from circumference.
	var ann  := _ann("2d_measure_radius", [_measure_radius_prim(0.0, 0.0, 20.0, 0.0)])
	check("measure_radius hit near circumference", kind.hit_test(ann, Vector2(20.0, 3.0), 5.0))


func test_measure_radius_hit_well_inside() -> void:
	print("test_measure_radius_hit_well_inside:")
	var kind := AnnotationMeasureRadius.new()
	# Center (0,0), edge (20,0) → radius=20, radial line along +x axis.
	# Point (5, 5): distance to circumference = 20 − √50 ≈ 12.93 (>>5);
	# distance to radial segment = 5 (>5 with the threshold value).
	# Threshold tightened to 4.0 so 5.0 is genuinely a miss on the radial too.
	var ann  := _ann("2d_measure_radius", [_measure_radius_prim(0.0, 0.0, 20.0, 0.0)])
	check("measure_radius miss in interior (not near circumference or radial)",
		not kind.hit_test(ann, Vector2(5.0, 5.0), 4.0))


func test_measure_radius_hit_near_radial() -> void:
	print("test_measure_radius_hit_near_radial:")
	var kind := AnnotationMeasureRadius.new()
	# Radial line from (0,0) to (20,0); point at (10, 3) is 3 units from the segment.
	var ann  := _ann("2d_measure_radius", [_measure_radius_prim(0.0, 0.0, 20.0, 0.0)])
	check("measure_radius hit near radial line", kind.hit_test(ann, Vector2(10.0, 3.0), 5.0))


func test_measure_radius_bounds() -> void:
	print("test_measure_radius_bounds:")
	var kind := AnnotationMeasureRadius.new()
	# Center (50,50), edge (70,50) → radius=20.
	var ann  := _ann("2d_measure_radius", [_measure_radius_prim(50.0, 50.0, 70.0, 50.0)])
	var b    := kind.bounds(ann)
	# Circle bounding rect: position (30,30), size (40,40) → edges at x=30,70 / y=30,70.
	# Note: Rect2.has_point is half-open on the max edge (`p.y < pos.y + size.y`),
	# so points exactly on the bottom/right edge fail. Verify enclosure via
	# explicit bounds checks instead.
	check("measure_radius bounds left edge",   b.position.x <= 30.0 and b.position.x + b.size.x >= 30.0)
	check("measure_radius bounds top edge",    b.position.y <= 30.0 and b.position.y + b.size.y >= 30.0)
	check("measure_radius bounds right edge",  b.position.x + b.size.x >= 70.0)
	check("measure_radius bounds bottom edge", b.position.y + b.size.y >= 70.0)


func test_measure_radius_label_unit() -> void:
	print("test_measure_radius_label_unit:")
	var kind := AnnotationMeasureRadius.new()
	var ctx  := MockRenderContext.new()
	ctx.unit  = "mm"
	var ann  := _ann("2d_measure_radius", [_measure_radius_prim(0.0, 0.0, 15.0, 0.0)])
	kind.render(ctx, ann)
	check("measure_radius label contains unit", "mm" in ctx.last_string)
	check("measure_radius label contains 'r='", "r=" in ctx.last_string)


# ── toolbar_icon wiring tests ─────────────────────────────────────────────────

func test_toolbar_icon_arrow() -> void:
	print("test_toolbar_icon_arrow:")
	var kind := AnnotationArrow.new()
	check("arrow toolbar_icon is set", kind.toolbar_icon != null)


func test_toolbar_icon_text() -> void:
	print("test_toolbar_icon_text:")
	var kind := AnnotationText.new()
	check("text toolbar_icon is set", kind.toolbar_icon != null)


func test_toolbar_icon_region() -> void:
	print("test_toolbar_icon_region:")
	var kind := AnnotationRegion.new()
	check("region toolbar_icon is set", kind.toolbar_icon != null)


func test_toolbar_icon_polyline() -> void:
	print("test_toolbar_icon_polyline:")
	var kind := AnnotationPolyline.new()
	check("polyline toolbar_icon is set", kind.toolbar_icon != null)


func test_toolbar_icon_highlight_null() -> void:
	print("test_toolbar_icon_highlight_null:")
	var kind := AnnotationHighlight.new()
	# toolbar_icon intentionally null until a highlight icon asset is added.
	check("highlight toolbar_icon is null (no asset yet — acceptable)", kind.toolbar_icon == null)


func test_toolbar_icon_measure_distance_null() -> void:
	print("test_toolbar_icon_measure_distance_null:")
	var kind := AnnotationMeasureDistance.new()
	# toolbar_icon intentionally null until a measure-distance icon asset is added.
	check("measure_distance toolbar_icon is null (no asset yet — acceptable)", kind.toolbar_icon == null)


func test_toolbar_icon_measure_angle_null() -> void:
	print("test_toolbar_icon_measure_angle_null:")
	var kind := AnnotationMeasureAngle.new()
	# toolbar_icon intentionally null until a measure-angle icon asset is added.
	check("measure_angle toolbar_icon is null (no asset yet — acceptable)", kind.toolbar_icon == null)


func test_toolbar_icon_measure_radius_null() -> void:
	print("test_toolbar_icon_measure_radius_null:")
	var kind := AnnotationMeasureRadius.new()
	# toolbar_icon intentionally null until a measure-radius icon asset is added.
	check("measure_radius toolbar_icon is null (no asset yet — acceptable)", kind.toolbar_icon == null)


# ── AnnotationKind base fixes (follow-up items) ───────────────────────────────

func test_bounds_from_primitives_at_origin_included() -> void:
	print("test_bounds_from_primitives_at_origin_included:")
	# Arrow at origin (from=[0,0] to=[0,0]) should still produce an initialized Rect2
	# rather than being dropped by the old zero-rect sentinel.  After the fix the
	# AABB will include the origin even if it has no area.
	var prims := [
		{"kind": "arrow", "from": [0.0, 0.0], "to": [0.0, 0.0]},
		{"kind": "text",  "at": [5.0, 5.0], "content": "x"},
	]
	var b := AnnotationKind.bounds_from_primitives(prims)
	# The text primitive at (5,5) must be included; before the fix the arrow would
	# reset `result` to Rect2() which then might prevent text from merging correctly.
	check("origin arrow + text: text position included in bounds",
		b.has_point(Vector2(5.0, 5.0)))
	# Highlight at origin with zero size — must not exclude subsequent primitives.
	var prims2 := [
		{"kind": "highlight", "rect": [0.0, 0.0, 0.0, 0.0]},
		{"kind": "text",      "at": [10.0, 10.0], "content": "y"},
	]
	var b2 := AnnotationKind.bounds_from_primitives(prims2)
	check("zero-size highlight at origin + text: text included", b2.has_point(Vector2(10.0, 10.0)))


func test_points_aabb_4col_delegates() -> void:
	print("test_points_aabb_4col_delegates:")
	# _points_aabb_4col should return the same result as _points_aabb when fed
	# 4-column points (x, y, pressure, timestamp) — _to_vec2 reads only indices 0,1.
	var pts_4col: Array = [[0.0, 0.0, 0.5, 0], [10.0, 5.0, 0.8, 100], [5.0, 10.0, 0.3, 200]]
	var pts_2col: Array = [[0.0, 0.0], [10.0, 5.0], [5.0, 10.0]]
	var b4 := AnnotationKind._points_aabb_4col(pts_4col)
	var b2 := AnnotationKind._points_aabb(pts_2col)
	check_approx("_points_aabb_4col x matches _points_aabb", b4.position.x, b2.position.x)
	check_approx("_points_aabb_4col y matches _points_aabb", b4.position.y, b2.position.y)
	check_approx("_points_aabb_4col w matches _points_aabb", b4.size.x, b2.size.x)
	check_approx("_points_aabb_4col h matches _points_aabb", b4.size.y, b2.size.y)


# ── summary() default and overrides ──────────────────────────────────────────

func test_summary_default_no_anchor() -> void:
	print("test_summary_default_no_anchor:")
	# Use AnnotationArrow but craft an annotation with no arrow primitive so
	# summary() falls back to super() — the default AnnotationKind implementation.
	var kind := AnnotationArrow.new()
	var ann := _ann("2d_arrow", [])  # no primitives → no arrow prim → falls to super
	var s := kind.summary(ann)
	check("default summary contains display_name", "Arrow" in s)
	check("default summary contains primitive count", "0 primitives" in s)
	check("default summary has no anchor suffix", not ("→" in s))


func test_summary_default_with_anchor() -> void:
	print("test_summary_default_with_anchor:")
	var kind := AnnotationArrow.new()
	var ann := _ann("2d_arrow", [])  # no arrow prim → super path
	ann["anchored_to"] = "comp:R5"
	var s := kind.summary(ann)
	check("default summary with anchor contains display_name", "Arrow" in s)
	check("default summary with anchor contains '→'", "→" in s)
	check("default summary with anchor contains anchor value", "comp:R5" in s)


func test_summary_arrow_no_anchor() -> void:
	print("test_summary_arrow_no_anchor:")
	var kind := AnnotationArrow.new()
	var ann := _ann("2d_arrow", [_arrow_prim(10.0, 20.0, 30.0, 40.0)])
	var s := kind.summary(ann)
	check("arrow summary starts with 'arrow from'", s.begins_with("arrow from"))
	check("arrow summary contains from coords", "(10, 20)" in s)
	check("arrow summary contains to coords",   "(30, 40)" in s)
	check("arrow summary has no anchor suffix", not ("→" in s))


func test_summary_arrow_with_anchor() -> void:
	print("test_summary_arrow_with_anchor:")
	var kind := AnnotationArrow.new()
	var ann := _ann("2d_arrow", [_arrow_prim(10.0, 20.0, 30.0, 40.0)])
	ann["anchored_to"] = "net:VCC"
	var s := kind.summary(ann)
	check("arrow summary with anchor contains coords", "(10, 20)" in s)
	check("arrow summary with anchor contains '→'", "→" in s)
	check("arrow summary with anchor contains anchor value", "net:VCC" in s)


func test_summary_text_no_anchor() -> void:
	print("test_summary_text_no_anchor:")
	var kind := AnnotationText.new()
	var ann := _ann("2d_text", [_text_prim(5.0, 6.0, "hello")])
	var s := kind.summary(ann)
	check("text summary starts with \"text '\"", s.begins_with("text '"))
	check("text summary contains content", "hello" in s)
	check("text summary contains position", "(5, 6)" in s)
	check("text summary has no anchor suffix", not ("→" in s))


func test_summary_text_with_anchor() -> void:
	print("test_summary_text_with_anchor:")
	var kind := AnnotationText.new()
	var ann := _ann("2d_text", [_text_prim(5.0, 6.0, "hello")])
	ann["anchored_to"] = "part:42"
	var s := kind.summary(ann)
	check("text summary with anchor contains content", "hello" in s)
	check("text summary with anchor contains '→'", "→" in s)
	check("text summary with anchor contains anchor value", "part:42" in s)


func test_summary_text_truncates_long_content() -> void:
	print("test_summary_text_truncates_long_content:")
	var kind := AnnotationText.new()
	# Content longer than 30 characters must be truncated with "..."
	var long_content := "This content is definitely longer than thirty characters"
	var ann := _ann("2d_text", [_text_prim(0.0, 0.0, long_content)])
	var s := kind.summary(ann)
	# The preview is 27 chars + "..." = 30 chars; full string must NOT appear
	check("long text summary does not contain full content", not (long_content in s))
	check("long text summary ends preview with '...'", "..." in s)
	# But the truncated form (first 27 chars) should be present
	check("long text summary contains first 27 chars",
		long_content.substr(0, 27) in s)


# ── Screen-px constants in bounds()/hit_test() ────────────────────────────────
# Round B1 U1, docket item 019fbb9ee9.
#
# THE BUG: render() divides every screen-pixel constant by ctx.zoom; bounds()
# and hit_test() carry no context and used to consume the SAME constants as
# DOCUMENT units. Harmless where doc units are pixels (the text editor), wrong
# on the PCB canvas where doc space is board MILLIMETRES — a 12 px arrowhead
# grew an anchored arrow's AABB by 12 mm per side, and the transform tool's
# selection rect, the marquee sweep and dock zoom-to-fit all consumed it.
#
# THE FIXTURE below is that bug: a 40 mm arrow on a board viewed at 6 px/mm.
# Pre-fix bounds were 64 x 24 mm (the 12 mm-per-side inflation); post-fix they
# are 44 x 4 mm. Every kind that mixes pixel constants into bounds()/hit_test()
# gets a case here, so weakening the fix at ANY ONE site still fails the suite.

## Board-mm document space viewed at 6 screen pixels per millimetre.
const _MM_ZOOM := 6.0

## Arrowhead / tick / label constants are SCREEN pixels; at _MM_ZOOM these are
## the document-unit sizes they must resolve to.
const _HEAD_PX := 12.0            # AnnotationArrow.DEFAULT_HEAD_SIZE_PX
const _HEAD_MM := 2.0             # 12 / 6


## Wire `kind` to a fixed screen-pixels-per-doc-unit scale, the way
## AnnotationOverlay.set_host() wires a live host on a real canvas.
func _at_zoom(kind: AnnotationKind, zoom: float) -> AnnotationKind:
	kind.view_zoom_source = func() -> float: return zoom
	return kind


## Anchored arrow: endpoints live in kind_payload as inline canvas points, so
## they resolve with no host — the same path a pcb/board.point anchor takes once
## the host has resolved it. No label, so the AABB is the shaft plus the head.
func _anchored_arrow(ax: float, ay: float, bx: float, by: float) -> Dictionary:
	var ann := _ann("2d_arrow", [])
	ann["kind_payload"] = {
		"endpoint_a": {"x": ax, "y": ay},
		"endpoint_b": {"x": bx, "y": by},
	}
	return ann


func test_px_zoom_source_fails_safe_when_unbound() -> void:
	print("test_px_zoom_source_fails_safe_when_unbound:")
	var kind := AnnotationArrow.new()
	check("unbound source is invalid", not kind.view_zoom_source.is_valid())
	check_approx("unbound view_zoom is 1.0", kind.view_zoom(), 1.0)
	check_approx("unbound px_to_doc is identity", kind.px_to_doc(_HEAD_PX), _HEAD_PX)
	check("unbound px_to_doc_size is identity",
		kind.px_to_doc_size(Vector2(50.0, 12.0)) == Vector2(50.0, 12.0))


func test_px_zoom_source_fails_safe_on_bad_values() -> void:
	print("test_px_zoom_source_fails_safe_on_bad_values:")
	var kind := AnnotationArrow.new()

	# Zero must never reach the divisor.
	kind.view_zoom_source = func() -> float: return 0.0
	check_approx("zero zoom falls back to 1.0", kind.view_zoom(), 1.0)
	check_approx("zero zoom does not divide by zero", kind.px_to_doc(_HEAD_PX), _HEAD_PX)

	kind.view_zoom_source = func() -> float: return -3.0
	check_approx("negative zoom falls back to 1.0", kind.view_zoom(), 1.0)

	kind.view_zoom_source = func() -> float: return NAN
	check_approx("NaN zoom falls back to 1.0", kind.view_zoom(), 1.0)

	kind.view_zoom_source = func() -> float: return INF
	check_approx("infinite zoom falls back to 1.0", kind.view_zoom(), 1.0)

	# A source that reports something that is not a number at all.
	kind.view_zoom_source = func(): return "not a number"
	check_approx("non-numeric zoom falls back to 1.0", kind.view_zoom(), 1.0)

	# And the rect never explodes: bounds stay finite under every bad source.
	kind.view_zoom_source = func() -> float: return 0.0
	var b := kind.bounds(_anchored_arrow(20.0, 40.0, 60.0, 40.0))
	check("bad zoom leaves bounds finite", is_finite(b.size.x) and is_finite(b.size.y))


func test_registry_stamps_zoom_source_on_existing_and_late_kinds() -> void:
	print("test_registry_stamps_zoom_source_on_existing_and_late_kinds:")
	var registry := AnnotationRegistry.new()
	BuiltinKinds.register_all(registry)

	var arrow_before: AnnotationKind = registry.get_annotation_kind(&"2d_arrow")
	check_approx("kind is unbound before wiring", arrow_before.view_zoom(), 1.0)

	registry.set_view_zoom_source(func() -> float: return _MM_ZOOM)

	# Kinds already held get stamped...
	var arrow: AnnotationKind = registry.get_annotation_kind(&"2d_arrow")
	check_approx("already-registered kind is stamped", arrow.view_zoom(), _MM_ZOOM)
	var dist: AnnotationKind = registry.get_annotation_kind(&"2d_measure_distance")
	check_approx("every already-registered kind is stamped", dist.view_zoom(), _MM_ZOOM)

	# ...and so does anything registered afterwards, which is how plugin kinds
	# (registered long after the host built its overlay) inherit the scale.
	var late := AnnotationTextComment.new()
	check("late kind registers", registry.register_annotation_kind(late))
	check_approx("late-registered kind inherits the source", late.view_zoom(), _MM_ZOOM)

	# Unbinding restores the pixels-are-doc-units default.
	registry.set_view_zoom_source(Callable())
	check_approx("unbinding restores 1.0", arrow.view_zoom(), 1.0)


func test_anchored_arrow_bounds_not_inflated_on_mm_canvas() -> void:
	print("test_anchored_arrow_bounds_not_inflated_on_mm_canvas:")
	# THE BUG FIXTURE: a 40 mm arrow on an 80 mm board at 6 px/mm.
	var kind := _at_zoom(AnnotationArrow.new(), _MM_ZOOM) as AnnotationArrow
	var b := kind.bounds(_anchored_arrow(20.0, 40.0, 60.0, 40.0))

	# The head is 12 SCREEN px = 2 mm here, so the AABB is 44 x 4 mm.
	check_approx("anchored arrow bounds width is shaft + 2 mm per side", b.size.x, 40.0 + 2.0 * _HEAD_MM)
	check_approx("anchored arrow bounds height is 2 mm per side", b.size.y, 2.0 * _HEAD_MM)
	check_approx("anchored arrow bounds left edge", b.position.x, 20.0 - _HEAD_MM)
	check_approx("anchored arrow bounds top edge", b.position.y, 40.0 - _HEAD_MM)

	# The pre-fix rect was 64 x 24 mm — a quarter of the board. Guard the
	# regression explicitly, not just by arithmetic.
	check("anchored arrow bounds are nowhere near the pre-fix 64 mm width", b.size.x < 50.0)
	check("anchored arrow bounds are nowhere near the pre-fix 24 mm height", b.size.y < 10.0)


func test_anchored_arrow_bounds_unchanged_at_zoom_1() -> void:
	print("test_anchored_arrow_bounds_unchanged_at_zoom_1:")
	# Hosts whose document space IS screen pixels (the text editor, the hello
	# panel) never set a zoom source. Their numbers must not move at all.
	var unbound := AnnotationArrow.new()
	var bound := _at_zoom(AnnotationArrow.new(), 1.0) as AnnotationArrow
	var ann := _anchored_arrow(20.0, 40.0, 60.0, 40.0)

	var b := unbound.bounds(ann)
	check_approx("unbound bounds width is the legacy 40 + 2x12", b.size.x, 40.0 + 2.0 * _HEAD_PX)
	check_approx("unbound bounds height is the legacy 2x12", b.size.y, 2.0 * _HEAD_PX)
	check("zoom 1 matches unbound exactly", bound.bounds(ann) == b)


func test_free_arrow_bounds_not_inflated_on_mm_canvas() -> void:
	print("test_free_arrow_bounds_not_inflated_on_mm_canvas:")
	# Legacy primitives path — a SECOND grow(head) site, fixed independently.
	var kind := _at_zoom(AnnotationArrow.new(), _MM_ZOOM) as AnnotationArrow
	var ann := _ann("2d_arrow", [_arrow_prim(20.0, 40.0, 60.0, 40.0, _HEAD_PX)])
	var b := kind.bounds(ann)
	check_approx("free arrow bounds width is shaft + 2 mm per side", b.size.x, 40.0 + 2.0 * _HEAD_MM)
	check_approx("free arrow bounds height is 2 mm per side", b.size.y, 2.0 * _HEAD_MM)

	var unbound := AnnotationArrow.new()
	check_approx("free arrow at zoom 1 keeps the legacy width",
		unbound.bounds(ann).size.x, 40.0 + 2.0 * _HEAD_PX)


func test_arrow_text_primitive_box_scales_with_zoom() -> void:
	print("test_arrow_text_primitive_box_scales_with_zoom:")
	# A THIRD site: the 50x12 px glyph-run approximation in the primitives path.
	var kind := _at_zoom(AnnotationArrow.new(), _MM_ZOOM) as AnnotationArrow
	var ann := _ann("2d_arrow", [_arrow_prim(0.0, 0.0, 10.0, 0.0, _HEAD_PX), _text_prim(200.0, 200.0)])
	var b := kind.bounds(ann)
	# Left edge proves the head fix; width proves the text-box fix.
	check_approx("arrow+text bounds left edge uses mm head", b.position.x, -_HEAD_MM)
	check_approx("arrow+text bounds width uses mm text box", b.size.x, 200.0 + 50.0 / _MM_ZOOM + _HEAD_MM)


func test_arrow_hit_test_text_box_honest_at_zoom() -> void:
	print("test_arrow_hit_test_text_box_honest_at_zoom:")
	var ann := _ann("2d_arrow", [_arrow_prim(0.0, 0.0, 10.0, 0.0, _HEAD_PX), _text_prim(200.0, 200.0)])
	# 30 mm to the right of the label origin: inside the pre-fix 50 mm-wide box,
	# far outside the honest 8.3 mm one.
	var probe := Vector2(230.0, 201.0)
	var zoomed := _at_zoom(AnnotationArrow.new(), _MM_ZOOM) as AnnotationArrow
	check("hit_test text box does not reach 30 mm at 6 px/mm", not zoomed.hit_test(ann, probe, 0.5))
	var unbound := AnnotationArrow.new()
	check("hit_test text box still reaches 30 units unbound", unbound.hit_test(ann, probe, 0.5))


func test_arrow_label_aabb_still_participates() -> void:
	print("test_arrow_label_aabb_still_participates:")
	# A8u2 semantics are unchanged: label_font_size is DOCUMENT units by
	# contract (screen px / authoring zoom), so the caption box is NOT divided
	# by zoom — it just has to keep merging into bounds after the head fix.
	var kind := _at_zoom(AnnotationArrow.new(), _MM_ZOOM) as AnnotationArrow
	var ann := _anchored_arrow(20.0, 40.0, 60.0, 40.0)
	var payload: Dictionary = ann["kind_payload"]
	payload["label"] = "NET1"
	payload["label_font_size"] = 2.0
	payload["label_offset"] = [0.0, -3.2]
	ann["kind_payload"] = payload

	var b := kind.bounds(ann)
	var centre: Variant = kind.label_position(ann, [Vector2(20.0, 40.0), Vector2(60.0, 40.0)])
	check("label centre resolves", centre is Vector2)
	check("bounds contain the caption centre", b.has_point(centre as Vector2))
	# Caption box is 4.4 x 2.4 mm centred at (40, 36.8) → top edge 35.6 mm,
	# above the shaft's 38 mm, so the merge is what sets the top edge.
	check_approx("caption sets the top edge of the merged AABB", b.position.y, 35.6)
	# And the shaft half is still the FIXED width, not the inflated one.
	check_approx("merged AABB keeps the mm-correct width", b.size.x, 40.0 + 2.0 * _HEAD_MM)


func test_measure_distance_bounds_tick_scales_with_zoom() -> void:
	print("test_measure_distance_bounds_tick_scales_with_zoom:")
	# TICK_SIZE is documented screen px and render() divides it by zoom; bounds
	# used to grow by the raw 4.
	var kind := _at_zoom(AnnotationMeasureDistance.new(), _MM_ZOOM) as AnnotationMeasureDistance
	var ann := _ann("2d_measure_distance", [_measure_distance_prim(20.0, 40.0, 60.0, 40.0)])
	var b := kind.bounds(ann)
	check_approx("measure_distance bounds grow by 4 px in mm", b.size.y, 2.0 * (4.0 / _MM_ZOOM))
	check_approx("measure_distance bounds width", b.size.x, 40.0 + 2.0 * (4.0 / _MM_ZOOM))

	var unbound := AnnotationMeasureDistance.new()
	check_approx("measure_distance unbound keeps the legacy 4-unit tick",
		unbound.bounds(ann).size.y, 8.0)


func test_measure_distance_hit_test_text_box_honest_at_zoom() -> void:
	print("test_measure_distance_hit_test_text_box_honest_at_zoom:")
	var ann := _ann("2d_measure_distance", [
		_measure_distance_prim(0.0, 0.0, 10.0, 0.0), _text_prim(200.0, 200.0)])
	# 35 mm right of the label origin: inside the pre-fix 60 mm box, outside the
	# honest 10 mm one.
	var probe := Vector2(235.0, 201.0)
	var zoomed := _at_zoom(AnnotationMeasureDistance.new(), _MM_ZOOM) as AnnotationMeasureDistance
	check("measure_distance label box does not reach 35 mm at 6 px/mm",
		not zoomed.hit_test(ann, probe, 0.5))
	check("measure_distance label box still reaches 35 units unbound",
		AnnotationMeasureDistance.new().hit_test(ann, probe, 0.5))


func test_measure_angle_bounds_margin_scales_with_zoom() -> void:
	print("test_measure_angle_bounds_margin_scales_with_zoom:")
	# arc_r is document space (25 % of the shorter arm, floored at 4); the
	# extra 20 is a SCREEN-px label margin.
	var kind := _at_zoom(AnnotationMeasureAngle.new(), _MM_ZOOM) as AnnotationMeasureAngle
	var ann := _ann("2d_measure_angle", [_measure_angle_prim(20.0, 40.0, 20.0, 20.0, 40.0, 20.0)])
	var b := kind.bounds(ann)
	var expected := 20.0 + 2.0 * (5.0 + 20.0 / _MM_ZOOM)   # arms 20 mm, arc_r 5 mm
	check_approx("measure_angle bounds width", b.size.x, expected)
	check_approx("measure_angle bounds height", b.size.y, expected)
	check("measure_angle bounds are far under the pre-fix 70", b.size.x < 45.0)

	check_approx("measure_angle unbound keeps the legacy 70",
		AnnotationMeasureAngle.new().bounds(ann).size.x, 70.0)


func test_measure_angle_hit_test_label_box_honest_at_zoom() -> void:
	print("test_measure_angle_hit_test_label_box_honest_at_zoom:")
	var ann := _ann("2d_measure_angle", [_measure_angle_prim(20.0, 40.0, 20.0, 20.0, 40.0, 20.0)])
	var arc_r := AnnotationMeasureAngle._arc_radius(Vector2(20, 40), Vector2(20, 20), Vector2(40, 20))
	var label_pos := AnnotationMeasureAngle._label_pos(
		Vector2(20, 40), Vector2(20, 20), Vector2(40, 20), arc_r)
	# 10 mm right of the label centre: inside the pre-fix 40x16 box (half-width
	# 20), outside the honest 6.7x2.7 one — and clear of both arms.
	var probe := label_pos + Vector2(10.0, 0.0)
	var zoomed := _at_zoom(AnnotationMeasureAngle.new(), _MM_ZOOM) as AnnotationMeasureAngle
	check("measure_angle label box does not reach 10 mm at 6 px/mm",
		not zoomed.hit_test(ann, probe, 0.5))
	check("measure_angle label box still reaches 10 units unbound",
		AnnotationMeasureAngle.new().hit_test(ann, probe, 0.5))


func test_measure_radius_bounds_label_scales_with_zoom() -> void:
	print("test_measure_radius_bounds_label_scales_with_zoom:")
	var kind := _at_zoom(AnnotationMeasureRadius.new(), _MM_ZOOM) as AnnotationMeasureRadius
	var ann := _ann("2d_measure_radius", [_measure_radius_prim(20.0, 20.0, 40.0, 20.0)])
	var b := kind.bounds(ann)
	# Circle rect is (0,0)-(40,40); the label sits at x=46 and is 60 px wide,
	# so the merged width is 46 + 60/zoom.
	check_approx("measure_radius bounds width", b.size.x, 46.0 + 60.0 / _MM_ZOOM)
	check_approx("measure_radius unbound keeps the legacy 106",
		AnnotationMeasureRadius.new().bounds(ann).size.x, 106.0)


func test_measure_radius_hit_test_label_box_honest_at_zoom() -> void:
	print("test_measure_radius_hit_test_label_box_honest_at_zoom:")
	var ann := _ann("2d_measure_radius", [_measure_radius_prim(20.0, 20.0, 40.0, 20.0)])
	# Label origin is (46, 12); probe 30 mm right of it, clear of the circle and
	# the radial line.
	var probe := Vector2(76.0, 13.0)
	var zoomed := _at_zoom(AnnotationMeasureRadius.new(), _MM_ZOOM) as AnnotationMeasureRadius
	check("measure_radius label box does not reach 30 mm at 6 px/mm",
		not zoomed.hit_test(ann, probe, 0.5))
	check("measure_radius label box still reaches 30 units unbound",
		AnnotationMeasureRadius.new().hit_test(ann, probe, 0.5))


func test_polyline_bounds_text_box_scales_with_zoom() -> void:
	print("test_polyline_bounds_text_box_scales_with_zoom:")
	var kind := _at_zoom(AnnotationPolyline.new(), _MM_ZOOM) as AnnotationPolyline
	var ann := _ann("2d_polyline", [
		_polyline_prim([[0.0, 0.0], [10.0, 0.0]]), _text_prim(200.0, 200.0)])
	check_approx("polyline bounds width uses mm text box",
		kind.bounds(ann).size.x, 200.0 + 50.0 / _MM_ZOOM)
	check_approx("polyline unbound keeps the legacy 250",
		AnnotationPolyline.new().bounds(ann).size.x, 250.0)


func test_polyline_hit_test_text_box_honest_at_zoom() -> void:
	print("test_polyline_hit_test_text_box_honest_at_zoom:")
	var ann := _ann("2d_polyline", [
		_polyline_prim([[0.0, 0.0], [10.0, 0.0]]), _text_prim(200.0, 200.0)])
	var probe := Vector2(230.0, 201.0)
	var zoomed := _at_zoom(AnnotationPolyline.new(), _MM_ZOOM) as AnnotationPolyline
	check("polyline label box does not reach 30 mm at 6 px/mm",
		not zoomed.hit_test(ann, probe, 0.5))
	check("polyline label box still reaches 30 units unbound",
		AnnotationPolyline.new().hit_test(ann, probe, 0.5))

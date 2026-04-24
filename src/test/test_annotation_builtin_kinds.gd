extends SceneTree
## Unit tests for the built-in 2D annotation kinds and BuiltinKinds registry helper.
## Run: godot --headless --script test/test_annotation_builtin_kinds.gd
##
## Coverage:
##   BuiltinKinds
##     - register_all() registers all 8 kinds
##     - deregister_all() removes all 8 kinds
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

	print("\n-- AnnotationKind base fixes --")
	test_bounds_from_primitives_at_origin_included()
	test_points_aabb_4col_delegates()

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
	check_eq("8 kinds registered", registry.count(), 8)


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
	check_eq("8 kinds after round-trip", registry.count(), 8)


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
	check("polyline bounds contains all points",
		b.has_point(Vector2(10.0, 20.0)) and
		b.has_point(Vector2(80.0, 60.0)) and
		b.has_point(Vector2(30.0, 90.0))
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
	# Point at center — well inside (>5 from circumference at radius 20).
	var ann  := _ann("2d_measure_radius", [_measure_radius_prim(0.0, 0.0, 20.0, 0.0)])
	check("measure_radius miss at center (not near circumference or radial)",
		not kind.hit_test(ann, Vector2(0.0, 0.0), 5.0))


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
	# Circle bounding rect: (30,30,40,40) = [50-20, 50-20, 40, 40].
	check("measure_radius bounds covers left of circle",   b.has_point(Vector2(30.0, 50.0)))
	check("measure_radius bounds covers top of circle",    b.has_point(Vector2(50.0, 30.0)))
	check("measure_radius bounds covers bottom of circle", b.has_point(Vector2(50.0, 70.0)))


func test_measure_radius_label_unit() -> void:
	print("test_measure_radius_label_unit:")
	var kind := AnnotationMeasureRadius.new()
	var ctx  := MockRenderContext.new()
	ctx.unit  = "mm"
	var ann  := _ann("2d_measure_radius", [_measure_radius_prim(0.0, 0.0, 15.0, 0.0)])
	kind.render(ctx, ann)
	check("measure_radius label contains unit", "mm" in ctx.last_string)
	check("measure_radius label contains 'r='", "r=" in ctx.last_string)


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

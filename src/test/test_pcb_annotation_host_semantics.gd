extends SceneTree
## PcbAnnotationHost board-space semantics test (annotation-migration round).
##
## Run: godot --headless --path src --script test/test_pcb_annotation_host_semantics.gd
##
## Fixes gap-register W-9: annotation markers must track board coordinates
## through zoom/pan (the host previously used an identity transform). Covers:
##   1. Board-mm↔screen transform bound to the live canvas — round-trips at
##      zoom=1 AND at a set zoom/pan, matching pcb_canvas.world_to_screen exactly.
##   2. describe_point precedence: pad → component → trace → canvas.point fallback.
##   3. anchored_to stamped on add (via AnnotationHost._stamp_anchor + describe_point).
##   4. canvas pan/zoom pokes the host's view_changed (the overlay redraw seam).
##   5. no-canvas fallback: identity transforms + bare-point describe_point, no crash.
##
## Off-tree scripts are load()ed at RUNTIME (res:// == src/, so
## res://../../minerva-plugins == C:/github/minerva-plugins) — a bad path FAILS a
## test rather than aborting the whole script at parse time. Everything is
## duck-typed (never typed AS a plugin class), matching the off-tree contract.

const PLUGIN_UI := "res://../../minerva-plugins/pcb/ui/"
const HOST_PATH := PLUGIN_UI + "PcbAnnotationHost.gd"
const CANVAS_PATH := PLUGIN_UI + "pcb_canvas.gd"
const DATA_PATH := PLUGIN_UI + "model/pcb_data.gd"
const COMPONENT_PATH := PLUGIN_UI + "model/pcb_component.gd"
const TRACE_PATH := PLUGIN_UI + "model/pcb_trace.gd"

var _pass_count: int = 0
var _fail_count: int = 0

var _Host: Script = null
var _Canvas: Script = null
var _Data: Script = null
var _Component: Script = null
var _Trace: Script = null


func _init() -> void:
	print("=== PcbAnnotationHost Board-Space Semantics ===\n")
	await process_frame

	_Host = load(HOST_PATH)
	_Canvas = load(CANVAS_PATH)
	_Data = load(DATA_PATH)
	_Component = load(COMPONENT_PATH)
	_Trace = load(TRACE_PATH)
	check("all off-tree scripts load",
			_Host != null and _Canvas != null and _Data != null
			and _Component != null and _Trace != null)
	if _Host == null:
		_finish()
		return

	_test_transform_roundtrip()
	_test_describe_point_precedence()
	_test_anchored_to_stamped_on_add()
	_test_view_changed_poke()
	_test_no_canvas_fallback()

	_finish()


func _finish() -> void:
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ── Fixtures ──────────────────────────────────────────────────────────────────

## Build a board: R1 (resistor) @ (10,10) with pins 1/2, U3 (IC_DIP) @ (30,20),
## and a GND trace along y=30 away from both parts.
func _make_board():
	var data = _Data.new()
	data.board_width = 60.0
	data.board_height = 40.0

	var r1 = _Component.new()
	r1.id = "R1"
	r1.set_footprint_by_name("RESISTOR")
	r1.position = Vector2(10.0, 10.0)
	r1.setup_standard_pins()   # pin "1"@(0,0), "2"@(2.54,0)
	data.add_component(r1)

	var u3 = _Component.new()
	u3.id = "U3"
	u3.set_footprint_by_name("IC_DIP")
	u3.position = Vector2(30.0, 20.0)
	u3.setup_standard_pins()
	data.add_component(u3)

	var t = _Trace.new()
	t.net_name = "GND"
	t.layer = "top"
	t.width = 0.25
	t.add_waypoint(Vector2(5.0, 30.0))   # typed Array[Vector2] — append, don't reassign
	t.add_waypoint(Vector2(20.0, 30.0))
	data.add_trace(t)

	return data


func _make_canvas(data):
	var canvas = _Canvas.new()
	canvas.size = Vector2(800.0, 600.0)
	canvas.set_data(data)
	return canvas


# ── 1. Transform round-trip ───────────────────────────────────────────────────

func _test_transform_roundtrip() -> void:
	print("-- board-mm↔screen transform tracks the live canvas --")
	var data = _make_board()
	var canvas = _make_canvas(data)
	var host = _Host.new()
	host.set_canvas(canvas)

	var probes: Array = [Vector2(10.0, 10.0), Vector2(0.0, 0.0), Vector2(-7.5, 22.25)]

	# zoom=1, pan=0 — screen == doc + size/2 (doc != screen, but round-trips).
	canvas.zoom = 1.0
	canvas.pan_offset = Vector2.ZERO
	check("get_annotation_zoom reflects canvas zoom=1", is_equal_approx(host.get_annotation_zoom(), 1.0))
	for p in probes:
		var screen: Vector2 = host.transform_doc_to_screen(p)
		check("doc→screen matches canvas.world_to_screen @z=1 %s" % str(p),
				screen.is_equal_approx(canvas.world_to_screen(p)),
				"host=%s canvas=%s" % [str(screen), str(canvas.world_to_screen(p))])
		check("doc→screen→doc round-trips @z=1 %s" % str(p),
				host.transform_screen_to_doc(screen).is_equal_approx(p))
	check("z=1 origin is size/2 (doc 0,0 → 400,300)",
			host.transform_doc_to_screen(Vector2.ZERO).is_equal_approx(Vector2(400.0, 300.0)))

	# A set zoom + pan — assert the transform math + inverse round-trip.
	canvas.zoom = 4.0
	canvas.pan_offset = Vector2(50.0, -30.0)
	check("get_annotation_zoom reflects canvas zoom=4", is_equal_approx(host.get_annotation_zoom(), 4.0))
	for p in probes:
		var screen: Vector2 = host.transform_doc_to_screen(p)
		check("doc→screen matches canvas.world_to_screen @z=4,pan %s" % str(p),
				screen.is_equal_approx(canvas.world_to_screen(p)),
				"host=%s canvas=%s" % [str(screen), str(canvas.world_to_screen(p))])
		check("doc→screen→doc round-trips @z=4,pan %s" % str(p),
				host.transform_screen_to_doc(screen).is_equal_approx(p))
	# view_transform is the same affine the overlay applies.
	var xf: Transform2D = host.get_annotation_view_transform()
	check("get_annotation_view_transform == doc→screen affine",
			(xf * Vector2(10.0, 10.0)).is_equal_approx(host.transform_doc_to_screen(Vector2(10.0, 10.0))))

	canvas.free()


# ── 2. describe_point precedence ──────────────────────────────────────────────

func _test_describe_point_precedence() -> void:
	print("\n-- describe_point precedence: pad → component → trace → fallback --")
	var data = _make_board()
	var canvas = _make_canvas(data)
	var host = _Host.new()
	host.set_canvas(canvas)

	# pad — exactly on R1 pin 1 (10,10) and pin 2 (12.54,10).
	check("pad hit on pin 1 → 'pad:R1.1'",
			host.describe_point(Vector2(10.0, 10.0)) == "pad:R1.1",
			host.describe_point(Vector2(10.0, 10.0)))
	check("pad hit on pin 2 → 'pad:R1.2'",
			host.describe_point(Vector2(12.54, 10.0)) == "pad:R1.2",
			host.describe_point(Vector2(12.54, 10.0)))

	# component — inside R1's body but >1mm from either pin.
	check("body hit (not a pad) → 'component:R1'",
			host.describe_point(Vector2(11.27, 10.6)) == "component:R1",
			host.describe_point(Vector2(11.27, 10.6)))

	# trace — on the GND polyline, away from all parts.
	check("trace hit → 'trace:GND'",
			host.describe_point(Vector2(12.5, 30.0)) == "trace:GND",
			host.describe_point(Vector2(12.5, 30.0)))

	# fallback — empty board space.
	check("empty space → 'canvas.point (x, y) mm'",
			host.describe_point(Vector2(50.0, 5.0)) == "canvas.point (50.0, 5.0) mm",
			host.describe_point(Vector2(50.0, 5.0)))

	canvas.free()


# ── 3. anchored_to stamped on add ─────────────────────────────────────────────

func _test_anchored_to_stamped_on_add() -> void:
	print("\n-- anchored_to stamped on add via describe_point --")
	var data = _make_board()
	var canvas = _make_canvas(data)
	var host = _Host.new()
	host.set_canvas(canvas)

	var pad_id: String = host.add_route_hint_at(10.0, 10.0, "keep clear of R1.1")
	check("route hint on pin 1 stamps anchored_to='pad:R1.1'",
			str(host.get_by_id(pad_id).get("anchored_to", "")) == "pad:R1.1",
			str(host.get_by_id(pad_id).get("anchored_to", "")))

	var body_id: String = host.add_route_hint_at(11.27, 10.6, "over R1 body")
	check("route hint over body stamps anchored_to='component:R1'",
			str(host.get_by_id(body_id).get("anchored_to", "")) == "component:R1",
			str(host.get_by_id(body_id).get("anchored_to", "")))

	canvas.free()


# ── 4. canvas pan/zoom pokes host.view_changed ────────────────────────────────

func _test_view_changed_poke() -> void:
	print("\n-- canvas pan/zoom pokes host.view_changed (overlay redraw seam) --")
	var data = _make_board()
	var canvas = _make_canvas(data)
	var host = _Host.new()
	host.set_canvas(canvas)

	var spy := {"count": 0}
	host.view_changed.connect(func() -> void: spy.count += 1)

	canvas._zoom_at(canvas.size / 2.0, 1.2)
	check("canvas zoom pokes host.view_changed", spy.count >= 1,
			"count=%d" % spy.count)

	var before: int = spy.count
	canvas._center_view()
	check("canvas pan (center) pokes host.view_changed", spy.count > before,
			"before=%d after=%d" % [before, spy.count])

	canvas.free()


# ── 5. no-canvas fallback (headless / pre-mount) ──────────────────────────────

func _test_no_canvas_fallback() -> void:
	print("\n-- no-canvas host: identity transforms + bare-point describe, no crash --")
	var host = _Host.new()   # never set_canvas

	check("no-canvas view transform is identity",
			host.get_annotation_view_transform() == Transform2D.IDENTITY)
	check("no-canvas doc→screen is identity",
			host.transform_doc_to_screen(Vector2(5.0, 7.0)) == Vector2(5.0, 7.0))
	check("no-canvas screen→doc is identity",
			host.transform_screen_to_doc(Vector2(5.0, 7.0)) == Vector2(5.0, 7.0))
	check("no-canvas zoom is 1.0", is_equal_approx(host.get_annotation_zoom(), 1.0))
	check("no-canvas describe_point → bare board point",
			host.describe_point(Vector2(5.0, 7.0)) == "canvas.point (5.0, 7.0) mm",
			host.describe_point(Vector2(5.0, 7.0)))
	check("no-canvas render_content_to_image → null (safe)",
			host.render_content_to_image(Rect2()) == null)
	# Adding still works (stamps a bare-point anchored_to, no crash).
	var id: String = host.add_route_hint_at(3.0, 4.0, "headless")
	check("no-canvas add still stamps a bare-point anchored_to",
			str(host.get_by_id(id).get("anchored_to", "")) == "canvas.point (3.0, 4.0) mm",
			str(host.get_by_id(id).get("anchored_to", "")))


# ──────────────────────────────────────────────────────────────────────────────

func check(description: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [description, detail])
		else:
			printerr("  FAIL: %s" % description)

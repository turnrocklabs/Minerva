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
const KIND_PATH := PLUGIN_UI + "kinds/pcb_route_hint_kind.gd"

var _pass_count: int = 0
var _fail_count: int = 0

var _Host: Script = null
var _Canvas: Script = null
var _Data: Script = null
var _Component: Script = null
var _Trace: Script = null
var _Kind: Script = null


func _init() -> void:
	print("=== PcbAnnotationHost Board-Space Semantics ===\n")
	await process_frame

	_Host = load(HOST_PATH)
	_Canvas = load(CANVAS_PATH)
	_Data = load(DATA_PATH)
	_Component = load(COMPONENT_PATH)
	_Trace = load(TRACE_PATH)
	_Kind = load(KIND_PATH)
	check("all off-tree scripts load",
			_Host != null and _Canvas != null and _Data != null
			and _Component != null and _Trace != null and _Kind != null)
	if _Host == null:
		_finish()
		return

	_test_transform_roundtrip()
	_test_describe_point_precedence()
	_test_anchored_to_stamped_on_add()
	_test_view_changed_poke()
	_test_no_canvas_fallback()

	# ── Semantic-anchor round additions ──
	_test_resolve_semantic_anchors()
	_test_resolve_rotated_pad()
	_test_stale_fallback()
	_test_anchor_summaries()
	_test_anchor_registry_repair()
	_test_repair_route_hint_endpoints()
	_test_kind_validate_payload()
	_test_kind_path_hit_test()
	_test_kind_summary_string()
	_test_author_tool_multiclick()
	_test_capabilities()

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

# ── Semantic anchor helpers ───────────────────────────────────────────────────

func _pad_anchor(component: String, pin: String, snap: Vector2) -> Dictionary:
	return {"plugin": "pcb", "type": "pad", "id": {"component": component, "pin": pin},
			"snapshot": {"position": [snap.x, snap.y]}}


func _component_anchor(comp_id: String, snap: Vector2) -> Dictionary:
	return {"plugin": "pcb", "type": "component", "id": comp_id,
			"snapshot": {"position": [snap.x, snap.y]}}


func _net_anchor(net: String, snap: Vector2) -> Dictionary:
	return {"plugin": "pcb", "type": "net", "id": net,
			"snapshot": {"position": [snap.x, snap.y]}}


func _trace_anchor(id: Variant, snap: Vector2) -> Dictionary:
	return {"plugin": "pcb", "type": "trace", "id": id,
			"snapshot": {"position": [snap.x, snap.y]}}


# ── 6. resolve semantic anchors (pad/component/net/trace) ─────────────────────

func _test_resolve_semantic_anchors() -> void:
	print("\n-- resolve pad/component/net/trace against the live board --")
	var data = _make_board()
	var canvas = _make_canvas(data)
	var host = _Host.new()
	host.set_canvas(canvas)

	# pad R1.2 lives at world (12.54, 10) (pin "2" offset (2.54,0), rot 0).
	var r1 = data.get_component("R1")
	var pad_res: Dictionary = host.resolve_anchor(_pad_anchor("R1", "2", Vector2(0, 0)))
	check("pad resolve → live pin world pos",
			pad_res.position.is_equal_approx(r1.get_pin_world_position("2")) and not pad_res.stale,
			"got %s exp %s" % [str(pad_res.position), str(r1.get_pin_world_position("2"))])

	# component U3 origin (30, 20).
	var comp_res: Dictionary = host.resolve_anchor(_component_anchor("U3", Vector2(0, 0)))
	check("component resolve → origin (30,20)",
			comp_res.position.is_equal_approx(Vector2(30.0, 20.0)) and not comp_res.stale,
			str(comp_res.position))

	# net GND — nearest point on the GND trace (y=30 segment x∈[5,20]) to a snapshot
	# at (12.5, 34) is (12.5, 30).
	var net_res: Dictionary = host.resolve_anchor(_net_anchor("GND", Vector2(12.5, 34.0)))
	check("net resolve → nearest trace point (12.5, 30)",
			net_res.position.is_equal_approx(Vector2(12.5, 30.0)) and not net_res.stale,
			str(net_res.position))

	# trace by {net, segment 0} → midpoint of the only segment = (12.5, 30).
	var tr_res: Dictionary = host.resolve_anchor(_trace_anchor({"net": "GND", "segment": 0}, Vector2(0, 0)))
	check("trace resolve → segment-0 midpoint (12.5, 30)",
			tr_res.position.is_equal_approx(Vector2(12.5, 30.0)) and not tr_res.stale,
			str(tr_res.position))

	canvas.free()


# ── 7. rotated-component pad resolves rotation-correct ────────────────────────

func _test_resolve_rotated_pad() -> void:
	print("\n-- rotated component: pad resolves through the rigid-body transform --")
	var data = _make_board()
	var canvas = _make_canvas(data)
	var host = _Host.new()
	host.set_canvas(canvas)

	data.rotate_component("R1", 90.0)
	var r1 = data.get_component("R1")
	var res: Dictionary = host.resolve_anchor(_pad_anchor("R1", "2", Vector2(0, 0)))
	check("rotated pad resolve matches get_pin_world_position",
			res.position.is_equal_approx(r1.get_pin_world_position("2")),
			str(res.position))
	check("rotation actually moved the pad (≠ unrotated 12.54,10)",
			not res.position.is_equal_approx(Vector2(12.54, 10.0)),
			str(res.position))
	canvas.free()


# ── 8. stale fallback: deleted target → snapshot + stale flag ─────────────────

func _test_stale_fallback() -> void:
	print("\n-- stale: deleted component → resolve falls back to snapshot, flagged --")
	var data = _make_board()
	var canvas = _make_canvas(data)
	var host = _Host.new()
	host.set_canvas(canvas)

	var snap := Vector2(12.54, 10.0)
	data.remove_component("R1")
	var res: Dictionary = host.resolve_anchor(_pad_anchor("R1", "2", snap))
	check("deleted pad → position falls back to snapshot", res.position.is_equal_approx(snap), str(res.position))
	check("deleted pad → stale flag set", bool(res.stale) == true)

	var cres: Dictionary = host.resolve_anchor(_component_anchor("R1", Vector2(9.0, 9.0)))
	check("deleted component → stale + snapshot", cres.position.is_equal_approx(Vector2(9.0, 9.0)) and bool(cres.stale))
	canvas.free()


# ── 9. anchor summaries ───────────────────────────────────────────────────────

func _test_anchor_summaries() -> void:
	print("\n-- anchor summaries: pad/component/net/trace --")
	var data = _make_board()
	var canvas = _make_canvas(data)
	var host = _Host.new()
	host.set_canvas(canvas)

	check("pad summary 'pad R1.2'", host.anchor_summary(_pad_anchor("R1", "2", Vector2.ZERO)) == "pad R1.2",
			host.anchor_summary(_pad_anchor("R1", "2", Vector2.ZERO)))
	check("component summary 'component U3'", host.anchor_summary(_component_anchor("U3", Vector2.ZERO)) == "component U3")
	check("net summary 'net GND'", host.anchor_summary(_net_anchor("GND", Vector2.ZERO)) == "net GND")
	check("trace summary 'trace GND'", host.anchor_summary(_trace_anchor({"net": "GND"}, Vector2.ZERO)) == "trace GND",
			host.anchor_summary(_trace_anchor({"net": "GND"}, Vector2.ZERO)))
	canvas.free()


# ── 10. anchor registry repair path (documented) ──────────────────────────────

func _test_anchor_registry_repair() -> void:
	print("\n-- get_anchor_registry() repair: refresh snapshot, null when gone --")
	var data = _make_board()
	var canvas = _make_canvas(data)
	var host = _Host.new()
	host.set_canvas(canvas)

	var reg = host.get_anchor_registry()
	check("get_anchor_registry() is non-null", reg != null)
	if reg == null:
		canvas.free()
		return

	# summary + validate route through the registry adapter.
	check("registry.summary delegates to host ('pad R1.2')",
			reg.summary(_pad_anchor("R1", "2", Vector2.ZERO), host) == "pad R1.2")
	check("registry.validate_anchor flags a missing pad",
			not (reg.validate_anchor(_pad_anchor("R1", "9", Vector2.ZERO)) as Array).is_empty())

	# repair: stale snapshot (0,0) → refreshed to the live pin position.
	var repaired: Variant = reg.repair(_pad_anchor("R1", "2", Vector2.ZERO), host)
	check("repair returns a refreshed anchor Dict", repaired is Dictionary)
	if repaired is Dictionary:
		var r1 = data.get_component("R1")
		var pos: Array = (repaired as Dictionary).get("snapshot", {}).get("position", [])
		check("repair refreshed snapshot to live pin pos",
				pos.size() == 2 and Vector2(pos[0], pos[1]).is_equal_approx(r1.get_pin_world_position("2")),
				str(pos))

	# repair of a deleted target → null (caller marks broken).
	data.remove_component("R1")
	check("repair of a deleted pad → null (broken)", reg.repair(_pad_anchor("R1", "2", Vector2.ZERO), host) == null)
	canvas.free()


# ── 11. route-hint endpoint repair ────────────────────────────────────────────

func _test_repair_route_hint_endpoints() -> void:
	print("\n-- repair_route_hint: all endpoints must exist or the hint is broken --")
	var data = _make_board()
	var canvas = _make_canvas(data)
	var host = _Host.new()
	host.set_canvas(canvas)

	var env: Dictionary = host.build_route_hint_envelope(
			10.0, 10.0, "", "F.Cu", "single_trace", [[10.0, 10.0], [30.0, 20.0]], "human",
			"", 0.25, ["R1.1"], ["U3.1"])
	env["anchor"] = _pad_anchor("R1", "1", Vector2(10.0, 10.0))

	var ok_res: Dictionary = host.repair_route_hint(env)
	check("intact endpoints → ok, not broken, has refreshed anchor",
			bool(ok_res.get("ok", false)) and not bool(ok_res.get("broken", true)) and ok_res.has("anchor"),
			str(ok_res))

	# Delete the destination component → its pin U3.1 vanishes.
	data.remove_component("U3")
	var broken_res: Dictionary = host.repair_route_hint(env)
	check("missing dest pin → broken, not silently re-anchored",
			not bool(broken_res.get("ok", true)) and bool(broken_res.get("broken", false)),
			str(broken_res))
	check("broken result reports the missing endpoint",
			"U3.1" in (broken_res.get("missing", []) as Array), str(broken_res.get("missing", [])))
	canvas.free()


# ── 12. kind validate on new payload + old skeleton tolerance ─────────────────

func _test_kind_validate_payload() -> void:
	print("\n-- kind.validate: new payload fields + old skeleton envelope --")
	var kind = _Kind.new()

	# Rich, valid envelope (pad anchor + all new fields).
	var rich := {
		"anchor": _pad_anchor("U1", "15", Vector2(12.0, 9.0)),
		"kind_payload": {
			"hint_type": "single_trace", "detail_level": "detailed", "layer": "F.Cu",
			"width_mm": 0.25, "source_pins": ["U1.15"], "dest_pins": ["J2.3"],
			"waypoints": [[12.0, 9.0], [20.0, 9.0]],
		},
	}
	check("rich pad-anchored payload validates clean", (kind.validate(rich) as Array).is_empty(),
			str(kind.validate(rich)))

	# Old skeleton envelope (board.point anchor, minimal payload) still accepted.
	var skeleton := {
		"anchor": {"plugin": "pcb", "type": "board.point", "id": {"x": 5.0, "y": 5.0},
				"snapshot": {"position": [5.0, 5.0]}},
		"kind_payload": {"hint_type": "waypoint", "layer": "F.Cu", "text": "", "waypoints": []},
	}
	check("old skeleton envelope still validates clean", (kind.validate(skeleton) as Array).is_empty(),
			str(kind.validate(skeleton)))

	# Bad detail_level rejected.
	var bad_detail := rich.duplicate(true)
	bad_detail["kind_payload"]["detail_level"] = "verbose"
	check("bad detail_level rejected", not (kind.validate(bad_detail) as Array).is_empty())

	# Self-referencing endpoint rejected.
	var self_ref := rich.duplicate(true)
	self_ref["kind_payload"]["source_pins"] = ["U1.15"]
	self_ref["kind_payload"]["dest_pins"] = ["U1.15"]
	check("self-referencing source==dest rejected", not (kind.validate(self_ref) as Array).is_empty())

	# Non-array width / bad hint_type rejected.
	var bad_hint := skeleton.duplicate(true)
	bad_hint["kind_payload"]["hint_type"] = "star"
	check("bad hint_type rejected", not (kind.validate(bad_hint) as Array).is_empty())


# ── 13. kind path-based hit test ──────────────────────────────────────────────

func _test_kind_path_hit_test() -> void:
	print("\n-- kind.hit_test: distance-to-segment, not AABB --")
	var kind = _Kind.new()
	var ann := {
		"anchor": {"plugin": "pcb", "type": "board.point", "id": {"x": 0.0, "y": 0.0},
				"snapshot": {"position": [0.0, 0.0]}},
		"kind_payload": {"hint_type": "waypoint", "layer": "F.Cu", "width_mm": 0.0,
				"waypoints": [[0.0, 0.0], [10.0, 0.0], [10.0, 10.0]]},
	}
	check("on-segment point is a hit", kind.hit_test(ann, Vector2(5.0, 0.2), 0.2))
	check("point near the L-corner is a hit", kind.hit_test(ann, Vector2(10.0, 5.0), 0.3))
	# Interior of the L's bounding box but far from any segment → miss (proves it's
	# not an AABB test: (3,7) is inside the 0..10 box but >2mm from both arms).
	check("interior-but-off-path point is a miss", not kind.hit_test(ann, Vector2(3.0, 7.0), 0.3))


# ── 14. kind summary string form ──────────────────────────────────────────────

func _test_kind_summary_string() -> void:
	print("\n-- kind.summary: 'route hint U1.15→J2.3, F.Cu, 0.25mm, N waypoints' --")
	var kind = _Kind.new()
	var ann := {
		"anchor": _pad_anchor("U1", "15", Vector2(0, 0)),
		"kind_payload": {
			"hint_type": "single_trace", "layer": "F.Cu", "width_mm": 0.25,
			"source_pins": ["U1.15"], "dest_pins": ["J2.3"],
			"waypoints": [[0, 0], [4, 0], [4, 4], [8, 4]],
		},
	}
	check("full summary string form",
			kind.summary(ann) == "route hint U1.15→J2.3, F.Cu, 0.25mm, 4 waypoints",
			kind.summary(ann))

	# Empty parts omitted gracefully.
	var sparse := {
		"anchor": {"plugin": "pcb", "type": "board.point", "id": {"x": 0, "y": 0},
				"snapshot": {"position": [0, 0]}},
		"kind_payload": {"hint_type": "waypoint", "layer": "B.Cu", "waypoints": []},
	}
	check("sparse summary omits endpoints/width",
			kind.summary(sparse).begins_with("route hint, B.Cu"), kind.summary(sparse))


# ── 15. author tool multi-click flow ──────────────────────────────────────────

func _test_author_tool_multiclick() -> void:
	print("\n-- author tool: N clicks + commit → annotation_ready with N waypoints --")
	var host = _Host.new()   # no canvas → identity transform, screen == doc
	var kind = _Kind.new()
	var tool = kind.author_ui()
	check("author_ui() returns a tool", tool != null)
	if tool == null:
		return
	tool.on_activate(host)

	var captured := {"env": null, "cancels": 0}
	tool.annotation_ready.connect(func(e: Dictionary) -> void: captured.env = e)
	tool.cancelled.connect(func() -> void: captured.cancels += 1)

	# Three distinct clicks, then a repeat click on the last waypoint
	# (double-click — the commit gesture; the overlay only forwards Escape keys).
	tool.on_pointer_down(Vector2(0.0, 0.0), MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_down(Vector2(10.0, 0.0), MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_down(Vector2(10.0, 10.0), MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_down(Vector2(10.0, 10.0), MOUSE_BUTTON_LEFT, 0)

	check("double-click commit emitted annotation_ready", captured.env != null)
	if captured.env != null:
		var wps: Array = (captured.env as Dictionary).get("kind_payload", {}).get("waypoints", [])
		check("committed payload carries 3 waypoints", wps.size() == 3, str(wps))
		var anc: Dictionary = (captured.env as Dictionary).get("anchor", {})
		check("anchor sits at the first waypoint (0,0)",
				anc.get("id", {}).get("x", -1) == 0.0 and anc.get("id", {}).get("y", -1) == 0.0)
		check("committed kind is pcb_route_hint", str((captured.env as Dictionary).get("kind", "")) == "pcb_route_hint")

	# Double-click commit: two distinct clicks then a repeat of the last point.
	var tool2 = kind.author_ui()
	tool2.on_activate(host)
	var cap2 := {"env": null}
	tool2.annotation_ready.connect(func(e: Dictionary) -> void: cap2.env = e)
	tool2.on_pointer_down(Vector2(1.0, 1.0), MOUSE_BUTTON_LEFT, 0)
	tool2.on_pointer_down(Vector2(5.0, 1.0), MOUSE_BUTTON_LEFT, 0)
	tool2.on_pointer_down(Vector2(5.0, 1.0), MOUSE_BUTTON_LEFT, 0)   # double-click → commit
	check("double-click commit emitted with 2 waypoints",
			cap2.env != null and (cap2.env as Dictionary).get("kind_payload", {}).get("waypoints", []).size() == 2)

	# Escape cancels an in-progress path (no annotation_ready, one cancelled).
	var tool3 = kind.author_ui()
	tool3.on_activate(host)
	var cap3 := {"env": null, "cancels": 0}
	tool3.annotation_ready.connect(func(e: Dictionary) -> void: cap3.env = e)
	tool3.cancelled.connect(func() -> void: cap3.cancels += 1)
	tool3.on_pointer_down(Vector2(2.0, 2.0), MOUSE_BUTTON_LEFT, 0)
	tool3.on_pointer_down(Vector2(3.0, 3.0), MOUSE_BUTTON_LEFT, KEY_ESCAPE)
	check("Escape cancelled the path (no annotation, one cancelled)",
			cap3.env == null and cap3.cancels == 1)


# ── 16. capabilities reflect reality ──────────────────────────────────────────

func _test_capabilities() -> void:
	print("\n-- get_capabilities(): kinds/anchor_types/repair reflect reality --")
	var host = _Host.new()
	var caps: Dictionary = host.get_capabilities()
	var kinds: Array = caps.get("kinds", [])
	check("caps.kinds includes pcb_route_hint + core 2d_* generics",
			"pcb_route_hint" in kinds and "2d_arrow" in kinds and "2d_text" in kinds
			and "2d_region" in kinds and "2d_polyline" in kinds, str(kinds))
	var atypes: Array = caps.get("anchor_types", [])
	check("caps.anchor_types includes the new semantic pcb anchors",
			"pcb/pad" in atypes and "pcb/component" in atypes and "pcb/net" in atypes and "pcb/trace" in atypes,
			str(atypes))
	check("caps.lifecycle.repair is true (repair implemented)",
			bool((caps.get("lifecycle", {}) as Dictionary).get("repair", false)))

	# The registry actually carries the advertised core generic kinds.
	var reg = host.get_registry()
	check("registry carries 2d_arrow + 2d_polyline (generic authoring is real)",
			reg != null and reg.get_annotation_kind(&"2d_arrow") != null
			and reg.get_annotation_kind(&"2d_polyline") != null)

	# Author colors: substrate defaults are human-magenta / AI-cyan.
	check("substrate author colors: human=magenta, ai=cyan",
			AnnotationRenderContext.author_color("human") == Color(1.0, 0.5, 1.0)
			and AnnotationRenderContext.author_color("ai") == Color(0.0, 1.0, 1.0))


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

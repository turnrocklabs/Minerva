extends SceneTree
## PCB panel MODEL test (Round A of the panel port).
##
## Run: godot --headless --path src --script test/test_pcb_panel_model.gd
##
## Exercises the off-tree ported board model at minerva-plugins/pcb/ui/model/
## (pcb_data.gd + siblings) — the model Round B's canvas/editor UI will consume
## verbatim. Pure GDScript behavior asserts, no Go binary, no autoloads.
##
## Coverage:
##   1. Canonical round-trip: model → to_board_dict() → model → to_board_dict()
##      deep-equal on a representative board.
##   2. Canonical field names present (spot-assert ref / x_mm / rotation_deg,
##      trace width_mm/points, net "Ref.Pad" pin strings).
##   3. from_board_dict TOLERATES + IGNORES annotation/route_hint keys (owned by
##      PcbAnnotationHost now); to_board_dict never emits them.
##   4. undo/redo round-trip on a mutation.
##   5. change_journal records EVERY mutation type symmetrically (the C-19 fix).
##   6. spatial query returns the expected neighbor set.
##
## Off-tree scripts are load()ed at runtime (res:// == src/, so
## res://../../minerva-plugins == C:/github/minerva-plugins) so a bad path FAILS a
## test rather than aborting the script at parse time.

const MODEL_DIR := "res://../../minerva-plugins/pcb/ui/model/"
const PCB_DATA_PATH := MODEL_DIR + "pcb_data.gd"
const PCB_COMPONENT_PATH := MODEL_DIR + "pcb_component.gd"
const PCB_NET_PATH := MODEL_DIR + "pcb_net.gd"
const PCB_TRACE_PATH := MODEL_DIR + "pcb_trace.gd"
const PCB_SPATIAL_PATH := MODEL_DIR + "pcb_spatial_index.gd"

var _pass_count: int = 0
var _fail_count: int = 0

var _PCBData: Script = null
var _PCBComponent: Script = null
var _PCBNet: Script = null
var _PCBTrace: Script = null
var _PCBSpatial: Script = null


func _init() -> void:
	print("=== PCB Panel Model Test ===\n")
	await process_frame

	_PCBData = load(PCB_DATA_PATH)
	_PCBComponent = load(PCB_COMPONENT_PATH)
	_PCBNet = load(PCB_NET_PATH)
	_PCBTrace = load(PCB_TRACE_PATH)
	_PCBSpatial = load(PCB_SPATIAL_PATH)
	check("all five model scripts load off-tree",
			_PCBData != null and _PCBComponent != null and _PCBNet != null
			and _PCBTrace != null and _PCBSpatial != null)
	if _PCBData == null:
		_finish()
		return

	_test_canonical_roundtrip()
	_test_canonical_field_names()
	_test_annotation_tolerance()
	_test_undo_redo()
	_test_via_undo_restore()
	_test_journal_symmetry()
	_test_spatial_query()
	_test_mounting_holes_roundtrip()
	_test_rotation_sign_lands_on_traces()

	_finish()


func _finish() -> void:
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ──────────────────────────────────────────────────────────────────────────────
# Representative board builder (shared)
# ──────────────────────────────────────────────────────────────────────────────

## Build a representative board via the model API (components with pins + value,
## an auto-created power net, a routed trace, a via, design rules).
func _build_board():
	var data = _PCBData.new(50.0, 40.0)
	data.board_name = "Blinky"
	data.grid_size = 2.54
	data.design_rules = {"clearance_mm": 0.2, "trace_width_mm": 0.25, "via_diameter_mm": 0.8}

	var u1 = _PCBComponent.new()
	u1.id = "U1"
	u1.set_footprint_by_name("IC_DIP")
	u1.position = Vector2(20.0, 12.0)
	u1.rotation = 90.0
	u1.setup_standard_pins()
	u1.properties["value"] = "NE555"
	data.add_component(u1)

	var r1 = _PCBComponent.new()
	r1.id = "R1"
	r1.set_footprint_by_name("RESISTOR")
	r1.position = Vector2(34.0, 6.0)
	r1.setup_standard_pins()
	r1.properties["value"] = "10k"
	data.add_component(r1)

	# Net (auto-created by connect_pin_to_net) with two pins.
	data.connect_pin_to_net("VCC", "U1", "8")
	data.connect_pin_to_net("VCC", "R1", "1")

	# Routed trace.
	var t = _PCBTrace.new()
	t.net_name = "VCC"
	t.layer = "top"
	t.width = 0.25
	t.add_waypoint(Vector2(10.0, 5.0))
	t.add_waypoint(Vector2(20.0, 12.0))
	data.add_trace(t)

	# Via with an Extra "layers" key (rides canonical Extra).
	data.add_via({
		"position": Vector2(15.0, 8.0),
		"drill": 0.4,
		"size": 0.8,
		"net_name": "VCC",
		"layers": ["top", "bottom"]
	})
	return data


# ──────────────────────────────────────────────────────────────────────────────
# Tests
# ──────────────────────────────────────────────────────────────────────────────

func _test_canonical_roundtrip() -> void:
	print("-- canonical round-trip model→board_dict→model deep-equal --")
	var a = _build_board()
	var d1: Dictionary = a.to_board_dict()

	var b = _PCBData.new()
	b.from_board_dict(d1)
	var d2: Dictionary = b.to_board_dict()

	check("board_dict round-trips deep-equal (model→dict→model→dict)", d1 == d2,
			"d1 != d2\n  d1=%s\n  d2=%s" % [str(d1), str(d2)])
	# State-level spot checks on the reconstructed model.
	check("reconstructed model keeps both components", b.get_component_count() == 2)
	check("reconstructed model keeps the net", b.has_net("VCC"))
	check("reconstructed model keeps the trace", b.get_trace_count() == 1)
	check("reconstructed component value survives (U1=NE555)",
			b.get_component("U1") != null and b.get_component("U1").properties.get("value", "") == "NE555")
	check("reconstructed via count preserved", b.vias.size() == 1)


func _test_canonical_field_names() -> void:
	print("\n-- canonical field names present at the boundary --")
	var a = _build_board()
	var d: Dictionary = a.to_board_dict()

	check("board dict uses width_mm/height_mm/grid_mm",
			d.has("width_mm") and d.has("height_mm") and d.has("grid_mm"))
	check("board dict carries design_rules", d.has("design_rules")
			and (d["design_rules"] as Dictionary).has("clearance_mm"))
	check("components is a list (not id-map)", d.get("components", null) is Array)

	# Find U1 in the (sorted) component list.
	var u1_dict := {}
	for c in d.get("components", []):
		if str(c.get("ref", "")) == "U1":
			u1_dict = c
			break
	check("component uses canonical 'ref'", u1_dict.get("ref", "") == "U1")
	check("component uses canonical 'x_mm'/'y_mm'",
			u1_dict.get("x_mm", null) == 20.0 and u1_dict.get("y_mm", null) == 12.0)
	check("component uses canonical 'rotation_deg'", u1_dict.get("rotation_deg", null) == 90.0)
	check("component pins are {number,x_mm,y_mm}",
			u1_dict.get("pins", []) is Array and (u1_dict["pins"] as Array).size() > 0
			and (u1_dict["pins"][0] as Dictionary).has("number")
			and (u1_dict["pins"][0] as Dictionary).has("x_mm"))

	# Trace canonical fields.
	var traces: Array = d.get("traces", [])
	check("trace uses canonical 'width_mm'/'points'/'net'",
			traces.size() == 1 and (traces[0] as Dictionary).has("width_mm")
			and (traces[0] as Dictionary).has("points")
			and str((traces[0] as Dictionary).get("net", "")) == "VCC")

	# Net pins flattened to "Ref.Pad" strings.
	var nets: Array = d.get("nets", [])
	var vcc := {}
	for n in nets:
		if str(n.get("name", "")) == "VCC":
			vcc = n
			break
	check("net pins are flat 'Ref.Pad' strings",
			vcc.get("pins", []) is Array and "U1.8" in vcc.get("pins", []) and "R1.1" in vcc.get("pins", []),
			"pins=%s" % str(vcc.get("pins", [])))


func _test_annotation_tolerance() -> void:
	print("\n-- from_board_dict tolerates + ignores annotation/route_hint keys --")
	var a = _build_board()
	var d: Dictionary = a.to_board_dict()
	# The Go importer passes annotations/route_hints through opaquely; the model
	# must ignore them without error.
	d["annotations"] = [{"id": "ann_0001", "kind": "pcb_route_hint"}]
	d["route_hints"] = [{"id": "hint_1", "hint_type": "waypoint"}]

	var b = _PCBData.new()
	b.from_board_dict(d)
	check("board with annotation keys loads without error (components intact)",
			b.get_component_count() == 2 and b.has_net("VCC"))

	# Model owns no annotation storage; its own board_dict must not emit them.
	var d2: Dictionary = b.to_board_dict()
	check("model's to_board_dict does NOT emit 'annotations'", not d2.has("annotations"))
	check("model's to_board_dict does NOT emit 'route_hints'", not d2.has("route_hints"))


func _test_undo_redo() -> void:
	print("\n-- undo/redo round-trip on a mutation --")
	var data = _build_board()
	# Establish a clean undo baseline (from_board_dict does this on load; here we
	# snapshot the current built state as the baseline).
	data.save_to_history("baseline")
	var orig: Vector2 = data.get_component("R1").position

	var moved := Vector2(40.0, 20.0)
	data.move_component("R1", moved)
	data.save_to_history("move R1")

	check("can_undo after a mutation", data.can_undo())
	check("undo() succeeds", data.undo())
	check("undo restores original position",
			data.get_component("R1").position == orig,
			"got %s want %s" % [str(data.get_component("R1").position), str(orig)])
	check("can_redo after undo", data.can_redo())
	check("redo() succeeds", data.redo())
	check("redo re-applies the move",
			data.get_component("R1").position == moved,
			"got %s want %s" % [str(data.get_component("R1").position), str(moved)])


## F1 / Via Correctness GATE INV-1 (Codex 019f70ec149b): undo/redo must restore
## vias, not orphan them. Before the fix the undo codec omitted vias, so undoing
## an accepted via route removed its traces but left its vias floating.
func _test_via_undo_restore() -> void:
	print("\n-- undo/redo restores vias (F1 / GATE INV-1) --")
	var data = _build_board()  # _build_board seeds one via at (15, 8)
	data.save_to_history("baseline")
	var base_count: int = data.vias.size()
	check("baseline has one via", base_count == 1, "got %d" % base_count)

	# Simulate accepting a via-bearing route: add a via, then snapshot.
	data.add_via({
		"position": Vector2(30.0, 18.0), "drill": 0.4, "size": 0.8,
		"net_name": "VCC", "from_layer": "top", "to_layer": "bottom"
	})
	data.save_to_history("accept via route")
	check("after accept, two vias", data.vias.size() == 2, "got %d" % data.vias.size())

	# The fix: undo removes the accepted via instead of orphaning it.
	check("undo() succeeds", data.undo())
	check("undo restores via count (no orphan)", data.vias.size() == base_count,
			"got %d want %d" % [data.vias.size(), base_count])
	var restored_pos = data.vias[0].get("position") if data.vias.size() == 1 else null
	check("restored via keeps its position", restored_pos == Vector2(15.0, 8.0),
			"got %s" % str(restored_pos))

	# redo re-adds the accepted via.
	check("redo() succeeds", data.redo())
	check("redo re-adds the via", data.vias.size() == 2, "got %d" % data.vias.size())


func _test_journal_symmetry() -> void:
	print("\n-- change_journal records ALL mutation types symmetrically (C-19) --")
	var data = _PCBData.new(50.0, 40.0)
	data.clear_change_journal()

	# Exercise every mutating operation exactly once.
	var c = _PCBComponent.new()
	c.id = "U1"
	c.set_footprint_by_name("IC_DIP")
	c.setup_standard_pins()
	data.add_component(c)                                   # add_component
	data.move_component("U1", Vector2(5.0, 5.0))            # move_component
	data.rotate_component("U1", 90.0)                       # rotate_component

	var n = _PCBNet.new()
	n.name = "GND"
	data.add_net(n)                                         # add_net
	data.connect_pin_to_net("GND", "U1", "1")              # connect_net
	data.disconnect_pin_from_net("GND", "U1", "1")         # disconnect_net

	var t = _PCBTrace.new()
	t.net_name = "GND"
	t.add_waypoint(Vector2(0, 0))
	t.add_waypoint(Vector2(1, 1))
	data.add_trace(t)                                       # add_trace
	data.remove_trace(t.id)                                 # remove_trace

	data.add_via({"position": Vector2(1, 1), "drill": 0.4, "size": 0.8})  # add_via
	data.remove_via(0)                                      # remove_via
	data.add_via({"position": Vector2(2, 2)})              # (re-add so clear has content)
	data.clear_traces()                                    # clear_traces
	data.set_board_size(60.0, 45.0)                        # resize_board
	data.remove_net("GND")                                 # remove_net
	data.remove_component("U1")                            # remove_component

	var actions := {}
	for entry in data.get_change_journal():
		actions[str(entry.get("action", ""))] = true

	var expected := [
		"add_component", "move_component", "rotate_component",
		"add_net", "connect_net", "disconnect_net", "remove_net",
		"add_trace", "remove_trace", "clear_traces",
		"add_via", "remove_via", "resize_board", "remove_component",
	]
	var missing: Array = []
	for act in expected:
		if not actions.has(act):
			missing.append(act)
	check("journal records every mutation type symmetrically (14 kinds)",
			missing.is_empty(), "missing journal actions: %s" % str(missing))


func _test_spatial_query() -> void:
	print("\n-- spatial query returns expected neighbors --")
	var data = _PCBData.new(100.0, 100.0)
	for spec in [["U1", Vector2(10.0, 10.0)], ["R1", Vector2(20.0, 10.0)], ["C1", Vector2(80.0, 80.0)]]:
		var comp = _PCBComponent.new()
		comp.id = spec[0]
		comp.set_footprint_by_name("RESISTOR")
		comp.position = spec[1]
		comp.setup_standard_pins()
		data.add_component(comp)

	var idx = _PCBSpatial.new(data)
	var near: Array = idx.get_components_near("U1", 15.0)
	check("get_components_near returns the close neighbor (R1)", "R1" in near,
			"near=%s" % str(near))
	check("get_components_near excludes the far component (C1)", not ("C1" in near),
			"near=%s" % str(near))
	check("get_nearest_component finds R1 nearest to U1",
			idx.get_nearest_to_component("U1") == "R1")


func _test_mounting_holes_roundtrip() -> void:
	print("\n-- board-level mounting_holes load + round-trip (mirrors vias) --")
	var board := {
		"version": 1,
		"name": "MountingHoleBoard",
		"width_mm": 80.0,
		"height_mm": 110.0,
		"grid_mm": 2.54,
		"layers": ["top", "bottom"],
		"design_rules": {},
		"components": [],
		"nets": [],
		"traces": [],
		"vias": [],
		"mounting_holes": [
			{"x_mm": 5.0, "y_mm": 5.0, "diameter_mm": 3.2, "plated": false},
			{"x_mm": 75.0, "y_mm": 5.0, "diameter_mm": 3.2, "plated": false},
			{"x_mm": 5.0, "y_mm": 105.0, "diameter_mm": 3.2, "plated": false},
			{"x_mm": 75.0, "y_mm": 105.0, "diameter_mm": 3.2, "plated": false},
		]
	}

	var data = _PCBData.new()
	data.from_board_dict(board)

	check("mounting_holes loaded (4 holes)", data.mounting_holes.size() == 4,
			"got %d" % data.mounting_holes.size())

	var first: Dictionary = data.mounting_holes[0] if data.mounting_holes.size() > 0 else {}
	check("first hole position is Vector2(5, 5)",
			first.get("position", null) == Vector2(5.0, 5.0),
			"got %s" % str(first.get("position", null)))
	check("first hole diameter preserved (3.2)",
			is_equal_approx(float(first.get("diameter", 0.0)), 3.2),
			"got %s" % str(first.get("diameter", null)))
	check("first hole plated preserved (false)",
			first.get("plated", true) == false)

	var d2: Dictionary = data.to_board_dict()
	var out_holes: Array = d2.get("mounting_holes", [])
	check("to_board_dict round-trips mounting_holes count (4)",
			out_holes.size() == 4, "got %d" % out_holes.size())

	if out_holes.size() == 4:
		var h0: Dictionary = out_holes[0]
		check("round-tripped hole x_mm/y_mm/diameter_mm/plated match input",
				is_equal_approx(float(h0.get("x_mm", -1.0)), 5.0)
				and is_equal_approx(float(h0.get("y_mm", -1.0)), 5.0)
				and is_equal_approx(float(h0.get("diameter_mm", -1.0)), 3.2)
				and h0.get("plated", true) == false,
				"h0=%s" % str(h0))

	# Legacy to_dict/load_from_dict path (undo snapshots) must also preserve holes.
	var snap: Dictionary = data.to_dict()
	check("legacy to_dict serializes mounting_holes (4)",
			(snap.get("mounting_holes", []) as Array).size() == 4,
			"got %d" % (snap.get("mounting_holes", []) as Array).size())
	var data2 = _PCBData.new()
	data2.load_from_dict(snap)
	check("legacy load_from_dict restores mounting_holes (4)",
			data2.mounting_holes.size() == 4,
			"got %d" % data2.mounting_holes.size())
	if data2.mounting_holes.size() == 4:
		var lh: Dictionary = data2.mounting_holes[0]
		check("legacy-restored hole position + plated:false preserved",
				lh.get("position", null) == Vector2(5.0, 5.0)
				and lh.get("plated", true) == false,
				"lh=%s" % str(lh))


# ──────────────────────────────────────────────────────────────────────────────

## Rotation-convention regression: rotation_deg is KiCad-equivalent, so
## get_transform() applies R(-rotation) (matching the worker's radians(-deg)).
## MIC1 at its KiCad-sign rotation (90) must land its WS pad on the I2S_WS trace
## end. A +rotation panel (or a stale-negated 270 in the data) puts it off-board.
func _test_rotation_sign_lands_on_traces() -> void:
	print("\n-- rotation convention: KiCad-sign 90-deg pin lands on its trace --")
	var comp = _PCBComponent.new()
	comp.id = "MIC1"
	comp.position = Vector2(40.64, 106.68)   # smart-remote MIC1 placement
	comp.rotation = 90.0                      # KiCad-sign (canonical, corrected)
	comp.pins = {"4": Vector2(7.62, 5.08)}    # WS pad, footprint-local

	# I2S_WS trace terminates at (45.72, 99.06); R(-90) must reach it.
	var wp: Vector2 = comp.get_pin_world_position("4")
	check("MIC1.WS (rot90, KiCad conv) world pos on I2S_WS trace end (45.72, 99.06)",
			wp.is_equal_approx(Vector2(45.72, 99.06)),
			"got %s (a +rotation panel would give 35.56,114.3 off-board)" % str(wp))
	# And it must be inside the 80x110 board, not hanging off the bottom.
	check("MIC1.WS world pos is on-board (y <= 110)", wp.y <= 110.0,
			"got y=%.2f" % wp.y)


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

extends SceneTree
## Legacy .minpcb inline annotation/route-hint → v2 sidecar migration test.
##
## Run: godot --headless --path src --script test/test_pcb_legacy_annotation_migration.gd
##
## Exercises minerva-plugins/pcb/ui/legacy_annotation_migration.gd (the off-tree
## one-shot translator) + its PCBPanel._on_panel_load_request hook. Covers:
##   1. Every annotation variant (arrow/text/region/polyline; mixed authors;
##      default + custom colors; associated_component / _net / both / neither;
##      an unknown legacy field) migrates to a conformant v2 envelope.
##   2. Every route-hint variant (each hint_type; waypoints; source/dest pins;
##      bus_spacing; client_id) migrates, with a pcb/pad anchor when the first
##      source pin resolves, else pcb/board.point.
##   3. All migrated envelopes pass validate_with_registry (host validates on add,
##      so migrated-count == fixture-count proves it) — plus an explicit re-check.
##   4. Unknown legacy fields land in kind_payload.legacy_extra AND warn.
##   5. Panel-level: a legacy-shaped load writes the sidecar, does NOT dirty the
##      tab, surfaces the count, and is idempotent (sidecar present → skip).
##   6. Round-trip: migrate → save_sidecar → fresh host load_sidecar survives.
##
## PLATFORM CONSTRAINT under test (verified this round): the core 2d_* kinds
## accept ONLY core/* anchors, so generic annotations anchor at core/canvas.point
## and preserve associated_component/_net in kind_payload (route hints keep the
## real pcb/pad|board.point upgrade). See the module header for the full note.
##
## Off-tree scripts are load()ed at RUNTIME and duck-typed (never typed AS a
## plugin class), matching the pcb suite's off-tree contract.

const PLUGIN_UI := "res://../../minerva-plugins/pcb/ui/"
const HOST_PATH := PLUGIN_UI + "PcbAnnotationHost.gd"
const CANVAS_PATH := PLUGIN_UI + "pcb_canvas.gd"
const DATA_PATH := PLUGIN_UI + "model/pcb_data.gd"
const COMPONENT_PATH := PLUGIN_UI + "model/pcb_component.gd"
const TRACE_PATH := PLUGIN_UI + "model/pcb_trace.gd"
const MIGRATION_PATH := PLUGIN_UI + "legacy_annotation_migration.gd"
const PANEL_PATH := PLUGIN_UI + "PCBPanel.gd"
const DRIVER_PATH := "res://test/helpers/plugin_panel_driver.gd"

var _pass_count: int = 0
var _fail_count: int = 0

var _Host: Script = null
var _Canvas: Script = null
var _Data: Script = null
var _Component: Script = null
var _Trace: Script = null
var _Migration: Script = null

# Legacy author-default colors (must mirror the in-tree serializers).
var _ANN_HUMAN := Color(0.95, 0.5, 0.9)
var _RHINT_HUMAN := Color(0.2, 0.8, 0.6, 0.8)


func _init() -> void:
	print("=== PCB Legacy Annotation Migration ===\n")
	await process_frame

	_Host = load(HOST_PATH)
	_Canvas = load(CANVAS_PATH)
	_Data = load(DATA_PATH)
	_Component = load(COMPONENT_PATH)
	_Trace = load(TRACE_PATH)
	_Migration = load(MIGRATION_PATH)
	check("all off-tree scripts load",
			_Host != null and _Canvas != null and _Data != null
			and _Component != null and _Trace != null and _Migration != null)
	if _Migration == null:
		_finish()
		return

	_test_migrate_all_variants()
	_test_idempotency_and_roundtrip()
	_test_panel_level_hook()

	_finish()


func _finish() -> void:
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ── Fixtures ──────────────────────────────────────────────────────────────────

## Board: R1 (resistor) @ (10,10) pins "1"@(0,0)/"2"@(2.54,0); U3 (IC_DIP) @ (30,20).
func _make_board():
	var data = _Data.new()
	data.board_width = 60.0
	data.board_height = 40.0
	var r1 = _Component.new()
	r1.id = "R1"
	r1.set_footprint_by_name("RESISTOR")
	r1.position = Vector2(10.0, 10.0)
	r1.setup_standard_pins()
	data.add_component(r1)
	var u3 = _Component.new()
	u3.id = "U3"
	u3.set_footprint_by_name("IC_DIP")
	u3.position = Vector2(30.0, 20.0)
	u3.setup_standard_pins()
	data.add_component(u3)
	return data


func _make_host_with_board():
	var data = _make_board()
	var canvas = _Canvas.new()
	canvas.size = Vector2(800.0, 600.0)
	canvas.set_data(data)
	var host = _Host.new()
	host.set_canvas(canvas)
	return [host, canvas, data]


## The legacy inline blobs — id→dict MAP shape, as PCBData.to_dict nests them.
## Covers every variant the task enumerates.
func _legacy_annotations() -> Dictionary:
	return {
		"ann_000001": {   # ARROW, human, DEFAULT color, associated_component
			"id": "ann_000001", "type": "ARROW",
			"positions": [{"x": 4.0, "y": 4.0}, {"x": 16.0, "y": 12.0}],
			"text": "check U3 clearance", "color": _ANN_HUMAN.to_html(),
			"author": "human", "created_at": 1745524440.5,
			"associated_component": "U3", "associated_net": "",
		},
		"ann_000002": {   # TEXT, ai, CUSTOM color, associated_net
			"id": "ann_000002", "type": "TEXT",
			"positions": [{"x": 20.0, "y": 5.0}],
			"text": "GND pour here", "color": Color(0.1, 0.2, 0.3).to_html(),
			"author": "ai", "created_at": 1745524441.0,
			"associated_component": "", "associated_net": "GND",
		},
		"ann_000003": {   # REGION, human, DEFAULT color, BOTH associations
			"id": "ann_000003", "type": "REGION",
			"positions": [{"x": 2.0, "y": 2.0}, {"x": 18.0, "y": 14.0}],
			"text": "", "color": _ANN_HUMAN.to_html(),
			"author": "human", "created_at": 1745524442.0,
			"associated_component": "R1", "associated_net": "GND",
		},
		"ann_000004": {   # POLYLINE, human, CUSTOM color, NEITHER, UNKNOWN field
			"id": "ann_000004", "type": "POLYLINE",
			"positions": [{"x": 1.0, "y": 1.0}, {"x": 5.0, "y": 3.0}, {"x": 9.0, "y": 1.0}],
			"text": "route corridor", "color": Color(0.8, 0.1, 0.1).to_html(),
			"author": "human", "created_at": 1745524443.0,
			"associated_component": "", "associated_net": "",
			"blink_rate_hz": 3,   # unknown legacy field → legacy_extra + warning
		},
	}


func _legacy_route_hints() -> Dictionary:
	return {
		"rhint_000001": {   # WAYPOINT, human, DEFAULT color, NO pins → board.point
			"id": "rhint_000001", "hint_type": "WAYPOINT", "detail_level": "SPARSE",
			"layer": "", "width": 0.0, "bus_spacing": 0.0,
			"source_pins": [], "dest_pins": [], "net_names": [],
			"waypoints": [{"x": 40.0, "y": 5.0}, {"x": 48.0, "y": 5.0}],
			"author": "human", "text": "keep off the edge",
			"color": _RHINT_HUMAN.to_html(), "created_at": 1745524450.0, "client_id": "",
		},
		"rhint_000002": {   # SINGLE_TRACE, ai, CUSTOM color, resolvable src → pad
			"id": "rhint_000002", "hint_type": "SINGLE_TRACE", "detail_level": "GUIDED",
			"layer": "F.Cu", "width": 0.25, "bus_spacing": 0.0,
			"source_pins": ["R1.1"], "dest_pins": ["U3.1"], "net_names": ["SIG"],
			"waypoints": [{"x": 10.0, "y": 10.0}, {"x": 30.0, "y": 20.0}],
			"author": "ai", "text": "", "color": Color(0.4, 0.1, 0.9, 0.9).to_html(),
			"created_at": 1745524451.0, "client_id": "idem-abc-123",
		},
		"rhint_000003": {   # BUS, human, DEFAULT color, bus_spacing, resolvable src
			"id": "rhint_000003", "hint_type": "BUS", "detail_level": "DETAILED",
			"layer": "B.Cu", "width": 0.2, "bus_spacing": 0.4,
			"source_pins": ["R1.1", "R1.2"], "dest_pins": ["U3.1", "U3.2"],
			"net_names": ["D0", "D1"],
			"waypoints": [{"x": 10.0, "y": 10.0}, {"x": 20.0, "y": 15.0}, {"x": 30.0, "y": 20.0}],
			"author": "human", "text": "data bus",
			"color": _RHINT_HUMAN.to_html(), "created_at": 1745524452.0, "client_id": "",
		},
	}


# ── 1. Migrate every variant, assert per-envelope shape ───────────────────────

func _test_migrate_all_variants() -> void:
	print("-- migrate all variants → conformant v2 envelopes --")
	var trip: Array = _make_host_with_board()
	var host = trip[0]
	var canvas = trip[1]

	var result: Dictionary = _Migration.migrate(_legacy_annotations(), _legacy_route_hints(), host)
	var expected := _legacy_annotations().size() + _legacy_route_hints().size()  # 7
	check("migrated count == fixture count (all validated on add)",
			int(result.get("migrated", -1)) == expected,
			"got %d expected %d; warnings=%s" % [int(result.get("migrated", -1)), expected, str(result.get("warnings", []))])
	check("host stores exactly the migrated envelopes",
			(host.get_annotations() as Array).size() == expected,
			str((host.get_annotations() as Array).size()))

	# Every stored envelope independently re-validates against the registry.
	var schema = AnnotationV2Schema.new()
	var reg = host.get_registry()
	var all_valid := true
	for ann in host.get_annotations():
		if schema.validate_with_registry(ann, reg).has_errors():
			all_valid = false
	check("every stored envelope passes validate_with_registry", all_valid)

	# ── ARROW (ann_000001): 2d_arrow, human default color, associated_component ──
	var arrow := _by_legacy_id(host, "ann_000001")
	check("arrow: kind 2d_arrow", str(arrow.get("kind", "")) == "2d_arrow")
	check("arrow: author {kind:human}", str(arrow.get("author", {}).get("kind", "")) == "human")
	var a_prims: Array = arrow.get("primitives", [])
	check("arrow: primitive from/to match legacy positions",
			a_prims.size() >= 1 and _vec_eq(a_prims[0].get("from"), [4.0, 4.0]) and _vec_eq(a_prims[0].get("to"), [16.0, 12.0]),
			str(a_prims))
	check("arrow: trailing text primitive carries the label",
			a_prims.size() == 2 and str(a_prims[1].get("content", "")) == "check U3 clearance", str(a_prims))
	check("arrow: DEFAULT color → no payload.color override", not arrow.has("payload"))
	check("arrow: anchor is core/canvas.point at positions[0]",
			str(arrow.get("anchor", {}).get("plugin", "")) == "core"
			and str(arrow.get("anchor", {}).get("type", "")) == "canvas.point"
			and _vec_eq(arrow.get("anchor", {}).get("snapshot", {}).get("position"), [4.0, 4.0]),
			str(arrow.get("anchor", {})))
	check("arrow: associated_component preserved in kind_payload",
			str(arrow.get("kind_payload", {}).get("associated_component", "")) == "U3")
	check("arrow: legacy_id preserved", str(arrow.get("kind_payload", {}).get("legacy_id", "")) == "ann_000001")
	check("arrow: created_at is int", arrow.get("created_at") is int and int(arrow.get("created_at")) == 1745524440)

	# ── TEXT (ann_000002): 2d_text, ai, custom color, associated_net ──
	var text := _by_legacy_id(host, "ann_000002")
	check("text: kind 2d_text", str(text.get("kind", "")) == "2d_text")
	check("text: author {kind:ai}", str(text.get("author", {}).get("kind", "")) == "ai")
	var t_prims: Array = text.get("primitives", [])
	check("text: primitive at/content match",
			t_prims.size() == 1 and _vec_eq(t_prims[0].get("at"), [20.0, 5.0]) and str(t_prims[0].get("content", "")) == "GND pour here",
			str(t_prims))
	check("text: CUSTOM color written to top-level payload.color",
			text.has("payload") and str(text.get("payload", {}).get("color", "")) == Color(0.1, 0.2, 0.3).to_html(),
			str(text.get("payload", {})))
	check("text: associated_net preserved in kind_payload",
			str(text.get("kind_payload", {}).get("associated_net", "")) == "GND")

	# ── REGION (ann_000003): 4-vertex promotion, both associations ──
	var region := _by_legacy_id(host, "ann_000003")
	check("region: kind 2d_region", str(region.get("kind", "")) == "2d_region")
	var r_prims: Array = region.get("primitives", [])
	var r_pts: Array = r_prims[0].get("points", []) if r_prims.size() > 0 else []
	check("region: 2-corner box promoted to 4 vertices",
			r_pts.size() == 4 and _vec_eq(r_pts[0], [2.0, 2.0]) and _vec_eq(r_pts[1], [18.0, 2.0])
			and _vec_eq(r_pts[2], [18.0, 14.0]) and _vec_eq(r_pts[3], [2.0, 14.0]), str(r_pts))
	check("region: DEFAULT color → no payload override", not region.has("payload"))
	check("region: BOTH associations preserved in kind_payload",
			str(region.get("kind_payload", {}).get("associated_component", "")) == "R1"
			and str(region.get("kind_payload", {}).get("associated_net", "")) == "GND",
			str(region.get("kind_payload", {})))

	# ── POLYLINE (ann_000004): custom color, neither assoc, unknown field ──
	var poly := _by_legacy_id(host, "ann_000004")
	check("polyline: kind 2d_polyline", str(poly.get("kind", "")) == "2d_polyline")
	var p_prims: Array = poly.get("primitives", [])
	var p_pts: Array = p_prims[0].get("points", []) if p_prims.size() > 0 else []
	check("polyline: all 3 vertices preserved",
			p_pts.size() == 3 and _vec_eq(p_pts[0], [1.0, 1.0]) and _vec_eq(p_pts[2], [9.0, 1.0]), str(p_pts))
	check("polyline: CUSTOM color written", poly.has("payload") and str(poly.get("payload", {}).get("color", "")) == Color(0.8, 0.1, 0.1).to_html())
	check("polyline: NEITHER association present",
			not poly.get("kind_payload", {}).has("associated_component")
			and not poly.get("kind_payload", {}).has("associated_net"))
	check("polyline: unknown field captured in legacy_extra",
			poly.get("kind_payload", {}).get("legacy_extra", {}).has("blink_rate_hz")
			and int(poly.get("kind_payload", {}).get("legacy_extra", {}).get("blink_rate_hz", -1)) == 3,
			str(poly.get("kind_payload", {}).get("legacy_extra", {})))
	var warn_hit := false
	for w in (result.get("warnings", []) as Array):
		if str(w).find("blink_rate_hz") != -1:
			warn_hit = true
	check("polyline: unknown field raised a warning", warn_hit, str(result.get("warnings", [])))

	# ── WAYPOINT hint (rhint_000001): board.point, no pins ──
	var wp := _by_legacy_id(host, "rhint_000001")
	check("waypoint hint: kind pcb_route_hint", str(wp.get("kind", "")) == "pcb_route_hint")
	check("waypoint hint: hint_type lowercased", str(wp.get("kind_payload", {}).get("hint_type", "")) == "waypoint")
	check("waypoint hint: anchor pcb/board.point at first waypoint",
			str(wp.get("anchor", {}).get("type", "")) == "board.point"
			and _vec_eq(wp.get("anchor", {}).get("snapshot", {}).get("position"), [40.0, 5.0]), str(wp.get("anchor", {})))
	check("waypoint hint: empty layer defaulted to F.Cu", str(wp.get("kind_payload", {}).get("layer", "")) == "F.Cu")

	# ── SINGLE_TRACE hint (rhint_000002): pcb/pad anchor (R1.1 resolves) ──
	var st := _by_legacy_id(host, "rhint_000002")
	check("single_trace: hint_type single_trace", str(st.get("kind_payload", {}).get("hint_type", "")) == "single_trace")
	check("single_trace: anchor upgraded to pcb/pad {R1,1}",
			str(st.get("anchor", {}).get("type", "")) == "pad"
			and str(st.get("anchor", {}).get("id", {}).get("component", "")) == "R1"
			and str(st.get("anchor", {}).get("id", {}).get("pin", "")) == "1", str(st.get("anchor", {})))
	check("single_trace: pad snapshot at live R1.1 world pos (10,10)",
			_vec_eq(st.get("anchor", {}).get("snapshot", {}).get("position"), [10.0, 10.0]),
			str(st.get("anchor", {}).get("snapshot", {})))
	check("single_trace: width→width_mm, pins, detail, client_id, net_names preserved",
			is_equal_approx(float(st.get("kind_payload", {}).get("width_mm", 0.0)), 0.25)
			and (st.get("kind_payload", {}).get("source_pins", []) as Array) == ["R1.1"]
			and (st.get("kind_payload", {}).get("dest_pins", []) as Array) == ["U3.1"]
			and str(st.get("kind_payload", {}).get("detail_level", "")) == "guided"
			and str(st.get("kind_payload", {}).get("client_id", "")) == "idem-abc-123"
			and (st.get("kind_payload", {}).get("net_names", []) as Array) == ["SIG"],
			str(st.get("kind_payload", {})))
	check("single_trace: legacy_id preserved", str(st.get("kind_payload", {}).get("legacy_id", "")) == "rhint_000002")

	# ── BUS hint (rhint_000003): bus_spacing preserved, pad anchor ──
	var bus := _by_legacy_id(host, "rhint_000003")
	check("bus: hint_type bus", str(bus.get("kind_payload", {}).get("hint_type", "")) == "bus")
	check("bus: bus_spacing preserved", is_equal_approx(float(bus.get("kind_payload", {}).get("bus_spacing", 0.0)), 0.4))
	check("bus: anchor pcb/pad (first source pin R1.1 resolves)",
			str(bus.get("anchor", {}).get("type", "")) == "pad"
			and str(bus.get("anchor", {}).get("id", {}).get("component", "")) == "R1", str(bus.get("anchor", {})))

	canvas.free()


# ── 2. Idempotency (function re-run) + round-trip through the sidecar ─────────

func _test_idempotency_and_roundtrip() -> void:
	print("\n-- round-trip: migrate → save_sidecar → fresh host load_sidecar --")
	var trip: Array = _make_host_with_board()
	var host = trip[0]
	var canvas = trip[1]

	var result: Dictionary = _Migration.migrate(_legacy_annotations(), _legacy_route_hints(), host)
	var expected := _legacy_annotations().size() + _legacy_route_hints().size()

	var board_path := _temp_root() + "/pcb_legacy_migration_rt/board.pcbskel"
	DirAccess.make_dir_recursive_absolute(board_path.get_base_dir())
	_cleanup(board_path)

	var save_err: int = host.save_sidecar(board_path)
	check("save_sidecar OK", save_err == OK, "err=%d" % save_err)
	check("sidecar file exists on disk", FileAccess.file_exists(board_path + ".annotations.json"))

	var host2 = _Host.new()   # fresh host, no board bound
	var loaded: int = host2.load_sidecar(board_path)
	check("fresh host load_sidecar restores every envelope", loaded == expected, "loaded=%d" % loaded)

	# Deep checks survive the round-trip.
	var arrow := _by_legacy_id(host2, "ann_000001")
	check("round-trip: arrow kind + legacy_id + associated_component survive",
			str(arrow.get("kind", "")) == "2d_arrow"
			and str(arrow.get("kind_payload", {}).get("legacy_id", "")) == "ann_000001"
			and str(arrow.get("kind_payload", {}).get("associated_component", "")) == "U3", str(arrow))
	var st := _by_legacy_id(host2, "rhint_000002")
	check("round-trip: pad-anchored route hint + client_id survive",
			str(st.get("anchor", {}).get("type", "")) == "pad"
			and str(st.get("kind_payload", {}).get("client_id", "")) == "idem-abc-123", str(st))

	_cleanup(board_path)
	canvas.free()


# ── 3. Panel-level hook: sidecar write, no dirty, count, idempotency ──────────

func _test_panel_level_hook() -> void:
	print("\n-- panel-level: legacy load writes sidecar, tab stays clean, idempotent --")
	var Panel: Script = load(PANEL_PATH)
	var driver = load(DRIVER_PATH).new()
	check("panel + driver load", Panel != null and driver != null)
	if Panel == null:
		return

	var panel = driver.load_panel(PANEL_PATH)
	check("panel instantiates", panel != null)
	if panel == null:
		return

	var board_dir: String = driver.make_temp_board_dir("pcb_legacy_migration_panel")
	var board_path := board_dir + "/legacy.pcbskel"
	driver.cleanup_sidecar(board_path)

	# content_changed must stay silent (migration is restore-class, gated by _restoring).
	var spy := {"dirty": 0}
	panel.content_changed.connect(func() -> void: spy.dirty += 1)

	# A legacy-shaped document: board fields + inline annotations/route_hints.
	var doc := {
		"version": 1, "name": "Legacy", "width_mm": 60.0, "height_mm": 40.0,
		"components": [],
		"annotations": _legacy_annotations(),
		"route_hints": _legacy_route_hints(),
	}
	var expected := _legacy_annotations().size() + _legacy_route_hints().size()

	driver.drive_load_merged(panel, board_path, doc)

	check("panel migration wrote the sidecar", FileAccess.file_exists(board_path + ".annotations.json"))
	var summary: Dictionary = panel.get_last_migration_summary()
	check("panel migration count == fixture count", int(summary.get("migrated", -1)) == expected,
			"got %d expected %d" % [int(summary.get("migrated", -1)), expected])
	check("panel host holds the migrated envelopes",
			(panel.get_annotation_host().get_annotations() as Array).size() == expected)
	check("tab NOT dirtied by migration (content_changed silent)", spy.dirty == 0, "dirty=%d" % spy.dirty)

	# Idempotency: a SECOND load sees the sidecar → migration skipped, no duplicates.
	var second = load(PANEL_PATH).new()
	second.content_changed.connect(func() -> void: pass)
	driver.drive_load_merged(second, board_path, doc)
	check("idempotent: 2nd load with sidecar present → NOT re-migrated",
			int(second.get_last_migration_summary().get("migrated", -1)) == 0,
			str(second.get_last_migration_summary()))
	check("idempotent: 2nd load host count == N (no duplicates)",
			(second.get_annotation_host().get_annotations() as Array).size() == expected,
			str((second.get_annotation_host().get_annotations() as Array).size()))

	driver.cleanup_sidecar(board_path)
	driver.cleanup_board_file(board_path)
	driver.free_panel(panel)
	driver.free_panel(second)


# ── helpers ───────────────────────────────────────────────────────────────────

func _by_legacy_id(host, legacy_id: String) -> Dictionary:
	for ann in host.get_annotations():
		if ann is Dictionary and str((ann as Dictionary).get("kind_payload", {}).get("legacy_id", "")) == legacy_id:
			return ann
	return {}


func _vec_eq(v: Variant, expected: Array) -> bool:
	if not v is Array or (v as Array).size() < 2:
		return false
	return is_equal_approx(float(v[0]), float(expected[0])) and is_equal_approx(float(v[1]), float(expected[1]))


func _temp_root() -> String:
	var t: String = OS.get_environment("TEMP")
	if t == "":
		t = OS.get_environment("TMP")
	if t == "":
		t = OS.get_user_data_dir()
	return t.replace("\\", "/")


func _cleanup(board_path: String) -> void:
	var sc := board_path + ".annotations.json"
	if FileAccess.file_exists(sc):
		DirAccess.remove_absolute(sc)


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

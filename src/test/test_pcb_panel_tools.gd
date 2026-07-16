extends SceneTree
## Unit tests for MCPPcbPanelTools — the re-homed PCB plugin-panel MCP surface.
## Docket: minerva 019eb47e72a7 · DCR 019dc140.
##
## Run: godot --headless --path src --script test/test_pcb_panel_tools.gd
##
## Drives EVERY panel-local tool through the module's handle() (not the MCP
## transport) against a REAL PcbAnnotationHost + PCBPanel board model, registered
## in AnnotationHostRegistry headless. Asserts args-in / JSON-out / model-state
## mutation, queries, journal, CSV + geometry round-trips, snapshot null-safety,
## and the missing-editor error shape. Five tools (add/move/get_components,
## spatial_query, describe_component) also assert field-by-field GOLDEN PARITY
## against the legacy MCPPCBTools return shapes (encoded as fixtures) — the DCR
## acceptance is "identical from the agent's perspective".
##
## Off-tree: the plugin scripts live outside res://; every panel/host/model ref is
## duck-typed and loaded by path (never typed AS a plugin class).
##
## C2 migration (docket 019f6c45f09e): the 16 wave-1 tools below moved to the
## pcb plugin's own panel_tools.gd (executor "panel") and are no longer
## registered/handled by MODULE. The `h()` dispatch helper routes those names
## through panel.handle_tool(tool_name, args) directly — the same plugin-side
## entry point PluginToolRegistry.handle_tool_call forwards to once it has
## resolved editor_name -> this panel (contract §2.2/§2.3); panel.handle_tool
## is a plain synchronous call for these tools (no internal await), so this
## keeps every existing `h(...)` call site in this file unchanged (no `await`
## threading needed — GDScript's static analyzer only forces "await" on calls
## it can prove are coroutines, and panel.handle_tool for wave-1 tools isn't
## one). The two editor_name-validation checks in _run_error_shapes() below
## are DISPATCHER-boundary behavior now (PluginToolRegistry.handle_tool_call
## rejects a missing/unknown editor_name before ever reaching panel_tools.gd),
## so those two specific calls route through the REAL registry instead
## (test/helpers/panel_tool_registry_driver.gd, mirroring
## test_panel_executed_tools.gd's fixture wiring) with assertions adjusted to
## the dispatcher's structured PluginErrors shape (error_message, not the old
## panel-level _err()'s "error" key) — that one function is async as a result.
## WAVE-2 tool names still dispatch through MODULE.handle() directly
## (get_change_journal, export/import_trace_geometry, get_image — unaffected).

const MODULE := preload("res://Scripts/Services/MCP/Modules/MCPPcbPanelTools.gd")
const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const DRIVER := preload("res://test/helpers/plugin_panel_driver.gd")
const REGISTRY_DRIVER := preload("res://test/helpers/panel_tool_registry_driver.gd")
const PCB_PLUGIN_ID := "pcb"

## The 16 wave-1 tool names — moved to pcb/ui/panel_tools.gd this round.
const _WAVE1_TOOLS: Array[String] = [
	"minerva_pcb_set_board_size",
	"minerva_pcb_get_components",
	"minerva_pcb_get_nets",
	"minerva_pcb_get_pin_position",
	"minerva_pcb_pin_info",
	"minerva_pcb_add_component",
	"minerva_pcb_move_component",
	"minerva_pcb_move_relative",
	"minerva_pcb_rotate_component",
	"minerva_pcb_delete_component",
	"minerva_pcb_connect_net",
	"minerva_pcb_spatial_query",
	"minerva_pcb_describe_component",
	"minerva_pcb_import_csv",
	"minerva_pcb_export_csv",
	"minerva_pcb_import_footprint_geometry",
]

const EDITOR := "PCB1"

var _pass := 0
var _fail := 0

var tools
var panel      # PCBPanel (duck-typed Node)
var host       # PcbAnnotationHost (duck-typed)
var data       # pcb_data model (duck-typed)
var registry: PluginToolRegistry = null


func _init() -> void:
	print("=== MCPPcbPanelTools Tests ===\n")
	tools = MODULE.new(null)  # server=null — register_tools() not exercised; handle() is server-free.

	if not _setup():
		printerr("SETUP FAILED — cannot load plugin panel; aborting")
		quit(1)
		return

	_run_queries_and_mutations()
	_run_golden_parity()
	_run_roundtrips()
	await _run_error_shapes()
	_run_get_image()

	_teardown()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── setup / teardown ──────────────────────────────────────────────────────────

func _setup() -> bool:
	var driver = DRIVER.new()
	panel = driver.load_panel(PANEL_PATH)
	if panel == null:
		return false
	host = panel.get_annotation_host()
	if host == null:
		return false
	# Wire the panel as the host's data source (mount normally does this via the
	# canvas; headless we bind the panel back-reference so get_board_data works).
	host.set_panel(panel)
	data = panel.get_data()
	if data == null:
		return false
	data.clear()  # start from a known-blank board for deterministic assertions

	AnnotationHostRegistry._reset_for_test()
	AnnotationHostRegistry.register(EDITOR, host)

	registry = REGISTRY_DRIVER.new().build(panel, PCB_PLUGIN_ID, EDITOR, _WAVE1_TOOLS)
	return registry != null


func _teardown() -> void:
	AnnotationHostRegistry._reset_for_test()
	if panel is Node:
		(panel as Node).free()


# ── assertion helpers ─────────────────────────────────────────────────────────

func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)


func check_approx(desc: String, actual: float, expected: float) -> void:
	check("%s (expected ~%s, got %s)" % [desc, str(expected), str(actual)], absf(actual - expected) < 0.001)


## Assert a result's key set exactly equals `expected` (order-independent).
func check_keys(desc: String, result: Dictionary, expected: Array) -> void:
	var got := result.keys()
	got.sort()
	var want := expected.duplicate()
	want.sort()
	check("%s — keys %s == %s" % [desc, str(got), str(want)], got == want)


func h(tool_name: String, args: Dictionary) -> Dictionary:
	if _WAVE1_TOOLS.has(tool_name):
		return panel.handle_tool(tool_name, args)
	return tools.handle(tool_name, args)


func _args(extra: Dictionary = {}) -> Dictionary:
	var a := {"editor_name": EDITOR}
	a.merge(extra, true)
	return a


# ── queries + mutations ───────────────────────────────────────────────────────

func _run_queries_and_mutations() -> void:
	print("-- set_board_size --")
	var r := h("minerva_pcb_set_board_size", _args({"width": 100.0, "height": 80.0}))
	check("set_board_size ok", r.get("success", false))
	check_approx("board_width=100", float(r.get("board_width", 0)), 100.0)
	check_approx("model board_width mutated", data.board_width, 100.0)
	check_approx("model board_height mutated", data.board_height, 80.0)

	print("\n-- add_component (IC_DIP) --")
	var add := h("minerva_pcb_add_component", _args({"id": "U9", "footprint": "IC_DIP", "x": 20.0, "y": 10.0}))
	check("add ok", add.get("success", false))
	check_eq("component in model", data.has_component("U9"), true)
	check("pin_count > 0", int(add.get("pin_count", 0)) > 0)

	print("\n-- add_component (RESISTOR with value) --")
	var addr := h("minerva_pcb_add_component", _args({"id": "R7", "footprint": "RESISTOR", "x": 40.0, "y": 30.0, "value": "10K"}))
	check("add R7 ok", addr.get("success", false))
	check_eq("R7 value stored", data.get_component("R7").properties.get("value", ""), "10K")

	print("\n-- add_component invalid footprint --")
	var bad := h("minerva_pcb_add_component", _args({"footprint": "BOGUS", "x": 1.0, "y": 1.0}))
	check("invalid footprint rejected", bad.get("success", true) == false)

	print("\n-- move_component --")
	var mv := h("minerva_pcb_move_component", _args({"component_id": "U9", "x": 22.0, "y": 12.0}))
	check("move ok", mv.get("success", false))
	var snapped_pos: Vector2 = data.snap_to_grid(Vector2(22.0, 12.0))
	check_approx("moved x snapped", float(mv.get("x", -1)), snapped_pos.x)
	check_approx("model x mutated", data.get_component("U9").position.x, snapped_pos.x)

	print("\n-- rotate_component --")
	var rot := h("minerva_pcb_rotate_component", _args({"component_id": "U9", "degrees": 90}))
	check("rotate ok", rot.get("success", false))
	check_approx("model rotation mutated", data.get_component("U9").rotation, 90.0)

	print("\n-- move_relative --")
	var mr := h("minerva_pcb_move_relative", _args({"component_id": "R7", "direction": "right"}))
	check("move_relative ok", mr.get("success", false))
	check("interpreted_direction echoed", str(mr.get("interpreted_direction", "")) == "right")
	check("new_x present", mr.has("new_x"))

	print("\n-- get_pin_position --")
	var pp := h("minerva_pcb_get_pin_position", _args({"component_id": "U9", "pin": "1"}))
	check("pin pos ok", pp.get("success", false))
	check("world_position present", pp.has("world_position"))
	check("available_pins array", pp.get("available_pins", null) is Array)
	var pp_bad := h("minerva_pcb_get_pin_position", _args({"component_id": "U9", "pin": "ZZZ"}))
	check("bad pin rejected", pp_bad.get("success", true) == false)
	check("bad pin returns available_pins", pp_bad.get("available_pins", null) is Array)

	print("\n-- connect_net + get_nets --")
	var cn := h("minerva_pcb_connect_net", _args({"net_name": "VCC", "pins": [
		{"component": "U9", "pin": "1"}, {"component": "R7", "pin": "1"}]}))
	check("connect ok", cn.get("success", false))
	check_eq("connected_pins count", (cn.get("connected_pins", []) as Array).size(), 2)
	check_eq("net created in model", data.has_net("VCC"), true)
	var nets := h("minerva_pcb_get_nets", _args())
	check("get_nets ok", nets.get("success", false))
	check_eq("net_count=1", int(nets.get("net_count", 0)), 1)
	var net0: Dictionary = (nets.get("nets", []) as Array)[0]
	check_eq("net name VCC", net0.get("name", ""), "VCC")
	check("net pins are Comp.Pin strings", (net0.get("pins", []) as Array).has("U9.1"))

	print("\n-- get_change_journal reflects mutations --")
	var jr := h("minerva_pcb_get_change_journal", _args())
	check("journal ok", jr.get("success", false))
	check("journal has entries", int(jr.get("total_entries", 0)) > 0)
	var actions: Array = []
	for e in (jr.get("entries", []) as Array):
		actions.append(str((e as Dictionary).get("action", "")))
	check("journal recorded add_component", actions.has("add_component"))
	check("journal recorded move_component", actions.has("move_component"))
	check("journal recorded connect_net", actions.has("connect_net"))

	print("\n-- delete_component --")
	var dl := h("minerva_pcb_delete_component", _args({"component_id": "R7"}))
	check("delete ok", dl.get("success", false))
	check_eq("R7 removed from model", data.has_component("R7"), false)


# ── golden parity (5 tools, field-by-field) ───────────────────────────────────

func _run_golden_parity() -> void:
	print("\n-- GOLDEN: get_components shape --")
	# Legacy MCPPCBTools._pcb_get_components → {success, component_count, components}
	# each component → {id, footprint, x, y, rotation, layer, pins} (+ value?).
	var gc := h("minerva_pcb_get_components", _args())
	check_keys("get_components top-level", gc, ["success", "component_count", "components"])
	var comps: Array = gc.get("components", [])
	check("components non-empty", comps.size() > 0)
	if comps.size() > 0:
		var c0: Dictionary = comps[0]
		# U9 has no value → exactly the 7-key base shape.
		check_keys("component entry (no value)", c0, ["id", "footprint", "x", "y", "rotation", "layer", "pins"])
		check("footprint is a name string", str(c0.get("footprint", "")) == "IC_DIP")
		check("pins is Array", c0.get("pins", null) is Array)

	print("\n-- GOLDEN: add_component shape --")
	# Legacy → {success, component_id, x, y, pin_count}
	var ga := h("minerva_pcb_add_component", _args({"id": "C3", "footprint": "CAPACITOR", "x": 10.0, "y": 50.0}))
	check_keys("add_component result", ga, ["success", "component_id", "x", "y", "pin_count"])
	check_eq("component_id echoed", ga.get("component_id", ""), "C3")

	print("\n-- GOLDEN: move_component shape --")
	# Legacy → {success, component_id, x, y}
	var gm := h("minerva_pcb_move_component", _args({"component_id": "C3", "x": 12.0, "y": 52.0}))
	check_keys("move_component result", gm, ["success", "component_id", "x", "y"])

	print("\n-- GOLDEN: spatial_query shape --")
	# Legacy → {success, reference, radius_mm, nearby_count, nearby:[{id, relationship}]}
	var gs := h("minerva_pcb_spatial_query", _args({"reference_component": "U9", "radius_mm": 100.0}))
	check_keys("spatial_query result", gs, ["success", "reference", "radius_mm", "nearby_count", "nearby"])
	var nearby: Array = gs.get("nearby", [])
	if nearby.size() > 0:
		check_keys("nearby entry", nearby[0], ["id", "relationship"])
		check("relationship is String", nearby[0].get("relationship", null) is String)
	# empty reference → falls back to get_components shape (legacy behaviour).
	var gs_empty := h("minerva_pcb_spatial_query", _args())
	check_keys("spatial_query no-ref → get_components shape", gs_empty,
		["success", "component_count", "components"])

	print("\n-- GOLDEN: describe_component shape --")
	# Legacy → describe_component_context(id) + success. Base keys:
	# {id, value, position, rotation, footprint, layer, nearby, connected_to, region, pins}
	# (+ properties when the component has any; success added by the tool).
	var gd := h("minerva_pcb_describe_component", _args({"component_id": "U9"}))
	check("describe ok", gd.get("success", false))
	for k in ["id", "position", "rotation", "footprint", "layer", "nearby", "connected_to", "region", "pins"]:
		check("describe has '%s'" % k, gd.has(k))
	check("describe position is {x,y}", (gd.get("position", {}) as Dictionary).has("x"))
	var gd_missing := h("minerva_pcb_describe_component", _args({"component_id": "NOPE"}))
	check("describe missing component → error", gd_missing.get("success", true) == false)


# ── CSV + geometry round-trips ────────────────────────────────────────────────

func _run_roundtrips() -> void:
	print("\n-- CSV round-trip --")
	var ex := h("minerva_pcb_export_csv", _args())
	check("export_csv ok", ex.get("success", false))
	var csv := str(ex.get("csv", ""))
	check("csv has header", csv.begins_with("id,footprint,x,y,rotation,layer,value"))
	check("csv mentions U9", csv.contains("U9"))
	# Import into a blank board and confirm the component count round-trips.
	var before_ids: Array = data.get_component_ids()
	var im := h("minerva_pcb_import_csv", _args({"csv_content": csv}))
	check("import_csv ok", im.get("success", false))
	check_eq("import restored same count", int(im.get("component_count", -1)), before_ids.size())

	print("\n-- footprint geometry import --")
	var geom := {
		"board_name": "TestBoard",
		"components": {
			"U9": {
				"footprint_id": "Package_DIP:DIP-8_W7.62mm",
				"footprint_found": true,
				"bounding_box": {"width": 9.0, "height": 6.0, "center_x": 3.81, "center_y": 3.81},
				"pads": [
					{"number": "1", "type": "thru_hole", "shape": "circle",
						"position": {"x": 0.0, "y": 0.0}, "size": {"width": 1.6, "height": 1.6}, "drill": 0.8, "layers": ["*.Cu"]},
				],
			},
		},
	}
	var fg := h("minerva_pcb_import_footprint_geometry", _args({"geometry": geom}))
	check("footprint import ok", fg.get("success", false))
	check_eq("updated_count=1", int(fg.get("updated_count", 0)), 1)
	check("U9 has pad geometry", data.get_component("U9").has_pad_geometry)

	print("\n-- trace geometry round-trip --")
	var tin := {
		"traces": [
			{"start": {"x": 0.0, "y": 0.0}, "end": {"x": 5.0, "y": 0.0}, "width": 0.25, "layer": "F.Cu", "net_name": "GND"},
			{"start": {"x": 5.0, "y": 0.0}, "end": {"x": 10.0, "y": 0.0}, "width": 0.25, "layer": "F.Cu", "net_name": "GND"},
		],
		"vias": [
			{"position": {"x": 10.0, "y": 0.0}, "size": 0.8, "drill": 0.4, "net_name": "GND", "layers": ["F.Cu", "B.Cu"]},
		],
	}
	var ti := h("minerva_pcb_import_trace_geometry", _args({"trace_data": tin}))
	check("trace import ok", ti.get("success", false))
	check("traces created", int(ti.get("trace_count", 0)) >= 1)
	check_eq("one via imported", int(ti.get("via_count", 0)), 1)
	check("model has traces", data.get_trace_count() >= 1)
	var te := h("minerva_pcb_export_trace_geometry", _args())
	check("trace export ok", te.get("success", false))
	var td: Dictionary = te.get("trace_data", {})
	check("export has traces", (td.get("traces", []) as Array).size() >= 1)
	check_eq("export via count", (td.get("vias", []) as Array).size(), 1)
	# Segments round-trip: 2 collinear input segments merge into one 3-point
	# polyline, which re-expands to exactly 2 output segments.
	check_eq("segments re-expand to 2", (td.get("traces", []) as Array).size(), 2)


# ── error shapes ──────────────────────────────────────────────────────────────

func _run_error_shapes() -> void:
	print("\n-- missing editor_name --")
	# Crosses the DISPATCHER boundary now (PluginToolRegistry.handle_tool_call
	# rejects a missing/unknown editor_name before ever reaching
	# panel_tools.gd — contract §2.2), so these two checks route through the
	# REAL registry instead of the h()/panel.handle_tool shortcut the rest of
	# this suite uses. Shape is PluginErrors.editor_name_required /
	# editor_not_found, not panel_tools.gd's own _err(); success=false still
	# holds, only the message field name changed (error_message, not "error").
	var e1: Dictionary = await registry.handle_tool_call("minerva_pcb_get_components", {})
	check("no editor_name → error", e1.get("success", true) == false)
	check("no editor_name → editor_name_required", e1.get("error_code", "") == "editor_name_required")

	print("\n-- missing host (unknown editor) matches the dispatcher convention --")
	# Same "structured error naming the editor + known editors" contract the
	# old MCPCadTools-style _no_host_error UX gave, just under error_message/
	# known_editors instead of a single "error" string.
	var e2: Dictionary = await registry.handle_tool_call("minerva_pcb_get_components", {"editor_name": "GhostBoard"})
	check("unknown editor → success=false", e2.get("success", true) == false)
	check("unknown editor → editor_not_found", e2.get("error_code", "") == "editor_not_found")
	check("error names the editor", str(e2.get("error_message", "")).contains("GhostBoard"))
	check("error lists known editors", str(e2.get("error_message", "")).contains("Known editors"))

	print("\n-- component not found --")
	var e3 := h("minerva_pcb_move_component", _args({"component_id": "NOSUCH", "x": 1.0, "y": 1.0}))
	check("missing component → error", e3.get("success", true) == false)


# ── snapshot (headless null-safety) ───────────────────────────────────────────

func _run_get_image() -> void:
	print("\n-- get_image (headless null-or-image, no crash) --")
	var gi := h("minerva_pcb_get_image", _args())
	check("get_image returns success", gi.get("success", false))
	var img = gi.get("image_data", "SENTINEL")
	check("image_data is null or a base64 String (headless)", img == null or img is String)
	check("metadata present", gi.get("metadata", null) is Dictionary)

extends SceneTree
## Wave-1 panel-executed tools migration gate (DCR 019f6c3d0e3d, C2 round,
## docket 019f6c45f09e).
##
## Run: godot --headless --path src --script test/test_pcb_panel_tools_migration.gd
##
## Proves the C2 migration contract for the 16 wave-1 pcb tools (set_board_size
## … import_footprint_geometry, Docs/design/panel-executed-tools.md §3):
##   (1) each dispatches through the REAL PluginToolRegistry.handle_tool_call
##       path (executor "panel") against a REAL PCBPanel + PcbAnnotationHost —
##       PluginToolRegistry -> PluginScenePanelBroker -> PCBPanel.handle_tool
##       -> pcb/ui/panel_tools.gd, end to end, no subprocess required;
##   (2) each answers with the SAME result shape test_pcb_panel_tools.gd
##       asserted before the migration (spot-checked field-by-field — this is
##       not a full re-run of that suite, just the shape-parity proof);
##   (3) MCPPcbPanelTools (Minerva core) no longer registers or handles any of
##       the 16 names — get_tool_names() omits them and handle() falls through
##       to the "Unknown PCB panel tool" error.
##
## REUSE SCAN: fixture stack (registry+broker+manifest-shaped tool dicts) via
## test/helpers/panel_tool_registry_driver.gd (new this round, shared with the
## mechanical test_pcb_pin_inspector.gd edit). Panel/board setup mirrors
## test_pcb_panel_tools.gd's plugin_panel_driver usage.

const MODULE := preload("res://Scripts/Services/MCP/Modules/MCPPcbPanelTools.gd")
const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const DRIVER := preload("res://test/helpers/plugin_panel_driver.gd")
const REGISTRY_DRIVER := preload("res://test/helpers/panel_tool_registry_driver.gd")

const EDITOR := "PCBWave1Migration"
const PCB_PLUGIN_ID := "pcb"

## The 16 wave-1 tool names — the exact migration table from
## Docs/design/panel-executed-tools.md §3.
const WAVE1_TOOLS: Array[String] = [
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

var _pass := 0
var _fail := 0

var panel      # PCBPanel (duck-typed Node)
var host       # PcbAnnotationHost (duck-typed)
var data       # pcb_data model (duck-typed)
var registry: PluginToolRegistry = null


func _init() -> void:
	print("=== PCB Wave-1 Panel-Tools Migration Gate (C2) ===\n")

	if not _setup():
		printerr("SETUP FAILED — cannot load plugin panel; aborting")
		quit(1)
		return

	await _run_dispatch_and_shape_checks()
	await _run_core_module_no_longer_handles_wave1()

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
	host.set_panel(panel)  # bind the model source (headless: no canvas)
	data = panel.get_data()
	if data == null:
		return false
	data.clear()  # start from a known-blank board for deterministic assertions

	AnnotationHostRegistry._reset_for_test()
	AnnotationHostRegistry.register(EDITOR, host)

	registry = REGISTRY_DRIVER.new().build(panel, PCB_PLUGIN_ID, EDITOR, WAVE1_TOOLS)
	return registry != null


func _teardown() -> void:
	AnnotationHostRegistry._reset_for_test()
	if panel is Node:
		(panel as Node).free()


# ── assertion helpers ─────────────────────────────────────────────────────────

func check(desc: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		if detail.is_empty():
			printerr("  FAIL: %s" % desc)
		else:
			printerr("  FAIL: %s — %s" % [desc, detail])


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


func _args(extra: Dictionary = {}) -> Dictionary:
	var a := {"editor_name": EDITOR}
	a.merge(extra, true)
	return a


## Dispatch through the REAL PluginToolRegistry — this is the (1) proof: every
## call in this suite goes through handle_tool_call, never panel_tools.gd or
## PCBPanel.handle_tool directly.
func d(tool_name: String, args: Dictionary) -> Dictionary:
	return await registry.handle_tool_call(tool_name, args)


# ── (1) + (2): dispatch through the real registry, spot-check shapes ─────────

func _run_dispatch_and_shape_checks() -> void:
	print("-- set_board_size --")
	var r := await d("minerva_pcb_set_board_size", _args({"width": 100.0, "height": 80.0}))
	check("set_board_size dispatched ok", r.get("success", false), str(r))
	check_keys("set_board_size shape", r, ["success", "board_width", "board_height"])
	check_approx("model board_width mutated", data.board_width, 100.0)
	check_approx("model board_height mutated", data.board_height, 80.0)

	print("\n-- add_component --")
	var add := await d("minerva_pcb_add_component", _args({"id": "U9", "footprint": "IC_DIP", "x": 20.0, "y": 10.0}))
	check("add_component dispatched ok", add.get("success", false), str(add))
	check_keys("add_component shape", add, ["success", "component_id", "x", "y", "pin_count"])
	check("component landed in the model", data.has_component("U9"))

	print("\n-- add_component invalid footprint --")
	var bad := await d("minerva_pcb_add_component", _args({"footprint": "BOGUS", "x": 1.0, "y": 1.0}))
	check("invalid footprint rejected through the dispatcher", bad.get("success", true) == false, str(bad))

	print("\n-- get_components --")
	var gc := await d("minerva_pcb_get_components", _args())
	check_keys("get_components shape", gc, ["success", "component_count", "components"])
	check("get_components sees U9", (gc.get("components", []) as Array).size() >= 1)
	var c0: Dictionary = (gc.get("components", []) as Array)[0]
	check_keys("get_components entry shape", c0, ["id", "footprint", "x", "y", "rotation", "layer", "pins"])

	print("\n-- move_component --")
	var mv := await d("minerva_pcb_move_component", _args({"component_id": "U9", "x": 22.0, "y": 12.0}))
	check_keys("move_component shape", mv, ["success", "component_id", "x", "y"])
	var snapped_pos: Vector2 = data.snap_to_grid(Vector2(22.0, 12.0))
	check_approx("model x mutated (snapped)", data.get_component("U9").position.x, snapped_pos.x)

	print("\n-- move_relative --")
	var mr := await d("minerva_pcb_move_relative", _args({"component_id": "U9", "direction": "right"}))
	check("move_relative dispatched ok", mr.get("success", false), str(mr))
	check_keys("move_relative shape", mr, ["success", "component_id", "new_x", "new_y", "interpreted_direction"])
	check("move_relative echoes direction", str(mr.get("interpreted_direction", "")) == "right")

	print("\n-- rotate_component --")
	var rot := await d("minerva_pcb_rotate_component", _args({"component_id": "U9", "degrees": 90}))
	check_keys("rotate_component shape", rot, ["success", "component_id", "rotation"])
	check_approx("model rotation mutated", data.get_component("U9").rotation, 90.0)

	print("\n-- get_pin_position --")
	var pp := await d("minerva_pcb_get_pin_position", _args({"component_id": "U9", "pin": "1"}))
	check("get_pin_position dispatched ok", pp.get("success", false), str(pp))
	check("world_position present", pp.has("world_position"))
	var pp_bad := await d("minerva_pcb_get_pin_position", _args({"component_id": "U9", "pin": "ZZZ"}))
	check("bad pin rejected through the dispatcher", pp_bad.get("success", true) == false, str(pp_bad))

	print("\n-- pin_info --")
	var pi := await d("minerva_pcb_pin_info", _args({"ref": "U9.1"}))
	check("pin_info dispatched ok", pi.get("success", false), str(pi))
	check("pin_info has display_name", pi.has("display_name"))

	print("\n-- connect_net + get_nets --")
	var cn := await d("minerva_pcb_connect_net", _args({"net_name": "VCC", "pins": [{"component": "U9", "pin": "1"}]}))
	check("connect_net dispatched ok", cn.get("success", false), str(cn))
	check("VCC net exists in model", data.has_net("VCC"))
	var nets := await d("minerva_pcb_get_nets", _args())
	check_keys("get_nets shape", nets, ["success", "net_count", "nets"])
	check_eq("net_count=1", int(nets.get("net_count", 0)), 1)

	print("\n-- spatial_query + describe_component --")
	var sq := await d("minerva_pcb_spatial_query", _args({"reference_component": "U9", "radius_mm": 100.0}))
	check_keys("spatial_query shape", sq, ["success", "reference", "radius_mm", "nearby_count", "nearby"])
	# empty reference → falls back to get_components shape (legacy behaviour,
	# still true post-migration since both live in the same panel_tools.gd).
	var sq_empty := await d("minerva_pcb_spatial_query", _args())
	check_keys("spatial_query no-ref -> get_components shape", sq_empty,
		["success", "component_count", "components"])
	var dc := await d("minerva_pcb_describe_component", _args({"component_id": "U9"}))
	check("describe_component dispatched ok", dc.get("success", false), str(dc))
	for k in ["id", "position", "rotation", "footprint", "layer", "nearby", "connected_to", "region", "pins"]:
		check("describe_component has '%s'" % k, dc.has(k))

	print("\n-- CSV round-trip --")
	var ex := await d("minerva_pcb_export_csv", _args())
	check_keys("export_csv shape", ex, ["success", "csv"])
	check("csv has header", str(ex.get("csv", "")).begins_with("id,footprint,x,y,rotation,layer,value"))
	var im := await d("minerva_pcb_import_csv", _args({"csv_content": str(ex.get("csv", ""))}))
	check_keys("import_csv shape", im, ["success", "component_count"])

	print("\n-- import_footprint_geometry --")
	var geom := {
		"board_name": "MigrationTest",
		"components": {
			"U9": {
				"footprint_id": "Package_DIP:DIP-8_W7.62mm",
				"footprint_found": true,
				"bounding_box": {"width": 9.0, "height": 6.0, "center_x": 3.81, "center_y": 3.81},
				"pads": [{"number": "1", "type": "thru_hole", "shape": "circle",
					"position": {"x": 0.0, "y": 0.0}, "size": {"width": 1.6, "height": 1.6}, "drill": 0.8, "layers": ["*.Cu"]}],
			},
		},
	}
	var fg := await d("minerva_pcb_import_footprint_geometry", _args({"geometry": geom}))
	check("import_footprint_geometry dispatched ok", fg.get("success", false), str(fg))
	check_eq("updated_count=1", int(fg.get("updated_count", 0)), 1)
	check("U9 has pad geometry", data.get_component("U9").has_pad_geometry)

	print("\n-- delete_component --")
	var dl := await d("minerva_pcb_delete_component", _args({"component_id": "U9"}))
	check_keys("delete_component shape", dl, ["success", "deleted"])
	check("component removed from model", not data.has_component("U9"))

	print("\n-- error shapes proven through the dispatcher --")
	var e_missing := await d("minerva_pcb_get_components", {})
	check("missing editor_name -> dispatcher structured error",
		not bool(e_missing.get("success", true)) and e_missing.get("error_code", "") == "editor_name_required",
		str(e_missing))


# ── (3): core module no longer registers/handles wave-1 names ───────────────

func _run_core_module_no_longer_handles_wave1() -> void:
	print("\n-- core module no longer owns wave-1 tools --")
	var core_tools = MODULE.new(null)  # server=null — handle() is server-free.
	var names: Array = core_tools.get_tool_names()
	for name in WAVE1_TOOLS:
		check("core get_tool_names() omits %s" % name, not names.has(name))

	# handle() is a coroutine (one wave-2 branch awaits the router) — Godot's
	# static analyzer requires "await" at every call site once the target
	# type is known (core_tools is inferred MCPPcbPanelTools from MODULE.new()).
	var r: Dictionary = await core_tools.handle("minerva_pcb_get_components", _args())
	check("core handle() no longer answers a wave-1 name",
		not bool(r.get("success", true)) and str(r.get("error", "")).begins_with("Unknown PCB panel tool"),
		str(r))

	# Wave-2 names must still be both registered and handled — the module
	# keeps working for the tools that stay this round (contract deliverable 4).
	var wave2_names := ["minerva_pcb_get_change_journal", "minerva_pcb_import_trace_geometry",
		"minerva_pcb_export_trace_geometry", "minerva_pcb_get_image", "minerva_pcb_apply_route_hints"]
	for name in wave2_names:
		check("core get_tool_names() still carries wave-2 %s" % name, names.has(name))

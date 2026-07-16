extends SceneTree
## PCB panel-executed tools migration gate — waves 1 + 2 + core deletion
## (DCR 019f6c3d0e3d; wave 1 C2 round docket 019f6c45f09e; wave 2 + core
## deletion C3 round docket 019f6c4604ba).
##
## Run: godot --headless --path src --script test/test_pcb_panel_tools_migration.gd
##
## Proves the FULL migration contract for all 21 pcb panel tools
## (Docs/design/panel-executed-tools.md §3):
##   (1) every tool dispatches through the REAL PluginToolRegistry.handle_tool_call
##       path (executor "panel") against a REAL PCBPanel + PcbAnnotationHost —
##       PluginToolRegistry -> PluginScenePanelBroker -> PCBPanel.handle_tool
##       -> pcb/ui/panel_tools.gd, end to end, no subprocess required;
##   (2) each answers with the SAME result shape the pre-migration suites
##       asserted (spot-checked field-by-field);
##   (3) E2E-P3 (contract §5): MCPPcbPanelTools.gd is DELETED from Minerva
##       core (file-existence check — the resource is gone, so this test
##       never preloads it) and a source-grep sweep of src/Scripts proves
##       zero pcb workflow semantics leaked into core (the generic annotation
##       substrate's illustrative "e.g. pcb_route_hint" doc-comment mentions
##       are allow-listed — they own no PCB-specific logic).
##
## REUSE SCAN: fixture stack (registry+broker+manifest-shaped tool dicts) via
## test/helpers/panel_tool_registry_driver.gd (C2). Panel/board setup mirrors
## test_pcb_panel_tools.gd's plugin_panel_driver usage. Wave-2 shape checks
## mirror test_pcb_panel_tools.gd's pre-migration assertions (journal has
## entries, CSV/trace round-trip, get_image null envelope). This fixture
## never mounts a `_MinervaIPC` node, so minerva_pcb_apply_route_hints always
## takes the worker-unavailable path headless — same failure-as-feedback
## shape test_pcb_apply_route_hints.gd asserts against the core module
## before its deletion.

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const DELETED_MODULE_PATH := "res://Scripts/Services/MCP/Modules/MCPPcbPanelTools.gd"
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

## The 5 wave-2 tool names — the remaining rows of the §3 migration table.
const WAVE2_TOOLS: Array[String] = [
	"minerva_pcb_get_change_journal",
	"minerva_pcb_import_trace_geometry",
	"minerva_pcb_export_trace_geometry",
	"minerva_pcb_get_image",
	"minerva_pcb_apply_route_hints",
]

## Generic annotation-substrate files allowed to mention "pcb_route_hint" as
## an illustrative "e.g." example of the domain-agnostic workflow-kind
## mechanism (AnnotationKind.workflow_class) — they own no PCB-specific
## logic, they just cite a concrete kind name in a doc comment. The (3c)
## grep gate below allow-lists exactly these; any OTHER src/Scripts file
## matching a forbidden identifier fails the gate.
const _GREP_GATE_ALLOWED_FILES: Array[String] = [
	"res://Scripts/Services/Annotations/AnnotationKind.gd",
	"res://Scripts/Services/MCP/Modules/MCPAnnotationTools.gd",
	"res://Scripts/UI/Controls/AnnotationDockPane/AnnotationWorkbench.gd",
	"res://Scripts/UI/Controls/AnnotationDockPane/WorkflowAnnotationList.gd",
]

## Identifiers that would indicate PCB workflow semantics leaking back into
## Minerva core (contract §5 E2E-P3: "generic dispatcher only").
const _GREP_GATE_FORBIDDEN: Array[String] = [
	"pcb_route_hint", "apply_route_hints", "_materialize_routes", "PCBPanel",
]

var _pass := 0
var _fail := 0

var panel      # PCBPanel (duck-typed Node)
var host       # PcbAnnotationHost (duck-typed)
var data       # pcb_data model (duck-typed)
var registry: PluginToolRegistry = null


func _init() -> void:
	print("=== PCB Panel-Tools Migration Gate (C3 — waves 1+2 + core deletion) ===\n")

	if not _setup():
		printerr("SETUP FAILED — cannot load plugin panel; aborting")
		quit(1)
		return

	await _run_wave1_dispatch_and_shape_checks()
	await _run_wave2_dispatch_and_shape_checks()
	_run_core_module_deleted()
	_run_source_grep_gate()

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

	var all_tools: Array = WAVE1_TOOLS + WAVE2_TOOLS
	registry = REGISTRY_DRIVER.new().build(panel, PCB_PLUGIN_ID, EDITOR, all_tools)
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


# ── (1) + (2), wave 1: dispatch through the real registry, spot-check shapes ──

func _run_wave1_dispatch_and_shape_checks() -> void:
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


# ── (1) + (2), wave 2: dispatch through the real registry, spot-check shapes ──

func _run_wave2_dispatch_and_shape_checks() -> void:
	print("\n-- wave 2: get_change_journal --")
	var add := await d("minerva_pcb_add_component", _args({"id": "W1", "footprint": "RESISTOR", "x": 5.0, "y": 5.0}))
	check("wave2 fixture: add_component ok", add.get("success", false), str(add))

	var jr := await d("minerva_pcb_get_change_journal", _args())
	check_keys("get_change_journal shape", jr, ["success", "total_entries", "returned_entries", "entries"])
	check("journal recorded a mutation", int(jr.get("total_entries", 0)) > 0, str(jr))

	print("\n-- wave 2: trace geometry round-trip --")
	var tin := {
		"traces": [
			{"start": {"x": 0.0, "y": 0.0}, "end": {"x": 5.0, "y": 0.0}, "width": 0.25, "layer": "F.Cu", "net_name": "GND"},
		],
		"vias": [],
	}
	var ti := await d("minerva_pcb_import_trace_geometry", _args({"trace_data": tin}))
	check_keys("import_trace_geometry shape", ti, ["success", "trace_count", "via_count"])
	check("trace imported", int(ti.get("trace_count", 0)) >= 1, str(ti))
	check("model has traces", data.get_trace_count() >= 1)

	var te := await d("minerva_pcb_export_trace_geometry", _args())
	check_keys("export_trace_geometry shape", te, ["success", "trace_count", "via_count", "trace_data"])
	check("export round-trips the imported trace",
		((te.get("trace_data", {}) as Dictionary).get("traces", []) as Array).size() >= 1, str(te))

	print("\n-- wave 2: get_image (headless graceful null envelope) --")
	var gi := await d("minerva_pcb_get_image", _args())
	check("get_image dispatched ok", gi.get("success", false), str(gi))
	var img_data = gi.get("image_data", "SENTINEL")
	check("get_image headless -> image_data null (never crashes)", img_data == null, str(gi))
	check("get_image metadata present", gi.get("metadata", null) is Dictionary)

	print("\n-- wave 2: apply_route_hints (no open hints -> no-op envelope) --")
	var ar_empty := await d("minerva_pcb_apply_route_hints", _args())
	check("apply_route_hints (no hints) dispatched ok", bool(ar_empty.get("success", false)), str(ar_empty))
	check_eq("no hints -> proposed 0", int(ar_empty.get("proposed", 0)), 0)

	print("\n-- wave 2: apply_route_hints (open hint, no broker -> worker-unavailable) --")
	var env: Dictionary = host.build_route_hint_envelope(0.0, 0.0, "", "F.Cu", "waypoint", [], "human")
	var seeded_id: String = host.add_annotation_v2(env)
	check("wave2 fixture: hint seeded", not seeded_id.is_empty())
	var trace_count_before: int = data.get_trace_count()
	var ar := await d("minerva_pcb_apply_route_hints", _args())
	check("apply_route_hints (headless, no broker) -> not success", not bool(ar.get("success", true)), str(ar))
	check_eq("apply_route_hints worker-unavailable failure-as-feedback tag",
		ar.get("error", ""), "route_worker_unavailable")
	check("apply_route_hints echoes the seeded hint id",
		(ar.get("hint_ids", []) as Array).has(seeded_id), str(ar))
	check_eq("board unmutated by an unavailable route", data.get_trace_count(), trace_count_before)
	host.remove_annotation(seeded_id)


# ── (3a): core module file deleted ────────────────────────────────────────────

func _run_core_module_deleted() -> void:
	print("\n-- (3a) MCPPcbPanelTools.gd deleted from Minerva core --")
	check("core module file no longer exists (no preload — the resource is gone)",
		not FileAccess.file_exists(DELETED_MODULE_PATH), DELETED_MODULE_PATH)


# ── (3c): source-grep gate — zero pcb workflow semantics under src/Scripts ────

func _run_source_grep_gate() -> void:
	print("\n-- (3c) source-grep gate: zero pcb workflow semantics under src/Scripts --")
	var offenders: Array = []
	_scan_dir_for_forbidden("res://Scripts", offenders)
	check("no forbidden pcb-workflow identifiers outside the allow-list",
		offenders.is_empty(), str(offenders))


## Recursively walk `path` (a res:// directory) looking for any
## _GREP_GATE_FORBIDDEN identifier in any .gd file NOT in
## _GREP_GATE_ALLOWED_FILES. Appends "<path>: <identifier>" to `offenders`
## for every hit. Fast + deterministic: plain text scan, no subprocess.
func _scan_dir_for_forbidden(path: String, offenders: Array) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not entry.begins_with("."):
			var full := path.path_join(entry)
			if dir.current_is_dir():
				_scan_dir_for_forbidden(full, offenders)
			elif entry.ends_with(".gd") and not _GREP_GATE_ALLOWED_FILES.has(full):
				var f := FileAccess.open(full, FileAccess.READ)
				if f != null:
					var content := f.get_as_text()
					f.close()
					for needle in _GREP_GATE_FORBIDDEN:
						if content.contains(needle):
							offenders.append("%s: %s" % [full, needle])
		entry = dir.get_next()
	dir.list_dir_end()

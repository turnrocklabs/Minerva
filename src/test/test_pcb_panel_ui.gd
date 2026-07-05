extends SceneTree
## PCB panel UI test (Round B of the panel port).
##
## Run: godot --headless --path src --script test/test_pcb_panel_ui.gd
##
## Drives the ported PCB panel (minerva-plugins/pcb/ui/PCBPanel.gd) HEADLESSLY via
## the plugin_panel_driver helper — exercising the panel-hook contract, the board
## model wiring, the dirty (content_changed) relay, and the annotation-host
## registration lifecycle. Interactive canvas behavior (selection, drag, rotate,
## trace draw, zoom/pan, grid snap, toolbar buttons, YAML export) CANNOT be
## asserted headlessly — that is the HITL debt and is NOT faked here.
##
## Off-tree scripts are load()ed at runtime (res:// == src/, so
## res://../../minerva-plugins == C:/github/minerva-plugins).

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const DRIVER_PATH := "res://test/helpers/plugin_panel_driver.gd"

var _pass_count: int = 0
var _fail_count: int = 0
var _driver = null


## Minimal editor stand-in: PCBPanel._on_panel_loaded reads ctx.editor.tab_title
## via `"tab_title" in ed` + property access.
class FakeEditor extends RefCounted:
	var tab_title: String = ""


func _init() -> void:
	print("=== PCB Panel UI Test ===\n")
	await process_frame

	_driver = load(DRIVER_PATH).new()
	check("plugin_panel_driver loads", _driver != null)
	var probe: Variant = _driver.load_panel(PANEL_PATH) if _driver != null else null
	check("PCBPanel script loads + instantiates off-tree", probe != null)
	if _driver == null or probe == null:
		_finish()
		return
	_driver.free_panel(probe)

	_test_canonical_load_and_save()
	_test_legacy_skeleton_migration()
	_test_content_changed_dirty_relay()
	_test_annotation_host_registration()

	_finish()


func _finish() -> void:
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ── Representative canonical board dict (to_board_dict shape) ──────────────────

func _canonical_board() -> Dictionary:
	return {
		"version": 1,
		"name": "UITestBoard",
		"width_mm": 50.0,
		"height_mm": 40.0,
		"grid_mm": 2.54,
		"design_rules": {"clearance_mm": 0.2},
		"components": [
			{"ref": "U1", "footprint": "IC_DIP", "x_mm": 20.0, "y_mm": 12.0, "rotation_deg": 90.0,
				"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}, {"number": "8", "x_mm": 7.62, "y_mm": 0.0}]},
			{"ref": "R1", "footprint": "RESISTOR", "x_mm": 34.0, "y_mm": 6.0, "rotation_deg": 0.0,
				"value": "10k",
				"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}, {"number": "2", "x_mm": 2.54, "y_mm": 0.0}]},
		],
		"nets": [
			{"name": "VCC", "pins": ["U1.8", "R1.1"]},
		],
		"traces": [
			{"net": "VCC", "layer": "top", "width_mm": 0.25,
				"points": [{"x_mm": 10.0, "y_mm": 5.0}, {"x_mm": 20.0, "y_mm": 12.0}]},
		],
		"vias": [],
	}


# ── Tests ─────────────────────────────────────────────────────────────────────

## Canonical board dict loads → model populated; save returns a canonical dict.
func _test_canonical_load_and_save() -> void:
	print("-- canonical board dict load → model populated; save → canonical dict --")
	var board_dir: String = _driver.make_temp_board_dir("pcb_panel_ui")
	var board_path := board_dir + "/canonical.pcbskel"
	_driver.cleanup_sidecar(board_path)

	var panel: Variant = _driver.load_panel(PANEL_PATH)
	_driver.drive_load_merged(panel, board_path, _canonical_board())

	var data: Variant = panel.get_data()
	check("panel exposes a board model after load", data != null)
	if data != null:
		check("model has both components (U1, R1)", data.get_component_count() == 2)
		check("model kept the VCC net", data.has_net("VCC"))
		check("model kept the routed trace", data.get_trace_count() == 1)
		check("U1 canonical fields survived (pos + rotation)",
				data.get_component("U1") != null
				and data.get_component("U1").position == Vector2(20.0, 12.0)
				and data.get_component("U1").rotation == 90.0)
		check("R1 value survived (10k)",
				data.get_component("R1") != null
				and data.get_component("R1").properties.get("value", "") == "10k")

	var saved: Dictionary = _driver.drive_save(panel)
	check("save returns canonical board dict (width_mm/height_mm/grid_mm)",
			saved.has("width_mm") and saved.has("height_mm") and saved.has("grid_mm"))
	check("save components is a list (canonical), not id-map",
			saved.get("components", null) is Array and (saved["components"] as Array).size() == 2)
	check("save does NOT emit the legacy nested 'board' key", not saved.has("board"),
			"saved keys: %s" % str(saved.keys()))
	check("save does NOT emit annotations/route_hints (dock owns them)",
			not saved.has("annotations") and not saved.has("route_hints"))

	_driver.cleanup_sidecar(board_path)
	_driver.cleanup_board_file(board_path)
	_driver.free_panel(panel)


## Legacy skeleton shape {board:{…}, components:[{ref,x,y,w,h}]} still loads
## (migration path).
func _test_legacy_skeleton_migration() -> void:
	print("\n-- legacy skeleton-shape document still loads (migration) --")
	var board_dir: String = _driver.make_temp_board_dir("pcb_panel_ui")
	var board_path := board_dir + "/legacy.pcbskel"
	_driver.cleanup_sidecar(board_path)

	var panel: Variant = _driver.load_panel(PANEL_PATH)
	_driver.drive_load_merged(panel, board_path, {
		"version": 1,
		"kind": "pcbskel_board",
		"board": {"width_mm": 60.0, "height_mm": 40.0},
		"components": [
			{"ref": "U1", "x": 8.0, "y": 8.0, "w": 16.0, "h": 16.0},
			{"ref": "J1", "x": 6.0, "y": 30.0, "w": 20.0, "h": 6.0},
		],
	})

	var data: Variant = panel.get_data()
	check("legacy board size migrated (60x40)",
			data != null and data.board_width == 60.0 and data.board_height == 40.0)
	check("legacy components migrated (U1, J1)",
			data != null and data.get_component_count() == 2
			and data.get_component("U1") != null and data.get_component("J1") != null)
	check("legacy component position migrated (U1 @ 8,8)",
			data != null and data.get_component("U1") != null
			and data.get_component("U1").position == Vector2(8.0, 8.0))

	# A canonical save after migration must be canonical (no nested 'board').
	var saved: Dictionary = _driver.drive_save(panel)
	check("migrated board saves canonical (no nested 'board')",
			saved.has("width_mm") and not saved.has("board"))

	_driver.cleanup_sidecar(board_path)
	_driver.cleanup_board_file(board_path)
	_driver.free_panel(panel)


## Model mutation flips content_changed; restoring a saved board does NOT.
func _test_content_changed_dirty_relay() -> void:
	print("\n-- model mutation flips content_changed; load does not (restoring gate) --")
	var board_dir: String = _driver.make_temp_board_dir("pcb_panel_ui")
	var board_path := board_dir + "/dirty.pcbskel"
	_driver.cleanup_sidecar(board_path)

	var panel: Variant = _driver.load_panel(PANEL_PATH)
	var spy := {"count": 0}
	panel.content_changed.connect(func() -> void: spy.count += 1)

	# Load a board — the _restoring gate must suppress the dirty relay.
	_driver.drive_load_merged(panel, board_path, _canonical_board())
	check("load does NOT flip content_changed (restoring gate)", spy.count == 0,
			"got %d emits during load" % spy.count)

	# Mutate via the model API → content_changed must fire (dirty glyph).
	var data: Variant = panel.get_data()
	data.move_component("U1", Vector2(25.0, 15.0))
	check("model mutation flips content_changed (dirty)", spy.count >= 1,
			"got %d emits after move_component" % spy.count)

	# Authoring an annotation via the host must also flip content_changed.
	var before: int = spy.count
	panel.get_annotation_host().add_route_hint_at(3.0, 3.0, "dirty hint")
	check("annotation authoring flips content_changed", spy.count > before,
			"count before=%d after=%d" % [before, spy.count])

	_driver.cleanup_sidecar(board_path)
	_driver.cleanup_board_file(board_path)
	_driver.free_panel(panel)


## The panel registers its annotation host by editor tab title on mount and
## deregisters on unload (the MCP-reach seam).
func _test_annotation_host_registration() -> void:
	print("\n-- annotation host registered on load / deregistered on unload --")
	AnnotationHostRegistry._reset_for_test()

	var panel: Variant = _driver.load_panel(PANEL_PATH)
	var ed := FakeEditor.new()
	ed.tab_title = "PCB UI Test Tab"
	panel._on_panel_loaded({"editor": ed, "file_path": ""})

	var host: Variant = panel.get_annotation_host()
	check("host registered under the editor tab title on mount",
			AnnotationHostRegistry.get_host("PCB UI Test Tab") == host)
	check("editor tab title listed in registry",
			"PCB UI Test Tab" in AnnotationHostRegistry.list_editor_names())

	panel._on_panel_unload()
	check("host deregistered on unload",
			AnnotationHostRegistry.get_host("PCB UI Test Tab") == null)

	AnnotationHostRegistry._reset_for_test()
	_driver.free_panel(panel)


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

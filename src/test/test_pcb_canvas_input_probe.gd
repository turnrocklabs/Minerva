extends SceneTree
## PCB canvas LIVE-input probe (docket 019f39164c2e).
##
## Run: godot --headless --path src --script test/test_pcb_canvas_input_probe.gd
##
## The headless panel-UI suite drives model/hooks and never exercises _gui_input,
## so it passes while the live panel is deaf to the mouse (findings 1/2/3:
## wheel-zoom, pan, box-select all dead). This probe mounts the REAL panel in a
## REAL Window viewport and pushes synthetic InputEventMouseButton / MouseMotion
## through Viewport.push_input — the same path the OS uses — then asserts the
## canvas actually zoomed / panned / began a box-select. It reproduces BOTH the
## bare panel AND the live condition (the platform AnnotationOverlay mounted as a
## sibling over the canvas by Editor._mount_annotation_dock_for_surface) so a
## regression in either seam is caught here instead of only in a human's hands.

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const DRIVER_PATH := "res://test/helpers/plugin_panel_driver.gd"

var _pass := 0
var _fail := 0


class FakeEditor extends RefCounted:
	var tab_title: String = "Probe Tab"
	var associated_object: Variant = ""


func _board_with_part() -> Dictionary:
	return {
		"version": 1, "name": "Probe", "width_mm": 60.0, "height_mm": 40.0, "grid_mm": 2.54,
		"components": [
			{"ref": "U1", "footprint": "IC_DIP", "x_mm": 30.0, "y_mm": 20.0, "rotation_deg": 0.0,
				"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}, {"number": "8", "x_mm": 7.62, "y_mm": 0.0}]},
		],
	}


func _init() -> void:
	print("=== PCB Canvas Input Probe ===\n")
	await process_frame

	var root_win := get_root()
	root_win.size = Vector2i(900, 700)

	await _probe_bare()
	await _probe_with_overlay()
	await _probe_full_live_mount()
	await _probe_reparent_after_mount()
	await _probe_select_tool_boxselect()
	await _probe_pan_tool_and_gestures()
	_probe_empty_default_board()

	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


## Mount the panel, load a board, force layout. Returns [panel, canvas].
func _mount_panel() -> Array:
	var panel = load(PANEL_PATH).new()
	get_root().add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.size = Vector2(900, 700)
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	panel.get_data().from_board_dict(_board_with_part())
	# Let containers lay out so the canvas gets a real rect.
	for _i in range(4):
		await process_frame
	var canvas = panel._canvas
	return [panel, canvas]


func _canvas_center_global(canvas) -> Vector2:
	var r: Rect2 = canvas.get_global_rect()
	return r.position + r.size * 0.5


func _push_wheel(pos: Vector2, up: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_WHEEL_UP if up else MOUSE_BUTTON_WHEEL_DOWN
	ev.pressed = true
	ev.position = pos
	ev.global_position = pos
	get_root().push_input(ev, true)


func _push_button(pos: Vector2, btn: int, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = btn
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	get_root().push_input(ev, true)


func _push_motion(pos: Vector2, btn_mask: int) -> void:
	var ev := InputEventMouseMotion.new()
	ev.position = pos
	ev.global_position = pos
	ev.button_mask = btn_mask
	get_root().push_input(ev, true)


func _run_input_asserts(label: String, panel, canvas) -> void:
	check("%s: canvas has a non-zero rect" % label, canvas.size.x > 1 and canvas.size.y > 1,
			"canvas.size=%s global_rect=%s" % [str(canvas.size), str(canvas.get_global_rect())])

	var center := _canvas_center_global(canvas)

	# 1. Wheel zoom. Reset to mid-range first so we test the INPUT path, not the
	#    min/max clamp (zoom_to_fit on a tiny board can pin zoom at max_zoom).
	canvas.zoom = 4.0
	var z0: float = canvas.zoom
	_push_wheel(center, true)
	await process_frame
	check("%s: wheel-up changed zoom (finding 1)" % label, canvas.zoom != z0,
			"zoom %.3f -> %.3f" % [z0, canvas.zoom])
	var z1: float = canvas.zoom
	_push_wheel(center, false)
	await process_frame
	check("%s: wheel-down changed zoom" % label, canvas.zoom != z1,
			"zoom %.3f -> %.3f" % [z1, canvas.zoom])

	# 2. Right-drag pan.
	var pan0: Vector2 = canvas.pan_offset
	_push_button(center, MOUSE_BUTTON_RIGHT, true)
	_push_motion(center + Vector2(40, 25), MOUSE_BUTTON_MASK_RIGHT)
	await process_frame
	var panned: bool = canvas.pan_offset != pan0
	_push_button(center + Vector2(40, 25), MOUSE_BUTTON_RIGHT, false)
	check("%s: right-drag panned the view (finding 2)" % label, panned,
			"pan %s -> %s" % [str(pan0), str(canvas.pan_offset)])

	# 2b. Middle-drag pan.
	var pan1: Vector2 = canvas.pan_offset
	_push_button(center, MOUSE_BUTTON_MIDDLE, true)
	_push_motion(center + Vector2(-30, 20), MOUSE_BUTTON_MASK_MIDDLE)
	await process_frame
	var panned_mid: bool = canvas.pan_offset != pan1
	_push_button(center + Vector2(-30, 20), MOUSE_BUTTON_MIDDLE, false)
	check("%s: middle-drag panned the view" % label, panned_mid,
			"pan %s -> %s" % [str(pan1), str(canvas.pan_offset)])

	# 3. Box-select on empty space.
	# Click an empty corner (world far from the part), drag out a box.
	var empty_pt: Vector2 = canvas.get_global_rect().position + Vector2(20, 20)
	_push_button(empty_pt, MOUSE_BUTTON_LEFT, true)
	await process_frame
	var began_box: bool = canvas.is_box_selecting
	_push_motion(empty_pt + Vector2(60, 60), MOUSE_BUTTON_MASK_LEFT)
	await process_frame
	_push_button(empty_pt + Vector2(60, 60), MOUSE_BUTTON_LEFT, false)
	check("%s: left-drag on empty began a box-select (finding 3)" % label, began_box,
			"is_box_selecting stayed false")


func _probe_bare() -> void:
	print("-- BARE panel (no annotation overlay) --")
	var pc := await _mount_panel()
	var panel = pc[0]
	var canvas = pc[1]
	await _run_input_asserts("bare", panel, canvas)
	panel.queue_free()
	await process_frame


## Reproduce the LIVE mount: Editor._mount_annotation_dock_for_surface adds a
## platform AnnotationOverlay as a child of the panel root, covering the canvas.
## Idle (no active tool) it MUST pass pointer events through to the canvas.
func _probe_with_overlay() -> void:
	print("\n-- panel WITH platform AnnotationOverlay sibling (live condition) --")
	var pc := await _mount_panel()
	var panel = pc[0]
	var canvas = pc[1]

	var overlay := AnnotationOverlay.new()
	overlay.name = "PlatformAnnotationOverlay"
	panel.add_child(overlay)
	overlay.set_host(panel.get_annotation_host())
	for _i in range(3):
		await process_frame

	check("overlay is idle (MOUSE_FILTER_IGNORE)", overlay.mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"mouse_filter=%d" % overlay.mouse_filter)
	await _run_input_asserts("overlay", panel, canvas)
	panel.queue_free()
	await process_frame


## Faithful reproduction of Editor._mount_annotation_dock_for_surface: the panel
## is reparented into an AnnotationContentRow HBox, a real AnnotationDockPane is
## added as a sibling, and the AnnotationOverlay is a child of the panel. Dock
## RIGHT mode (wide viewport). This is the closest headless replica of the live
## tab a user drives.
func _probe_full_live_mount() -> void:
	print("\n-- FULL live mount (content-row + real AnnotationDockPane + overlay) --")
	var panel = load(PANEL_PATH).new()
	var row := HBoxContainer.new()
	row.name = "AnnotationContentRow"
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.size = Vector2(900, 700)
	get_root().add_child(row)
	row.add_child(panel)
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	panel.get_data().from_board_dict(_board_with_part())

	var host: RefCounted = panel.get_annotation_host()
	var dock := AnnotationDockPane.new()
	dock.name = "AnnotationDockPane"
	row.add_child(dock)
	dock.set_host(host)
	dock.set_dock_mode(AnnotationDockPane.DockMode.RIGHT)

	var overlay := AnnotationOverlay.new()
	overlay.name = "PlatformAnnotationOverlay"
	panel.add_child(overlay)
	overlay.set_host(host)
	if dock.has_signal("active_tool_changed"):
		dock.active_tool_changed.connect(Callable(overlay, "set_active_tool"))

	for _i in range(5):
		await process_frame

	var canvas = panel._canvas
	await _run_input_asserts("full", panel, canvas)
	row.queue_free()
	await process_frame


## REGRESSION GUARD for bug 019f39164c2e: the real editor builds the panel under
## one parent (_on_panel_loaded runs), THEN reparents it into the annotation
## content row (Editor._ensure_annotation_content_row). That reparent fires the
## canvas's _exit_tree/_enter_tree WITHOUT re-running _ready. If input config is
## only set in _ready, the reparented canvas is left MOUSE_FILTER_IGNORE and
## swallows all input (draws fine — the exact "buttons work, canvas dead" bug the
## earlier probes MISSED because they built the canvas after the final add).
## This probe reproduces the mount→reparent order and asserts input survives.
func _probe_reparent_after_mount() -> void:
	print("\n-- Reparent-after-mount (bug 019f39164c2e regression guard) --")
	var first_parent := Control.new()
	first_parent.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	first_parent.size = Vector2(900, 700)
	get_root().add_child(first_parent)

	# 1. Build the panel + canvas UNDER the first parent (as the plugin host does).
	var panel = load(PANEL_PATH).new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	first_parent.add_child(panel)
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	panel.get_data().from_board_dict(_board_with_part())
	for _i in range(3):
		await process_frame

	var canvas = panel._canvas
	check("canvas STOP before reparent", canvas.mouse_filter == Control.MOUSE_FILTER_STOP,
			"mouse_filter=%d" % canvas.mouse_filter)

	# 2. Reparent the panel into an AnnotationContentRow (as the dock mount does).
	#    This fires the canvas _exit_tree → _enter_tree.
	first_parent.remove_child(panel)
	var row := HBoxContainer.new()
	row.name = "AnnotationContentRow"
	row.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	row.size = Vector2(900, 700)
	get_root().add_child(row)
	row.add_child(panel)
	var overlay := AnnotationOverlay.new()
	overlay.name = "PlatformAnnotationOverlay"
	panel.add_child(overlay)
	overlay.set_host(panel.get_annotation_host())
	for _i in range(5):
		await process_frame

	# 3. After the reparent the canvas MUST still accept input.
	check("canvas STOP after reparent (not left IGNORE)",
			canvas.mouse_filter == Control.MOUSE_FILTER_STOP,
			"mouse_filter=%d — the reparent left it IGNORE" % canvas.mouse_filter)
	await _run_input_asserts("reparented", panel, canvas)
	row.queue_free()
	first_parent.queue_free()
	await process_frame


## With the Select tool_mode ACTIVE (toolbar Select pressed), a left-drag on
## empty space must still produce a box-select. Pre-fix this fails: the tool
## click short-circuits and box-select is unreachable in any tool mode.
func _probe_select_tool_boxselect() -> void:
	print("\n-- Select-tool box-select + click-drag move (finding 3/5) --")
	var pc := await _mount_panel()
	var panel = pc[0]
	var canvas = pc[1]

	canvas.set_tool_mode(canvas.ToolMode.SELECT)
	await process_frame

	var origin: Vector2 = canvas.get_global_rect().position
	var empty_pt := origin + Vector2(20, 20)
	_push_button(empty_pt, MOUSE_BUTTON_LEFT, true)
	await process_frame
	var began_box: bool = canvas.is_box_selecting
	_push_motion(empty_pt + Vector2(80, 80), MOUSE_BUTTON_MASK_LEFT)
	await process_frame
	_push_button(empty_pt + Vector2(80, 80), MOUSE_BUTTON_LEFT, false)
	await process_frame
	check("SELECT tool: empty left-drag begins a box-select (finding 3)", began_box,
			"is_box_selecting stayed false with Select tool active")

	# Click-drag on the component moves it (smart tool, finding 5).
	var comp = panel.get_data().get_component("U1")
	var start_pos: Vector2 = comp.position
	var comp_screen: Vector2 = canvas.get_global_transform() * canvas.world_to_screen(start_pos)
	_push_button(comp_screen, MOUSE_BUTTON_LEFT, true)
	await process_frame
	_push_motion(comp_screen + Vector2(canvas.zoom * 5.0, 0), MOUSE_BUTTON_MASK_LEFT)
	await process_frame
	var moved: bool = comp.position != start_pos
	_push_button(comp_screen + Vector2(canvas.zoom * 5.0, 0), MOUSE_BUTTON_LEFT, false)
	check("SELECT tool: click-drag on a component moves it (finding 5)", moved,
			"component stayed at %s" % str(start_pos))

	panel.queue_free()
	await process_frame


## Pan tool (left-drag), Space-drag pan, and trackpad pan-gesture (finding 1/2).
func _probe_pan_tool_and_gestures() -> void:
	print("\n-- Pan tool + Space-drag + trackpad pan gesture (finding 1/2) --")
	var pc := await _mount_panel()
	var panel = pc[0]
	var canvas = pc[1]
	var center := _canvas_center_global(canvas)

	# Pan tool: a plain left-drag pans (no box-select).
	canvas.set_tool_mode(canvas.ToolMode.PAN)
	await process_frame
	var p0: Vector2 = canvas.pan_offset
	_push_button(center, MOUSE_BUTTON_LEFT, true)
	_push_motion(center + Vector2(35, 20), MOUSE_BUTTON_MASK_LEFT)
	await process_frame
	var pan_tool_worked: bool = canvas.pan_offset != p0 and not canvas.is_box_selecting
	_push_button(center + Vector2(35, 20), MOUSE_BUTTON_LEFT, false)
	check("Pan tool: left-drag pans (finding 2 discoverability)", pan_tool_worked,
			"pan %s -> %s box=%s" % [str(p0), str(canvas.pan_offset), str(canvas.is_box_selecting)])

	# Space-drag pan in the Select tool.
	canvas.set_tool_mode(canvas.ToolMode.SELECT)
	await process_frame
	var space_ev := InputEventKey.new()
	space_ev.keycode = KEY_SPACE
	space_ev.pressed = true
	get_root().push_input(space_ev, true)
	await process_frame
	var p1: Vector2 = canvas.pan_offset
	_push_button(center, MOUSE_BUTTON_LEFT, true)
	_push_motion(center + Vector2(-25, 15), MOUSE_BUTTON_MASK_LEFT)
	await process_frame
	var space_pan: bool = canvas.pan_offset != p1 and not canvas.is_box_selecting
	_push_button(center + Vector2(-25, 15), MOUSE_BUTTON_LEFT, false)
	check("Space-drag pans while Select tool active", space_pan,
			"pan %s -> %s box=%s" % [str(p1), str(canvas.pan_offset), str(canvas.is_box_selecting)])

	# Trackpad pan gesture → view pans.
	var p2: Vector2 = canvas.pan_offset
	var pg := InputEventPanGesture.new()
	pg.position = center
	pg.delta = Vector2(4, 3)
	get_root().push_input(pg, true)
	await process_frame
	check("trackpad pan-gesture pans the view (finding 1)", canvas.pan_offset != p2,
			"pan %s -> %s" % [str(p2), str(canvas.pan_offset)])

	panel.queue_free()
	await process_frame


## A brand-new (anonymous) panel's default board is EMPTY (finding 4).
func _probe_empty_default_board() -> void:
	print("\n-- fresh panel default board is empty (finding 4) --")
	var panel = load(PANEL_PATH).new()
	check("default board has zero components (no phantom U1/R1)",
			panel.get_data().get_component_count() == 0,
			"got %d" % panel.get_data().get_component_count())
	panel.free()


func check(desc: String, cond: bool, detail: String = "") -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [desc, detail])
		else:
			printerr("  FAIL: %s" % desc)

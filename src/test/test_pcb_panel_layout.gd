extends SceneTree
## PCB panel responsive layout (UI redesign round B) — tests-first spec.
##
## Run: godot --headless --path src --script test/test_pcb_panel_layout.gd
##
## The panel adapts to its OWN width across Minerva's resizable 1/2/3-column
## layouts. This suite is the acceptance spec the layout code must satisfy:
##   1. panel_layout.mode_for_width — boundaries + hysteresis (pure logic).
##   2. Panel at 1100px (wide): sidebar visible, layout state reports wide.
##   3. Panel at 600px (medium, the 3-col target): sidebar visible, all
##      toolbar controls fit without horizontal scrolling.
##   4. Panel at 400px (narrow): sidebar hidden behind a drawer toggle; view
##      toggles folded into a View menu; toolbar fits without h-scroll.
##   5. get_annotation_dock_parent() returns a Control inside the sidebar
##      (the platform mounts the annotation dock there — round A hook).
##   6. Mode transitions preserve the loaded board and canvas.
##   7. get_layout_state() exposes structured state for MCP/agent verification.

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const LAYOUT_PATH := "res://../../minerva-plugins/pcb/ui/panel_layout.gd"

var _pass := 0
var _fail := 0


func check(desc: String, ok: bool) -> void:
	if ok:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


class FakeEditor extends RefCounted:
	var tab_title: String = "Layout Tab"
	var associated_object: Variant = ""


func _board() -> Dictionary:
	return {
		"version": 1, "name": "Layout", "width_mm": 60.0, "height_mm": 40.0, "grid_mm": 2.54,
		"components": [
			{"ref": "U1", "footprint": "IC_DIP", "x_mm": 30.0, "y_mm": 20.0, "rotation_deg": 0.0,
				"pins": [{"number": "1", "x_mm": 0.0, "y_mm": 0.0}]},
		],
	}


func _init() -> void:
	print("=== PCB panel responsive layout ===\n")
	await process_frame
	get_root().size = Vector2i(1300, 800)

	_test_mode_resolver()
	await _test_wide_mode()
	await _test_medium_mode()
	await _test_narrow_mode()
	await _test_dock_parent_hook()
	await _test_dock_pane_migrates()
	await _test_transitions_preserve_board()
	await _test_properties_panel()
	await _test_tool_buttons_render()

	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── 1. Resolver logic ──────────────────────────────────────────────────────────

func _test_mode_resolver() -> void:
	print("-- mode_for_width boundaries + hysteresis --")
	var L := load(LAYOUT_PATH)

	check("400 → narrow", L.mode_for_width(400.0) == L.MODE_NARROW)
	check("479.9 → narrow", L.mode_for_width(479.9) == L.MODE_NARROW)
	check("480 → medium", L.mode_for_width(480.0) == L.MODE_MEDIUM)
	check("600 → medium (3-col target)", L.mode_for_width(600.0) == L.MODE_MEDIUM)
	check("899.9 → medium", L.mode_for_width(899.9) == L.MODE_MEDIUM)
	check("900 → wide", L.mode_for_width(900.0) == L.MODE_WIDE)
	check("1100 → wide", L.mode_for_width(1100.0) == L.MODE_WIDE)

	# Hysteresis: leaving a mode needs the boundary + band.
	check("narrow stays at 490 (boundary+10)",
		L.mode_for_width(490.0, L.MODE_NARROW) == L.MODE_NARROW)
	check("narrow leaves at 505 (boundary+25)",
		L.mode_for_width(505.0, L.MODE_NARROW) == L.MODE_MEDIUM)
	check("medium enters narrow below 480",
		L.mode_for_width(470.0, L.MODE_MEDIUM) == L.MODE_NARROW)
	check("wide stays at 890 (boundary-10)",
		L.mode_for_width(890.0, L.MODE_WIDE) == L.MODE_WIDE)
	check("wide leaves at 875 (boundary-25)",
		L.mode_for_width(875.0, L.MODE_WIDE) == L.MODE_MEDIUM)
	check("medium enters wide at 900",
		L.mode_for_width(900.0, L.MODE_MEDIUM) == L.MODE_WIDE)


# ── Panel harness ──────────────────────────────────────────────────────────────

func _mount_panel_at(width: float) -> Control:
	var panel: Control = load(PANEL_PATH).new()
	get_root().add_child(panel)
	panel.position = Vector2.ZERO
	panel.size = Vector2(width, 700)
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})
	panel.get_data().from_board_dict(_board())
	for _i in range(6):
		await process_frame
	return panel


func _teardown(panel: Control) -> void:
	panel.queue_free()


## The toolbar row must fit in the panel: its content width must not exceed
## the scroll container's width (no horizontal overflow at this panel width).
func _toolbar_fits(panel: Control) -> bool:
	var scroll: ScrollContainer = panel.find_child("ToolbarScroll", true, false)
	if scroll == null:
		return false
	var bar: Control = scroll.get_child(0) if scroll.get_child_count() > 0 else null
	if bar == null:
		return false
	return bar.get_combined_minimum_size().x <= scroll.size.x + 1.0


# ── 2. Wide mode ───────────────────────────────────────────────────────────────

func _test_wide_mode() -> void:
	print("\n-- wide mode (1100px) --")
	var panel := await _mount_panel_at(1100.0)

	var state: Dictionary = panel.get_layout_state()
	check("state.mode == wide", str(state.get("mode", "")) == "wide")
	check("state width ~ 1100", absf(float(state.get("width", 0.0)) - 1100.0) < 2.0)
	check("sidebar visible", bool(state.get("sidebar_visible", false)))

	var sidebar: Control = panel.find_child("RightSidebar", true, false)
	check("sidebar node exists + visible", sidebar != null and sidebar.visible)
	check("toolbar fits without h-scroll", _toolbar_fits(panel))

	_teardown(panel)


# ── 3. Medium mode (3-col target) ──────────────────────────────────────────────

func _test_medium_mode() -> void:
	print("\n-- medium mode (600px) --")
	var panel := await _mount_panel_at(600.0)

	var state: Dictionary = panel.get_layout_state()
	check("state.mode == medium", str(state.get("mode", "")) == "medium")
	check("sidebar visible", bool(state.get("sidebar_visible", false)))
	check("toolbar fits without h-scroll at 600px", _toolbar_fits(panel))

	var canvas: Control = panel._canvas
	check("canvas keeps majority width",
		canvas != null and canvas.size.x > 600.0 * 0.5)

	_teardown(panel)


# ── 4. Narrow mode ─────────────────────────────────────────────────────────────

func _test_narrow_mode() -> void:
	print("\n-- narrow mode (400px) --")
	var panel := await _mount_panel_at(400.0)

	var state: Dictionary = panel.get_layout_state()
	check("state.mode == narrow", str(state.get("mode", "")) == "narrow")
	check("sidebar hidden", not bool(state.get("sidebar_visible", true)))
	check("drawer reported closed", not bool(state.get("drawer_open", true)))

	var drawer_btn: Control = panel.find_child("SidebarDrawerButton", true, false)
	check("drawer toggle present + visible", drawer_btn != null and drawer_btn.visible)

	var view_menu: Control = panel.find_child("ViewMenuButton", true, false)
	check("View menu present + visible", view_menu != null and view_menu.visible)
	check("toolbar fits without h-scroll at 400px", _toolbar_fits(panel))

	# Open the drawer: sidebar becomes visible.
	if drawer_btn is Button:
		(drawer_btn as Button).emit_signal("pressed")
		await process_frame
		var state2: Dictionary = panel.get_layout_state()
		check("drawer opens sidebar", bool(state2.get("sidebar_visible", false)))
		check("drawer reported open", bool(state2.get("drawer_open", false)))
	else:
		check("drawer toggle is a Button", false)

	_teardown(panel)


# ── 5. Dock parent hook (round A contract) ─────────────────────────────────────

func _test_dock_parent_hook() -> void:
	print("\n-- get_annotation_dock_parent (mode-dependent slot) --")

	# Medium (3-col HITL note): dock belongs in the BOTTOM strip.
	var panel := await _mount_panel_at(700.0)
	check("panel exposes get_annotation_dock_parent",
		panel.has_method("get_annotation_dock_parent"))
	var dock_parent: Variant = panel.get_annotation_dock_parent()
	var bottom: Control = panel.find_child("BottomDockSlot", true, false)
	check("medium: dock parent is a Control", dock_parent is Control)
	check("medium: dock parent is the bottom strip",
		dock_parent is Control and bottom != null
		and (dock_parent == bottom or bottom.is_ancestor_of(dock_parent)))
	check("medium: state reports dock at bottom",
		str(panel.get_layout_state().get("dock_position", "")) == "bottom")
	_teardown(panel)

	# Wide: dock belongs in the right sidebar.
	var panel2 := await _mount_panel_at(1100.0)
	var dock_parent2: Variant = panel2.get_annotation_dock_parent()
	var sidebar: Control = panel2.find_child("RightSidebar", true, false)
	check("wide: dock parent lives inside the sidebar",
		dock_parent2 is Control and sidebar != null
		and (dock_parent2 == sidebar or sidebar.is_ancestor_of(dock_parent2)))
	check("wide: state reports dock in sidebar",
		str(panel2.get_layout_state().get("dock_position", "")) == "sidebar")
	_teardown(panel2)


## A mounted dock pane must MIGRATE between slots as the mode changes, with
## its internal arrangement following (RIGHT in the sidebar, BOTTOM in the
## strip) and no active tool stranded.
func _test_dock_pane_migrates() -> void:
	print("\n-- dock pane migrates between slots --")
	const DockPaneScript := preload("res://Scripts/UI/Controls/AnnotationDockPane/AnnotationDockPane.gd")

	var panel := await _mount_panel_at(1100.0)  # wide: mounts into sidebar
	var pane: Node = DockPaneScript.new()
	pane.name = "AnnotationDockPane"
	(panel.get_annotation_dock_parent() as Control).add_child(pane)
	pane.set_dock_mode(DockPaneScript.DockMode.RIGHT)  # as the platform mount does
	for _i in range(3):
		await process_frame

	var sidebar_slot: Control = panel.find_child("AnnotationDockParent", true, false)
	var bottom_slot: Control = panel.find_child("BottomDockSlot", true, false)
	check("wide: pane sits in the sidebar slot", pane.get_parent() == sidebar_slot)
	check("wide: pane arranged RIGHT",
		int(pane.get("dock_mode")) == DockPaneScript.DockMode.RIGHT)

	panel.size = Vector2(600.0, 700.0)  # → medium
	for _i in range(4):
		await process_frame
	check("medium: pane migrated to the bottom strip", pane.get_parent() == bottom_slot)
	check("medium: pane arranged BOTTOM",
		int(pane.get("dock_mode")) == DockPaneScript.DockMode.BOTTOM)

	panel.size = Vector2(1100.0, 700.0)  # → back to wide
	for _i in range(4):
		await process_frame
	check("back to wide: pane returned to the sidebar", pane.get_parent() == sidebar_slot)
	check("back to wide: pane arranged RIGHT again",
		int(pane.get("dock_mode")) == DockPaneScript.DockMode.RIGHT)

	_teardown(panel)


# ── 6. Transitions preserve the board ──────────────────────────────────────────

func _test_transitions_preserve_board() -> void:
	print("\n-- mode transitions preserve state --")
	var panel := await _mount_panel_at(1100.0)

	var parts_before: int = panel.get_data().components.size()
	check("board loaded in wide", parts_before == 1)

	panel.size = Vector2(600.0, 700.0)
	for _i in range(4):
		await process_frame
	check("wide→medium: mode followed",
		str(panel.get_layout_state().get("mode", "")) == "medium")
	check("wide→medium: board intact", panel.get_data().components.size() == parts_before)

	panel.size = Vector2(400.0, 700.0)
	for _i in range(4):
		await process_frame
	check("medium→narrow: mode followed",
		str(panel.get_layout_state().get("mode", "")) == "narrow")
	check("medium→narrow: board intact", panel.get_data().components.size() == parts_before)
	check("medium→narrow: canvas alive", is_instance_valid(panel._canvas))

	# Flip a view flag through the View MENU while narrow (inline toggles are
	# hidden), then widen — the inline CheckButton must show the live flag.
	panel._on_view_menu_id_pressed(0)  # toggles show_grid off
	check("menu toggled canvas flag", panel._canvas.show_grid == false)

	panel.size = Vector2(1100.0, 700.0)
	for _i in range(4):
		await process_frame
	check("narrow→wide: mode followed",
		str(panel.get_layout_state().get("mode", "")) == "wide")
	check("narrow→wide: sidebar visible again",
		bool(panel.get_layout_state().get("sidebar_visible", false)))

	var toggles: Control = panel.find_child("ViewTogglesBox", true, false)
	var grid_toggle: CheckButton = toggles.get_child(0) as CheckButton if toggles != null and toggles.get_child_count() > 0 else null
	check("inline Grid toggle re-synced from canvas flag",
		grid_toggle != null and grid_toggle.button_pressed == false)

	_teardown(panel)


# ── 7. Properties section (round C) ────────────────────────────────────────────

func _test_properties_panel() -> void:
	print("\n-- properties section --")
	var panel := await _mount_panel_at(1100.0)

	var section: Control = panel.find_child("PropertiesSection", true, false)
	check("properties section exists in sidebar", section != null)
	check("wide mode: properties expanded",
		bool(panel.get_layout_state().get("properties_expanded", false)))

	# Select the only component → fields populate.
	panel._canvas.selected_components.append("U1")
	panel._canvas.selection_changed.emit()
	await process_frame
	var id_label: Label = panel._prop_labels.get("ID", null)
	check("ID populates on selection", id_label != null and id_label.text == "U1")
	var pos_label: Label = panel._prop_labels.get("Position", null)
	check("Position populates", pos_label != null and pos_label.text.begins_with("(30"))

	# Clear selection → dashes.
	panel._canvas.selected_components.clear()
	panel._canvas.selection_changed.emit()
	await process_frame
	check("clears to dash on deselect", id_label.text == "-")

	# Medium mode collapses by default.
	panel.size = Vector2(600.0, 700.0)
	for _i in range(4):
		await process_frame
	check("medium mode: properties collapsed",
		not bool(panel.get_layout_state().get("properties_expanded", true)))

	_teardown(panel)


# ── 8. Tool buttons render (round C icons) ─────────────────────────────────────

func _test_tool_buttons_render() -> void:
	print("\n-- tool buttons (icon or text, never blank) --")
	var panel := await _mount_panel_at(700.0)

	var flow: Control = panel.find_child("ToolsFlow", true, false)
	check("tools flow lives in the sidebar", flow != null)
	if flow != null:
		var buttons := 0
		for child in flow.get_children():
			if child is Button:
				buttons += 1
				var b := child as Button
				check("tool button has icon or text",
					b.icon != null or not b.text.is_empty())
		# WC-3 (contract §5) added a fourth button (Trace — the route-flow
		# cluster's single-trace author tool toggle) to the same ToolsFlow
		# container, next to Select/Pan/Pin Inspect. C5 (docket 019f6c465fd8)
		# adds a sixth: Propose (a non-toggle act button, not part of the
		# route-flow mutual-exclusion set, but rendered in the same
		# ToolsFlow for discoverability — see PCBPanel.gd's _propose_button).
		# U4 (DCR 019f7095c395 Stage-2) adds a seventh: Add Via (another
		# route-flow toggle tool, ViaInsertTool, in the same
		# _route_flow_buttons mutual-exclusion set as Trace/Edit Hint).
		check("seven tool buttons (Select/Pan/Pin Inspect/Trace/Edit Hint/Add Via/Propose)", buttons == 7)

	_teardown(panel)

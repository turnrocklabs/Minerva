extends SceneTree
## PCB pin inspector E2E-1 (WC-1, docket 019f6a8918fe).
##
## Run: godot --headless --path . --script test/test_pcb_pin_inspector.gd
## (run from the Minerva worktree's src/ directory)
##
## Boots the REAL PCBPanel + PcbAnnotationHost headless (real Window viewport,
## real canvas, real toolbar), builds a 3-component/2-net fixture board directly
## against the live pcb_data model (one geometry-named pin, one unconnected
## pin), and drives the INSPECT_PIN mode with REAL synthetic input
## (Viewport.push_input — mouse clicks + a Shift+P key event), exactly like
## test_pcb_canvas_input_probe.gd. MCP parity (minerva_pcb_pin_info) is
## dispatched through the REAL PluginToolRegistry.handle_tool_call path
## (executor "panel", DCR 019f6c3d0e3d C2 round) against the registered panel
## — headless, no subprocess required for panel-executed tools.
##
## REUSE SCAN (see work-cycle report): mount pattern copied from
## test_pcb_canvas_input_probe.gd's _mount_panel/_push_button/_push_motion.
## C2 migration (docket 019f6c45f09e): minerva_pcb_pin_info moved to the pcb
## plugin's own panel_tools.gd (executor "panel") — MCP parity now dispatches
## through the REAL PluginToolRegistry.handle_tool_call path (a registered
## PCBPanel via PluginScenePanelBroker), mirroring test_panel_executed_tools.gd's
## fixture wiring, instead of calling the old core module's handle() directly.
## No hit-test logic is reimplemented here — every assertion reads live UI
## state or calls through the real dispatcher.

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const REGISTRY_DRIVER := preload("res://test/helpers/panel_tool_registry_driver.gd")

const EDITOR_NAME := "PinInspectorProbe"
const PCB_PLUGIN_ID := "pcb"

var _pass := 0
var _fail := 0

var panel = null
var canvas = null
var host = null
var data = null
var registry: PluginToolRegistry = null

## Captured via canvas.pin_selected — the last emitted info Dictionary.
var _last_pin_selected: Dictionary = {"__unset__": true}


class FakeEditor extends RefCounted:
	var tab_title: String = EDITOR_NAME
	var associated_object: Variant = ""


func _init() -> void:
	print("=== PCB Pin Inspector E2E-1 ===\n")
	await process_frame

	if not await _mount():
		printerr("SETUP FAILED — cannot mount PCB panel; aborting")
		quit(1)
		return

	_test_pad_at_units()
	await _test_e2e_1_scenario()

	panel.queue_free()
	await process_frame
	AnnotationHostRegistry._reset_for_test()

	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── mount + fixture ─────────────────────────────────────────────────────────

func _mount() -> bool:
	panel = load(PANEL_PATH).new()
	if panel == null:
		return false
	get_root().add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.size = Vector2(900, 700)
	panel._on_panel_loaded({"editor": FakeEditor.new(), "file_path": ""})

	host = panel.get_annotation_host()
	data = panel.get_data()
	if host == null or data == null:
		return false

	_build_fixture_board(data)

	for _i in range(4):
		await process_frame

	canvas = panel._canvas
	if canvas == null:
		return false

	# PCBPanel's own zoom-to-fit is a ONE-SHOT deferred to the canvas's first
	# `resized` signal (queued back in _on_panel_loaded, before the fixture board
	# existed and before layout had settled) — timing-sensitive and NOT what we
	# want to depend on for exact-pixel pin clicks. Re-fit explicitly now that
	# the canvas has its final laid-out size AND the fixture board, so
	# world_to_screen() is deterministic for every click below.
	canvas.zoom_to_fit()
	await process_frame
	canvas.pin_selected.connect(func(info: Dictionary) -> void: _last_pin_selected = info)

	# Real PluginToolRegistry + PluginScenePanelBroker rig with `panel`
	# registered under EDITOR_NAME, owned by "pcb" — the same shape production
	# dispatch resolves against (contract §2.2/§2.3).
	registry = REGISTRY_DRIVER.new().build(panel, PCB_PLUGIN_ID, EDITOR_NAME, ["minerva_pcb_pin_info"])
	return registry != null


## 3 components, 2 nets, one geometry-named pin (U1.15 -> "3V3"), one
## deliberately unconnected pin (U1.2). Pins are spaced 8mm apart so an
## exact-position click is unambiguous even against pad_at's default 5mm
## inspector radius (a click AT a pin is distance 0 — always nearer than any
## neighbour at >=8mm, radius considerations aside).
func _build_fixture_board(d) -> void:
	d.board_width = 100.0
	d.board_height = 60.0

	var u1 = d.new_component()
	u1.id = "U1"
	u1.position = Vector2(20.0, 20.0)
	u1.pins = {"1": Vector2(0.0, 0.0), "15": Vector2(8.0, 0.0), "2": Vector2(16.0, 0.0)}
	u1.pads = [{
		"number": "15", "name": "3V3", "type": "smd", "shape": "rect",
		"position": Vector2(8.0, 0.0), "size": Vector2(1.0, 1.0),
		"drill": Vector2.ZERO, "layers": ["F.Cu"],
	}]
	d.add_component(u1)

	var u2 = d.new_component()
	u2.id = "U2"
	u2.position = Vector2(50.0, 20.0)
	u2.pins = {"A": Vector2(0.0, 0.0)}
	d.add_component(u2)

	var u3 = d.new_component()
	u3.id = "U3"
	u3.position = Vector2(75.0, 20.0)
	u3.pins = {"1": Vector2(0.0, 0.0)}
	d.add_component(u3)

	d.connect_pin_to_net("GND", "U1", "1")
	d.connect_pin_to_net("GND", "U2", "A")
	d.connect_pin_to_net("VCC", "U1", "15")
	d.connect_pin_to_net("VCC", "U3", "1")
	# U1.2 stays unconnected — no connect_pin_to_net call.


# ── synthetic input helpers (copied convention from test_pcb_canvas_input_probe.gd) ──

func _push_button(pos: Vector2, btn: int, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = btn
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	get_root().push_input(ev, true)


func _click(pos: Vector2) -> void:
	_push_button(pos, MOUSE_BUTTON_LEFT, true)


func _release(pos: Vector2) -> void:
	_push_button(pos, MOUSE_BUTTON_LEFT, false)


func _push_shift_p() -> void:
	var ev := InputEventKey.new()
	ev.keycode = KEY_P
	ev.shift_pressed = true
	ev.pressed = true
	get_root().push_input(ev, true)


func _push_escape() -> void:
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	get_root().push_input(ev, true)


func _world_to_root_screen(world_pos: Vector2) -> Vector2:
	return canvas.get_global_transform() * canvas.world_to_screen(world_pos)


func _click_world(world_pos: Vector2) -> void:
	var pt := _world_to_root_screen(world_pos)
	_click(pt)


func _release_world(world_pos: Vector2) -> void:
	var pt := _world_to_root_screen(world_pos)
	_release(pt)


# ── E2E-1 scenario ───────────────────────────────────────────────────────────

func _test_e2e_1_scenario() -> void:
	print("-- E2E-1: toggle / click-select / display rule / MCP parity / clear --")

	var u1 = data.get_component("U1")
	var world_1: Vector2 = u1.get_pin_world_position("1")     # net-only (GND)
	var world_15: Vector2 = u1.get_pin_world_position("15")   # geometry name "3V3" + net VCC
	var world_2: Vector2 = u1.get_pin_world_position("2")     # unconnected
	# A guaranteed-on-canvas, far-from-any-pad point: derived from a LOCAL
	# corner of the canvas's OWN rect (post zoom-to-fit) rather than a fixed
	# board-mm literal — zoom_to_fit's content bbox (component BODIES, ~5x2.5mm,
	# not the wider pin spread this fixture uses) does not necessarily cover
	# every board-mm coordinate, so a hardcoded "far" point can land outside the
	# fitted view and silently miss the canvas control entirely.
	var empty_pt: Vector2 = canvas.screen_to_world(Vector2(24.0, canvas.size.y - 24.0))
	check("fixture: empty_pt is actually pad-free (sanity)", host.pad_at(empty_pt).is_empty(),
		"pad_at(empty_pt)=%s" % str(host.pad_at(empty_pt)))

	# ── A. Toggle inspect mode via Shift+P (real key event), then click a
	#      net-connected, non-geometry pad. ──
	# Grab focus first (a real click on empty space, SELECT tool still active —
	# same mechanism the existing canvas probe relies on for keyboard tests).
	_click_world(empty_pt)
	await process_frame
	_release_world(empty_pt)
	await process_frame

	check("A: SELECT is the resting tool before toggling",
		canvas.tool_mode == canvas.ToolMode.SELECT, "tool_mode=%d" % canvas.tool_mode)

	_push_shift_p()
	await process_frame

	check("A: Shift+P arms INSPECT_PIN", canvas.tool_mode == canvas.ToolMode.INSPECT_PIN,
		"tool_mode=%d" % canvas.tool_mode)
	check("A: toolbar Pin button reflects the mode", panel._inspect_pin_button.button_pressed,
		"button_pressed=%s" % str(panel._inspect_pin_button.button_pressed))

	_last_pin_selected = {"__unset__": true}
	_click_world(world_1)
	await process_frame
	_release_world(world_1)
	await process_frame

	check("A: pin_selected fired for U1.1", str(_last_pin_selected.get("ref", "")) == "U1.1",
		"got %s" % str(_last_pin_selected))
	check("A: Pin Info section visible", panel._pin_info_section.visible,
		"visible=%s" % str(panel._pin_info_section.visible))
	check("A: ref label shows U1.1-style ref", panel._pin_info_ref_label.text == "U1.1",
		"got '%s'" % panel._pin_info_ref_label.text)
	var a_net := str(_last_pin_selected.get("net", ""))
	check("A: net name shown (GND, no geometry name)", a_net == "GND", "net='%s'" % a_net)
	check("A: display value = net (no geometry name to win)",
		panel._pin_info_value_label.text == "GND", "got '%s'" % panel._pin_info_value_label.text)
	var a_members: Array = _last_pin_selected.get("net_members", [])
	check("A: net_members = [U2.A]", a_members == ["U2.A"], "got %s" % str(a_members))

	# ── B. Click the geometry-named pin — geometry name wins over net. ──
	_last_pin_selected = {"__unset__": true}
	_click_world(world_15)
	await process_frame
	_release_world(world_15)
	await process_frame

	check("B: pin_selected fired for U1.15", str(_last_pin_selected.get("ref", "")) == "U1.15",
		"got %s" % str(_last_pin_selected))
	var b_pin_name := str(_last_pin_selected.get("pin_name", ""))
	var b_net := str(_last_pin_selected.get("net", ""))
	check("B: geometry pin_name is '3V3'", b_pin_name == "3V3", "pin_name='%s'" % b_pin_name)
	check("B: net is still VCC (present, just outranked)", b_net == "VCC", "net='%s'" % b_net)
	check("B: display value = geometry name, NOT net",
		panel._pin_info_value_label.text == "3V3", "got '%s'" % panel._pin_info_value_label.text)

	# ── C. Click the unconnected pin. ──
	_last_pin_selected = {"__unset__": true}
	_click_world(world_2)
	await process_frame
	_release_world(world_2)
	await process_frame

	check("C: pin_selected fired for U1.2", str(_last_pin_selected.get("ref", "")) == "U1.2",
		"got %s" % str(_last_pin_selected))
	var c_net := str(_last_pin_selected.get("net", ""))
	check("C: net is empty (unconnected)", c_net == "", "net='%s'" % c_net)
	check("C: display value = '(unconnected)'",
		panel._pin_info_value_label.text == "(unconnected)", "got '%s'" % panel._pin_info_value_label.text)

	# ── D. MCP parity: minerva_pcb_pin_info must match the UI exactly, for all
	#      three pins, plus net_members. ──
	var r1: Dictionary = await registry.handle_tool_call("minerva_pcb_pin_info", {"editor_name": EDITOR_NAME, "ref": "U1.1"})
	check("D: MCP U1.1 succeeds", bool(r1.get("success", false)), "got %s" % str(r1))
	check("D: MCP U1.1 net matches UI (GND)", str(r1.get("net", "")) == "GND", "got %s" % str(r1))
	check("D: MCP U1.1 display_name matches UI ('GND')",
		str(r1.get("display_name", "")) == "GND", "got %s" % str(r1))
	check("D: MCP U1.1 net_members matches UI ([U2.A])",
		r1.get("net_members", []) == ["U2.A"], "got %s" % str(r1.get("net_members", [])))

	var r15: Dictionary = await registry.handle_tool_call("minerva_pcb_pin_info", {"editor_name": EDITOR_NAME, "ref": "U1.15"})
	check("D: MCP U1.15 pin_name matches UI ('3V3')",
		str(r15.get("pin_name", "")) == "3V3", "got %s" % str(r15))
	check("D: MCP U1.15 display_name = geometry name (wins over net)",
		str(r15.get("display_name", "")) == "3V3", "got %s" % str(r15))
	check("D: MCP U1.15 net_members matches UI ([U3.1])",
		r15.get("net_members", []) == ["U3.1"], "got %s" % str(r15.get("net_members", [])))

	var r2: Dictionary = await registry.handle_tool_call("minerva_pcb_pin_info", {"editor_name": EDITOR_NAME, "ref": "U1.2"})
	check("D: MCP U1.2 display_name = '(unconnected)'",
		str(r2.get("display_name", "")) == "(unconnected)", "got %s" % str(r2))
	check("D: MCP U1.2 net_members is empty",
		(r2.get("net_members", []) as Array).is_empty(), "got %s" % str(r2.get("net_members", [])))

	# x_mm/y_mm variant hits the same pad as the ref variant.
	var r_xy: Dictionary = await registry.handle_tool_call("minerva_pcb_pin_info",
		{"editor_name": EDITOR_NAME, "x_mm": world_1.x, "y_mm": world_1.y})
	check("D: MCP x_mm/y_mm resolves the same pin as ref", str(r_xy.get("ref", "")) == "U1.1",
		"got %s" % str(r_xy))

	# ── E. Click empty space clears; malformed/unknown MCP refs error cleanly. ──
	_last_pin_selected = {"__unset__": true}
	_click_world(empty_pt)
	await process_frame
	_release_world(empty_pt)
	await process_frame

	check("E: click empty space clears (pin_selected({}))", _last_pin_selected.is_empty(),
		"got %s" % str(_last_pin_selected))
	check("E: Pin Info section hidden after clear", not panel._pin_info_section.visible,
		"visible=%s" % str(panel._pin_info_section.visible))

	var r_unknown: Dictionary = await registry.handle_tool_call("minerva_pcb_pin_info", {"editor_name": EDITOR_NAME, "ref": "ZZ9.99"})
	check("E: MCP unknown ref 'ZZ9.99' -> structured error, not a crash",
		not bool(r_unknown.get("success", true)) and r_unknown.has("error"), "got %s" % str(r_unknown))

	var r_malformed: Dictionary = await registry.handle_tool_call("minerva_pcb_pin_info", {"editor_name": EDITOR_NAME, "ref": "garbage"})
	check("E: MCP malformed ref (no dot) -> structured error",
		not bool(r_malformed.get("success", true)) and r_malformed.has("error"), "got %s" % str(r_malformed))

	var r_empty_ref: Dictionary = await registry.handle_tool_call("minerva_pcb_pin_info", {"editor_name": EDITOR_NAME, "ref": ""})
	check("E: MCP empty-string ref -> structured error",
		not bool(r_empty_ref.get("success", true)) and r_empty_ref.has("error"), "got %s" % str(r_empty_ref))

	var r_no_args: Dictionary = await registry.handle_tool_call("minerva_pcb_pin_info", {"editor_name": EDITOR_NAME})
	check("E: MCP neither ref nor x_mm/y_mm -> structured error",
		not bool(r_no_args.get("success", true)) and r_no_args.has("error"), "got %s" % str(r_no_args))

	# This one crosses the DISPATCHER boundary (unknown editor_name never
	# reaches panel_tools.gd at all) so the error shape is PluginErrors'
	# structured editor_not_found, not panel_tools.gd's own _err({"error":…})
	# shape the other assertions in this scenario check — mechanical fallout
	# of routing through the real dispatcher (contract §2.2), not a behavior
	# change: still a structured, non-crashing error naming the bad editor.
	var r_bad_editor: Dictionary = await registry.handle_tool_call("minerva_pcb_pin_info", {"editor_name": "NoSuchEditor", "ref": "U1.1"})
	check("E: MCP unknown editor_name -> structured error",
		not bool(r_bad_editor.get("success", true)) and r_bad_editor.get("error_code", "") == "editor_not_found",
		"got %s" % str(r_bad_editor))

	# Bonus: Escape exits the mode; Shift+P toggles both directions. Still in
	# INSPECT_PIN here — nothing above exited it (clicking empty space only
	# clears the selection, per contract §3).
	check("bonus: still in INSPECT_PIN (empty-space click doesn't exit the mode)",
		canvas.tool_mode == canvas.ToolMode.INSPECT_PIN, "tool_mode=%d" % canvas.tool_mode)
	_push_escape()
	await process_frame
	check("bonus: Escape exits INSPECT_PIN back to Select",
		canvas.tool_mode == canvas.ToolMode.SELECT, "tool_mode=%d" % canvas.tool_mode)
	check("bonus: Escape also clears the Pin Info section",
		not panel._pin_info_section.visible, "visible=%s" % str(panel._pin_info_section.visible))

	_push_shift_p()
	await process_frame
	check("bonus: Shift+P re-arms INSPECT_PIN from Select",
		canvas.tool_mode == canvas.ToolMode.INSPECT_PIN, "tool_mode=%d" % canvas.tool_mode)
	_push_shift_p()
	await process_frame
	check("bonus: Shift+P toggles back off to Select",
		canvas.tool_mode == canvas.ToolMode.SELECT, "tool_mode=%d" % canvas.tool_mode)


# ── pad_at unit checks (welcome, not the gate) ──────────────────────────────

func _test_pad_at_units() -> void:
	print("-- pad_at unit checks (miss / nearest-wins / radius boundary / tie-break) --")

	check("pad_at: miss returns {} far from any pad",
		host.pad_at(Vector2(-500.0, -500.0)).is_empty())

	var u1 = data.get_component("U1")
	var world_1: Vector2 = u1.get_pin_world_position("1")

	var hit_exact: Dictionary = host.pad_at(world_1)
	check("pad_at: exact hit resolves U1.1", str(hit_exact.get("component", "")) == "U1"
		and str(hit_exact.get("pin", "")) == "1", "got %s" % str(hit_exact))

	# Radius boundary: a point exactly at the default radius (5.0mm) is inside
	# (<=); a hair beyond it is outside. Offset along Y (perpendicular to the
	# 8mm-spaced sibling pins on the X axis) so no other pad's radius overlaps
	# this probe point.
	var boundary_in := world_1 + Vector2(0.0, 5.0)
	var boundary_out := world_1 + Vector2(0.0, 5.01)
	var hit_boundary_in: Dictionary = host.pad_at(boundary_in, 5.0)
	check("pad_at: exactly-at-radius is a hit (inclusive boundary)",
		str(hit_boundary_in.get("component", "")) == "U1" and str(hit_boundary_in.get("pin", "")) == "1",
		"got %s" % str(hit_boundary_in))
	check("pad_at: just-outside-radius is a miss",
		host.pad_at(boundary_out, 5.0).is_empty())

	# Nearest-wins: a point 3mm from U1.1 and 5mm from U1.15 (8mm pin spacing) has
	# BOTH pads within the 5mm radius — the nearer one (U1.1) must win.
	var between_1_and_15 := world_1 + Vector2(3.0, 0.0)
	var hit_near: Dictionary = host.pad_at(between_1_and_15, 5.0)
	check("pad_at: nearest pad wins when two candidates are both in radius",
		str(hit_near.get("component", "")) == "U1" and str(hit_near.get("pin", "")) == "1",
		"got %s" % str(hit_near))

	# Deterministic tie-break: two equidistant synthetic pads resolve to the
	# lexicographically-first (component, pin).
	_test_pad_at_tie_break()


func _test_pad_at_tie_break() -> void:
	# A separate throwaway board (via a second panel-free pcb_data instance is not
	# reachable off-tree without a class ref, so reuse the SAME data model with two
	# extra components placed equidistant from a probe point, then remove them).
	var probe := Vector2(90.0, 10.0)
	var b1 = data.new_component()
	b1.id = "ZTIE"
	b1.position = probe + Vector2(3.0, 0.0)
	b1.pins = {"9": Vector2(0.0, 0.0)}
	data.add_component(b1)

	var a1 = data.new_component()
	a1.id = "ATIE"
	a1.position = probe + Vector2(0.0, 3.0)
	a1.pins = {"9": Vector2(0.0, 0.0)}
	data.add_component(a1)

	var hit: Dictionary = host.pad_at(probe, 5.0)
	check("pad_at: equidistant tie breaks lexicographically (ATIE before ZTIE)",
		str(hit.get("component", "")) == "ATIE", "got %s" % str(hit))

	data.remove_component("ZTIE")
	data.remove_component("ATIE")


# ── assertion helper ─────────────────────────────────────────────────────────

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

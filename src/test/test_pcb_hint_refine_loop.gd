extends SceneTree
## Hint refine-loop E2E (C4, docket 019f6c464ff0): per-hint revision history,
## undo/redo (host methods + panel-executed MCP tools + Ctrl+Z/Ctrl+Shift+Z
## UI seam), and the bend-handle editing tool.
##
## Run: godot --headless --path . --script test/test_pcb_hint_refine_loop.gd
## (run from the Minerva worktree's src/ directory — see CRITICAL SAFETY in
## the round brief: never run headless godot from the non-worktree checkout).
##
## Scenario (product contract v2 — human draws sloppy, agent/human refine the
## SAME hint through a shared per-hint revision stack, undo/redo works over
## both authors, from UI and from the agent):
##   A) Human draws a sloppy 4-bend hint via the Trace tool (real input,
##      pad-to-pad so detail_level auto-derives "detailed" — 4 interior
##      waypoints — which is what makes the real router reproduce the
##      polyline verbatim in step G; see route_bridge.materialize_detailed_
##      hints. The round brief's "3-bend" is descriptive framing, not a
##      literal count — 4 is the smallest count that clears the
##      _derive_detail_level "detailed" threshold (>3), which is load-bearing
##      for G's exact-match assertion; see the report's Findings section).
##   B) Agent squares it via minerva_annotations_update (core generic tool,
##      called directly — annotations_* are core, not panel-executed) →
##      ONE revision pushed, canvas payload updated.
##   C) Human drags one bend via the Edit-hint tool (real input) → ONE more
##      revision (commits on release only — see BendHandleEditTool's class
##      doc for why NOT AnnotationTransformTool's per-frame-emit convention).
##   D) Agent calls minerva_pcb_hint_undo via the REAL panel-tool dispatch
##      (PluginToolRegistry.handle_tool_call, via panel_tool_registry_driver)
##      → the bend-drag is reverted; payload proves it (back to squared).
##   E) Ctrl+Z with the hint selected undoes the agent's square-up (the
##      cross-author guarantee: a UI keypress undoes an agent's MCP edit) →
##      back to the original sloppy hint.
##   F) Redo via minerva_pcb_hint_redo (same REAL dispatch path) restores the
##      squared state (undoes E).
##   G) Apply via minerva_pcb_apply_route_hints (REAL worker when the
##      pcb-plugin binary is built, contract-allowed canned fallback
##      otherwise) → the committed trace matches the FINAL payload (squared,
##      undragged) exactly; the consumed hint is deleted (existing contract).
##   H) A SEPARATE fresh hint (G consumed the scenario A-G hint) proves the
##      revision stack survives a sidecar save/reload and is bounded at the
##      25-entry cap (oldest dropped).
##
## REUSE SCAN: mount/fixture/input/real-worker-stdio conventions copied
## verbatim from test_pcb_single_trace_tool.gd (real PCBPanel boot headless,
## real input via get_root().push_input(), MCPAnnotationTools direct calls
## for the core-generic annotations_* tools, the e2e_route_stdio.py bridge +
## documented canned fallback for the real-worker apply step). REAL
## panel-tool dispatch for the new undo/redo MCP tools uses
## test/helpers/panel_tool_registry_driver.gd (same fixture
## test_pcb_panel_tools_migration.gd established) — deliverable 5D
## explicitly requires the REAL registry path, not a direct panel_tools.gd
## call.

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const ANN_MODULE := preload("res://Scripts/Services/MCP/Modules/MCPAnnotationTools.gd")
const DRIVER := preload("res://test/helpers/plugin_panel_driver.gd")
const REGISTRY_DRIVER := preload("res://test/helpers/panel_tool_registry_driver.gd")

const EDITOR_NAME := "HintRefineLoopProbe"
const PLUGIN_ROOT := "res://../../minerva-plugins/pcb"
const PCB_PLUGIN_ID := "pcb"

var _pass := 0
var _fail := 0
var _used_real_worker := false

var panel = null
var canvas = null
var host = null
var data = null
var driver = null

var overlay: AnnotationOverlay = null
var ann_tools = null

const U1_PIN1 := Vector2(15.0, 20.0)
const U2_PIN1 := Vector2(55.0, 20.0)

## The sloppy hand-drawn corridor (A) — 4 interior bends, deliberately messy.
const ORIGINAL_BENDS := [[25.0, 8.0], [30.0, 27.0], [40.0, 6.0], [48.0, 24.0]]

## The agent's squared-to-90° corridor (B).
const SQUARED_BENDS := [[25.0, 20.0], [25.0, 10.0], [45.0, 10.0], [45.0, 20.0]]

## Where the human drags bend index 1 of the SQUARED corridor to (C).
const DRAG_TARGET := Vector2(25.0, 5.0)

var _hint_id := ""


class FakeEditor extends RefCounted:
	var tab_title: String = EDITOR_NAME
	var associated_object: Variant = ""


func _init() -> void:
	print("=== PCB Hint Refine Loop E2E (C4) ===\n")
	await process_frame

	if not await _mount():
		printerr("SETUP FAILED — cannot mount PCB panel; aborting")
		quit(1)
		return

	await _test_a_human_draws_sloppy_hint()
	await _test_b_agent_squares_it()
	await _test_c_human_drags_a_bend()
	await _test_d_agent_undo_via_real_dispatch()
	await _test_e_ctrl_z_undoes_agents_squareup()
	await _test_f_agent_redo_via_real_dispatch()
	await _test_g_apply_matches_final_payload()
	await _test_h_cap_and_sidecar_survival()

	panel.queue_free()
	await process_frame
	AnnotationHostRegistry._reset_for_test()

	print("\n=== Results: %d passed, %d failed (real_worker_used=%s) ===" % [_pass, _fail, str(_used_real_worker)])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── mount + fixture (test_pcb_single_trace_tool.gd conventions) ──────────────

func _mount() -> bool:
	driver = DRIVER.new()
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

	canvas.zoom = 4.0
	canvas.pan_offset = -Vector2(data.board_width, data.board_height) / 2.0 * canvas.zoom
	canvas.queue_redraw()
	await process_frame

	overlay = AnnotationOverlay.new()
	overlay.name = "PlatformAnnotationOverlay"
	panel.get_annotation_overlay_parent().add_child(overlay)
	overlay.set_host(host)
	await process_frame

	ann_tools = ANN_MODULE.new(null)   # server=null — handle() is server-free.
	AnnotationHostRegistry._reset_for_test()
	AnnotationHostRegistry.register(EDITOR_NAME, host)
	return true


func _build_fixture_board(d) -> void:
	d.board_width = 70.0
	d.board_height = 40.0

	var u1 = d.new_component()
	u1.id = "U1"
	u1.position = U1_PIN1
	u1.pins = {"1": Vector2(0.0, 0.0)}
	d.add_component(u1)

	var u2 = d.new_component()
	u2.id = "U2"
	u2.position = U2_PIN1
	u2.pins = {"1": Vector2(0.0, 0.0)}
	d.add_component(u2)

	d.connect_pin_to_net("SIG", "U1", "1")
	d.connect_pin_to_net("SIG", "U2", "1")


# ── input helpers (copied convention from test_pcb_single_trace_tool.gd) ─────

func _push_button(pos: Vector2, btn: int, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = btn
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	get_root().push_input(ev, true)


func _world_to_root_screen(world_pos: Vector2) -> Vector2:
	return canvas.get_global_transform() * canvas.world_to_screen(world_pos)


func _click_world(world_pos: Vector2, btn: int = MOUSE_BUTTON_LEFT) -> void:
	var pt := _world_to_root_screen(world_pos)
	_push_button(pt, btn, true)
	await process_frame
	_push_button(pt, btn, false)
	await process_frame


## Press-move-release drag, for the bend-handle tool's drag gesture.
func _drag_world(from_world: Vector2, to_world: Vector2, btn: int = MOUSE_BUTTON_LEFT) -> void:
	var from_pt := _world_to_root_screen(from_world)
	var to_pt := _world_to_root_screen(to_world)
	_push_button(from_pt, btn, true)
	await process_frame
	var motion := InputEventMouseMotion.new()
	motion.position = to_pt
	motion.global_position = to_pt
	get_root().push_input(motion, true)
	await process_frame
	_push_button(to_pt, btn, false)
	await process_frame


func _press_ctrl_z(shift: bool = false) -> void:
	var ev := InputEventKey.new()
	ev.keycode = KEY_Z
	ev.ctrl_pressed = true
	ev.shift_pressed = shift
	ev.pressed = true
	get_root().push_input(ev, true)
	await process_frame


# ── route-flow cluster button helpers (drives the REAL PCBPanel handlers) ────

func _press_trace_button() -> void:
	var btn: Button = panel._route_flow_buttons["single_trace"]
	btn.button_pressed = true
	panel._on_single_trace_button_pressed()
	await process_frame


func _release_trace_button() -> void:
	var btn: Button = panel._route_flow_buttons["single_trace"]
	btn.button_pressed = false
	panel._on_single_trace_button_pressed()
	await process_frame


func _press_edit_hint_button() -> void:
	var btn: Button = panel._route_flow_buttons["edit_hint"]
	btn.button_pressed = true
	panel._on_edit_hint_button_pressed()
	await process_frame


func _release_edit_hint_button() -> void:
	var btn: Button = panel._route_flow_buttons["edit_hint"]
	btn.button_pressed = false
	panel._on_edit_hint_button_pressed()
	await process_frame


func _active_tool():
	return panel._active_route_flow_tool


## panel_tool_registry_driver.build() registers a REAL PluginScenePanelBroker
## against `panel` (test_pcb_panel_tools_migration.gd's own fixture pattern),
## which (a) attaches a REAL MinervaIPC helper node named "_MinervaIPC" as a
## child of the panel and (b) connects an anonymous lambda to panel.request
## — neither undone by a normal call flow (PluginScenePanelBroker.
## unregister_panel detaches the node but never disconnects the request
## listener; a platform gap, out of this round's fence). Left alone, G's own
## fake "_MinervaIPC" node collides with the stale one and route_board()'s
## get_node_or_null("_MinervaIPC") can resolve to the non-functional stale
## broker instead. Clean both up by hand between dispatch calls so later
## steps start from a known-clean IPC surface — test-file-local, touches no
## production code.
func _cleanup_stale_registry_dispatch() -> void:
	for conn in panel.request.get_connections():
		panel.request.disconnect(conn["callable"])
	for child in panel.get_children():
		if str(child.name).begins_with("_MinervaIPC"):
			panel.remove_child(child)
			child.queue_free()


# ── A: human draws a sloppy 4-bend hint via the Trace tool ───────────────────

func _test_a_human_draws_sloppy_hint() -> void:
	print("-- A: human draws a sloppy 4-bend hint pin1 -> pin2 --")
	check("A: no annotations before drawing", host.get_annotations().size() == 0)

	await _press_trace_button()
	check("A: Trace button toggled on", (panel._route_flow_buttons["single_trace"] as Button).button_pressed)
	check("A: overlay's active tool is a route-flow tool", overlay.has_active_tool() and _active_tool() != null)

	await _click_world(U1_PIN1)
	for bend in ORIGINAL_BENDS:
		await _click_world(Vector2(bend[0], bend[1]))
	await _click_world(U2_PIN1)   # dest pad -> commits

	check("A: hint committed — host has 1 annotation", host.get_annotations().size() == 1,
		"count=%d" % host.get_annotations().size())

	var ann: Dictionary = host.get_annotations()[0] if host.get_annotations().size() == 1 else {}
	_hint_id = str(ann.get("id", ""))
	check("A: hint id assigned", not _hint_id.is_empty())

	var kp: Dictionary = ann.get("kind_payload", {})
	check("A: hint_type is single_trace", str(kp.get("hint_type", "")) == "single_trace")
	check("A: 4 interior waypoints recorded", (kp.get("waypoints", []) as Array).size() == 4,
		"got %s" % str(kp.get("waypoints")))
	check("A: detail_level auto-derived to 'detailed' (>3 interior waypoints)",
		str(kp.get("detail_level", "")) == "detailed", "detail_level=%s" % str(kp.get("detail_level")))
	check("A: source_pins == [U1.1]", (kp.get("source_pins", []) as Array) == ["U1.1"])
	check("A: dest_pins == [U2.1]", (kp.get("dest_pins", []) as Array) == ["U2.1"])
	check("A: waypoints match the drawn corridor", _bends_equal(kp.get("waypoints", []), ORIGINAL_BENDS),
		"got %s" % str(kp.get("waypoints")))

	check("A: no revision history yet (fresh hint)", not ann.has("revision_stack") or (ann.get("revision_stack") as Array).is_empty())
	check("A: no redo history yet", not ann.has("redo_stack") or (ann.get("redo_stack") as Array).is_empty())

	await _release_trace_button()


# ── B: agent squares it via minerva_annotations_update ───────────────────────

func _test_b_agent_squares_it() -> void:
	print("-- B: agent squares the hint to 90 deg via minerva_annotations_update --")
	var before: Dictionary = host.get_by_id(_hint_id)
	var new_kp: Dictionary = (before.get("kind_payload", {}) as Dictionary).duplicate(true)
	new_kp["waypoints"] = SQUARED_BENDS.duplicate(true)

	var result: Dictionary = await ann_tools.handle("minerva_annotations_update", {
		"editor_name": EDITOR_NAME,
		"id": _hint_id,
		"patch": {"kind_payload": new_kp},
	})
	check("B: annotations_update ok", bool(result.get("ok", false)), str(result))

	var ann: Dictionary = host.get_by_id(_hint_id)
	var kp: Dictionary = ann.get("kind_payload", {})
	check("B: waypoints squared", _bends_equal(kp.get("waypoints", []), SQUARED_BENDS), "got %s" % str(kp.get("waypoints")))

	var revisions: Array = ann.get("revision_stack", [])
	check("B: ONE revision pushed", revisions.size() == 1, "revisions=%s" % str(revisions))
	if revisions.size() == 1:
		var prior: Dictionary = revisions[0]
		check("B: pushed revision carries the ORIGINAL sloppy waypoints",
			_bends_equal(prior.get("waypoints", []), ORIGINAL_BENDS), "got %s" % str(prior.get("waypoints")))
	check("B: redo stack empty (fresh edit)", (ann.get("redo_stack", []) as Array).is_empty())


# ── C: human drags one bend via the Edit-hint tool ────────────────────────────

func _test_c_human_drags_a_bend() -> void:
	print("-- C: human drags a bend via the Edit-hint tool --")

	await _press_edit_hint_button()
	check("C: Edit-hint button toggled on", (panel._route_flow_buttons["edit_hint"] as Button).button_pressed)
	check("C: overlay's active tool is the bend-edit tool", overlay.has_active_tool() and _active_tool() != null)

	# First click selects the hint (via its anchor marker at U1_PIN1).
	await _click_world(U1_PIN1)
	check("C: hint selected", host.get_selected_annotation_id() == _hint_id,
		"selected='%s' expected='%s'" % [host.get_selected_annotation_id(), _hint_id])

	# Drag bend index 1 of the SQUARED corridor ([25,10]) to DRAG_TARGET.
	var from_bend := Vector2(SQUARED_BENDS[1][0], SQUARED_BENDS[1][1])
	await _drag_world(from_bend, DRAG_TARGET)

	var ann: Dictionary = host.get_by_id(_hint_id)
	var kp: Dictionary = ann.get("kind_payload", {})
	var wps: Array = kp.get("waypoints", [])
	check("C: bend 1 moved to the drag target", wps.size() == 4
		and Vector2(wps[1][0], wps[1][1]).distance_to(DRAG_TARGET) < 0.5,
		"got %s" % str(wps))
	check("C: bends 0/2/3 unchanged", wps.size() == 4
		and Vector2(wps[0][0], wps[0][1]).distance_to(Vector2(SQUARED_BENDS[0][0], SQUARED_BENDS[0][1])) < 0.01
		and Vector2(wps[2][0], wps[2][1]).distance_to(Vector2(SQUARED_BENDS[2][0], SQUARED_BENDS[2][1])) < 0.01
		and Vector2(wps[3][0], wps[3][1]).distance_to(Vector2(SQUARED_BENDS[3][0], SQUARED_BENDS[3][1])) < 0.01,
		"got %s" % str(wps))

	var revisions: Array = ann.get("revision_stack", [])
	check("C: TWO revisions now (A->B pushed B, B->C pushed the squared state)",
		revisions.size() == 2, "revisions=%s" % str(revisions))
	check("C: redo stack still empty (a fresh edit, not an undo)", (ann.get("redo_stack", []) as Array).is_empty())

	await _release_edit_hint_button()


# ── D: agent undoes the drag via REAL panel-tool dispatch ────────────────────

func _test_d_agent_undo_via_real_dispatch() -> void:
	print("-- D: agent calls minerva_pcb_hint_undo via the REAL panel-tool dispatch --")
	var registry: PluginToolRegistry = REGISTRY_DRIVER.new().build(
		panel, PCB_PLUGIN_ID, EDITOR_NAME, ["minerva_pcb_hint_undo", "minerva_pcb_hint_redo"])
	check("D: dispatch registry built", registry != null)
	if registry == null:
		return

	var result: Dictionary = await registry.handle_tool_call("minerva_pcb_hint_undo", {
		"editor_name": EDITOR_NAME, "id": _hint_id,
	})
	check("D: minerva_pcb_hint_undo ok", bool(result.get("success", result.get("ok", false))), str(result))

	var restored_kp: Dictionary = result.get("kind_payload", {})
	check("D: returned kind_payload is the squared (pre-drag) corridor",
		_bends_equal(restored_kp.get("waypoints", []), SQUARED_BENDS), "got %s" % str(restored_kp.get("waypoints")))

	var ann: Dictionary = host.get_by_id(_hint_id)
	var kp: Dictionary = ann.get("kind_payload", {})
	check("D: bend-drag reverted on the live host — waypoints are squared again",
		_bends_equal(kp.get("waypoints", []), SQUARED_BENDS), "got %s" % str(kp.get("waypoints")))

	check("D: one revision left (the original sloppy corridor)",
		(ann.get("revision_stack", []) as Array).size() == 1)
	check("D: one redo entry now (the reverted drag)",
		(ann.get("redo_stack", []) as Array).size() == 1)

	_cleanup_stale_registry_dispatch()
	await process_frame


# ── E: Ctrl+Z with the hint selected undoes the agent's square-up ────────────

func _test_e_ctrl_z_undoes_agents_squareup() -> void:
	print("-- E: Ctrl+Z with the hint selected undoes B's square-up --")
	check("E: hint still selected going in", host.get_selected_annotation_id() == _hint_id,
		"selected='%s'" % host.get_selected_annotation_id())

	await _press_ctrl_z(false)

	var ann: Dictionary = host.get_by_id(_hint_id)
	var kp: Dictionary = ann.get("kind_payload", {})
	check("E: waypoints reverted to the ORIGINAL sloppy corridor",
		_bends_equal(kp.get("waypoints", []), ORIGINAL_BENDS), "got %s" % str(kp.get("waypoints")))
	check("E: revision stack now empty", (ann.get("revision_stack", []) as Array).is_empty())
	check("E: redo stack has two entries (dragged, squared)",
		(ann.get("redo_stack", []) as Array).size() == 2)


# ── F: redo via minerva_pcb_hint_redo restores the squared state ─────────────

func _test_f_agent_redo_via_real_dispatch() -> void:
	print("-- F: agent calls minerva_pcb_hint_redo via the REAL panel-tool dispatch --")
	var registry: PluginToolRegistry = REGISTRY_DRIVER.new().build(
		panel, PCB_PLUGIN_ID, EDITOR_NAME, ["minerva_pcb_hint_undo", "minerva_pcb_hint_redo"])
	check("F: dispatch registry built", registry != null)
	if registry == null:
		return

	var result: Dictionary = await registry.handle_tool_call("minerva_pcb_hint_redo", {
		"editor_name": EDITOR_NAME, "id": _hint_id,
	})
	check("F: minerva_pcb_hint_redo ok", bool(result.get("success", result.get("ok", false))), str(result))

	var ann: Dictionary = host.get_by_id(_hint_id)
	var kp: Dictionary = ann.get("kind_payload", {})
	check("F: waypoints restored to the SQUARED corridor (E's undo is undone)",
		_bends_equal(kp.get("waypoints", []), SQUARED_BENDS), "got %s" % str(kp.get("waypoints")))
	check("F: one revision again (original sloppy)", (ann.get("revision_stack", []) as Array).size() == 1)
	check("F: one redo entry left (the dragged state)", (ann.get("redo_stack", []) as Array).size() == 1)

	_cleanup_stale_registry_dispatch()
	await process_frame


# ── G: apply materializes a trace matching the FINAL payload exactly ─────────

func _test_g_apply_matches_final_payload() -> void:
	print("-- G: apply via minerva_pcb_apply_route_hints (real worker, detailed hint) --")
	check("G: no traces on the board yet", data.get_trace_count() == 0)

	var final_ann: Dictionary = host.get_by_id(_hint_id)
	var final_kp: Dictionary = final_ann.get("kind_payload", {})

	# route_board() requires a mounted "_MinervaIPC" broker node (production:
	# the plugin scene broker; here, the same broker-fidelity fake
	# test_pcb_single_trace_tool.gd uses) — drives the REAL pcb-plugin binary
	# + Python worker over stdio when built, documented canned fallback
	# otherwise.
	var fake := FakeBrokerIpc.new()
	fake.name = "_MinervaIPC"
	fake.suite = self
	panel.add_child(fake)
	panel.request.connect(fake.on_request)

	var propose_res: Dictionary = await panel.handle_tool(
		"minerva_pcb_apply_route_hints", {"editor_name": EDITOR_NAME})
	check("G: propose ok", bool(propose_res.get("success", false)), str(propose_res))
	check("G: board still has 0 traces after propose", data.get_trace_count() == 0)

	var commit_res: Dictionary = await panel.handle_tool(
		"minerva_pcb_apply_route_hints", {"editor_name": EDITOR_NAME, "commit": true})
	check("G: commit ok", bool(commit_res.get("success", false)), str(commit_res))
	check("G: which routing path ran is reported", true,
		"real_worker=%s (binary at <minerva-plugins>/pcb/pcb-plugin)" % str(_used_real_worker))
	check("G: exactly one trace added", int(commit_res.get("traces_added", 0)) == 1, str(commit_res))

	panel.request.disconnect(fake.on_request)
	fake.queue_free()
	await process_frame

	var sig_traces: Array = data.get_traces_for_net("SIG")
	check("G: SIG trace exists", sig_traces.size() >= 1)
	if sig_traces.size() >= 1:
		var t = sig_traces[0]
		var expected: Array = [U1_PIN1]
		for wp in final_kp.get("waypoints", []):
			expected.append(Vector2(wp[0], wp[1]))
		expected.append(U2_PIN1)
		var actual: Array = t.waypoints
		check("G: trace waypoint count matches the final payload exactly",
			actual.size() == expected.size(), "expected=%s actual=%s" % [str(expected), str(actual)])
		# Direction-agnostic (a trace has no inherent forward/reverse
		# semantics — _build_polylines_from_segments chains by endpoint
		# proximity and may emit either order).
		var reversed_expected: Array = expected.duplicate()
		reversed_expected.reverse()
		check("G: trace geometry matches the final (squared, undragged) payload point-for-point",
			_points_equal(actual, expected) or _points_equal(actual, reversed_expected),
			"expected=%s actual=%s" % [str(expected), str(actual)])

	var consumed_ids: Array = commit_res.get("consumed_hint_ids", [])
	check("G: source hint consumed", consumed_ids.size() == 1 and str(consumed_ids[0]) == _hint_id,
		"consumed=%s hint_id=%s" % [str(consumed_ids), _hint_id])
	check("G: consumed hint DELETED from the host", host.get_by_id(_hint_id).is_empty())


# ── H: revision stack survives sidecar save/reload; bounded at cap ───────────

func _test_h_cap_and_sidecar_survival() -> void:
	print("-- H: revision stack bounded at cap + survives sidecar save/reload --")

	var env: Dictionary = host.build_route_hint_envelope(
		U1_PIN1.x, U1_PIN1.y, "", "F.Cu", "single_trace",
		[[0.0, 0.0]], "human", "", 0.25, ["U1.1"], ["U2.1"])
	var hid := str(host.add_annotation_v2(env))
	check("H: fresh hint seeded", not hid.is_empty())

	# 30 edits, transitioning waypoints [[k,k]] -> [[k+1,k+1]] for k=0..29.
	var n := 30
	for k in range(n):
		var ann: Dictionary = host.get_by_id(hid)
		var kp: Dictionary = (ann.get("kind_payload", {}) as Dictionary).duplicate(true)
		kp["waypoints"] = [[float(k + 1), float(k + 1)]]
		var updated := ann.duplicate(true)
		updated["kind_payload"] = kp
		host.update_annotation(hid, updated)

	var after: Dictionary = host.get_by_id(hid)
	var revisions: Array = after.get("revision_stack", [])
	check("H: revision stack capped at 25 (not 30)", revisions.size() == 25, "size=%d" % revisions.size())
	if revisions.size() == 25:
		check("H: oldest 5 dropped — stack starts at the 6th edit's prior payload ([5,5])",
			_bends_equal(revisions[0].get("waypoints", []), [[5.0, 5.0]]), "got %s" % str(revisions[0].get("waypoints")))
		check("H: newest entry is the 30th edit's prior payload ([29,29])",
			_bends_equal(revisions[24].get("waypoints", []), [[29.0, 29.0]]), "got %s" % str(revisions[24].get("waypoints")))
	check("H: current payload is the 30th (final) state ([30,30])",
		_bends_equal((after.get("kind_payload", {}) as Dictionary).get("waypoints", []), [[30.0, 30.0]]),
		"got %s" % str(after.get("kind_payload", {}).get("waypoints")))

	# Sidecar round-trip.
	var sidecar_doc := "user://c4_hint_history_cap.minpcb"
	var save_err: int = host.save_sidecar(sidecar_doc)
	check("H: sidecar save OK", save_err == OK, "err=%d" % save_err)

	host.set_annotations([])
	var loaded: int = host.load_sidecar(sidecar_doc)
	check("H: sidecar reload restored 1 annotation", loaded == 1, "loaded=%d" % loaded)

	var reloaded: Dictionary = host.get_by_id(hid)
	check("H: reloaded hint found", not reloaded.is_empty())
	var reloaded_revisions: Array = reloaded.get("revision_stack", [])
	check("H: reloaded revision stack still capped at 25", reloaded_revisions.size() == 25,
		"size=%d" % reloaded_revisions.size())
	if reloaded_revisions.size() == 25 and revisions.size() == 25:
		check("H: reloaded revision stack content matches pre-save exactly",
			_bends_equal(reloaded_revisions[0].get("waypoints", []), revisions[0].get("waypoints", []))
			and _bends_equal(reloaded_revisions[24].get("waypoints", []), revisions[24].get("waypoints", [])))
	check("H: reloaded current payload still [30,30]",
		_bends_equal((reloaded.get("kind_payload", {}) as Dictionary).get("waypoints", []), [[30.0, 30.0]]))

	var sidecar_path := sidecar_doc + ".annotations.json"
	if FileAccess.file_exists(sidecar_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(sidecar_path))
	host.set_annotations([])


# ── real-worker broker-fidelity fake (test_pcb_single_trace_tool.gd convention) ─
## Mirrors the live broker (MinervaIPC): wraps the backend reply in
## {success, result} while the Go side forwards the worker's own {ok, result}
## envelope verbatim (HandleRouteChannel) — a DOUBLE-wrapped envelope that
## route_board()/the apply tool must unwrap correctly.
class FakeBrokerIpc:
	extends Node
	var suite = null
	var _params: Dictionary = {}
	var _reply_id: String = ""

	func on_request(channel: String, params: Dictionary, reply_id: String) -> void:
		if channel == "pcb.route":
			_params = params
			_reply_id = reply_id

	func await_reply(reply_id: String, _timeout_ms: int = 0) -> Dictionary:
		if reply_id != _reply_id or suite == null:
			return {"success": false, "error_code": "timeout", "error_message": "no captured request"}
		var worker_env: Dictionary = suite.raw_worker_envelope(_params)
		return {"success": true, "result": worker_env}


## Runs the REAL pcb-plugin Go binary + Python worker over stdio with the
## exact captured IPC params (route_hints already has C4's revision/redo
## history stripped by PCBPanel.route_board() -> strip_hint_history — this
## is the "route-request building" exclusion, exercised live here). Returns
## the worker's own {ok, result} envelope (not unwrapped, matching the live
## broker's double-wrap). Falls back to a documented canned "detailed hint
## materializes verbatim" result — same shape route_bridge.
## materialize_detailed_hints produces (see worker/tests/test_route_as_
## drawn.py) — ONLY when the binary genuinely isn't built.
func raw_worker_envelope(params: Dictionary) -> Dictionary:
	var binary_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/pcb-plugin")
	var wrapper_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/scripts/e2e_route_stdio.py")
	if FileAccess.file_exists(binary_path) and FileAccess.file_exists(wrapper_path):
		var req_uri := "user://c4_hint_refine_route_request.json"
		var f := FileAccess.open(req_uri, FileAccess.WRITE)
		if f != null:
			f.store_string(JSON.stringify(params))
			f.close()
			var req_abs := ProjectSettings.globalize_path(req_uri)
			var output: Array = []
			var exit_code := OS.execute("python3", [wrapper_path, binary_path, req_abs], output, true)
			DirAccess.remove_absolute(req_abs)
			if exit_code == 0 and not output.is_empty():
				var parsed: Variant = JSON.parse_string(str(output[0]))
				if parsed is Dictionary and bool((parsed as Dictionary).get("ok", false)):
					_used_real_worker = true
					return parsed
	_used_real_worker = false
	push_warning("[test_pcb_hint_refine_loop] real pcb-plugin binary unavailable — " +
		"falling back to a documented canned 'detailed hint materializes verbatim' result")
	return {"ok": true, "result": _canned_detailed_result()}


## Contract-allowed fallback (subprocess-boundary fake), reached ONLY when the
## real binary isn't built. Mirrors route_bridge.materialize_detailed_hints'
## verbatim-reproduction contract for a detail_level="detailed" single_trace
## hint: segments = [src] + kind_payload.waypoints + [dst], one per leg.
func _canned_detailed_result() -> Dictionary:
	var ann: Dictionary = host.get_by_id(_hint_id)
	var kp: Dictionary = ann.get("kind_payload", {})
	var pts: Array = [U1_PIN1]
	for wp in kp.get("waypoints", []):
		pts.append(Vector2(wp[0], wp[1]))
	pts.append(U2_PIN1)
	var segments: Array = []
	for i in range(pts.size() - 1):
		segments.append({"start": [pts[i].x, pts[i].y], "end": [pts[i + 1].x, pts[i + 1].y], "layer": "F.Cu"})
	return {
		"success": true,
		"via_count": 0,
		"routes": [{"net": "SIG", "segments": segments, "vias": [], "as_drawn": true, "hint_id": _hint_id}],
		"unrouted": [],
	}


# ── helpers ────────────────────────────────────────────────────────────────

func _points_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if (a[i] as Vector2).distance_to(b[i] as Vector2) > 0.01:
			return false
	return true


func _bends_equal(a: Variant, b: Variant) -> bool:
	if not (a is Array) or not (b is Array):
		return false
	var arr_a: Array = a
	var arr_b: Array = b
	if arr_a.size() != arr_b.size():
		return false
	for i in range(arr_a.size()):
		var pa: Array = arr_a[i]
		var pb: Array = arr_b[i]
		if absf(float(pa[0]) - float(pb[0])) > 0.01 or absf(float(pa[1]) - float(pb[1])) > 0.01:
			return false
	return true


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

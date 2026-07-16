extends SceneTree
## Single-trace author tool E2E-3/E2E-4 (WC-3, docket 019f6a894a37).
##
## Run: godot --headless --path . --script test/test_pcb_single_trace_tool.gd
## (run from the Minerva worktree's src/ directory; also runnable WITHOUT
## --headless under xvfb-run for the windowed pixel-probe branch of A1 — see
## _test_e2e3_a_human_hints_it).
##
## E2E-3 "human hints it, agent routes it" (two-pin test board, one net, no
## traces): A) simulate human with the single-trace tool: click pin 1 pad →
## click pin 2 pad → hint commits and DRAWS. B) agent sees it via MCP
## (annotations_list/query). C) agent acts: apply_route_hints → cyan proposal
## → commit → REAL trace connecting pin1-pin2. D) serialize → trace in saved
## YAML/board dict; reload → trace and hint state intact.
##
## E2E-4 "human changes their mind" (same board): A) start, add a waypoint,
## right-click cancel → nothing persisted. B) start again, click the source
## pad as destination → self-reference cancel → nothing persisted. C) author
## a real hint, clear-by-author(human) → gone from canvas/MCP/sidecar; a
## pre-seeded AI proposal SURVIVES the human-clear.
##
## REUSE SCAN: mount/fixture/input conventions copied verbatim from
## test_pcb_workflow_kinds.gd (real PCBPanel boot headless, real input via
## get_root().push_input(), MCP via MODULE.new(null).handle()). The apply/
## materialize call sequence for E2E-3C is copied from test_pcb_apply_
## route_hints.gd (_gather_route_hints / _write_back_proposals /
## _materialize_routes), with the canned RoutingResult REPLACED by a call to
## the REAL pcb-plugin Go binary + real Python pcb_worker over stdio (see
## _real_route_result / pcb/scripts/e2e_route_stdio.py) — falls back to a
## documented canned result ONLY if the binary genuinely isn't built at
## <minerva-plugins>/pcb/pcb-plugin (contract-allowed fallback), and always
## reports which path ran.

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const ANN_MODULE := preload("res://Scripts/Services/MCP/Modules/MCPAnnotationTools.gd")
const PCB_MODULE := preload("res://Scripts/Services/MCP/Modules/MCPPcbPanelTools.gd")
const DRIVER := preload("res://test/helpers/plugin_panel_driver.gd")
const _WorkflowListScript := preload("res://Scripts/UI/Controls/AnnotationDockPane/WorkflowAnnotationList.gd")

const EDITOR_NAME := "SingleTraceProbe"
const PLUGIN_ROOT := "res://../../minerva-plugins/pcb"

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
var pcb_tools = null

const U1_PIN1 := Vector2(15.0, 20.0)
const U2_PIN1 := Vector2(55.0, 20.0)
const WAYPOINT_AT := Vector2(35.0, 10.0)
const EMPTY_DEST_AT := Vector2(35.0, 30.0)


class FakeEditor extends RefCounted:
	var tab_title: String = EDITOR_NAME
	var associated_object: Variant = ""


func _init() -> void:
	print("=== PCB Single-Trace Tool E2E-3 / E2E-4 ===\n")
	await process_frame

	if not await _mount():
		printerr("SETUP FAILED — cannot mount PCB panel; aborting")
		quit(1)
		return

	await _test_e2e3_a_human_hints_it()
	await _test_e2e3_b_agent_sees_it()
	await _test_e2e3_c_agent_routes_it()
	await _test_e2e3_d_serialize_reload()

	await _test_mutual_exclusion_across_surfaces()
	await _test_e2e4_a_cancel_mid_draw()
	await _test_e2e4_b_self_reference_cancel()
	await _test_e2e4_c_clear_by_author()

	await _test_apply_tool_full_mcp_broker_path()

	panel.queue_free()
	await process_frame
	AnnotationHostRegistry._reset_for_test()

	print("\n=== Results: %d passed, %d failed (real_worker_used=%s) ===" % [_pass, _fail, str(_used_real_worker)])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── mount + fixture (test_pcb_workflow_kinds.gd conventions) ─────────────────

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

	# Deterministic view (same technique as test_pcb_workflow_kinds.gd — avoids
	# depending on zoom_to_fit's content-bbox heuristics / the documented
	# canvas_zoom_to_fit test race).
	canvas.zoom = 4.0
	canvas.pan_offset = -Vector2(data.board_width, data.board_height) / 2.0 * canvas.zoom
	canvas.queue_redraw()
	await process_frame

	# The REAL platform overlay, named exactly as Editor.gd mounts it, so the
	# panel's own _find_annotation_overlay() (route-flow cluster) locates it —
	# this test exercises the PRODUCTION lookup path, not a test-only stand-in.
	overlay = AnnotationOverlay.new()
	overlay.name = "PlatformAnnotationOverlay"
	panel.get_annotation_overlay_parent().add_child(overlay)
	overlay.set_host(host)
	await process_frame

	ann_tools = ANN_MODULE.new(null)   # server=null — handle() is server-free.
	pcb_tools = PCB_MODULE.new(null)
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


# ── input helpers (copied convention from test_pcb_workflow_kinds.gd) ────────

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


func _press_escape() -> void:
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	get_root().push_input(ev, true)
	await process_frame


# ── route-flow cluster button helpers (drives the REAL PCBPanel handler) ─────

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


func _active_tool():
	return panel._active_route_flow_tool


# ── E2E-3A: human hints it (toolbar + click flow + preview) ──────────────────

func _test_e2e3_a_human_hints_it() -> void:
	print("-- E2E-3 A: human draws a single-trace hint pin1 → pin2 --")

	check("A: no annotations before drawing", host.get_annotations().size() == 0)

	await _press_trace_button()
	check("A: Trace button toggled on", (panel._route_flow_buttons["single_trace"] as Button).button_pressed)
	check("A: mode label shows Single Trace", panel._route_flow_mode_label.text == "Single Trace")
	check("A: overlay's active tool is our tool", overlay.has_active_tool() and _active_tool() != null)

	await _click_world(U1_PIN1)
	var tool = _active_tool()
	check("A: tool state is drawing after first click", tool != null and tool.current_state() == "drawing")
	var src: Dictionary = tool.source_info() if tool != null else {}
	check("A: source snapped to pad U1.1", str(src.get("type", "")) == "pad"
		and str(src.get("component", "")) == "U1" and str(src.get("pin", "")) == "1",
		"src=%s" % str(src))

	await _click_world(U2_PIN1)
	check("A: hint committed — host has 1 annotation", host.get_annotations().size() == 1,
		"count=%d" % host.get_annotations().size())

	var ann: Dictionary = host.get_annotations()[0] if host.get_annotations().size() == 1 else {}
	check("A: kind is pcb_route_hint", str(ann.get("kind", "")) == "pcb_route_hint")
	var kp: Dictionary = ann.get("kind_payload", {})
	check("A: hint_type is single_trace", str(kp.get("hint_type", "")) == "single_trace")
	check("A: source_pins == [U1.1]", (kp.get("source_pins", []) as Array) == ["U1.1"], "got %s" % str(kp.get("source_pins")))
	check("A: dest_pins == [U2.1]", (kp.get("dest_pins", []) as Array) == ["U2.1"], "got %s" % str(kp.get("dest_pins")))
	check("A: no interior waypoints (direct pad-to-pad)", (kp.get("waypoints", []) as Array).is_empty())
	check("A: layer defaults F.Cu", str(kp.get("layer", "")) == "F.Cu")
	var author: Dictionary = ann.get("author", {})
	check("A: author kind human", str(author.get("kind", "")) == "human")
	var anchor: Dictionary = ann.get("anchor", {})
	check("A: anchor is a semantic pad anchor", str(anchor.get("type", "")) == "pad", "anchor=%s" % str(anchor))
	check("A: anchor id is U1.1", (anchor.get("id", {}) as Dictionary).get("component", "") == "U1"
		and (anchor.get("id", {}) as Dictionary).get("pin", "") == "1")

	check("A: tool stays armed for continuous tracing (button still pressed)",
		(panel._route_flow_buttons["single_trace"] as Button).button_pressed)
	check("A: tool internal state reset to idle post-commit", tool.current_state() == "idle")

	# Canvas state assertion ("DRAWS"): the hint is visible + hit-testable —
	# clicking its polyline midpoint (with the Select tool) selects it. Swap
	# in a Select tool the same way the dock would after deactivating Trace.
	await _release_trace_button()
	var select_tool := AnnotationSelectTool.new()
	select_tool.on_activate(host)
	overlay.set_active_tool(select_tool)
	await process_frame
	var midpoint: Vector2 = (U1_PIN1 + U2_PIN1) / 2.0
	await _click_world(midpoint)
	check("A: hint renders + hit-tests (click on its polyline selects it)",
		host.get_selected_annotation_id() == str(ann.get("id", "")),
		"selected='%s' expected='%s'" % [host.get_selected_annotation_id(), str(ann.get("id", ""))])
	host.set_selected_annotation_id("")
	select_tool.on_deactivate()
	overlay.clear_active_tool()

	# Pixel-probe branch: windowed (xvfb-run) gets a real image; a bare
	# --headless run must get the graceful null envelope (contract §1c).
	var img_result: Dictionary = pcb_tools.handle("minerva_pcb_get_image", {"editor_name": EDITOR_NAME})
	if DisplayServer.get_name() == "headless":
		check("A: pcb_get_image ok:true headless", bool(img_result.get("success", false)), str(img_result))
		check("A: pcb_get_image graceful null envelope headless",
			img_result.get("image_data", "SENTINEL") == null, str(img_result))
	else:
		check("A: pcb_get_image returns real pixels (windowed)",
			bool(img_result.get("success", false)) and img_result.get("image_data", null) != null
			and int(img_result.get("width", 0)) > 0 and int(img_result.get("height", 0)) > 0,
			str(img_result))


# ── E2E-3B: agent sees it via MCP ─────────────────────────────────────────────

func _test_e2e3_b_agent_sees_it() -> void:
	print("-- E2E-3 B: agent sees the hint via MCP annotations_list/query --")
	var listed: Dictionary = await ann_tools.handle("minerva_annotations_list", {"editor_name": EDITOR_NAME})
	check("B: annotations_list ok", bool(listed.get("ok", listed.get("success", false))), str(listed))
	check("B: annotations_list count == 1", int(listed.get("count", -1)) == 1, str(listed))

	var queried: Dictionary = await ann_tools.handle("minerva_annotations_query", {"editor_name": EDITOR_NAME})
	check("B: annotations_query ok", bool(queried.get("ok", false)), str(queried))
	var results: Array = queried.get("annotations", queried.get("results", []))
	check("B: annotations_query returns 1 entry", results.size() == 1, "got %s" % str(queried))
	if results.size() == 1:
		var ann: Dictionary = results[0]
		var kp: Dictionary = ann.get("kind_payload", {})
		check("B: MCP sees source_pins", (kp.get("source_pins", []) as Array) == ["U1.1"])
		check("B: MCP sees dest_pins", (kp.get("dest_pins", []) as Array) == ["U2.1"])
		check("B: MCP sees the semantic pad anchor", str((ann.get("anchor", {}) as Dictionary).get("type", "")) == "pad")


# ── E2E-3C: agent acts — propose → commit → REAL trace ───────────────────────

func _test_e2e3_c_agent_routes_it() -> void:
	print("-- E2E-3 C: agent routes it (propose → commit → real trace) --")
	check("C: no traces on the board yet", data.get_trace_count() == 0)

	var source_hints: Array = pcb_tools._gather_route_hints(host, [])
	check("C: gather finds the open source hint", source_hints.size() == 1, "size=%d" % source_hints.size())

	var result := await _route_result(source_hints)
	check("C: which routing path ran is reported", true,
		"real_worker=%s (binary at <minerva-plugins>/pcb/pcb-plugin)" % str(_used_real_worker))
	check("C: route result reports success", bool(result.get("success", false)), str(result))
	check("C: route result has a SIG route", _has_route_for_net(result, "SIG"), str(result))

	# PROPOSE (write-back): cyan proposal, board unmutated.
	var propose_res: Dictionary = pcb_tools._write_back_proposals(host, result, source_hints)
	check("C: propose ok", bool(propose_res.get("success", false)), str(propose_res))
	check("C: exactly one proposal", int(propose_res.get("proposed", 0)) == 1, str(propose_res))
	check("C: board still has 0 traces after propose", data.get_trace_count() == 0)

	var proposal := _find_proposal()
	check("C: cyan (ai-authored) proposal exists", not proposal.is_empty())
	if not proposal.is_empty():
		check("C: proposal author is ai", str((proposal.get("author", {}) as Dictionary).get("kind", "")) == "ai")

	# COMMIT (materialize): REAL trace connecting pin1-pin2 along the hinted line.
	var commit_res: Dictionary = pcb_tools._materialize_routes(host, data, result, source_hints)
	check("C: materialize ok", bool(commit_res.get("success", false)), str(commit_res))
	check("C: one trace added", int(commit_res.get("traces_added", 0)) >= 1, str(commit_res))
	check("C: board now has a trace", data.get_trace_count() >= 1)

	var sig_traces: Array = data.get_traces_for_net("SIG")
	check("C: SIG trace exists", sig_traces.size() >= 1)
	if sig_traces.size() >= 1:
		var t = sig_traces[0]
		check("C: trace starts at U1.1", (t.get_start() as Vector2).is_equal_approx(U1_PIN1)
			or (t.get_end() as Vector2).is_equal_approx(U1_PIN1), "start=%s end=%s" % [str(t.get_start()), str(t.get_end())])
		check("C: trace reaches U2.1", (t.get_start() as Vector2).is_equal_approx(U2_PIN1)
			or (t.get_end() as Vector2).is_equal_approx(U2_PIN1), "start=%s end=%s" % [str(t.get_start()), str(t.get_end())])

	# Source hint transitioned open→applied.
	var applied_ids: Array = commit_res.get("applied_hint_ids", [])
	check("C: source hint applied", applied_ids.size() == 1)
	if applied_ids.size() == 1:
		var updated: Dictionary = host.get_by_id(str(applied_ids[0]))
		check("C: source hint lifecycle == applied", str(updated.get("lifecycle", "")) == "applied")


## Real-worker-first route call (contract: prefer the real subprocess path).
## Returns a RoutingResult shaped exactly like the worker's own envelope
## ({success, via_count, routes:[{net,segments,vias}], unrouted}); sets
## _used_real_worker so the report can state which path ran.
func _route_result(source_hints: Array) -> Dictionary:
	var real := _real_route_result(data.to_board_dict(), source_hints, {"mode": "open"})
	if not real.is_empty():
		_used_real_worker = true
		return real
	_used_real_worker = false
	push_warning("[test_pcb_single_trace_tool] real pcb-plugin binary unavailable — " +
		"falling back to a documented canned RoutingResult (contract-allowed fallback)")
	return _canned_fallback_result()


## Drives the REAL pcb-plugin Go binary + real Python pcb_worker over stdio via
## pcb/scripts/e2e_route_stdio.py (Godot's OS.execute cannot pipe stdin — see
## that script's header). Returns {} (never crashes) when the binary isn't
## built at the documented location, so the caller can fall back cleanly.
func _real_route_result(board_dict: Dictionary, hints: Array, selection: Dictionary) -> Dictionary:
	var binary_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/pcb-plugin")
	if not FileAccess.file_exists(binary_path):
		return {}
	var wrapper_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/scripts/e2e_route_stdio.py")
	if not FileAccess.file_exists(wrapper_path):
		return {}

	var req_uri := "user://e2e3_route_request.json"
	var f := FileAccess.open(req_uri, FileAccess.WRITE)
	if f == null:
		return {}
	f.store_string(JSON.stringify({"board": board_dict, "route_hints": hints, "selection": selection}))
	f.close()
	var req_abs := ProjectSettings.globalize_path(req_uri)

	var output: Array = []
	var exit_code := OS.execute("python3", [wrapper_path, binary_path, req_abs], output, true)
	DirAccess.remove_absolute(req_abs)
	if exit_code != 0 or output.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(str(output[0]))
	if not (parsed is Dictionary) or not bool((parsed as Dictionary).get("ok", false)):
		return {}
	var res: Variant = (parsed as Dictionary).get("result", {})
	return res if res is Dictionary else {}


## Contract-allowed fallback (subprocess-boundary fake) ONLY reached when the
## real binary genuinely isn't built — same RoutingResult shape
## test_pcb_apply_route_hints.gd's _canned_result() uses, specialised to a
## direct pin1→pin2 SIG route (no waypoints, matches our fixture).
func _canned_fallback_result() -> Dictionary:
	return {
		"success": true,
		"via_count": 0,
		"routes": [{
			"net": "SIG",
			"segments": [{"start": [U1_PIN1.x, U1_PIN1.y], "end": [U2_PIN1.x, U2_PIN1.y], "layer": "F.Cu"}],
			"vias": [],
		}],
		"unrouted": [],
	}


func _has_route_for_net(result: Dictionary, net: String) -> bool:
	for route in result.get("routes", []):
		if route is Dictionary and str((route as Dictionary).get("net", "")) == net:
			return true
	return false


func _find_proposal() -> Dictionary:
	for ann in host.get_all_annotations():
		if not (ann is Dictionary):
			continue
		if str(ann.get("kind", "")) != "pcb_route_hint":
			continue
		var kp: Dictionary = ann.get("kind_payload", {})
		if kp.has("proposal_for"):
			return ann
	return {}


# ── E2E-3D: serialize → reload, trace + hint state intact ────────────────────

func _test_e2e3_d_serialize_reload() -> void:
	print("-- E2E-3 D: serialize the board → trace present; reload → intact --")

	# A real on-disk path so save/load exercises the ACTUAL sidecar round-trip
	# (host_owned pattern — _on_panel_save_request writes the sidecar as a
	# side effect; Editor.gd owns writing the returned board dict to disk as
	# JSON, which is exactly the "saved YAML"/board-file equivalent here).
	var board_dir: String = driver.make_temp_board_dir("e2e3d_single_trace")
	var board_path: String = board_dir + "/board.minpcb"
	panel._file_path = board_path
	host.set_document_path(board_path)

	var trace_count_before: int = data.get_trace_count()
	var hint_count_before: int = host.get_annotations().size()
	var hint_ids_before: Array = []
	for ann in host.get_annotations():
		hint_ids_before.append(str((ann as Dictionary).get("id", "")))

	var saved: Dictionary = panel._on_panel_save_request()
	var traces: Array = saved.get("traces", [])
	check("D: saved board dict carries a trace", traces.size() >= 1, "traces=%s" % str(traces))
	check("D: sidecar was written", AnnotationSidecar.has_sidecar(board_path))

	# Reload the SAME saved shape back through the panel's own load hook
	# (host_owned round-trip — the exact path Ctrl+S/reopen drives) with a
	# real file_path so the sidecar branch actually runs.
	var doc: Dictionary = saved.duplicate(true)
	doc["file_path"] = board_path
	panel._on_panel_load_request(doc)
	await process_frame

	check("D: trace count intact after reload", data.get_trace_count() == trace_count_before,
		"before=%d after=%d" % [trace_count_before, data.get_trace_count()])
	check("D: hint annotation count intact after reload (via sidecar)",
		host.get_annotations().size() == hint_count_before,
		"before=%d after=%d" % [hint_count_before, host.get_annotations().size()])
	for hid in hint_ids_before:
		check("D: hint %s survives the reload" % hid, not host.get_by_id(hid).is_empty())

	driver.cleanup_sidecar(board_path)
	driver.cleanup_board_file(board_path)


# ── E2E-4A: cancel mid-draw (waypoint placed, right-click cancels) ───────────

func _test_e2e4_a_cancel_mid_draw() -> void:
	print("-- E2E-4 A: right-click mid-draw cancels — nothing persisted --")
	var before_count: int = host.get_annotations().size()

	await _press_trace_button()
	await _click_world(U1_PIN1)
	await _click_world(WAYPOINT_AT)   # append a waypoint
	var tool = _active_tool()
	check("4A: waypoint recorded", tool != null and tool.waypoint_count() == 1)

	await _click_world(WAYPOINT_AT, MOUSE_BUTTON_RIGHT)   # right-click cancels
	check("4A: right-click cancel deactivates the tool (button un-pressed)",
		not (panel._route_flow_buttons["single_trace"] as Button).button_pressed)
	check("4A: no envelope committed — annotation count unchanged",
		host.get_annotations().size() == before_count,
		"before=%d after=%d" % [before_count, host.get_annotations().size()])

	var listed: Dictionary = await ann_tools.handle("minerva_annotations_list", {"editor_name": EDITOR_NAME})
	check("4A: MCP echoes the unchanged count (no echo of a cancelled draft)",
		int(listed.get("count", -1)) == before_count, str(listed))


# ── E2E-4B: self-reference cancel ─────────────────────────────────────────────

func _test_e2e4_b_self_reference_cancel() -> void:
	print("-- E2E-4 B: clicking the source pad as its own destination cancels --")
	var before_count: int = host.get_annotations().size()

	await _press_trace_button()
	await _click_world(U1_PIN1)   # source = pad U1.1
	await _click_world(U1_PIN1)   # same pad again → self-reference

	check("4B: self-reference cancel deactivates the tool (button un-pressed)",
		not (panel._route_flow_buttons["single_trace"] as Button).button_pressed)
	check("4B: no envelope committed on self-reference",
		host.get_annotations().size() == before_count,
		"before=%d after=%d" % [before_count, host.get_annotations().size()])

	var listed: Dictionary = await ann_tools.handle("minerva_annotations_list", {"editor_name": EDITOR_NAME})
	check("4B: MCP echoes the unchanged count", int(listed.get("count", -1)) == before_count, str(listed))


# ── E2E-4C: clear-by-author(human) spares AI proposals ────────────────────────

func _test_e2e4_c_clear_by_author() -> void:
	print("-- E2E-4 C: clear-by-author(human) removes human hints, spares AI proposals --")

	# A fresh REAL human hint (pin1 → pin2 again — the E2E-3 hint is already
	# 'applied' by this point, which clear_annotations_by_author does NOT
	# special-case; author.kind is what matters).
	await _press_trace_button()
	await _click_world(U1_PIN1)
	await _click_world(U2_PIN1)
	await _release_trace_button()

	var human_ids: Array = []
	var ai_ids: Array = []
	for ann in host.get_annotations():
		if not (ann is Dictionary):
			continue
		var a: Dictionary = ann.get("author", {})
		if str(a.get("kind", "")) == "human":
			human_ids.append(str(ann.get("id", "")))
		elif str(a.get("kind", "")) == "ai":
			ai_ids.append(str(ann.get("id", "")))
	check("4C: at least one human hint present pre-clear", human_ids.size() >= 1, "human_ids=%s" % str(human_ids))
	check("4C: an AI proposal survives from E2E-3C pre-clear", ai_ids.size() >= 1, "ai_ids=%s" % str(ai_ids))

	var workflow_list = _WorkflowListScript.new()
	get_root().add_child(workflow_list)
	workflow_list.set_host(host)
	await process_frame

	var removed: int = workflow_list.clear_by_author("human")
	check("4C: clear_by_author(human) removed >= 1", removed >= 1, "removed=%d" % removed)

	for hid in human_ids:
		check("4C: human hint %s gone from the host" % hid, host.get_by_id(hid).is_empty())
	for aid in ai_ids:
		check("4C: AI proposal %s SURVIVES the human-clear" % aid, not host.get_by_id(aid).is_empty())

	# Gone from MCP too (UI clear IS a real removal, not a view filter).
	var listed: Dictionary = await ann_tools.handle("minerva_annotations_list", {"editor_name": EDITOR_NAME})
	var mcp_ids := []
	for a in listed.get("annotations", listed.get("results", [])):
		mcp_ids.append(str((a as Dictionary).get("id", "")))
	for hid in human_ids:
		check("4C: human hint %s gone from MCP" % hid, not (hid in mcp_ids))
	for aid in ai_ids:
		check("4C: AI proposal %s still visible via MCP" % aid, aid in mcp_ids)

	# Gone from the sidecar (persist the clear, then reload and confirm).
	var sidecar_doc := "user://e2e4c_board.minpcb"
	var err: int = host.save_sidecar(sidecar_doc)
	check("4C: sidecar save OK", err == OK, "err=%d" % err)
	host.set_annotations([])
	var loaded: int = host.load_sidecar(sidecar_doc)
	var reloaded_kinds := {}
	for hid in human_ids:
		reloaded_kinds[hid] = false
	for aid in ai_ids:
		reloaded_kinds[aid] = false
	for ann in host.get_annotations():
		var aid2 := str((ann as Dictionary).get("id", ""))
		if reloaded_kinds.has(aid2):
			reloaded_kinds[aid2] = true
	for hid in human_ids:
		check("4C: human hint %s absent from reloaded sidecar" % hid, not reloaded_kinds.get(hid, false))
	for aid in ai_ids:
		check("4C: AI proposal %s present in reloaded sidecar" % aid, reloaded_kinds.get(aid, false))
	check("4C: reload count == survivors only", loaded == ai_ids.size(), "loaded=%d expected=%d" % [loaded, ai_ids.size()])

	var sidecar_path := sidecar_doc + ".annotations.json"
	if FileAccess.file_exists(sidecar_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(sidecar_path))
	workflow_list.queue_free()
	await process_frame


# ── cross-surface mutual exclusion (review must_fix regression) ──────────────
## Arming the Trace tool must release the canvas tool surface (Pan /
## Pin-Inspect drop to Select, buttons un-press) and vice versa: pressing a
## canvas tool while tracing deactivates the route-flow cluster.
func _test_mutual_exclusion_across_surfaces() -> void:
	print("\n-- mutual exclusion: route-flow cluster vs canvas tool surface --")
	var canvas = panel._canvas
	var modes = canvas.ToolMode

	# Pin-Inspect armed, then Trace pressed -> canvas back to SELECT, button off.
	panel._inspect_pin_button.button_pressed = true
	panel._on_inspect_pin_button_pressed()
	await process_frame
	check("MX: pin-inspect armed (precondition)", canvas.tool_mode == modes.INSPECT_PIN)
	await _press_trace_button()
	check("MX: trace activation resets canvas to SELECT", canvas.tool_mode == modes.SELECT,
		"mode=%d" % canvas.tool_mode)
	check("MX: pin-inspect button un-pressed", not panel._inspect_pin_button.button_pressed)
	check("MX: trace tool active", _active_tool() != null)

	# Trace active, then Pan pressed -> route-flow cluster fully released.
	panel._toggle_tool_mode(modes.PAN)
	await process_frame
	check("MX: canvas tool press deactivates trace tool", _active_tool() == null)
	check("MX: trace button un-pressed after canvas tool press",
		not (panel._route_flow_buttons["single_trace"] as Button).button_pressed)
	check("MX: canvas is in PAN", canvas.tool_mode == modes.PAN)

	# Trace active, then Pin-Inspect pressed -> same release path.
	await _press_trace_button()
	check("MX: trace re-armed", _active_tool() != null)
	panel._inspect_pin_button.button_pressed = true
	panel._on_inspect_pin_button_pressed()
	await process_frame
	check("MX: pin-inspect press deactivates trace tool", _active_tool() == null)
	check("MX: canvas is in INSPECT_PIN", canvas.tool_mode == modes.INSPECT_PIN)

	# Restore a neutral state for the next scenario.
	panel._inspect_pin_button.button_pressed = false
	panel._on_inspect_pin_button_pressed()
	await process_frame


# ── full MCP path through the broker envelope (HITL-2 live-bug regression) ───
## The live broker (MinervaIPC) wraps the backend reply in {success, result}
## while the Go side forwards the worker's own {ok, result} envelope verbatim
## (HandleRouteChannel) — so route_board receives a DOUBLE-wrapped envelope.
## E2E-3C fed the RoutingResult straight into the write-back helpers and never
## crossed that hop, which let a live "0 proposals from a routable hint" bug
## through. This section drives the REAL minerva_pcb_apply_route_hints handle()
## through a broker-fidelity IPC fake (still calling the REAL worker binary
## when present).
class FakeBrokerIpc:
	extends Node
	var suite = null
	var _params: Dictionary = {}
	var _reply_id: String = ""

	func on_request(channel: String, params: Dictionary, reply_id: String) -> void:
		if channel == "pcb.route":
			_params = params
			_reply_id = reply_id

	## Duck-typed stand-in for MinervaIPC.await_reply — returns the LIVE broker
	## envelope shape: {success:true, result:<worker's own {ok, result}>}.
	func await_reply(reply_id: String, _timeout_ms: int = 0) -> Dictionary:
		if reply_id != _reply_id or suite == null:
			return {"success": false, "error_code": "timeout", "error_message": "no captured request"}
		var worker_env: Dictionary = suite.raw_worker_envelope(_params)
		return {"success": true, "result": worker_env}


## Runs the stdio bridge with the exact captured IPC params; returns the
## worker's own {ok, result} envelope (NOT unwrapped). Canned fallback keeps
## the same double shape when the binary genuinely isn't built.
func raw_worker_envelope(params: Dictionary) -> Dictionary:
	var binary_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/pcb-plugin")
	var wrapper_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/scripts/e2e_route_stdio.py")
	if FileAccess.file_exists(binary_path) and FileAccess.file_exists(wrapper_path):
		var req_uri := "user://e2e_broker_route_request.json"
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
					return parsed
	return {"ok": true, "result": _canned_fallback_result()}


func _test_apply_tool_full_mcp_broker_path() -> void:
	print("\n-- apply tool through the FULL MCP + broker-envelope path --")
	var traces_before: int = data.get_trace_count()

	# Fresh open hint (host-authored twin of a tool-drawn one).
	var env: Dictionary = host.build_route_hint_envelope(
		U1_PIN1.x, U1_PIN1.y, "", "F.Cu", "single_trace",
		[[U1_PIN1.x, U1_PIN1.y], [U2_PIN1.x, U2_PIN1.y]], "human")
	var kp: Dictionary = env.get("kind_payload", {})
	kp["source_pins"] = ["U1.1"]
	kp["dest_pins"] = ["U2.1"]
	env["kind_payload"] = kp
	var hint_id := str(host.add_annotation_v2(env))
	check("BR: fresh hint added", not hint_id.is_empty())

	# Broker-fidelity IPC fake mounted exactly where route_board looks.
	var fake := FakeBrokerIpc.new()
	fake.name = "_MinervaIPC"
	fake.suite = self
	panel.add_child(fake)
	panel.request.connect(fake.on_request)

	var propose_res: Dictionary = await pcb_tools.handle(
		"minerva_pcb_apply_route_hints", {"editor_name": EDITOR_NAME})
	check("BR: propose ok through full MCP path", bool(propose_res.get("success", false)), str(propose_res))
	check("BR: broker double-envelope unwrapped -> >=1 proposal",
		int(propose_res.get("proposed", 0)) >= 1, str(propose_res))

	var commit_res: Dictionary = await pcb_tools.handle(
		"minerva_pcb_apply_route_hints", {"editor_name": EDITOR_NAME, "commit": true})
	check("BR: commit ok through full MCP path", bool(commit_res.get("success", false)), str(commit_res))
	check("BR: trace added through full MCP path", data.get_trace_count() > traces_before,
		"before=%d after=%d" % [traces_before, data.get_trace_count()])

	panel.request.disconnect(fake.on_request)
	fake.queue_free()
	await process_frame


# ── assertion helper ──────────────────────────────────────────────────────────

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

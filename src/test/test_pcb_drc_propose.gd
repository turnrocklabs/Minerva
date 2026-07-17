extends SceneTree
## DRC-at-propose E2E (docket 019f6f1492e0): real PCBPanel + REAL worker.
##
## Extends the C5 explicit-propose product contract (test_pcb_explicit_propose.gd)
## with the DRC-at-propose deliverable: after Propose routes open hints, each
## proposal's kind_payload.drc carries the worker's per-route DRC verdict
## (pcb_worker.methods._attach_route_drc reusing drc.py's existing geometric
## checks verbatim), the propose envelope surfaces a top-level drc_summary, the
## panel status label appends a DRC suffix, the WorkflowAnnotationList dock
## renders a warning badge for a dirty proposal and none for a clean one, and
## accepting a violating proposal still works (informs, never blocks).
##
## Run: godot --headless --path . --script test/test_pcb_drc_propose.gd
## (from the Minerva WORKTREE's src/ directory — never the owner's live
## checkout, see CRITICAL SAFETY in the round brief).
##
## Fixture geometry (deliberately mirrors pcb/worker/tests/test_route_drc.py so
## the plugin-side and worker-side DRC coverage reason about the SAME shapes):
##   * SIG1: U1(10,20) <-> J1(50,20), straight pad-to-pad — CROSSES an existing
##     EXIST trace authored directly on the board at x=30 (y 5..35, same
##     "top" layer) -> its proposal must come back dirty.
##   * SIG2: U3(10,60) <-> J3(50,60), straight pad-to-pad, far from EXIST ->
##     its proposal must come back clean.
## Both hints are 'detailed' (0 interior waypoints, i.e. pad -> pad verbatim)
## so both the real worker AND this suite's canned stdio-boundary fallback
## (which always emits a straight pad-to-pad segment, ignoring waypoints)
## produce IDENTICAL routed geometry — the DRC assertions hold on either path.
##
## REUSE SCAN: mount/input/real-worker-stdio/FakeBrokerIpc conventions copied
## verbatim from test_pcb_explicit_propose.gd (same PANEL_PATH, same
## e2e_route_stdio.py bridge, same documented canned fallback). The existing
## suite's own scenarios (A-F) are left untouched — this is a fresh dedicated
## suite rather than a 7th scenario grafted onto that file's already-shared
## six-scenario fixture state, per the round brief's "(or a new suite modeled
## on it)" option.

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const REGISTRY_DRIVER := preload("res://test/helpers/panel_tool_registry_driver.gd")

const EDITOR_NAME := "DrcProposeProbe"
const PLUGIN_ROOT := "res://../../minerva-plugins/pcb"
const PCB_PLUGIN_ID := "pcb"

var _pass := 0
var _fail := 0
var _used_real_worker := false

var panel = null
var host = null
var data = null

const U1_PIN := Vector2(10.0, 20.0)
const J1_PIN := Vector2(50.0, 20.0)
const U3_PIN := Vector2(10.0, 60.0)
const J3_PIN := Vector2(50.0, 60.0)


class FakeEditor extends RefCounted:
	var tab_title: String = EDITOR_NAME
	var associated_object: Variant = ""


func _init() -> void:
	print("=== PCB DRC-at-Propose E2E (docket 019f6f1492e0) ===\n")
	await process_frame

	if not await _mount():
		printerr("SETUP FAILED — cannot mount PCB panel; aborting")
		quit(1)
		return

	await _test_propose_flags_dirty_and_clean_routes()

	panel.queue_free()
	await process_frame
	AnnotationHostRegistry._reset_for_test()

	print("\n=== Results: %d passed, %d failed (real_worker_used=%s) ===" % [_pass, _fail, str(_used_real_worker)])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── mount + fixture (test_pcb_explicit_propose.gd conventions) ───────────────

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
	_seed_hints()

	for _i in range(4):
		await process_frame

	AnnotationHostRegistry._reset_for_test()
	AnnotationHostRegistry.register(EDITOR_NAME, host)
	return true


## SIG1 (U1<->J1) will collide with a hand-authored EXIST trace; SIG2
## (U3<->J3) sits far away and stays clean. EXIST is authored as a raw trace
## with NO matching net/components entry — board_to_router() (the router's
## own board builder) only reads canonical board "nets", never "traces", so
## an untracked EXIST trace cannot be auto-routed by the engine's "route every
## net with >=2 pads" behavior (see nudge hint
## pcb-plugin/router-reroutes-whole-board) — it exists purely as fixed copper
## for the DRC pass to check the new routes against, keeping this fixture
## deterministic.
func _build_fixture_board(d) -> void:
	d.board_width = 70.0
	d.board_height = 80.0

	var u1 = d.new_component()
	u1.id = "U1"
	u1.position = U1_PIN
	u1.pins = {"SIG1": Vector2(0.0, 0.0)}
	d.add_component(u1)

	var j1 = d.new_component()
	j1.id = "J1"
	j1.position = J1_PIN
	j1.pins = {"SIG1": Vector2(0.0, 0.0)}
	d.add_component(j1)

	d.connect_pin_to_net("SIG1", "U1", "SIG1")
	d.connect_pin_to_net("SIG1", "J1", "SIG1")

	var u3 = d.new_component()
	u3.id = "U3"
	u3.position = U3_PIN
	u3.pins = {"SIG2": Vector2(0.0, 0.0)}
	d.add_component(u3)

	var j3 = d.new_component()
	j3.id = "J3"
	j3.position = J3_PIN
	j3.pins = {"SIG2": Vector2(0.0, 0.0)}
	d.add_component(j3)

	d.connect_pin_to_net("SIG2", "U3", "SIG2")
	d.connect_pin_to_net("SIG2", "J3", "SIG2")

	var exist_trace = d.new_trace()
	exist_trace.net_name = "EXIST"
	exist_trace.layer = "top"
	exist_trace.width = 0.25
	# trace.waypoints is Array[Vector2] — append one at a time (matches
	# PCBPanel._materialize_routes' own convention) rather than assigning a
	# plain Array literal, which the typed-array setter rejects.
	exist_trace.waypoints.append(Vector2(30.0, 5.0))
	exist_trace.waypoints.append(Vector2(30.0, 35.0))
	d.add_trace(exist_trace)


## Hints built directly (host.build_route_hint_envelope), same pattern as
## test_pcb_explicit_propose.gd scenario E's fresh_hint_id — this suite's
## focus is the DRC wiring, not re-proving real-click hint authoring (already
## covered by scenario A of that suite).
func _seed_hints() -> void:
	var env1: Dictionary = host.build_route_hint_envelope(
		U1_PIN.x, U1_PIN.y, "", "F.Cu", "single_trace",
		[], "human", "detailed", 0.25, ["U1.SIG1"], ["J1.SIG1"])
	var id1 := str(host.add_annotation_v2(env1))
	check("setup: SIG1 (dirty) hint seeded", not id1.is_empty())

	var env2: Dictionary = host.build_route_hint_envelope(
		U3_PIN.x, U3_PIN.y, "", "F.Cu", "single_trace",
		[], "human", "detailed", 0.25, ["U3.SIG2"], ["J3.SIG2"])
	var id2 := str(host.add_annotation_v2(env2))
	check("setup: SIG2 (clean) hint seeded", not id2.is_empty())


# ── real-worker broker-fidelity fake (test_pcb_explicit_propose.gd convention) ─

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


func raw_worker_envelope(params: Dictionary) -> Dictionary:
	var binary_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/pcb-plugin")
	var wrapper_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/scripts/e2e_route_stdio.py")
	if FileAccess.file_exists(binary_path) and FileAccess.file_exists(wrapper_path):
		var req_uri := "user://drc_propose_route_request.json"
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
	push_warning("[test_pcb_drc_propose] real pcb-plugin binary unavailable — " +
		"falling back to a documented canned single-segment result (no DRC)")
	return {"ok": true, "result": _canned_result_for(params)}


## Contract-allowed fallback (subprocess-boundary fake), reached ONLY when the
## real binary isn't built: one straight pad->pad segment per open hint,
## deliberately WITHOUT any drc/drc_summary keys (a real worker is required to
## exercise the DRC assertions below; when this path is taken the suite still
## proves propose-without-DRC degrades gracefully — no badge, no status
## suffix — rather than skip outright).
func _canned_result_for(params: Dictionary) -> Dictionary:
	var routes: Array = []
	for hint in params.get("route_hints", []):
		if not (hint is Dictionary):
			continue
		var kp: Dictionary = (hint as Dictionary).get("kind_payload", {})
		var src: Array = kp.get("source_pins", [])
		var dst: Array = kp.get("dest_pins", [])
		if src.is_empty() or dst.is_empty():
			continue
		var src_pos := _pin_world_pos(str(src[0]))
		var dst_pos := _pin_world_pos(str(dst[0]))
		var net := _net_for_pin(str(src[0]))
		routes.append({
			"net": net,
			"segments": [{"start": [src_pos.x, src_pos.y], "end": [dst_pos.x, dst_pos.y], "layer": "F.Cu"}],
			"vias": [],
		})
	return {"success": true, "via_count": 0, "routes": routes, "unrouted": []}


func _pin_world_pos(ref: String) -> Vector2:
	var parts := ref.split(".")
	if parts.size() != 2:
		return Vector2.ZERO
	var comp = data.get_component(parts[0])
	if comp == null:
		return Vector2.ZERO
	return comp.get_pin_world_position(parts[1])


func _net_for_pin(ref: String) -> String:
	var parts := ref.split(".")
	if parts.size() != 2:
		return ""
	for net_name in data.nets:
		var net = data.nets[net_name]
		for pin in net.pins:
			if str(pin.get("component_id", "")) == parts[0] and str(pin.get("pin_name", "")) == parts[1]:
				return net.name
	return ""


## Real input on the Propose button — same async-drain convention as
## test_pcb_explicit_propose.gd's _click_propose_button.
func _click_propose_button() -> void:
	panel._propose_button.pressed.emit()
	var guard := 0
	while panel._status_label.text == "Proposing routes…" and guard < 200:
		await process_frame
		guard += 1


# ── the scenario ───────────────────────────────────────────────────────────

func _test_propose_flags_dirty_and_clean_routes() -> void:
	print("-- Propose (real input, REAL worker when available) --")

	var fake := FakeBrokerIpc.new()
	fake.name = "_MinervaIPC"
	fake.suite = self
	panel.add_child(fake)
	panel.request.connect(fake.on_request)

	await _click_propose_button()

	check("which routing path ran is reported", true,
		"real_worker=%s (binary at <minerva-plugins>/pcb/pcb-plugin)" % str(_used_real_worker))

	if not _used_real_worker:
		printerr("SKIP-NOTE: real pcb-plugin binary unavailable — DRC assertions below " +
			"require the real worker (the canned fallback carries no drc/drc_summary). " +
			"Verifying graceful degradation only.")
		check("no-DRC degrade: status label has no DRC suffix",
			not panel._status_label.text.contains("DRC"),
			"got '%s'" % panel._status_label.text)
		panel.request.disconnect(fake.on_request)
		fake.queue_free()
		return

	# -- envelope-level drc_summary (deliverable 1/2) --------------------------
	var reply: Dictionary = await panel.handle_tool("minerva_pcb_apply_route_hints", {"commit": false})
	check("propose ok", bool(reply.get("success", false)), str(reply))
	var summary: Dictionary = reply.get("drc_summary", {})
	check("drc_summary present", not summary.is_empty(), str(reply))
	check("drc_summary.clean is false (SIG1 collides)", summary.get("clean", true) == false, str(summary))
	check("drc_summary.violation_count >= 1", int(summary.get("violation_count", 0)) >= 1, str(summary))

	# -- status label (deliverable 3) ------------------------------------------
	check("status label reports a DRC violation count",
		panel._status_label.text.findn("DRC:") != -1 and panel._status_label.text.findn("violation") != -1,
		"got '%s'" % panel._status_label.text)

	# -- per-proposal kind_payload.drc (deliverable 2) --------------------------
	var dirty_proposal: Dictionary = {}
	var clean_proposal: Dictionary = {}
	for ann in host.get_annotations():
		if not (ann is Dictionary):
			continue
		var kp: Dictionary = ann.get("kind_payload", {})
		var nets: Array = kp.get("net_names", [])
		if nets == ["SIG1"]:
			dirty_proposal = ann
		elif nets == ["SIG2"]:
			clean_proposal = ann

	check("SIG1 proposal exists", not dirty_proposal.is_empty(), str(host.get_annotations()))
	check("SIG2 proposal exists", not clean_proposal.is_empty(), str(host.get_annotations()))

	if not dirty_proposal.is_empty():
		var dirty_drc: Dictionary = dirty_proposal.get("kind_payload", {}).get("drc", {})
		check("SIG1 proposal kind_payload.drc.clean == false", dirty_drc.get("clean", true) == false, str(dirty_drc))
		check("SIG1 proposal kind_payload.drc.violations non-empty",
			(dirty_drc.get("violations", []) as Array).size() >= 1, str(dirty_drc))

	if not clean_proposal.is_empty():
		var clean_drc: Dictionary = clean_proposal.get("kind_payload", {}).get("drc", {})
		check("SIG2 proposal kind_payload.drc.clean == true", clean_drc.get("clean", false) == true, str(clean_drc))
		check("SIG2 proposal kind_payload.drc.violations empty",
			(clean_drc.get("violations", []) as Array).size() == 0, str(clean_drc))

	# Propose is fully resolved — drop the route-worker fake before any further
	# dispatch (test_pcb_explicit_propose.gd convention: never leave a stale
	# "_MinervaIPC" node/connection lying around for a later dispatch to trip
	# over — see _cleanup_stale_registry_dispatch below).
	panel.request.disconnect(fake.on_request)
	fake.queue_free()
	await process_frame

	# -- MCP annotations_list surfaces kind_payload.drc unmodified (deliverable 2) --
	# MCPAnnotationTools reads the live AnnotationHost directly (no route-worker
	# IPC involved) — instantiated the same way test_pcb_route_hint_mcp_parity.gd
	# does (ANN_MODULE.new(null): mcp_server unused for a direct handler call).
	var ann_tools = MCPAnnotationTools.new(null)
	var list_result: Dictionary = ann_tools._annotations_list({"editor_name": EDITOR_NAME})
	check("annotations_list ok", bool(list_result.get("success", false)), str(list_result))
	var found_drc_via_mcp := false
	for a in (list_result.get("annotations", []) as Array):
		if not (a is Dictionary):
			continue
		var kp2: Dictionary = (a as Dictionary).get("kind_payload", {})
		if (kp2.get("net_names", []) as Array) == ["SIG1"] and kp2.has("drc"):
			found_drc_via_mcp = true
	check("annotations_list exposes kind_payload.drc for the dirty proposal", found_drc_via_mcp,
		str(list_result))

	# -- WorkflowAnnotationList dock badge (deliverable 4) ----------------------
	var wf_list := WorkflowAnnotationList.new()
	get_root().add_child(wf_list)
	wf_list.set_host(host)
	await process_frame

	# Recursive: rows moved inside a capped ScrollContainer (dock-size fix).
	var groups_node := wf_list.find_child("WorkflowGroups", true, false)
	check("WorkflowGroups node mounted", groups_node != null)
	if groups_node != null and not dirty_proposal.is_empty() and not clean_proposal.is_empty():
		var dirty_summary := str(dirty_proposal.get("summary", ""))
		var clean_summary := str(clean_proposal.get("summary", ""))
		var dirty_row: Control = null
		var clean_row: Control = null
		for child in groups_node.get_children():
			if not (child is HBoxContainer):
				continue
			var tt := str((child as Control).tooltip_text)
			if tt == dirty_summary:
				dirty_row = child
			elif tt == clean_summary:
				clean_row = child
		check("dirty proposal row found", dirty_row != null)
		check("clean proposal row found", clean_row != null)
		if dirty_row != null:
			var badge := dirty_row.find_child("DrcBadge", false, false)
			check("dirty row has a DRC badge", badge != null)
			if badge != null:
				check("dirty badge text starts with a warning glyph", str(badge.text).begins_with("⚠"),
					"got '%s'" % str(badge.text))
		if clean_row != null:
			check("clean row has NO DRC badge", clean_row.find_child("DrcBadge", false, false) == null)

	wf_list.queue_free()
	await process_frame

	# -- accept a VIOLATING proposal still works (informs, never blocks) --------
	# panel_tool_registry_driver.build() attaches its OWN real "_MinervaIPC"
	# helper node to `panel` (test_pcb_explicit_propose.gd's documented
	# platform-gap finding, scenario C) — clean it up afterward so it can't
	# collide with anything else. The route-worker `fake` above is already
	# disconnected/freed by this point, so there is nothing else to preserve.
	if not dirty_proposal.is_empty():
		var dirty_id := str(dirty_proposal.get("id", ""))
		var traces_before: int = data.get_trace_count()
		var registry: PluginToolRegistry = REGISTRY_DRIVER.new().build(
			panel, PCB_PLUGIN_ID, EDITOR_NAME, ["minerva_pcb_proposal_accept"])
		check("accept-dispatch registry built", registry != null)
		if registry != null:
			var accept_result: Dictionary = await registry.handle_tool_call("minerva_pcb_proposal_accept", {
				"editor_name": EDITOR_NAME, "id": dirty_id,
			})
			check("accepting a violating proposal still succeeds (informs, never blocks)",
				bool(accept_result.get("success", false)), str(accept_result))
			check("a trace was added despite the violation",
				data.get_trace_count() > traces_before,
				"before=%d after=%d" % [traces_before, data.get_trace_count()])
		_cleanup_stale_registry_dispatch()
		await process_frame


## Mirrors test_pcb_explicit_propose.gd's helper of the same name: a
## panel_tool_registry_driver dispatch leaves a real "_MinervaIPC" node +
## panel.request connection behind (a platform gap, out of this round's
## fence) — clean both by hand so nothing later collides with it.
func _cleanup_stale_registry_dispatch() -> void:
	for conn in panel.request.get_connections():
		panel.request.disconnect(conn["callable"])
	for child in panel.get_children():
		if str(child.name).begins_with("_MinervaIPC"):
			panel.remove_child(child)
			child.queue_free()


# ── helpers ────────────────────────────────────────────────────────────────

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

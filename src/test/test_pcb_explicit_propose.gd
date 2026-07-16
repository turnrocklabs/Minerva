extends SceneTree
## Explicit-propose UX + proposal lifecycle E2E (C5, docket 019f6c465fd8).
##
## Run: godot --headless --path . --script test/test_pcb_explicit_propose.gd
## (run from the Minerva worktree's src/ directory — see CRITICAL SAFETY in
## the round brief: never run headless godot from the non-worktree checkout).
##
## Product contract v2 (owner-ratified): the router NEVER runs implicitly —
## proposing routes is always an explicit human or agent act. Proposals (cyan
## AI annotations linked to hints via kind_payload.proposal_for) are
## individually answerable: ACCEPT materializes that proposal's trace, deletes
## the consumed source hint(s) AND the proposal; REJECT deletes the proposal,
## source hints stay open for iteration.
##
## Scenarios:
##   A) Human draws a hint via the Trace tool (real input) → NO proposal exists
##      (nothing auto-fires — panel mount / tool activation / annotation
##      changes never invoke the router; this is deliverable 4's audit,
##      exercised live).
##   B) Click the Propose button (real input on the actual Button, not a
##      direct handler call for the click itself — see _click_propose_button)
##      → a cyan AI-authored proposal linked to the hint appears; the board is
##      NOT mutated. Also proves the WorkflowAnnotationList generic
##      Accept/Reject wiring (deliverable 2's UI half): the proposal row gets
##      Accept/Reject buttons, the plain-hint row does not.
##   C) minerva_pcb_proposal_reject via REAL panel-tool dispatch (
##      panel_tool_registry_driver, same rig test_pcb_apply_route_hints.gd /
##      test_pcb_hint_refine_loop.gd use for panel-executed tools) → proposal
##      gone, source hint still open, zero residue.
##   D) Propose again → accept via minerva_pcb_proposal_accept (REAL dispatch)
##      → a real trace matches the proposal's own polyline exactly; the source
##      hint AND the proposal are both deleted; the board has exactly one
##      trace.
##   E) Backend-stopped affordance (bug 019f6c1e0399): sabotage the IPC seam
##      the way test_pcb_apply_route_hints.gd simulates worker-unavailable
##      (a fake "_MinervaIPC" node intercepting panel.request) — but replying
##      with the SAME {error_code:"plugin_not_running", ...} shape
##      PluginScenePanelBroker._dispatch_to_plugin_backend returns when the
##      backend subprocess isn't RUNNING (not the "no bridge at all" shape the
##      existing suite uses). The Propose button's status label shows the
##      human-actionable message; the tool result carries the structured
##      pcb_backend_stopped error + recovery hint.
##   F) Bulk regression: minerva_pcb_apply_route_hints commit=true still works
##      through the SAME _materialize_routes machinery the new per-proposal
##      accept path now shares — delete-on-commit contract intact.
##
## REUSE SCAN: mount/fixture/input/real-worker-stdio conventions copied
## verbatim from test_pcb_hint_refine_loop.gd (real PCBPanel boot headless,
## real input via get_root().push_input(), the e2e_route_stdio.py bridge +
## documented canned fallback for real-worker steps, the FakeBrokerIpc
## broker-fidelity shape). REAL panel-tool dispatch for the new proposal
## accept/reject tools uses test/helpers/panel_tool_registry_driver.gd (same
## fixture test_pcb_panel_tools_migration.gd established, reused by every pcb
## panel-tool suite since).
##
## Off-tree: the plugin scripts live outside res://; every panel/host/model
## ref is duck-typed and loaded by path (never typed AS a plugin class).

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const REGISTRY_DRIVER := preload("res://test/helpers/panel_tool_registry_driver.gd")

const EDITOR_NAME := "ExplicitProposeProbe"
const PLUGIN_ROOT := "res://../../minerva-plugins/pcb"
const PCB_PLUGIN_ID := "pcb"

var _pass := 0
var _fail := 0
var _used_real_worker := false

var panel = null
var canvas = null
var host = null
var data = null

var overlay: AnnotationOverlay = null

const U1_PIN1 := Vector2(15.0, 20.0)
const U2_PIN1 := Vector2(55.0, 20.0)
const U3_PIN1 := Vector2(15.0, 55.0)
const U4_PIN1 := Vector2(55.0, 55.0)

var _hint_id := ""
var _proposal_id := ""


class FakeEditor extends RefCounted:
	var tab_title: String = EDITOR_NAME
	var associated_object: Variant = ""


func _init() -> void:
	print("=== PCB Explicit-Propose + Proposal-Lifecycle E2E (C5) ===\n")
	await process_frame

	if not await _mount():
		printerr("SETUP FAILED — cannot mount PCB panel; aborting")
		quit(1)
		return

	await _test_a_draw_hint_nothing_auto_fires()
	await _test_b_propose_creates_proposal()
	await _test_c_reject_via_real_dispatch()
	await _test_d_propose_again_then_accept_via_real_dispatch()
	await _test_e_backend_stopped_affordance()
	await _test_f_bulk_commit_regression()

	panel.queue_free()
	await process_frame
	AnnotationHostRegistry._reset_for_test()

	print("\n=== Results: %d passed, %d failed (real_worker_used=%s) ===" % [_pass, _fail, str(_used_real_worker)])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── mount + fixture (test_pcb_hint_refine_loop.gd conventions) ───────────────

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

	canvas.zoom = 4.0
	canvas.pan_offset = -Vector2(data.board_width, data.board_height) / 2.0 * canvas.zoom
	canvas.queue_redraw()
	await process_frame

	overlay = AnnotationOverlay.new()
	overlay.name = "PlatformAnnotationOverlay"
	panel.get_annotation_overlay_parent().add_child(overlay)
	overlay.set_host(host)
	await process_frame

	AnnotationHostRegistry._reset_for_test()
	AnnotationHostRegistry.register(EDITOR_NAME, host)
	return true


## Only U1/U2 (net SIG) are wired up front — U3/U4 (net SIG2) are added later,
## right before scenario F, so earlier scenarios' router calls only ever see
## the ONE net that has an open hint (matches test_pcb_hint_refine_loop.gd's
## single-net fixture, a proven-working shape for the real worker).
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


# ── input helpers (copied convention from test_pcb_hint_refine_loop.gd) ──────

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


## Real input on the Propose button (deliverable 1: "Click Propose button
## (real input)") — a plain (non-toggle) Button, so a real click is just
## emitting its own `pressed` signal (no button_pressed toggle-state to
## manage, unlike the Trace/Edit-hint radio buttons above). Godot resumes the
## connected async handler across its internal awaits before this call
## returns (signals don't block on coroutine completion), so callers must
## await process_frame in a loop until the panel's status label stops
## reading "Proposing routes…" — mirrors how a real user's click resolves
## asynchronously without freezing the UI thread.
func _click_propose_button() -> void:
	panel._propose_button.pressed.emit()
	var guard := 0
	while panel._status_label.text == "Proposing routes…" and guard < 200:
		await process_frame
		guard += 1


# ── real-worker broker-fidelity fake (test_pcb_hint_refine_loop.gd convention) ─
## Mirrors the live broker (MinervaIPC): wraps the backend reply in
## {success, result} while the Go side forwards the worker's own {ok, result}
## envelope verbatim (HandleRouteChannel).
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
## exact captured IPC params. Returns the worker's own {ok, result} envelope
## (matching the live broker's double-wrap). Falls back to a documented canned
## "single segment source-pad→dest-pad" result ONLY when the binary genuinely
## isn't built.
func raw_worker_envelope(params: Dictionary) -> Dictionary:
	var binary_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/pcb-plugin")
	var wrapper_path := ProjectSettings.globalize_path(PLUGIN_ROOT + "/scripts/e2e_route_stdio.py")
	if FileAccess.file_exists(binary_path) and FileAccess.file_exists(wrapper_path):
		var req_uri := "user://c5_explicit_propose_route_request.json"
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
	push_warning("[test_pcb_explicit_propose] real pcb-plugin binary unavailable — " +
		"falling back to a documented canned single-segment result")
	return {"ok": true, "result": _canned_result_for(params)}


## Contract-allowed fallback (subprocess-boundary fake), reached ONLY when the
## real binary isn't built: one straight segment per open route_hint envelope
## in the request, source pad → dest pad, on the hint's own net (derived from
## source_pins' component's connected net — falls back to "SIG" when absent,
## which is the only net every fixture hint in this suite ever uses).
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
		return "SIG"
	for net_name in data.nets:
		var net = data.nets[net_name]
		for pin in net.pins:
			if str(pin.get("component_id", "")) == parts[0] and str(pin.get("pin_name", "")) == parts[1]:
				return net.name
	return "SIG"


# ── A: draw a hint via the Trace tool; NOTHING auto-fires ────────────────────

func _test_a_draw_hint_nothing_auto_fires() -> void:
	print("-- A: human draws a hint pin1 -> pin2 via the Trace tool (real input) --")
	check("A: no annotations before drawing", host.get_annotations().size() == 0)

	await _press_trace_button()
	check("A: overlay's active tool is a route-flow tool", overlay.has_active_tool())

	await _click_world(U1_PIN1)
	await _click_world(U2_PIN1)   # dest pad -> commits (0 interior waypoints)

	check("A: hint committed — host has exactly 1 annotation", host.get_annotations().size() == 1,
		"count=%d" % host.get_annotations().size())

	var ann: Dictionary = host.get_annotations()[0] if host.get_annotations().size() == 1 else {}
	_hint_id = str(ann.get("id", ""))
	check("A: hint id assigned", not _hint_id.is_empty())
	check("A: hint_type is single_trace", str(ann.get("kind_payload", {}).get("hint_type", "")) == "single_trace")
	check("A: source_pins == [U1.1]", (ann.get("kind_payload", {}).get("source_pins", []) as Array) == ["U1.1"])
	check("A: dest_pins == [U2.1]", (ann.get("kind_payload", {}).get("dest_pins", []) as Array) == ["U2.1"])

	# Deliverable 4 (nothing auto-fires), exercised live: drawing a hint alone
	# never invokes the router — no proposal exists, board unmutated.
	check("A: NO proposal exists — nothing auto-fired",
		not _any_proposal_exists(), "annotations=%s" % str(host.get_annotations()))
	check("A: board has zero traces (nothing auto-fired)", data.get_trace_count() == 0)

	await _release_trace_button()


func _any_proposal_exists() -> bool:
	for ann in host.get_annotations():
		if ann is Dictionary and not (ann.get("kind_payload", {}).get("proposal_for", []) as Array).is_empty():
			return true
	return false


# ── B: click Propose; a cyan proposal appears; board unmutated ───────────────

func _test_b_propose_creates_proposal() -> void:
	print("-- B: click Propose (real input, REAL worker) --")

	var fake := FakeBrokerIpc.new()
	fake.name = "_MinervaIPC"
	fake.suite = self
	panel.add_child(fake)
	panel.request.connect(fake.on_request)

	await _click_propose_button()

	check("B: which routing path ran is reported", true,
		"real_worker=%s (binary at <minerva-plugins>/pcb/pcb-plugin)" % str(_used_real_worker))
	check("B: status label reports one proposal", panel._status_label.text == "1 proposal",
		"got '%s'" % panel._status_label.text)
	check("B: host now has 2 annotations (hint + proposal)", host.get_annotations().size() == 2,
		"count=%d" % host.get_annotations().size())
	check("B: board still unmutated — zero traces", data.get_trace_count() == 0)

	var proposal: Dictionary = {}
	for ann in host.get_annotations():
		if ann is Dictionary and not (ann.get("kind_payload", {}).get("proposal_for", []) as Array).is_empty():
			proposal = ann
	check("B: a proposal exists", not proposal.is_empty())
	_proposal_id = str(proposal.get("id", ""))
	check("B: proposal id assigned", not _proposal_id.is_empty())
	check("B: proposal is AI-authored (cyan)", str(proposal.get("author", {}).get("kind", "")) == "ai")
	check("B: proposal links back to the source hint",
		(proposal.get("kind_payload", {}).get("proposal_for", []) as Array) == [_hint_id],
		"got %s" % str(proposal.get("kind_payload", {}).get("proposal_for", [])))
	check("B: proposal carries a routable polyline (>=2 points)",
		(proposal.get("kind_payload", {}).get("waypoints", []) as Array).size() >= 2)

	panel.request.disconnect(fake.on_request)
	fake.queue_free()
	await process_frame

	await _test_b2_workflow_list_generic_wiring(proposal.duplicate(true))


## B2 (deliverable 2's UI half): mount the CORE WorkflowAnnotationList against
## the SAME live host and prove the generic accept/reject wiring — the
## proposal row gets Accept/Reject buttons, the plain human-drawn hint row
## does not. Zero pcb-specific knowledge on the core side (the row match is by
## the proposal's own distinct summary text, "Proposed route …", which
## _write_back_proposals stamps — not by any pcb kind_payload field name).
func _test_b2_workflow_list_generic_wiring(proposal: Dictionary) -> void:
	print("-- B2: WorkflowAnnotationList generic per-row Accept/Reject wiring --")
	var wf_list := WorkflowAnnotationList.new()
	get_root().add_child(wf_list)
	wf_list.set_host(host)
	await process_frame

	var listing: Array = wf_list.get_listing()
	check("B2: listing has 2 entries (hint + proposal)", listing.size() == 2, "got %d" % listing.size())

	var proposal_summary := str(proposal.get("summary", ""))
	var groups_node := wf_list.get_node_or_null("WorkflowGroups")
	check("B2: WorkflowGroups node mounted", groups_node != null)
	if groups_node != null:
		var proposal_row: Control = null
		var hint_row: Control = null
		for child in groups_node.get_children():
			if not (child is HBoxContainer):
				continue
			if str((child as Control).tooltip_text) == proposal_summary:
				proposal_row = child
			else:
				hint_row = child   # the only other row — the plain human hint
		check("B2: proposal row found", proposal_row != null)
		check("B2: hint row found", hint_row != null)
		if proposal_row != null:
			check("B2: proposal row has an Accept button",
				proposal_row.find_child("AcceptButton", false, false) != null)
			check("B2: proposal row has a Reject button",
				proposal_row.find_child("RejectButton", false, false) != null)
		if hint_row != null:
			check("B2: plain hint row has NO Accept button",
				hint_row.find_child("AcceptButton", false, false) == null)
			check("B2: plain hint row has NO Reject button",
				hint_row.find_child("RejectButton", false, false) == null)

	wf_list.queue_free()
	await process_frame


# ── C: reject via REAL panel-tool dispatch — proposal gone, hint stays open ──

func _test_c_reject_via_real_dispatch() -> void:
	print("-- C: minerva_pcb_proposal_reject via REAL registry dispatch --")
	var registry: PluginToolRegistry = REGISTRY_DRIVER.new().build(
		panel, PCB_PLUGIN_ID, EDITOR_NAME, ["minerva_pcb_proposal_reject", "minerva_pcb_proposal_accept"])
	check("C: dispatch registry built", registry != null)
	if registry == null:
		return

	var result: Dictionary = await registry.handle_tool_call("minerva_pcb_proposal_reject", {
		"editor_name": EDITOR_NAME, "id": _proposal_id,
	})
	check("C: reject ok", bool(result.get("success", false)), str(result))
	check_eq("C: removed_proposal_id", str(result.get("removed_proposal_id", "")), _proposal_id)
	check("C: source_hints_still_open == [hint_id]",
		(result.get("source_hints_still_open", []) as Array) == [_hint_id],
		"got %s" % str(result.get("source_hints_still_open", [])))

	check("C: proposal gone, zero residue — exactly 1 annotation left", host.get_annotations().size() == 1,
		"count=%d" % host.get_annotations().size())
	var remaining: Dictionary = host.get_by_id(_hint_id)
	check("C: the source hint itself is untouched and still open",
		not remaining.is_empty() and str(remaining.get("lifecycle", "")) == "open")
	check("C: board still has zero traces", data.get_trace_count() == 0)

	_cleanup_stale_registry_dispatch()
	await process_frame


## panel_tool_registry_driver.build() attaches a REAL MinervaIPC helper node
## ("_MinervaIPC") to `panel` and connects an anonymous lambda to panel.request
## — neither is undone by a normal call flow (a platform gap, out of this
## round's fence — same finding test_pcb_hint_refine_loop.gd documents at its
## own call site). Clean both by hand between dispatch calls so a later
## FakeBrokerIpc mount doesn't collide with a stale non-functional broker.
func _cleanup_stale_registry_dispatch() -> void:
	for conn in panel.request.get_connections():
		panel.request.disconnect(conn["callable"])
	for child in panel.get_children():
		if str(child.name).begins_with("_MinervaIPC"):
			panel.remove_child(child)
			child.queue_free()


# ── D: propose again, then accept via REAL dispatch ───────────────────────────

func _test_d_propose_again_then_accept_via_real_dispatch() -> void:
	print("-- D: propose again, then minerva_pcb_proposal_accept via REAL dispatch --")

	var fake := FakeBrokerIpc.new()
	fake.name = "_MinervaIPC"
	fake.suite = self
	panel.add_child(fake)
	panel.request.connect(fake.on_request)

	await _click_propose_button()
	check("D: status label reports one proposal again", panel._status_label.text == "1 proposal",
		"got '%s'" % panel._status_label.text)

	panel.request.disconnect(fake.on_request)
	fake.queue_free()
	await process_frame

	var new_proposal: Dictionary = {}
	for ann in host.get_annotations():
		if ann is Dictionary and not (ann.get("kind_payload", {}).get("proposal_for", []) as Array).is_empty():
			new_proposal = ann
	check("D: a fresh proposal exists", not new_proposal.is_empty())
	var new_proposal_id := str(new_proposal.get("id", ""))
	var proposal_waypoints: Array = new_proposal.get("kind_payload", {}).get("waypoints", [])

	var registry: PluginToolRegistry = REGISTRY_DRIVER.new().build(
		panel, PCB_PLUGIN_ID, EDITOR_NAME, ["minerva_pcb_proposal_accept"])
	check("D: dispatch registry built", registry != null)
	if registry == null:
		return

	check("D: no traces on the board yet", data.get_trace_count() == 0)
	var result: Dictionary = await registry.handle_tool_call("minerva_pcb_proposal_accept", {
		"editor_name": EDITOR_NAME, "id": new_proposal_id,
	})
	check("D: accept ok", bool(result.get("success", false)), str(result))
	check("D: trace_added true", bool(result.get("trace_added", false)))
	check("D: consumed_hint_ids == [hint_id]",
		(result.get("consumed_hint_ids", []) as Array) == [_hint_id],
		"got %s" % str(result.get("consumed_hint_ids", [])))
	check_eq("D: removed_proposal_id", str(result.get("removed_proposal_id", "")), new_proposal_id)

	check("D: exactly one trace on the board", data.get_trace_count() == 1,
		"count=%d" % data.get_trace_count())
	var sig_traces: Array = data.get_traces_for_net("SIG")
	check("D: SIG trace exists", sig_traces.size() == 1)
	if sig_traces.size() == 1:
		var t = sig_traces[0]
		var expected: Array = []
		for wp in proposal_waypoints:
			expected.append(Vector2(wp[0], wp[1]))
		check("D: trace polyline matches the proposal's own polyline exactly (point count)",
			(t.waypoints as Array).size() == expected.size(),
			"expected=%s actual=%s" % [str(expected), str(t.waypoints)])
		check("D: trace polyline matches the proposal's own polyline exactly (points)",
			_points_equal(t.waypoints, expected) or _points_equal(t.waypoints, _reversed(expected)),
			"expected=%s actual=%s" % [str(expected), str(t.waypoints)])

	check("D: source hint deleted", host.get_by_id(_hint_id).is_empty())
	check("D: proposal deleted", host.get_by_id(new_proposal_id).is_empty())
	check("D: zero annotations left", host.get_annotations().is_empty(),
		"count=%d" % host.get_annotations().size())

	_cleanup_stale_registry_dispatch()
	await process_frame


# ── E: backend-stopped affordance ─────────────────────────────────────────────

## Sabotage-broker fake replying with the SAME shape
## PluginScenePanelBroker._dispatch_to_plugin_backend returns when the pcb
## backend subprocess is registered but not RUNNING — distinct from
## test_pcb_apply_route_hints.gd's "no _MinervaIPC at all" worker-unavailable
## simulation (that shape stays a generic route_worker_unavailable; THIS shape
## is the one PCBPanel.route_board()/panel_tools.gd's _router_unavailable must
## now recognise specifically).
class SabotageBrokerIpc:
	extends Node
	var _reply_id: String = ""

	func on_request(channel: String, _params: Dictionary, reply_id: String) -> void:
		if channel == "pcb.route":
			_reply_id = reply_id

	func await_reply(reply_id: String, _timeout_ms: int = 0) -> Dictionary:
		if reply_id != _reply_id:
			return {"success": false, "error_code": "timeout", "error_message": "no captured request"}
		return {"success": false, "error_code": "plugin_not_running",
			"error_message": "Plugin is not running", "plugin_id": PCB_PLUGIN_ID}


func _test_e_backend_stopped_affordance() -> void:
	print("-- E: backend-stopped affordance (bug 019f6c1e0399) --")

	# A fresh open hint so _apply_route_hints reaches the router bridge
	# instead of short-circuiting on "no open route hints".
	var env: Dictionary = host.build_route_hint_envelope(
		U1_PIN1.x, U1_PIN1.y, "", "F.Cu", "single_trace",
		[], "human", "", 0.25, ["U1.1"], ["U2.1"])
	var fresh_hint_id := str(host.add_annotation_v2(env))
	check("E: fresh hint seeded", not fresh_hint_id.is_empty())
	var traces_before_e: int = data.get_trace_count()

	var sabotage := SabotageBrokerIpc.new()
	sabotage.name = "_MinervaIPC"
	panel.add_child(sabotage)
	panel.request.connect(sabotage.on_request)

	# Structured machine shape: call the tool directly (same code path the
	# Propose button uses).
	var tool_result: Dictionary = await panel.handle_tool("minerva_pcb_apply_route_hints", {"commit": false})
	check("E: tool result is not success", not bool(tool_result.get("success", true)))
	check_eq("E: tool error tag", str(tool_result.get("error", "")), "pcb_backend_stopped")
	check_eq("E: recovery hint", str(tool_result.get("recovery_hint", "")), "start via minerva_plugin_start")
	check("E: detail carries the plugin_not_running kind",
		str(tool_result.get("detail", {}).get("kind", "")) == "plugin_not_running",
		str(tool_result))
	check("E: board unmutated by the sabotaged call — trace count unchanged",
		data.get_trace_count() == traces_before_e,
		"before=%d after=%d" % [traces_before_e, data.get_trace_count()])

	# Human-actionable shape: the Propose button's status label.
	await _click_propose_button()
	check_eq("E: status label shows the backend-stopped affordance", panel._status_label.text,
		"Routing needs the pcb backend — it's stopped. Start it from the Plugin Manager, then retry.")

	panel.request.disconnect(sabotage.on_request)
	sabotage.queue_free()
	await process_frame

	check("E: fresh hint still open (never consumed by the failed attempt)",
		str(host.get_by_id(fresh_hint_id).get("lifecycle", "")) == "open")

	# FINDING (not a C5 regression — pre-existing route_board() behavior):
	# PCBPanel.route_board() gathers EVERY pcb_route_hint annotation on the
	# host into the IPC request regardless of the selection/hint_ids scope
	# the caller passed — only _gather_route_hints' SOURCE-hint bookkeeping
	# (consumed ids / width lookup) is scoped by hint_ids; the routes a
	# router reply contains are all materialized unconditionally. Left open,
	# this leftover hint would make F's explicit hint_ids=[sig2] commit also
	# re-route (and re-materialize a duplicate trace for) net SIG. Clean it
	# up so F's assertions measure ONLY its own net, matching how a real user
	# would also want to resolve/redraw a stale failed-propose hint before
	# moving on rather than have it silently ride along on the next call.
	host.remove_annotation(fresh_hint_id)


# ── F: bulk commit=true regression — shared machinery, delete-on-commit intact ─

func _test_f_bulk_commit_regression() -> void:
	print("-- F: bulk apply_route_hints commit=true regression (shared machinery) --")

	var u3 = data.new_component()
	u3.id = "U3"
	u3.position = U3_PIN1
	u3.pins = {"1": Vector2(0.0, 0.0)}
	data.add_component(u3)

	var u4 = data.new_component()
	u4.id = "U4"
	u4.position = U4_PIN1
	u4.pins = {"1": Vector2(0.0, 0.0)}
	data.add_component(u4)

	data.connect_pin_to_net("SIG2", "U3", "1")
	data.connect_pin_to_net("SIG2", "U4", "1")

	var env: Dictionary = host.build_route_hint_envelope(
		U3_PIN1.x, U3_PIN1.y, "", "F.Cu", "single_trace",
		[], "human", "", 0.3, ["U3.1"], ["U4.1"])
	var sig2_hint_id := str(host.add_annotation_v2(env))
	check("F: SIG2 hint seeded", not sig2_hint_id.is_empty())

	var traces_before: int = data.get_trace_count()

	var fake := FakeBrokerIpc.new()
	fake.name = "_MinervaIPC"
	fake.suite = self
	panel.add_child(fake)
	panel.request.connect(fake.on_request)

	# Explicit hint_ids scopes which ANNOTATION counts as a source hint (so
	# ONLY sig2_hint_id can be consumed/deleted), immune to any hint residue
	# left by earlier scenarios. It does NOT scope which board NETS the
	# worker routes — FINDING (pre-existing, not a C5 regression): board_to_
	# router() (route_bridge.py) builds the router's Board from the
	# canonical board's components/nets only, never reading `traces` — so it
	# has no notion of "already wired" and route_board()/route_board_with_
	# hints() re-route EVERY net on the board with >=2 pads, including SIG
	# (already real-traced by scenario D). traces_added can therefore be >1
	# here; the assertions below check what THIS deliverable actually
	# promises — the SIG2 net got exactly one trace and its hint followed
	# the delete-on-commit contract — not the worker's total trace count.
	var result: Dictionary = await panel.handle_tool("minerva_pcb_apply_route_hints", {
		"hint_ids": [sig2_hint_id], "commit": true,
	})
	check("F: commit ok", bool(result.get("success", false)), str(result))
	check("F: committed flag true", bool(result.get("committed", false)))
	check("F: at least one trace added", int(result.get("traces_added", 0)) >= 1, str(result))
	check("F: board trace count did not decrease",
		data.get_trace_count() >= traces_before,
		"before=%d after=%d" % [traces_before, data.get_trace_count()])

	var sig2_traces: Array = data.get_traces_for_net("SIG2")
	check("F: exactly one SIG2 trace exists", sig2_traces.size() == 1, "count=%d" % sig2_traces.size())

	# Delete-on-commit contract intact: the consumed source hint is gone.
	check("F: SIG2 hint consumed", (result.get("consumed_hint_ids", []) as Array) == [sig2_hint_id],
		"got %s" % str(result.get("consumed_hint_ids", [])))
	check("F: SIG2 hint deleted from the host", host.get_by_id(sig2_hint_id).is_empty())

	panel.request.disconnect(fake.on_request)
	fake.queue_free()
	await process_frame


# ── helpers ────────────────────────────────────────────────────────────────

func _points_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		if (a[i] as Vector2).distance_to(b[i] as Vector2) > 0.01:
			return false
	return true


func _reversed(a: Array) -> Array:
	var out := a.duplicate()
	out.reverse()
	return out


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


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)

extends SceneTree
## Unit tests for minerva_pcb_apply_route_hints — the route-correction
## collaboration loop (route-proposal write-back + apply). Docket: minerva
## 019eb481cddd · agent-router child 019eb47eb567 · DCR 019dc140.
##
## Run: godot --headless --path src --script test/test_pcb_apply_route_hints.gd
##
## Drives the apply flow through the module against a REAL PcbAnnotationHost +
## PCBPanel board model (same harness as test_pcb_panel_tools.gd). Because the
## router WORKER is unreachable headless (no IPC channel / no worker binary), the
## worker `route` call is STUBBED at the boundary: the write-back / materialize /
## lifecycle logic is exercised directly against a CANNED RoutingResult (the exact
## {success, routes[…segments…], unrouted, via_count} shape methods.py._route
## returns). The tool-level handle() path is exercised only for its error shapes
## (missing/unknown editor) and the worker-unavailable failure-as-feedback shape —
## which is what a live headless call actually hits.
##
## Off-tree: the plugin scripts live outside res://; every panel/host/model ref is
## duck-typed and loaded by path (never typed AS a plugin class).

const MODULE := preload("res://Scripts/Services/MCP/Modules/MCPPcbPanelTools.gd")
const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const DRIVER := preload("res://test/helpers/plugin_panel_driver.gd")

const EDITOR := "PCB1"

var _pass := 0
var _fail := 0

var tools
var panel      # PCBPanel (duck-typed Node)
var host       # PcbAnnotationHost (duck-typed)
var data       # pcb_data model (duck-typed)


## Canned RoutingResult — the worker `route` reply payload for a run that routed
## GND (2 F.Cu segments + a via) and SIG (1 B.Cu segment), leaving PWR unrouted.
func _canned_result() -> Dictionary:
	return {
		"success": true,
		"via_count": 1,
		"routes": [
			{
				"net": "GND",
				"segments": [
					{"start": [0.0, 0.0], "end": [5.0, 0.0], "layer": "F.Cu"},
					{"start": [5.0, 0.0], "end": [5.0, 5.0], "layer": "F.Cu"},
				],
				"vias": [[5.0, 5.0]],
			},
			{
				"net": "SIG",
				"segments": [
					{"start": [10.0, 0.0], "end": [15.0, 0.0], "layer": "B.Cu"},
				],
				"vias": [],
			},
		],
		"unrouted": [{"net": "PWR", "from": "U2.1", "to": "J1.2"}],
		"warnings": [],
	}


func _init() -> void:
	print("=== minerva_pcb_apply_route_hints Tests ===\n")
	tools = MODULE.new(null)  # server=null — handle() is server-free for these paths.

	if not _setup():
		printerr("SETUP FAILED — cannot load plugin panel; aborting")
		quit(1)
		return

	await _run_error_shapes()   # async handle() paths (open hints still present)
	_run_write_back()           # sync: propose → cyan proposals, board unmutated
	_run_commit_and_iterate()   # sync: materialize traces + open→applied + re-gather

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
	data.clear()  # blank board (the panel seeds U1/R1 in _init)

	AnnotationHostRegistry._reset_for_test()
	AnnotationHostRegistry.register(EDITOR, host)

	# Two OPEN source hints: GND (0.4mm, U1.1→R1.1) and SIG (0.25mm).
	_seed_hint("GND", 0.4, ["U1.1"], ["R1.1"])
	_seed_hint("SIG", 0.25, [], [])
	return true


func _teardown() -> void:
	AnnotationHostRegistry._reset_for_test()
	if panel is Node:
		(panel as Node).free()


## Build + store an OPEN human pcb_route_hint carrying a target net + width.
func _seed_hint(net: String, width: float, src: Array, dst: Array) -> String:
	var env: Dictionary = host.build_route_hint_envelope(1.0, 2.0, "", "F.Cu", "waypoint", [], "human")
	var kp: Dictionary = env.get("kind_payload", {})
	kp["net_names"] = [net]
	kp["width_mm"] = width
	kp["source_pins"] = src
	kp["dest_pins"] = dst
	env["kind_payload"] = kp
	return host.add_annotation_v2(env)


# ── assertion helpers ─────────────────────────────────────────────────────────

func check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func check_eq(desc: String, actual, expected) -> void:
	check("%s (expected %s, got %s)" % [desc, str(expected), str(actual)], actual == expected)


func _find_proposal(net: String) -> Dictionary:
	for ann in host.get_all_annotations():
		if not (ann is Dictionary):
			continue
		if str(ann.get("kind", "")) != "pcb_route_hint":
			continue
		var kp: Dictionary = ann.get("kind_payload", {})
		if not kp.has("proposal_for"):
			continue
		if net in _names(kp.get("net_names", [])):
			return ann
	return {}


func _names(raw) -> Array:
	var out: Array = []
	if raw is Array:
		for v in raw:
			out.append(str(v))
	return out


# ── error shapes + worker-unavailable (async handle) ──────────────────────────

func _run_error_shapes() -> void:
	print("-- error shapes + worker-unavailable --")
	var missing: Dictionary = await tools.handle("minerva_pcb_apply_route_hints", {})
	check("missing editor_name → error", not bool(missing.get("success", true)))
	check_eq("missing editor_name message", missing.get("error", ""), "editor_name is required")

	var unknown: Dictionary = await tools.handle("minerva_pcb_apply_route_hints", {"editor_name": "NOPE"})
	check("unknown editor → error", not bool(unknown.get("success", true)))
	check("unknown editor names the miss", str(unknown.get("error", "")).begins_with("no_pcb_host_for_editor"))

	# Open source hints exist → the tool reaches the worker bridge, which is
	# unreachable headless (no _MinervaIPC) → structured failure-as-feedback.
	var wu: Dictionary = await tools.handle("minerva_pcb_apply_route_hints", {"editor_name": EDITOR})
	check("worker-unavailable → not success", not bool(wu.get("success", true)))
	check_eq("worker-unavailable error tag", wu.get("error", ""), "route_worker_unavailable")
	check("worker-unavailable echoes hint_ids", (wu.get("hint_ids", []) as Array).size() == 2)
	check("board unmutated by unavailable route", data.get_trace_count() == 0)


# ── propose: write-back cyan proposals, board unmutated ───────────────────────

func _run_write_back() -> void:
	print("-- propose (write-back) --")
	var source_hints: Array = tools._gather_route_hints(host, [])
	check_eq("gather open source hints", source_hints.size(), 2)

	var res: Dictionary = tools._write_back_proposals(host, _canned_result(), source_hints)
	check("write-back ok", bool(res.get("success", false)))
	check_eq("proposed count", res.get("proposed", 0), 2)
	check_eq("not committed", res.get("committed", true), false)
	check("board still unmutated (no traces)", data.get_trace_count() == 0)

	# Stuck feedback carries the unrouted net's blocked pad pair.
	var stuck: Array = res.get("stuck", [])
	check_eq("one stuck net", stuck.size(), 1)
	if stuck.size() == 1:
		check_eq("stuck net is PWR", (stuck[0] as Dictionary).get("net", ""), "PWR")
		check_eq("stuck from", (stuck[0] as Dictionary).get("from", ""), "U2.1")
		check_eq("stuck to", (stuck[0] as Dictionary).get("to", ""), "J1.2")

	# GND proposal: AI-authored (→ cyan), linked to the GND source hint, 3 waypoints.
	var gnd: Dictionary = _find_proposal("GND")
	check("GND proposal exists", not gnd.is_empty())
	if not gnd.is_empty():
		var author: Dictionary = gnd.get("author", {})
		check_eq("GND proposal author is ai (cyan)", author.get("kind", ""), "ai")
		check_eq("GND proposal lifecycle open", gnd.get("lifecycle", ""), "open")
		var kp: Dictionary = gnd.get("kind_payload", {})
		var linked: Array = kp.get("proposal_for", [])
		check("GND proposal_for non-empty", linked.size() >= 1)
		var wps: Array = kp.get("waypoints", [])
		check_eq("GND proposal 3 waypoints", wps.size(), 3)
		if wps.size() == 3:
			check("GND wp0 == [0,0]", float(wps[0][0]) == 0.0 and float(wps[0][1]) == 0.0)
			check("GND wp2 == [5,5]", float(wps[2][0]) == 5.0 and float(wps[2][1]) == 5.0)
		check_eq("GND proposal width from hint", float(kp.get("width_mm", 0.0)), 0.4)

	var sig: Dictionary = _find_proposal("SIG")
	check("SIG proposal exists", not sig.is_empty())


# ── commit: materialize traces + open→applied, then iterate ───────────────────

func _run_commit_and_iterate() -> void:
	print("-- commit (materialize) + iterate --")
	var source_hints: Array = tools._gather_route_hints(host, [])
	check_eq("source hints still open pre-commit", source_hints.size(), 2)

	# Known undo baseline (blank board) so the journal-ordering guard below is
	# deterministic regardless of prior history depth.
	data.save_to_history("baseline")

	var res: Dictionary = tools._materialize_routes(host, data, _canned_result(), source_hints)
	check("materialize ok", bool(res.get("success", false)))
	check_eq("committed flag", res.get("committed", false), true)
	check_eq("two traces added", res.get("traces_added", 0), 2)
	check_eq("no failed nets", (res.get("failed", []) as Array).size(), 0)
	check_eq("two hints applied", res.get("applied", 0), 2)

	# GND trace geometry: top layer, 0.4mm, waypoints [(0,0),(5,0),(5,5)].
	var gnd_traces: Array = data.get_traces_for_net("GND")
	check_eq("one GND trace", gnd_traces.size(), 1)
	if gnd_traces.size() == 1:
		var t = gnd_traces[0]
		check_eq("GND trace layer top", t.layer, "top")
		check_eq("GND trace width 0.4", float(t.width), 0.4)
		check_eq("GND trace 3 waypoints", t.waypoints.size(), 3)
		if t.waypoints.size() == 3:
			check("GND trace wp0", (t.waypoints[0] as Vector2).is_equal_approx(Vector2(0, 0)))
			check("GND trace wp2", (t.waypoints[2] as Vector2).is_equal_approx(Vector2(5, 5)))

	# SIG trace on the bottom layer.
	var sig_traces: Array = data.get_traces_for_net("SIG")
	check_eq("one SIG trace", sig_traces.size(), 1)
	if sig_traces.size() == 1:
		check_eq("SIG trace layer bottom", sig_traces[0].layer, "bottom")

	# One via materialized (GND's).
	check_eq("one via added", data.vias.size(), 1)

	# Journal-ordering guard: the "Apply route hints" checkpoint is snapshotted
	# AFTER the traces are added, so undo restores the pre-apply (blank) board and
	# redo re-applies — the applied state is recoverable on both sides.
	check("can undo after apply", data.can_undo())
	data.undo()
	check_eq("undo restores pre-apply board (0 traces)", data.get_trace_count(), 0)
	data.redo()
	check_eq("redo re-applies traces (2)", data.get_trace_count(), 2)

	# Owner-ratified contract (HITL-2): consumed hints are DELETED on commit
	# (not kept as lifecycle=applied); answering proposals are removed too.
	for hid in res.get("consumed_hint_ids", []):
		check("source hint %s deleted on commit" % hid, host.get_by_id(str(hid)).is_empty())

	# ITERATE: consumed hints are gone and AI proposals are excluded from the
	# default gather, so a re-run finds no fresh open source hints.
	var after: Array = tools._gather_route_hints(host, [])
	check_eq("re-gather finds no fresh open hints", after.size(), 0)

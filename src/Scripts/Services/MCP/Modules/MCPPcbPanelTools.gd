class_name MCPPcbPanelTools
extends MCPToolModule
## MCP tool module for the PCB PLUGIN panel's panel-coupled tools.
## Docket: minerva 019eb47e72a7 · DCR 019dc140.
##
## WAVE-2 ONLY (DCR 019f6c3d0e3d, C2 round, docket 019f6c45f09e): the wave-1
## board-model tools (set_board_size, get_components, get_nets,
## get_pin_position, pin_info, add_component, move_component, move_relative,
## rotate_component, delete_component, connect_net, spatial_query,
## describe_component, import_csv, export_csv, import_footprint_geometry)
## MIGRATED to the pcb plugin's own panel_tools.gd (executor "panel") and are
## no longer registered or handled here — see
## Docs/design/panel-executed-tools.md. This module now owns only the
## remaining wave-2 tools: the change journal, trace-geometry round-trip, the
## snapshot image, and the async route-correction loop
## (minerva_pcb_apply_route_hints) — all still resolved off the registered
## PcbAnnotationHost via AnnotationHostRegistry (backend-executor this round;
## C3 migrates wave-2 + deletes this module).
##
## Architecture (copies the CAD precedent, MCPCadTools):
##   * Off-tree discipline. PcbAnnotationHost and the pcb model scripts
##     (pcb_data/pcb_component/pcb_spatial_index) are PLUGIN classes living
##     outside res://. This core module MUST NOT reference them by class_name /
##     preload. Every host/model/component call goes through duck typing
##     (has_method / call / property access on the returned Variant). The host is
##     typed as AnnotationHost (the platform base class the registry stores).
##   * Single gateway. AnnotationHostRegistry.get_host(editor_name) yields the
##     PcbAnnotationHost; host.get_board_data() vends the live pcb_data model and
##     host.get_spatial_index() vends the pcb_spatial_index. All mutations run
##     against the model API so its change journal, undo history and data_changed
##     dirty relay come for free.
##
## RETIRED legacy tools (NOT here — see pcb/docs/tools.md for the disposition):
##   annotations/route-hints → core minerva_annotations_*; interpret_route_hints
##   → agent-router; create_note → generic plugin_data note flow;
##   minerva_create_pcb_editor → minerva_create_plugin_editor; export_yaml →
##   worker pcb.serialize / the panel's Export YAML action.
## WORKER tools (already live, not here): pcb_validate / pcb_generate /
##   pcb_check_libraries / pcb_check_bom.
##
## NAME-COLLISION GUARD. The legacy in-tree MCPPCBTools registers these SAME
## minerva_pcb_* names (for the in-tree PCBEditor) and sits earlier in
## MinervaMCPServer._modules, so it wins dispatch (first can_handle wins) AND its
## schema would be clobbered by a later duplicate registration (tool_registry is
## a name-keyed Dict, last-writer-wins). MinervaMCPServer offers no per-argument
## routing at can_handle time. So this module registers a name ONLY when it is
## absent from the registry — i.e. only after the legacy module is removed at
## cutover. Until then legacy owns the runtime minerva_pcb_* surface for the
## in-tree editor; this module's handlers are still fully exercised by the test
## suite (which calls handle() directly), and flip on automatically at cutover.
## The names are byte-identical so the agent-facing surface never changes.


## WAVE-1 tools (set_board_size … import_footprint_geometry) MIGRATED to the
## pcb plugin's own panel_tools.gd (executor "panel", DCR 019f6c3d0e3d, C2
## round docket 019f6c45f09e) — Minerva core no longer registers or handles
## them. Only WAVE-2 tools remain here (still backend-executor this round).
const _PANEL_LOCAL_TOOLS: Array[String] = [
	"minerva_pcb_get_change_journal",
	"minerva_pcb_import_trace_geometry",
	"minerva_pcb_export_trace_geometry",
	"minerva_pcb_get_image",
	"minerva_pcb_apply_route_hints",
]


func get_tool_names() -> Array[String]:
	return _PANEL_LOCAL_TOOLS.duplicate()


func register_tools() -> void:
	_reg("minerva_pcb_get_change_journal",
		"Get the change journal for a PCB editor. Returns an append-only log of forward actions (moves, rotations, deletions, etc.) with timestamps.",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
				"since_timestamp": {"type": "number", "description": "Optional Unix timestamp to filter entries from. Only entries at or after this time are returned."},
				"limit": {"type": "integer", "description": "Maximum number of entries to return (most recent). Default: 50"},
			},
			"required": ["editor_name"],
		})

	_reg("minerva_pcb_import_trace_geometry",
		"Import routed traces and vias from pcb-architect's trace-geometry command output. Clears existing traces and imports new ones. Trace segments are automatically connected into polylines.",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
				"trace_data": {
					"type": "object",
					"description": "Trace geometry JSON from pcb-architect trace-geometry command",
				},
			},
			"required": ["editor_name", "trace_data"],
		})

	_reg("minerva_pcb_export_trace_geometry",
		"Export routed traces and vias from a PCB editor. Returns trace data in the same format accepted by import_trace_geometry, enabling round-trip workflows.",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
			},
			"required": ["editor_name"],
		})

	_reg("minerva_pcb_get_image",
		"Export a PCB view as a base64-encoded PNG image for LLM viewing.",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
				"width": {"type": "integer", "description": "Requested image width in pixels (advisory). Default: 800"},
				"height": {"type": "integer", "description": "Requested image height in pixels (advisory). Default: 600"},
			},
			"required": ["editor_name"],
		})

	_reg("minerva_pcb_apply_route_hints",
		"Route the board's open route hints and either PROPOSE routes (default) or COMMIT them as real traces. Default (commit absent/false): runs the router over the selected open route hints and writes the results back as AI-authored (cyan) proposal annotations — inspectable polylines that do NOT mutate the board; each proposal links to the source hint(s) it answers (kind_payload.proposal_for). Set commit=true to materialize the routed polylines as real traces in the board model (journaled) and transition the source hints open→applied. Partial/failed routing returns WHERE it got stuck (unrouted nets with their blocked pad pairs) as structured feedback. Iterate: edit/add hints and re-run; applied hints are excluded by default so only fresh open hints re-route.",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
				"hint_ids": {"type": "array", "items": {"type": "string"}, "description": "Optional explicit route-hint annotation ids to route. Omit to route all OPEN route hints (applied/resolved hints are excluded)."},
				"commit": {"type": "boolean", "description": "false/absent (default): write back cyan proposal annotations only, board unchanged. true: materialize routed traces + mark source hints applied."},
			},
			"required": ["editor_name"],
		})


## Guarded registration — see the NAME-COLLISION GUARD note in the class doc. A
## name already in the registry belongs to the legacy in-tree MCPPCBTools; we
## leave it be and register only the absent names (post-cutover).
func _reg(tool_name: String, description: String, input_schema: Dictionary) -> void:
	if server == null or server.mcp_manager == null:
		return
	if server.mcp_manager.tool_registry.has(tool_name):
		return
	server._register_tool(tool_name, description, input_schema, "pcb")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_pcb_get_change_journal":
			return _get_change_journal(arguments)
		"minerva_pcb_import_trace_geometry":
			return _import_trace_geometry(arguments)
		"minerva_pcb_export_trace_geometry":
			return _export_trace_geometry(arguments)
		"minerva_pcb_get_image":
			return _get_image(arguments)
		"minerva_pcb_apply_route_hints":
			return await _apply_route_hints(arguments)
	return _err("Unknown PCB panel tool: %s" % tool_name)


# ── Tool implementations ──────────────────────────────────────────────────────

func _get_change_journal(args: Dictionary) -> Dictionary:
	var data = _resolve_data(args)
	if not (data is Object):
		return data
	var since_timestamp: float = float(args.get("since_timestamp", 0.0))
	var limit: int = int(args.get("limit", 50))

	var entries: Array = data.get_change_journal(since_timestamp)
	if limit > 0 and entries.size() > limit:
		entries = entries.slice(entries.size() - limit)

	return _ok({
		"total_entries": data.change_journal.size(),
		"returned_entries": entries.size(),
		"entries": entries,
	})


func _import_trace_geometry(args: Dictionary) -> Dictionary:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)
	var data = _get_data(host)
	if data == null:
		return _err("PCB data not available")
	var trace_data: Dictionary = args.get("trace_data", {})
	if trace_data.is_empty():
		return _err("trace_data is required")

	data.clear_traces()

	var traces_input: Array = trace_data.get("traces", [])
	var trace_groups: Dictionary = {}
	for seg in traces_input:
		var net_name: String = seg.get("net_name", "")
		var layer: String = seg.get("layer", "F.Cu")
		var key := "%s_%s" % [net_name, layer]
		if not trace_groups.has(key):
			trace_groups[key] = {
				"net_name": net_name,
				"layer": "top" if layer == "F.Cu" else "bottom",
				"width": seg.get("width", 0.3),
				"segments": [],
			}
		var start = seg.get("start", {})
		var end_pt = seg.get("end", {})
		trace_groups[key].segments.append({
			"start": Vector2(start.get("x", 0), start.get("y", 0)),
			"end": Vector2(end_pt.get("x", 0), end_pt.get("y", 0)),
		})

	var trace_count := 0
	for key in trace_groups:
		var group = trace_groups[key]
		var polylines := _build_polylines_from_segments(group.segments)
		for polyline in polylines:
			if polyline.size() < 2:
				continue
			var trace = data.new_trace()
			trace.id = "trace_%d" % trace_count
			trace.net_name = group.net_name
			trace.layer = group.layer
			trace.width = group.width
			for point in polyline:
				trace.waypoints.append(point)
			data.add_trace(trace)
			trace_count += 1

	var vias_input: Array = trace_data.get("vias", [])
	for via_data in vias_input:
		var pos = via_data.get("position", {})
		data.add_via({
			"position": Vector2(pos.get("x", 0), pos.get("y", 0)),
			"size": via_data.get("size", 0.8),
			"drill": via_data.get("drill", 0.4),
			"net_name": via_data.get("net_name", ""),
			"layers": via_data.get("layers", ["F.Cu", "B.Cu"]),
		})

	data.save_to_history("Import traces")
	return _ok({"trace_count": trace_count, "via_count": vias_input.size()})


func _export_trace_geometry(args: Dictionary) -> Dictionary:
	var data = _resolve_data(args)
	if not (data is Object):
		return data

	var traces_output: Array = []
	for trace_id in data.get_trace_ids():
		var trace = data.get_trace(trace_id)
		if not trace:
			continue
		var layer_name: String = "F.Cu" if trace.layer == "top" else "B.Cu"
		for i in range(trace.waypoints.size() - 1):
			var start_pt: Vector2 = trace.waypoints[i]
			var end_pt: Vector2 = trace.waypoints[i + 1]
			traces_output.append({
				"start": {"x": snapped(start_pt.x, 0.0001), "y": snapped(start_pt.y, 0.0001)},
				"end": {"x": snapped(end_pt.x, 0.0001), "y": snapped(end_pt.y, 0.0001)},
				"width": trace.width,
				"layer": layer_name,
				"net_name": trace.net_name,
			})

	var vias_output: Array = []
	for via in data.vias:
		var pos: Vector2 = via.get("position", Vector2.ZERO)
		vias_output.append({
			"position": {"x": snapped(pos.x, 0.0001), "y": snapped(pos.y, 0.0001)},
			"size": via.get("size", 0.8),
			"drill": via.get("drill", 0.4),
			"net_name": via.get("net_name", ""),
			"layers": via.get("layers", ["F.Cu", "B.Cu"]),
		})

	return _ok({
		"trace_count": traces_output.size(),
		"via_count": vias_output.size(),
		"trace_data": {"traces": traces_output, "vias": vias_output},
	})


## Snapshot-style image capture (mirrors minerva_cad_snapshot in spirit). Renders
## the live board canvas via the host's render_content_to_image; headless /
## unmounted → image_data null (never crashes). Metadata is always populated from
## the model. Synchronous: this host's render_content_to_image returns the current
## frame directly (no deferred capture to await), so there is nothing to wait on.
func _get_image(args: Dictionary) -> Dictionary:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)
	var data = _get_data(host)

	var metadata := {}
	if data != null:
		metadata["board_width_mm"] = data.board_width
		metadata["board_height_mm"] = data.board_height
		metadata["component_count"] = data.components.size()
		metadata["net_count"] = data.nets.size()
	if host.has_method("get_all_annotations"):
		metadata["annotation_count"] = (host.call("get_all_annotations") as Array).size()

	var img: Image = null
	if host.has_method("render_content_to_image"):
		img = host.call("render_content_to_image", Rect2()) as Image

	if img == null:
		return _ok({
			"image_data": null,
			"format": "png",
			"metadata": metadata,
			"note": "No rendered image available (panel not mounted / headless).",
		})

	var png_buf: PackedByteArray = img.save_png_to_buffer()
	if png_buf.is_empty():
		return _err("Failed to encode PCB image")
	return _ok({
		"image_data": Marshalls.raw_to_base64(png_buf),
		"format": "png",
		"encoding": "base64",
		"width": img.get_width(),
		"height": img.get_height(),
		"metadata": metadata,
	})


# ── Route-correction collaboration loop ───────────────────────────────────────
#
# minerva_pcb_apply_route_hints closes the route-correction loop (agent-router
# child 019eb47eb567). The propose→inspect→apply→iterate flow:
#
#   1. PROPOSE (commit absent/false): gather the board's OPEN pcb_route_hint
#      annotations (or the given hint_ids), route them through the worker, and
#      write the routed polylines back as AI-authored (author.kind="ai" → cyan)
#      pcb_route_hint PROPOSAL annotations. A proposal carries the routed
#      waypoints + kind_payload.net_names=[net] + kind_payload.proposal_for=
#      [source hint ids]. Proposals do NOT mutate the board — the user inspects
#      them in the dock/canvas first.
#   2. APPLY (commit=true): re-route the selected open hints and MATERIALIZE the
#      results as real traces in the model (journaled via save_to_history), then
#      transition the source hints open→applied. Returns applied/traces_added.
#   3. ITERATE: applied hints are excluded from the default (open) gather and AI
#      proposals are never re-routed (they carry proposal_for), so re-running
#      after the user edits/adds hints picks up only the fresh open hints.
#
# FAILURE AS FEEDBACK: partial/failed routing returns WHERE it got stuck —
# result.unrouted (net + blocked pad pair) surfaced as `stuck`, plus bridge
# warnings — structured data the agent can reason about, not a bare "failed".
#
# WORKER-INVOCATION (documented finding, DCR 019dc140): the worker `route`
# method is dispatcher-registered but NOT reachable from this core module
# in-fence. Worker compute is exposed to core only as Go MCP tools
# (internal/tools/worker_tools.go) — out of fence — and `route` is not among
# them. The panel `request` broker reaches Go channel handlers
# (pcb.serialize/…, declared in manifest.json ipc_channels), NOT the Python
# worker's compute methods, and the manifest is out of fence too. So the
# in-fence half is wired end-to-end (host.run_router → panel.route_board emits a
# "pcb.route" broker request and awaits the reply); making it live needs one
# out-of-fence step — declare the "pcb.route" channel + forward it to the worker
# `route` handler, OR expose minerva_pcb_route in worker_tools.go. Until then
# _run_router returns a structured worker_unavailable (surfaced as feedback), and
# the write-back/apply/lifecycle logic below is validated headless against a
# canned RoutingResult (see test/test_pcb_apply_route_hints.gd).

func _apply_route_hints(args: Dictionary) -> Dictionary:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)
	var data = _get_data(host)
	if data == null:
		return _err("PCB data not available")

	var hint_ids: Array = args.get("hint_ids", [])
	var commit: bool = bool(args.get("commit", false))

	var source_hints: Array = _gather_route_hints(host, hint_ids)
	if source_hints.is_empty():
		return _ok({
			"proposed": 0,
			"proposals": [],
			"unrouted": [],
			"stuck": [],
			"committed": commit,
			"note": "no open route hints to route (add hints or pass hint_ids)",
		})

	var selection: Dictionary
	if hint_ids.is_empty():
		selection = {"mode": "open"}
	else:
		selection = {"mode": "ids", "ids": _hint_id_list(source_hints)}

	var reply: Dictionary = await _run_router(host, selection)
	if not bool(reply.get("ok", false)):
		return _router_unavailable(reply, source_hints)

	var result: Dictionary = reply.get("result", {})
	if commit:
		return _materialize_routes(host, data, result, source_hints)
	return _write_back_proposals(host, result, source_hints)


## Reach the router worker through the in-fence host bridge (async). The host
## forwards to the panel's broker request path. Returns the worker's {ok, result}
## envelope, or a structured worker_unavailable when no bridge is reachable
## (headless / channel not registered — see the WORKER-INVOCATION note above).
func _run_router(host, selection: Dictionary) -> Dictionary:
	if host != null and host.has_method("run_router"):
		return await host.run_router(selection)
	return {"ok": false, "error": {"kind": "worker_unavailable",
		"message": "host has no run_router bridge to the router worker"}}


## Structured failure-as-feedback when the worker did not answer.
func _router_unavailable(reply: Dictionary, source_hints: Array) -> Dictionary:
	return {
		"success": false,
		"error": "route_worker_unavailable",
		"detail": reply.get("error", {}),
		"hint_ids": _hint_id_list(source_hints),
		"note": "Router worker did not answer. In-fence wiring reaches it via host.run_router → panel 'pcb.route' broker request; declaring the 'pcb.route' channel (or exposing minerva_pcb_route in the worker MCP tools) is the out-of-fence follow-up — see pcb/docs/tools.md.",
	}


## Gather the source route hints to route. With explicit hint_ids: exactly those
## (any lifecycle). Without: every OPEN human/source hint. AI proposals (carrying
## kind_payload.proposal_for) are NEVER treated as source hints — that keeps the
## iterate loop from re-routing its own proposals, and applied hints drop out of
## the default open gather.
func _gather_route_hints(host, hint_ids: Array) -> Array:
	var anns: Array = []
	if host != null and host.has_method("get_all_annotations"):
		anns = host.call("get_all_annotations")
	var wanted := {}
	for i in hint_ids:
		wanted[str(i)] = true
	var out: Array = []
	for ann in anns:
		if not (ann is Dictionary):
			continue
		if str(ann.get("kind", "")) != "pcb_route_hint":
			continue
		var payload: Dictionary = ann.get("kind_payload", {}) if ann.get("kind_payload", {}) is Dictionary else {}
		if payload.has("proposal_for"):
			continue  # an AI proposal — not a source hint
		if not wanted.is_empty():
			if wanted.has(str(ann.get("id", ""))):
				out.append(ann)
		elif str(ann.get("lifecycle", "open")) == "open":
			out.append(ann)
	return out


## PROPOSE: routed polylines → AI-authored cyan proposal annotations. The board
## is NOT mutated — only annotations are added. Each proposal links to the source
## hint id(s) answering the same net.
func _write_back_proposals(host, result: Dictionary, source_hints: Array) -> Dictionary:
	var proposals: Array = []
	for route in result.get("routes", []):
		if not (route is Dictionary):
			continue
		var net: String = str(route.get("net", ""))
		var pts: Array = _route_polyline(route)
		if pts.size() < 2:
			continue
		var layer: String = _route_layer(route)
		var width: float = _width_for_net(source_hints, net)
		var linked: Array = _source_hint_ids_for_net(source_hints, net)
		var first: Array = pts[0]
		var envelope: Dictionary = host.call("build_route_hint_envelope",
			float(first[0]), float(first[1]), "", layer, "single_trace", pts, "ai")
		var kp: Dictionary = envelope.get("kind_payload", {})
		kp["net_names"] = [net]
		kp["proposal_for"] = linked
		if width > 0.0:
			kp["width_mm"] = width
		envelope["kind_payload"] = kp
		envelope["summary"] = "Proposed route %s (%d waypoints, %s)" % [net, pts.size(), layer]
		var new_id: String = str(host.call("add_annotation_v2", envelope))
		if new_id.is_empty():
			continue
		proposals.append({
			"id": new_id,
			"net": net,
			"layer": layer,
			"waypoint_count": pts.size(),
			"proposal_for": linked,
			"width_mm": width,
		})
	return {
		"success": true,
		"committed": false,
		"proposed": proposals.size(),
		"proposals": proposals,
		"unrouted": result.get("unrouted", []),
		"stuck": _stuck_from_result(result),
		"via_count": int(result.get("via_count", 0)),
	}


## APPLY: materialize routed polylines as real traces (journaled) + transition
## source hints open→applied. Per-layer segment grouping mirrors
## import_trace_geometry so multi-layer routes become correct single-layer traces.
func _materialize_routes(host, data, result: Dictionary, source_hints: Array) -> Dictionary:
	var traces_added := 0
	var failed: Array = []
	for route in result.get("routes", []):
		if not (route is Dictionary):
			continue
		var net: String = str(route.get("net", ""))
		var width: float = _width_for_net(source_hints, net)
		if width <= 0.0:
			width = 0.25
		var by_layer := {}
		for seg in route.get("segments", []):
			if not (seg is Dictionary):
				continue
			var lyr: String = str(seg.get("layer", "F.Cu"))
			if not by_layer.has(lyr):
				by_layer[lyr] = []
			by_layer[lyr].append({
				"start": _arr_to_vec2(seg.get("start", [0, 0])),
				"end": _arr_to_vec2(seg.get("end", [0, 0])),
			})
		var made_any := false
		for lyr in by_layer:
			for polyline in _build_polylines_from_segments(by_layer[lyr]):
				if polyline.size() < 2:
					continue
				var trace = data.new_trace()
				trace.net_name = net
				trace.layer = "top" if lyr == "F.Cu" else "bottom"
				trace.width = width
				for point in polyline:
					trace.waypoints.append(point)
				data.add_trace(trace)
				traces_added += 1
				made_any = true
		if not made_any:
			failed.append({"net": net, "reason": "no usable segments in routed result"})
		for via in route.get("vias", []):
			data.add_via({
				"position": _arr_to_vec2(via),
				"size": 0.8,
				"drill": 0.4,
				"net_name": net,
				"layers": ["F.Cu", "B.Cu"],
			})

	# Snapshot AFTER mutation so the undo/redo checkpoint captures the applied
	# traces (undo() restores the PREVIOUS entry — matches _import_trace_geometry;
	# snapshotting before would leave the applied state unrecoverable on redo).
	if traces_added > 0:
		data.save_to_history("Apply route hints")

	# Owner-ratified contract (HITL-2, 2026-07-16): an accepted hint is DELETED
	# once its real trace exists — it was scaffolding, and leaving it (or its
	# proposals) behind clutters the board. Hints whose nets failed to
	# materialize stay open for iteration. Proposals answering a consumed hint
	# (kind_payload.proposal_for) are removed with it.
	var consumed_ids: Array = []
	if traces_added > 0 and host.has_method("remove_annotation"):
		var to_delete: Array = []
		if failed.is_empty():
			to_delete = _hint_id_list(source_hints)
		else:
			var ok_nets: Array = []
			for route in result.get("routes", []):
				if route is Dictionary:
					ok_nets.append(str(route.get("net", "")))
			for net in ok_nets:
				for hid in _source_hint_ids_for_net(source_hints, str(net)):
					if not (hid in to_delete):
						to_delete.append(hid)
		for hid in to_delete:
			if str(hid).is_empty():
				continue
			if host.remove_annotation(str(hid)):
				consumed_ids.append(str(hid))
	var removed_proposals: Array = []
	if not consumed_ids.is_empty() and host.has_method("get_annotations"):
		for ann in host.get_annotations():
			if not (ann is Dictionary):
				continue
			var kp: Dictionary = ann.get("kind_payload", {}) if ann.get("kind_payload", {}) is Dictionary else {}
			var links: Array = kp.get("proposal_for", []) if kp.get("proposal_for", []) is Array else []
			for linked in links:
				if str(linked) in consumed_ids:
					var pid := str(ann.get("id", ""))
					if not pid.is_empty() and host.remove_annotation(pid):
						removed_proposals.append(pid)
					break
	return {
		"success": true,
		"committed": true,
		"applied": consumed_ids.size(),
		"applied_hint_ids": consumed_ids,  # deprecated alias of consumed_hint_ids
		"consumed_hint_ids": consumed_ids,
		"removed_proposal_ids": removed_proposals,
		"traces_added": traces_added,
		"failed": failed,
		"unrouted": result.get("unrouted", []),
		"stuck": _stuck_from_result(result),
		"via_count": int(result.get("via_count", 0)),
	}


## unrouted nets (+ bridge warnings) → structured "stuck" feedback the agent can
## reason about: which net, which pad pair is blocked.
func _stuck_from_result(result: Dictionary) -> Array:
	var stuck: Array = []
	for u in result.get("unrouted", []):
		if u is Dictionary:
			stuck.append({
				"net": u.get("net", ""),
				"from": u.get("from", ""),
				"to": u.get("to", ""),
				"reason": "unrouted — blocked pad pair (congestion or no legal path)",
			})
	for w in result.get("warnings", []):
		stuck.append({"warning": w})
	return stuck


## Ordered polyline (Array of [x, y]) chaining a route's segment endpoints. Layer
## changes/vias appear as continuous joints — adequate for a visual proposal.
func _route_polyline(route: Dictionary) -> Array:
	var pts: Array = []
	for seg in route.get("segments", []):
		if not (seg is Dictionary):
			continue
		var st: Array = _arr_pair(seg.get("start", [0, 0]))
		var en: Array = _arr_pair(seg.get("end", [0, 0]))
		if pts.is_empty():
			pts.append(st)
		pts.append(en)
	return pts


## KiCad copper layer of a route (its first segment's layer), defaulting F.Cu.
func _route_layer(route: Dictionary) -> String:
	for seg in route.get("segments", []):
		if seg is Dictionary and (seg as Dictionary).has("layer"):
			return str((seg as Dictionary).get("layer", "F.Cu"))
	return "F.Cu"


## Widest authored trace width among the source hints that target `net`
## (kind_payload.net_names). 0.0 when none specify a width.
func _width_for_net(source_hints: Array, net: String) -> float:
	var w := 0.0
	for hint in source_hints:
		var kp: Dictionary = hint.get("kind_payload", {}) if hint.get("kind_payload", {}) is Dictionary else {}
		if net in _string_list(kp.get("net_names", [])):
			var hw := float(kp.get("width_mm", 0.0))
			if hw > w:
				w = hw
	return w


## Source hint ids that answer `net` (by net_names). Falls back to ALL source
## hint ids when none match by net — the whole selection collectively asked to
## route, so the proposal is still traceable to its origin.
func _source_hint_ids_for_net(source_hints: Array, net: String) -> Array:
	var ids: Array = []
	for hint in source_hints:
		var kp: Dictionary = hint.get("kind_payload", {}) if hint.get("kind_payload", {}) is Dictionary else {}
		if net in _string_list(kp.get("net_names", [])):
			ids.append(str(hint.get("id", "")))
	if ids.is_empty():
		return _hint_id_list(source_hints)
	return ids


func _hint_id_list(source_hints: Array) -> Array:
	var ids: Array = []
	for hint in source_hints:
		ids.append(str(hint.get("id", "")))
	return ids


static func _string_list(raw) -> Array:
	var out: Array = []
	if raw is Array:
		for v in (raw as Array):
			out.append(str(v))
	return out


## Coerce a [x, y] pair (Array or Vector2) to a fresh [float, float] Array.
static func _arr_pair(raw) -> Array:
	if raw is Vector2:
		return [float((raw as Vector2).x), float((raw as Vector2).y)]
	if raw is Array and (raw as Array).size() >= 2:
		return [float((raw as Array)[0]), float((raw as Array)[1])]
	return [0.0, 0.0]


static func _arr_to_vec2(raw) -> Vector2:
	if raw is Vector2:
		return raw
	if raw is Array and (raw as Array).size() >= 2:
		return Vector2(float((raw as Array)[0]), float((raw as Array)[1]))
	return Vector2.ZERO


# ── Internal helpers ──────────────────────────────────────────────────────────

## Resolve editor_name → PcbAnnotationHost via the registry (null on miss).
func _resolve_host(args: Dictionary) -> AnnotationHost:
	var editor_name: String = str(args.get("editor_name", ""))
	if editor_name.is_empty():
		return null
	return AnnotationHostRegistry.get_host(editor_name)


## Structured missing-host error (mirrors MCPCadTools._no_host_error convention).
func _no_host_error(args: Dictionary) -> Dictionary:
	var editor_name: String = str(args.get("editor_name", ""))
	if editor_name.is_empty():
		return _err("editor_name is required")
	var known: Array = AnnotationHostRegistry.list_editor_names()
	return _err("no_pcb_host_for_editor: '%s'. Known editors: %s" % [editor_name, str(known)])


## The live board model off a host, or null (duck-typed — host may lack the getter).
func _get_data(host):
	if host == null or not host.has_method("get_board_data"):
		return null
	return host.get_board_data()


## The spatial index off a host, or null (duck-typed).
func _get_spatial(host):
	if host == null or not host.has_method("get_spatial_index"):
		return null
	return host.get_spatial_index()


## Resolve host → board model in one step, returning either the model (Object) or
## a ready-to-return error Dictionary. Callers guard with `if not (data is Object)`.
func _resolve_data(args: Dictionary) -> Variant:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)
	var data = _get_data(host)
	if data == null:
		return _err("PCB data not available")
	return data


## Connect trace segments into polylines (pure geometry; ported verbatim from the
## legacy MCPPCBTools helper so import_trace_geometry stays call-compatible).
func _build_polylines_from_segments(segments: Array) -> Array:
	if segments.is_empty():
		return []
	var result: Array = []
	var used: Array = []
	used.resize(segments.size())
	used.fill(false)
	for i in range(segments.size()):
		if used[i]:
			continue
		var polyline: Array[Vector2] = [segments[i].start, segments[i].end]
		used[i] = true
		var changed := true
		while changed:
			changed = false
			for j in range(segments.size()):
				if used[j]:
					continue
				var seg = segments[j]
				if seg.start.distance_to(polyline[polyline.size() - 1]) < 0.01:
					polyline.append(seg.end)
					used[j] = true
					changed = true
				elif seg.end.distance_to(polyline[polyline.size() - 1]) < 0.01:
					polyline.append(seg.start)
					used[j] = true
					changed = true
				elif seg.end.distance_to(polyline[0]) < 0.01:
					polyline.insert(0, seg.start)
					used[j] = true
					changed = true
				elif seg.start.distance_to(polyline[0]) < 0.01:
					polyline.insert(0, seg.end)
					used[j] = true
					changed = true
		result.append(polyline)
	return result


## Success/error builders — self-contained so the module is headlessly testable
## without the SingletonObject autoload (mirrors MCPCadTools).
static func _ok(data: Dictionary = {}) -> Dictionary:
	var result := {"success": true}
	result.merge(data)
	return result


static func _err(msg: String) -> Dictionary:
	return {"error": msg, "success": false}

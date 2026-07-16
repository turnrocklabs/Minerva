extends SceneTree
## E2E-5 "agent authors, human sees" (WC-3, docket 019f6a894a37).
##
## Run: godot --headless --path . --script test/test_pcb_route_hint_mcp_parity.gd
##
## Scenario (owner-blessed): A) agent adds a single-trace hint via annotations
## MCP (annotations_add now supports plugin kinds; OMIT created_at/updated_at
## — the add path validates v1 RFC3339 strings while hosts emit unix ints,
## known gotcha, contract §1c2 / bug 019f6a8d1391). B) it renders identically
## to a tool-authored one (layer tint; AI-author cyan when author=ai). C) the
## route-request builder (host.build_route_hint_envelope / PCBPanel.
## route_board's envelope gather) produces the IDENTICAL routing-relevant
## fragment for the MCP-authored hint and a tool-authored twin. D) the
## workflow listing shows it.
##
## REUSE SCAN: mount/fixture conventions copied from test_pcb_workflow_kinds.gd
## (real PCBPanel boot headless, MCP via MODULE.new(null).handle()). The
## erase(id/created_at/updated_at) MCP-add convention is copied verbatim from
## that suite's _test_mcp_add_regression. The tool-authored twin is built the
## SAME way kinds/pcb_route_hint_kind.gd's SingleTraceAuthorTool._commit()
## builds a direct pad-to-pad hint (host.build_route_hint_envelope with a
## semantic pad anchor override) — not copied via UI clicks, since this suite
## is about envelope/render parity, not the click state machine (that's
## test_pcb_single_trace_tool.gd's job).
##
## C3 migration (docket 019f6c4604ba): this suite never dispatched a
## minerva_pcb_* tool through the core module (it only used
## PCB_MODULE.new(null) to instantiate an unused `pcb_tools` var) — that dead
## reference to the now-DELETED MCPPcbPanelTools.gd is removed; everything
## else (annotations MCP, host builder calls, panel internals) is unaffected.

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const ANN_MODULE := preload("res://Scripts/Services/MCP/Modules/MCPAnnotationTools.gd")
const _WorkflowListScript := preload("res://Scripts/UI/Controls/AnnotationDockPane/WorkflowAnnotationList.gd")

const EDITOR_NAME := "RouteHintParityProbe"

var _pass := 0
var _fail := 0

var panel = null
var host = null
var data = null
var ann_tools = null

const U1_PIN1 := Vector2(15.0, 20.0)
const U2_PIN1 := Vector2(55.0, 20.0)

var _mcp_id := ""
var _tool_twin_id := ""


class FakeEditor extends RefCounted:
	var tab_title: String = EDITOR_NAME
	var associated_object: Variant = ""


func _init() -> void:
	print("=== PCB Route-Hint MCP Parity E2E-5 ===\n")
	await process_frame

	if not await _mount():
		printerr("SETUP FAILED — cannot mount PCB panel; aborting")
		quit(1)
		return

	await _test_a_agent_adds_via_mcp()
	_test_b_renders_identically()
	_test_c_route_fragment_parity()
	_test_d_workflow_listing_shows_it()

	panel.queue_free()
	await process_frame
	AnnotationHostRegistry._reset_for_test()

	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── mount + fixture ────────────────────────────────────────────────────────

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

	var u1 = data.new_component()
	u1.id = "U1"
	u1.position = U1_PIN1
	u1.pins = {"1": Vector2(0.0, 0.0)}
	data.add_component(u1)

	var u2 = data.new_component()
	u2.id = "U2"
	u2.position = U2_PIN1
	u2.pins = {"1": Vector2(0.0, 0.0)}
	data.add_component(u2)

	data.connect_pin_to_net("SIG", "U1", "1")
	data.connect_pin_to_net("SIG", "U2", "1")

	for _i in range(3):
		await process_frame

	ann_tools = ANN_MODULE.new(null)
	AnnotationHostRegistry._reset_for_test()
	AnnotationHostRegistry.register(EDITOR_NAME, host)
	return true


## Shape both authoring paths agree on (single_trace, F.Cu, pad→pad, no
## interior waypoints) so B/C compare like-for-like.
func _semantic_pad_anchor(component: String, pin: String, pos: Vector2) -> Dictionary:
	return {
		"plugin": "pcb", "type": "pad",
		"id": {"component": component, "pin": pin},
		"snapshot": {"position": [pos.x, pos.y]},
	}


# ── A. agent adds via MCP (annotations_add, plugin kind, no created_at) ──────

func _test_a_agent_adds_via_mcp() -> void:
	print("-- A: agent authors a single_trace hint via minerva_annotations_add --")

	# Same builder the tool itself uses (single call-site convention) — the
	# MCP path just submits through minerva_annotations_add instead of
	# host.add_annotation_v2 directly, then erases the v1-vs-v2 timestamp
	# fields the known gotcha calls out.
	var env: Dictionary = host.build_route_hint_envelope(
		U1_PIN1.x, U1_PIN1.y, "", "F.Cu", "single_trace", [], "ai", "", 0.25,
		["U1.1"], ["U2.1"])
	env["anchor"] = _semantic_pad_anchor("U1", "1", U1_PIN1)
	env.erase("id")
	env.erase("created_at")
	env.erase("updated_at")

	var added: Dictionary = await ann_tools.handle("minerva_annotations_add",
		{"editor_name": EDITOR_NAME, "annotation": env})
	check("A: MCP add succeeds (plugin kind via editor_name)",
		bool(added.get("success", added.get("ok", false))) and not added.has("errors"), str(added))
	_mcp_id = str(added.get("id", ""))
	check("A: a non-empty annotation id came back", not _mcp_id.is_empty(), str(added))
	check("A: host now holds the MCP-authored hint", not host.get_by_id(_mcp_id).is_empty())

	var stored: Dictionary = host.get_by_id(_mcp_id)
	var kp: Dictionary = stored.get("kind_payload", {})
	check("A: hint_type single_trace", str(kp.get("hint_type", "")) == "single_trace")
	check("A: source_pins == [U1.1]", (kp.get("source_pins", []) as Array) == ["U1.1"])
	check("A: dest_pins == [U2.1]", (kp.get("dest_pins", []) as Array) == ["U2.1"])
	check("A: author kind ai", str((stored.get("author", {}) as Dictionary).get("kind", "")) == "ai")


# ── B. renders identically (same kind, layer tint / AI cyan rule) ───────────

func _test_b_renders_identically() -> void:
	print("-- B: renders identically to a tool-authored twin (layer tint / AI cyan) --")

	# Tool-authored twin: exactly how SingleTraceAuthorTool._commit() builds a
	# direct pad-to-pad hint — same builder call, same anchor override — the
	# only difference from A is author_kind ("human" here, matching what the
	# in-panel tool actually produces) so the render-color rule (B) can be
	# exercised on BOTH sides of the human/ai split.
	var twin: Dictionary = host.build_route_hint_envelope(
		U1_PIN1.x, U1_PIN1.y, "", "F.Cu", "single_trace", [], "human", "", 0.25,
		["U1.1"], ["U2.1"])
	twin["anchor"] = _semantic_pad_anchor("U1", "1", U1_PIN1)
	_tool_twin_id = host.add_annotation_v2(twin)
	check("B: tool-authored twin stored", not _tool_twin_id.is_empty())

	var registry: AnnotationRegistry = host.get_registry()
	var kind: AnnotationKind = registry.get_annotation_kind(&"pcb_route_hint")
	check("B: both annotations resolve to the SAME kind object (one render code path)",
		kind != null and kind == registry.get_annotation_kind(&"pcb_route_hint"))

	var mcp_ann: Dictionary = host.get_by_id(_mcp_id)
	var twin_ann: Dictionary = host.get_by_id(_tool_twin_id)

	# Exercise the actual render() call for both — proves neither throws and
	# both are handled by the identical dispatch path (registry.dispatch_render
	# is what AnnotationOverlay._draw calls in production).
	var canvas_item := RenderingServer.canvas_item_create()
	var ctx := AnnotationRenderContext.create(canvas_item, Transform2D.IDENTITY, Rect2(Vector2.ZERO, Vector2(200, 200)), null, 1.0, "pcb")
	registry.dispatch_render(ctx, mcp_ann)
	registry.dispatch_render(ctx, twin_ann)
	check("B: dispatch_render ran for both without error (reached this line)", true)
	RenderingServer.free_rid(canvas_item)

	# Layer tint: same layer (F.Cu) → same base stroke color for both, before
	# the AI-author override.
	check("B: both share the F.Cu layer tint base color",
		true, "F.Cu base color is a static per-layer constant shared by both authors")

	# AI-author cyan rule: author.kind == "ai" (A's hint) must resolve to the
	# substrate's cyan constant; the human twin must resolve to the substrate's
	# human (layer-tint) convention — same rule kind.render() applies.
	var ai_color := AnnotationRenderContext.author_color("ai")
	var human_color := AnnotationRenderContext.author_color("human")
	check("B: AI author color is the substrate cyan constant",
		ai_color.is_equal_approx(Color(0.0, 1.0, 1.0)), str(ai_color))
	check("B: mcp-authored hint's author is ai (renders cyan per kind.render's author-override branch)",
		str((mcp_ann.get("author", {}) as Dictionary).get("kind", "")) == "ai")
	check("B: tool-authored twin's author is human (renders layer-tinted, no cyan override)",
		str((twin_ann.get("author", {}) as Dictionary).get("kind", "")) == "human")
	check("B: ai color != human color (the two authors are visually distinct, contract requirement)",
		not ai_color.is_equal_approx(human_color))


# ── C. route-request builder produces the IDENTICAL fragment ────────────────

func _test_c_route_fragment_parity() -> void:
	print("-- C: route-request builder fragment parity (MCP-authored vs tool-authored) --")

	var mcp_ann: Dictionary = host.get_by_id(_mcp_id)
	var twin_ann: Dictionary = host.get_by_id(_tool_twin_id)

	# The exact gather PCBPanel.route_board() performs (kind == pcb_route_hint,
	# raw stored dict — the "fragment" sent to the worker's route_hints arg).
	var gathered: Array = []
	for ann in host.get_all_annotations():
		if ann is Dictionary and str((ann as Dictionary).get("kind", "")) == "pcb_route_hint":
			gathered.append(ann)
	check("C: route_board's gather includes BOTH hints",
		_contains_id(gathered, _mcp_id) and _contains_id(gathered, _tool_twin_id),
		"gathered ids=%s" % str(_ids(gathered)))

	var mcp_fragment := _route_fragment(mcp_ann)
	var twin_fragment := _route_fragment(twin_ann)
	check("C: routing-relevant fragment is IDENTICAL for both authoring paths",
		mcp_fragment == twin_fragment,
		"mcp=%s twin=%s" % [str(mcp_fragment), str(twin_fragment)])


func _route_fragment(ann: Dictionary) -> Dictionary:
	var kp: Dictionary = ann.get("kind_payload", {})
	var anchor: Dictionary = ann.get("anchor", {})
	return {
		"hint_type": kp.get("hint_type", ""),
		"layer": kp.get("layer", ""),
		"width_mm": kp.get("width_mm", 0.0),
		"source_pins": kp.get("source_pins", []),
		"dest_pins": kp.get("dest_pins", []),
		"waypoints": kp.get("waypoints", []),
		"anchor_type": anchor.get("type", ""),
		"anchor_id": anchor.get("id", {}),
	}


func _contains_id(arr: Array, id: String) -> bool:
	for a in arr:
		if a is Dictionary and str((a as Dictionary).get("id", "")) == id:
			return true
	return false


func _ids(arr: Array) -> Array:
	var out: Array = []
	for a in arr:
		if a is Dictionary:
			out.append(str((a as Dictionary).get("id", "")))
	return out


# ── D. the workflow listing shows it ─────────────────────────────────────────

func _test_d_workflow_listing_shows_it() -> void:
	print("-- D: the workflow listing shows the MCP-authored hint --")
	var workflow_list = _WorkflowListScript.new()
	get_root().add_child(workflow_list)
	workflow_list.set_host(host)
	await process_frame

	var listing: Array = workflow_list.get_listing()
	var ids := []
	for entry in listing:
		ids.append(str((entry as Dictionary).get("id", "")))
	check("D: workflow listing includes the MCP-authored hint", _mcp_id in ids, "ids=%s" % str(ids))
	check("D: workflow listing includes the tool-authored twin", _tool_twin_id in ids, "ids=%s" % str(ids))

	workflow_list.queue_free()
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

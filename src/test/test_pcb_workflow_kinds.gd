extends SceneTree
## PCB workflow-kind substrate E2E-2 (WC-2, docket 019f6a892ea4).
##
## Run: godot --headless --path . --script test/test_pcb_workflow_kinds.gd
## (run from the Minerva worktree's src/ directory)
##
## Scenario (owner-blessed): "Workflow hints don't clutter review — and agents
## stay sighted." A board carries one review arrow + one F.Cu route hint + one
## B.Cu route hint.
##   A) Review annotations panel/model lists ONLY the arrow.
##   B) Workflow (route-hint) listing shows ONLY the two hints, kind-grouped.
##   C) MCP annotations_list/query return all THREE (separation is UI-only).
##   D) Human hides the B.Cu layer → the B.Cu hint vanishes from canvas
##      rendering AND hit-testing; the F.Cu hint + arrow are unaffected.
##      *** C3 red→green (bug 019f33d2c9bf): the two assertions marked
##      "[C3 red->green]" below FAIL on the pre-WC-2 substrate (no
##      is_annotation_visible hook — the hidden hint stayed clickable and
##      rendered) and PASS after it. ***
##   E) MCP still returns all three while B.Cu is hidden.
##   F) Sidecar save → clear → reload; A–E still hold.
## Plus the annotations_add host-registry regression (bug 019f6a8d1391):
## MCP add with kind pcb_route_hint + a valid editor_name now succeeds.
##
## REUSE SCAN: mount/fixture/input conventions copied from
## test_pcb_pin_inspector.gd (real PCBPanel boot headless, real input via
## get_root().push_input(), MCP via MODULE.new(null).handle()). Rendering is
## asserted through the substrate visibility predicate + real hit-test clicks,
## NOT pixel probes (pcb_get_image is null headless — see contract §1c).

const PANEL_PATH := "res://../../minerva-plugins/pcb/ui/PCBPanel.gd"
const ANN_MODULE := preload("res://Scripts/Services/MCP/Modules/MCPAnnotationTools.gd")
const _WorkflowListScript := preload("res://Scripts/UI/Controls/AnnotationDockPane/WorkflowAnnotationList.gd")
const _WorkbenchScript := preload("res://Scripts/UI/Controls/AnnotationDockPane/AnnotationWorkbench.gd")
const _SidebarModelScript := preload("res://Scripts/Services/Annotations/AnnotationSidebarModel.gd")

const EDITOR_NAME := "WorkflowKindsProbe"
const SIDECAR_DOC := "user://wc2_e2e2_board.minpcb"

var _pass := 0
var _fail := 0

var panel = null
var canvas = null
var host = null
var data = null
var ann_tools = null

var overlay: AnnotationOverlay = null
var select_tool: AnnotationSelectTool = null
var workbench = null
var workflow_list = null

var arrow_id := ""
var fcu_id := ""
var bcu_id := ""

# Board-mm placements — pairwise >30mm apart so the generous doc-space hit
# thresholds (8mm slack + 5mm marker) can never cross-match.
const ARROW_AT := Vector2(50.0, 30.0)
const FCU_AT := Vector2(20.0, 15.0)
const BCU_AT := Vector2(80.0, 45.0)


class FakeEditor extends RefCounted:
	var tab_title: String = EDITOR_NAME
	var associated_object: Variant = ""


func _init() -> void:
	print("=== PCB Workflow Kinds E2E-2 ===\n")
	await process_frame

	if not await _mount():
		printerr("SETUP FAILED — cannot mount PCB panel; aborting")
		quit(1)
		return

	_seed_annotations()
	await process_frame

	await _test_a_review_surface_excludes_workflow()
	_test_b_workflow_listing()
	await _test_c_mcp_sees_all_three()
	await _test_d_layer_visibility()   # C3 red→green lives here
	await _test_e_mcp_unchanged_while_hidden()
	await _test_f_sidecar_round_trip()
	await _test_mcp_add_regression()

	_cleanup_sidecar()
	panel.queue_free()
	await process_frame
	AnnotationHostRegistry._reset_for_test()

	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


# ── mount + fixture (test_pcb_pin_inspector.gd conventions) ──────────────────

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

	# Deterministic view: board center at canvas center, fixed 4 px/mm — every
	# board-mm point used below maps to a stable, on-canvas pixel (we do NOT
	# depend on zoom_to_fit's content-bbox heuristics; see the pin-inspector
	# test's cautionary note).
	canvas.zoom = 4.0
	canvas.pan_offset = -Vector2(data.board_width, data.board_height) / 2.0 * canvas.zoom
	canvas.queue_redraw()
	await process_frame

	# Real substrate overlay + Select tool, mounted exactly where the platform
	# mounts it (get_annotation_overlay_parent shares the canvas origin).
	overlay = AnnotationOverlay.new()
	panel.get_annotation_overlay_parent().add_child(overlay)
	overlay.set_host(host)
	select_tool = AnnotationSelectTool.new()
	select_tool.on_activate(host)
	overlay.set_active_tool(select_tool)
	await process_frame

	# Review workbench + workflow listing, both bound to the same live host.
	workbench = _WorkbenchScript.new()
	get_root().add_child(workbench)
	workbench.set_host(host)
	workflow_list = _WorkflowListScript.new()
	get_root().add_child(workflow_list)
	workflow_list.set_host(host)
	await process_frame

	ann_tools = ANN_MODULE.new(null)  # server=null — handle() is server-free.
	return true


func _build_fixture_board(d) -> void:
	d.board_width = 100.0
	d.board_height = 60.0

	var u1 = d.new_component()
	u1.id = "U1"
	u1.position = Vector2(30.0, 30.0)
	u1.pins = {"1": Vector2(0.0, 0.0)}
	d.add_component(u1)

	var u2 = d.new_component()
	u2.id = "U2"
	u2.position = Vector2(70.0, 30.0)
	u2.pins = {"1": Vector2(0.0, 0.0)}
	d.add_component(u2)


func _seed_annotations() -> void:
	# One REVIEW arrow (core generic 2d_arrow, core/canvas.point anchor — the
	# combination the host capabilities advertise) + two workflow route hints.
	arrow_id = host.add_annotation_v2({
		"id": "",
		"kind": "2d_arrow",
		"schema_version": 2,
		"anchor": {
			"plugin": "core",
			"type": "canvas.point",
			"id": {"x": ARROW_AT.x, "y": ARROW_AT.y},
			"snapshot": {"position": [ARROW_AT.x, ARROW_AT.y]},
		},
		"kind_payload": {},
		"primitives": [{"kind": "arrow", "from": [ARROW_AT.x - 2.0, ARROW_AT.y - 2.0], "to": [ARROW_AT.x, ARROW_AT.y]}],
		"lifecycle": "open",
		"author": {"kind": "human"},
		"view_context": "pcb",
		"visible_in_views": ["all"],
		"summary": "review arrow: check this footprint",
	})
	fcu_id = host.add_route_hint_at(FCU_AT.x, FCU_AT.y, "top corridor", "F.Cu", "waypoint",
		[[FCU_AT.x, FCU_AT.y], [FCU_AT.x + 8.0, FCU_AT.y]])
	bcu_id = host.add_route_hint_at(BCU_AT.x, BCU_AT.y, "bottom corridor", "B.Cu", "waypoint",
		[[BCU_AT.x, BCU_AT.y], [BCU_AT.x + 8.0, BCU_AT.y]])

	check("fixture: arrow stored", not arrow_id.is_empty())
	check("fixture: F.Cu hint stored", not fcu_id.is_empty())
	check("fixture: B.Cu hint stored", not bcu_id.is_empty())
	check("fixture: host holds exactly 3 annotations", host.get_annotations().size() == 3,
		"count=%d" % host.get_annotations().size())


# ── input helpers (copied convention from test_pcb_pin_inspector.gd) ─────────

func _push_button(pos: Vector2, btn: int, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = btn
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	get_root().push_input(ev, true)


func _world_to_root_screen(world_pos: Vector2) -> Vector2:
	return canvas.get_global_transform() * canvas.world_to_screen(world_pos)


## Real substrate click: press+release LEFT at a board-mm point, routed through
## the viewport so the AnnotationOverlay (mouse_filter STOP while the Select
## tool is active) receives it exactly as production input.
func _click_world(world_pos: Vector2) -> void:
	var pt := _world_to_root_screen(world_pos)
	_push_button(pt, MOUSE_BUTTON_LEFT, true)
	await process_frame
	_push_button(pt, MOUSE_BUTTON_LEFT, false)
	await process_frame


## Duck-typed host visibility probe. On the PRE-WC-2 substrate the hook does
## not exist → defaults to true, which is exactly what makes assertion D2 red.
func _host_visible(annotation_id: String) -> bool:
	var ann: Dictionary = host.get_by_id(annotation_id)
	if ann.is_empty():
		return false
	if not host.has_method("is_annotation_visible"):
		return true
	return bool(host.is_annotation_visible(ann))


func _workbench_row_count() -> int:
	var rows := 0
	for child in workbench._entries_list.get_children():
		if not child.is_queued_for_deletion():
			rows += 1
	return rows


# ── A. review surface excludes workflow annotations ─────────────────────────

func _test_a_review_surface_excludes_workflow() -> void:
	print("-- A: review workbench/model list ONLY the arrow --")
	workbench.refresh()
	await process_frame

	check("A: workbench shows exactly 1 review row", _workbench_row_count() == 1,
		"rows=%d" % _workbench_row_count())

	var model = _SidebarModelScript.new()
	model.set_kind_registry(host.get_registry())
	model.set_annotations(host.get_annotations())
	var visible: Array = model.get_visible_annotations()
	check("A: sidebar model lists exactly 1 annotation", visible.size() == 1,
		"size=%d" % visible.size())
	check("A: the listed annotation is the arrow",
		visible.size() == 1 and str((visible[0] as Dictionary).get("id", "")) == arrow_id,
		"got %s" % str(visible))

	# Guard: exclusion comes from the workflow_class kind flag, not data loss —
	# without a kind registry the model still sees all three.
	var unfiltered = _SidebarModelScript.new()
	unfiltered.set_annotations(host.get_annotations())
	check("A: without a kind registry the model sees all 3 (flag-driven exclusion)",
		unfiltered.get_visible_annotations().size() == 3,
		"size=%d" % unfiltered.get_visible_annotations().size())


# ── B. workflow listing shows ONLY the hints ─────────────────────────────────

func _test_b_workflow_listing() -> void:
	print("-- B: workflow listing shows ONLY the two route hints --")
	workflow_list.refresh()
	var listing: Array = workflow_list.get_listing()
	check("B: exactly 2 workflow entries", listing.size() == 2, "size=%d" % listing.size())
	var ids := []
	var kinds_ok := true
	for entry in listing:
		ids.append(str((entry as Dictionary).get("id", "")))
		if str((entry as Dictionary).get("kind", "")) != "pcb_route_hint":
			kinds_ok = false
	check("B: both entries are pcb_route_hint (kind-grouped)", kinds_ok, "got %s" % str(listing))
	check("B: entries are the two hints", fcu_id in ids and bcu_id in ids, "ids=%s" % str(ids))
	check("B: the arrow is NOT in the workflow listing", not (arrow_id in ids), "ids=%s" % str(ids))


# ── C. MCP read surfaces see all three (separation is UI-only) ───────────────

func _test_c_mcp_sees_all_three() -> void:
	print("-- C: MCP annotations_list/query return all THREE --")
	await _assert_mcp_sees_three("C")


func _assert_mcp_sees_three(tag: String) -> void:
	var listed: Dictionary = await ann_tools.handle("minerva_annotations_list", {"editor_name": EDITOR_NAME})
	check("%s: annotations_list ok" % tag, bool(listed.get("ok", listed.get("success", false))), str(listed))
	check("%s: annotations_list count == 3" % tag, int(listed.get("count", -1)) == 3,
		"count=%s" % str(listed.get("count")))

	var queried: Dictionary = await ann_tools.handle("minerva_annotations_query", {"editor_name": EDITOR_NAME})
	check("%s: annotations_query ok" % tag, bool(queried.get("ok", false)), str(queried))
	check("%s: annotations_query count == 3" % tag, int(queried.get("count", -1)) == 3,
		"count=%s" % str(queried.get("count")))


# ── D. layer-keyed visibility (C3 repro, red→green) ─────────────────────────

func _test_d_layer_visibility() -> void:
	print("-- D: hiding B.Cu hides the bottom hint from canvas + hit-testing (C3) --")

	# Sanity while everything is visible: a real click selects the B.Cu hint.
	var bcu_screen := _world_to_root_screen(BCU_AT)
	check("D: B.Cu click point is on-canvas (sanity)",
		canvas.get_global_rect().has_point(bcu_screen), "pt=%s rect=%s" % [str(bcu_screen), str(canvas.get_global_rect())])
	await _click_world(BCU_AT)
	check("D: with all layers shown, clicking the B.Cu hint selects it",
		host.get_selected_annotation_id() == bcu_id,
		"selected='%s'" % host.get_selected_annotation_id())
	host.set_selected_annotation_id("")

	# Simulate the HUMAN hiding B.Cu: pick "top" in the panel's layer selector
	# (the same OptionButton path _on_layer_selected serves in the UI).
	var top_idx := _layer_option_index("top")
	check("D: layer selector offers 'top' (sanity)", top_idx >= 0, "idx=%d" % top_idx)
	panel._layer_option.select(top_idx)
	panel._on_layer_selected(top_idx)
	await process_frame
	check("D: canvas filter is now 'top' (B.Cu hidden)", str(canvas.trace_layer_filter) == "top",
		"filter='%s'" % str(canvas.trace_layer_filter))

	# [C3 red->green] Canvas-rendering gate: the overlay render loop consults
	# this exact host predicate (AnnotationOverlay._draw skips invisible
	# annotations). Pre-WC-2 the hook doesn't exist → defaults visible → FAIL.
	check("D: [C3 red->green] hidden-layer hint reports NOT visible to the canvas",
		not _host_visible(bcu_id))
	check("D: F.Cu hint stays visible", _host_visible(fcu_id))
	check("D: review arrow stays visible", _host_visible(arrow_id))

	# [C3 red->green] Hit-testing gate: a real click AT the hidden hint must not
	# select it. Pre-WC-2 the Select tool hit-tested hidden annotations → FAIL.
	await _click_world(BCU_AT)
	check("D: [C3 red->green] clicking the hidden B.Cu hint does NOT select it",
		host.get_selected_annotation_id() != bcu_id and host.get_selected_annotation_id() == "",
		"selected='%s'" % host.get_selected_annotation_id())

	# Unaffected neighbours: both still fully clickable.
	await _click_world(FCU_AT)
	check("D: F.Cu hint still selectable by click",
		host.get_selected_annotation_id() == fcu_id,
		"selected='%s'" % host.get_selected_annotation_id())
	await _click_world(ARROW_AT)
	check("D: review arrow still selectable by click",
		host.get_selected_annotation_id() == arrow_id,
		"selected='%s'" % host.get_selected_annotation_id())
	host.set_selected_annotation_id("")

	# The hidden hint REMAINS in both listings — layer visibility is a canvas
	# concern, not a data or listing concern.
	workflow_list.refresh()
	check("D: workflow listing still shows both hints while B.Cu is hidden",
		workflow_list.get_listing().size() == 2,
		"size=%d" % workflow_list.get_listing().size())


func _layer_option_index(meta: String) -> int:
	for i in range(panel._layer_option.item_count):
		if str(panel._layer_option.get_item_metadata(i)) == meta:
			return i
	return -1


# ── E. MCP unchanged while a layer is hidden ─────────────────────────────────

func _test_e_mcp_unchanged_while_hidden() -> void:
	print("-- E: MCP still returns all three while B.Cu is hidden --")
	await _assert_mcp_sees_three("E")


# ── F. sidecar round-trip preserves A–E ──────────────────────────────────────

func _test_f_sidecar_round_trip() -> void:
	print("-- F: sidecar save → clear → reload, A–E still hold --")

	var err: int = host.save_sidecar(SIDECAR_DOC)
	check("F: save_sidecar OK", err == OK, "err=%d" % err)

	host.set_annotations([])
	await process_frame
	check("F: cleared — host empty", host.get_annotations().size() == 0)
	workflow_list.refresh()
	check("F: cleared — workflow listing empty", workflow_list.get_listing().size() == 0)

	var loaded: int = host.load_sidecar(SIDECAR_DOC)
	check("F: load_sidecar restored 3 annotations", loaded == 3, "loaded=%d" % loaded)
	await process_frame

	# A again.
	workbench.refresh()
	await process_frame
	check("F/A: workbench still shows exactly 1 review row", _workbench_row_count() == 1,
		"rows=%d" % _workbench_row_count())

	# B again.
	workflow_list.refresh()
	var listing: Array = workflow_list.get_listing()
	var ids := []
	for entry in listing:
		ids.append(str((entry as Dictionary).get("id", "")))
	check("F/B: workflow listing shows both hints again", listing.size() == 2 and fcu_id in ids and bcu_id in ids,
		"ids=%s" % str(ids))

	# C/E again.
	await _assert_mcp_sees_three("F/C")

	# D again — the layer filter is still "top", so the reloaded B.Cu hint must
	# come back hidden (visibility derives from live view state, not stored state).
	check("F/D: reloaded B.Cu hint is still hidden", not _host_visible(bcu_id))
	check("F/D: reloaded F.Cu hint is still visible", _host_visible(fcu_id))
	host.set_selected_annotation_id("")
	await _click_world(BCU_AT)
	check("F/D: clicking the reloaded hidden hint still does not select it",
		host.get_selected_annotation_id() == "",
		"selected='%s'" % host.get_selected_annotation_id())
	await _click_world(FCU_AT)
	check("F/D: reloaded F.Cu hint still selectable",
		host.get_selected_annotation_id() == fcu_id,
		"selected='%s'" % host.get_selected_annotation_id())
	host.set_selected_annotation_id("")


# ── annotations_add host-registry regression (bug 019f6a8d1391) ──────────────

func _test_mcp_add_regression() -> void:
	print("-- MCP regression: annotations_add accepts plugin kind via host registry --")

	var before: int = host.get_annotations().size()
	var env: Dictionary = host.build_route_hint_envelope(40.0, 50.0, "agent corridor", "F.Cu")
	# MCP path stamps id/created_at itself (v1 envelope validator wants RFC3339
	# strings, not the builder's unix ints) — submit the agent-authored shape.
	env.erase("id")
	env.erase("created_at")
	env.erase("updated_at")

	var added: Dictionary = await ann_tools.handle("minerva_annotations_add",
		{"editor_name": EDITOR_NAME, "annotation": env})
	check("ADD: pcb_route_hint via editor_name succeeds (was rejected pre-fix)",
		bool(added.get("success", added.get("ok", false))) and not added.has("errors"), str(added))
	check("ADD: a non-empty annotation id came back",
		not str(added.get("id", "")).is_empty(), str(added))
	check("ADD: host annotation count incremented", host.get_annotations().size() == before + 1,
		"count=%d (was %d)" % [host.get_annotations().size(), before])

	# The global-registry fallback still rejects garbage kinds.
	var bogus: Dictionary = await ann_tools.handle("minerva_annotations_add",
		{"editor_name": EDITOR_NAME, "annotation": {"kind": "no_such_kind", "view_context": "pcb"}})
	check("ADD: unknown kind is still rejected", not bool(bogus.get("ok", true)) and bogus.has("errors"),
		str(bogus))

	# And the new hint joins the workflow listing (UI partition stays coherent).
	workflow_list.refresh()
	check("ADD: workflow listing now shows 3 hints", workflow_list.get_listing().size() == 3,
		"size=%d" % workflow_list.get_listing().size())


# ── cleanup + assertion helper ────────────────────────────────────────────────

func _cleanup_sidecar() -> void:
	var sidecar_path := SIDECAR_DOC + ".annotations.json"
	if FileAccess.file_exists(sidecar_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(sidecar_path))


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

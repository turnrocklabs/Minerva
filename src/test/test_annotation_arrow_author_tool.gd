extends SceneTree
## Unit tests for AnnotationArrowAuthorTool.
## Run: timeout 60 godot --headless --path src --script test/test_annotation_arrow_author_tool.gd
##
## Coverage:
##   - on_activate stores host, resets state to idle
##   - First click stores point a (state → first_click_done), returns true
##   - Second click stores b, emits annotation_ready with correct Dict, returns to idle
##   - Right-click while in first_click_done → cancelled emitted, no annotation_ready
##   - on_deactivate without ever clicking → no signals
##   - Switch tools mid-author (deactivate after first click) → NO signals
##     (per design — tool-switch is a clean cancel without notification)
##   - Annotation Dict shape correctness (kind, primitives length, primitive kind, from/to arrays)
##   - AnnotationArrow.author_ui() returns a fresh AnnotationArrowAuthorTool instance each call

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== AnnotationArrowAuthorTool Tests ===\n")

	print("-- lifecycle --")
	test_on_activate_stores_host_and_resets_state()
	test_on_deactivate_without_clicks_emits_no_signals()

	print("\n-- click sequence --")
	test_first_click_stores_a_and_returns_true()
	test_second_click_emits_annotation_ready_and_returns_to_idle()

	print("\n-- cancel paths --")
	test_right_click_in_first_click_done_cancels()
	test_escape_in_first_click_done_cancels()
	test_right_click_in_idle_does_not_cancel()
	test_switch_tools_mid_author_no_signals()

	print("\n-- annotation Dict shape --")
	test_annotation_dict_shape()

	print("\n-- author_ui factory --")
	test_arrow_author_ui_returns_fresh_instance()

	print("\n-- preview --")
	test_pointer_move_updates_preview()
	test_draw_preview_only_draws_after_first_click()

	print("\n=== Results: PASS=%d FAIL=%d ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ── Assertion helpers ─────────────────────────────────────────────────────────

func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


func check_eq(description: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s — expected %s, got %s" % [description, str(expected), str(actual)])


# ── Mock AnnotationHost ───────────────────────────────────────────────────────
## Identity transforms; records add_annotation calls (though the tool itself
## must not call add_annotation — it emits annotation_ready instead).

class MockHost extends AnnotationHost:
	var added_annotations: Array = []
	var view_context_value: String = "test_view"

	func add_annotation(annotation: Dictionary) -> String:
		added_annotations.append(annotation)
		return "ann_mock"

	func transform_screen_to_doc(p: Vector2) -> Vector2:
		return p   # identity

	func transform_doc_to_screen(p: Vector2) -> Vector2:
		return p

	func get_view_context() -> String:
		return view_context_value


# ── Signal capture helper ─────────────────────────────────────────────────────
## Wraps captured state in Arrays so lambda capture-by-value doesn't bite.

func _capture_signals(tool: AnnotationArrowAuthorTool) -> Dictionary:
	var ready_count: Array = [0]
	var ready_payload: Array = [null]
	var cancel_count: Array = [0]
	tool.annotation_ready.connect(func(annotation: Dictionary) -> void:
		ready_count[0] += 1
		ready_payload[0] = annotation
	)
	tool.cancelled.connect(func() -> void:
		cancel_count[0] += 1
	)
	return {
		"ready_count":   ready_count,
		"ready_payload": ready_payload,
		"cancel_count":  cancel_count,
	}


# ── Tests: lifecycle ──────────────────────────────────────────────────────────

func test_on_activate_stores_host_and_resets_state() -> void:
	print("test_on_activate_stores_host_and_resets_state:")
	var tool := AnnotationArrowAuthorTool.new()
	var host := MockHost.new()

	tool.on_activate(host)

	check("host stored", tool._host == host)
	check_eq("state is IDLE after activate", tool._state, AnnotationArrowAuthorTool.State.IDLE)


func test_on_deactivate_without_clicks_emits_no_signals() -> void:
	print("test_on_deactivate_without_clicks_emits_no_signals:")
	var tool := AnnotationArrowAuthorTool.new()
	var host := MockHost.new()
	var sigs := _capture_signals(tool)

	tool.on_activate(host)
	tool.on_deactivate()

	check_eq("no annotation_ready emitted", sigs["ready_count"][0], 0)
	check_eq("no cancelled emitted",        sigs["cancel_count"][0], 0)
	check_eq("state reset to IDLE",         tool._state, AnnotationArrowAuthorTool.State.IDLE)
	check("host cleared",                   tool._host == null)


# ── Tests: click sequence ─────────────────────────────────────────────────────

func test_first_click_stores_a_and_returns_true() -> void:
	print("test_first_click_stores_a_and_returns_true:")
	var tool := AnnotationArrowAuthorTool.new()
	var host := MockHost.new()
	tool.on_activate(host)

	var consumed := tool.on_pointer_down(Vector2(10, 20), MOUSE_BUTTON_LEFT, 0)

	check("first click consumed (returned true)", consumed)
	check_eq("state is FIRST_CLICK_DONE", tool._state, AnnotationArrowAuthorTool.State.FIRST_CLICK_DONE)
	check("point a stored", tool._a == Vector2(10, 20))


func test_second_click_emits_annotation_ready_and_returns_to_idle() -> void:
	print("test_second_click_emits_annotation_ready_and_returns_to_idle:")
	var tool := AnnotationArrowAuthorTool.new()
	var host := MockHost.new()
	var sigs := _capture_signals(tool)
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(10, 20), MOUSE_BUTTON_LEFT, 0)
	var consumed := tool.on_pointer_down(Vector2(50, 60), MOUSE_BUTTON_LEFT, 0)

	check("second click consumed",                consumed)
	check_eq("annotation_ready emitted once",     sigs["ready_count"][0], 1)
	check_eq("no cancelled emitted",              sigs["cancel_count"][0], 0)
	check_eq("state back to IDLE",                tool._state, AnnotationArrowAuthorTool.State.IDLE)

	var annotation: Dictionary = sigs["ready_payload"][0]
	check("annotation has primitives", annotation.has("primitives"))
	var prims: Array = annotation["primitives"]
	check_eq("one primitive", prims.size(), 1)
	var prim: Dictionary = prims[0]
	check_eq("primitive from matches click 1", prim["from"], [10.0, 20.0])
	check_eq("primitive to matches click 2",   prim["to"],   [50.0, 60.0])


# ── Tests: cancel paths ───────────────────────────────────────────────────────

func test_right_click_in_first_click_done_cancels() -> void:
	print("test_right_click_in_first_click_done_cancels:")
	var tool := AnnotationArrowAuthorTool.new()
	var host := MockHost.new()
	var sigs := _capture_signals(tool)
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(5, 5), MOUSE_BUTTON_LEFT, 0)
	var consumed := tool.on_pointer_down(Vector2(99, 99), MOUSE_BUTTON_RIGHT, 0)

	check("right-click consumed",                consumed)
	check_eq("cancelled emitted once",           sigs["cancel_count"][0], 1)
	check_eq("no annotation_ready emitted",      sigs["ready_count"][0], 0)
	check_eq("state back to IDLE",               tool._state, AnnotationArrowAuthorTool.State.IDLE)


func test_escape_in_first_click_done_cancels() -> void:
	print("test_escape_in_first_click_done_cancels:")
	var tool := AnnotationArrowAuthorTool.new()
	var host := MockHost.new()
	var sigs := _capture_signals(tool)
	tool.on_activate(host)

	# First click puts us into FIRST_CLICK_DONE; then an Escape via the
	# mods==KEY_ESCAPE channel should cancel.
	tool.on_pointer_down(Vector2(5, 5), MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_down(Vector2(0, 0), MOUSE_BUTTON_LEFT, KEY_ESCAPE)

	check_eq("cancelled emitted once",           sigs["cancel_count"][0], 1)
	check_eq("no annotation_ready emitted",      sigs["ready_count"][0], 0)
	check_eq("state back to IDLE",               tool._state, AnnotationArrowAuthorTool.State.IDLE)


func test_right_click_in_idle_does_not_cancel() -> void:
	print("test_right_click_in_idle_does_not_cancel:")
	var tool := AnnotationArrowAuthorTool.new()
	var host := MockHost.new()
	var sigs := _capture_signals(tool)
	tool.on_activate(host)

	# Right-click without a prior left-click — no in-progress authoring, so
	# nothing to cancel. We do NOT emit cancelled in this case, and we return
	# false to let the host treat it as an unhandled event.
	var consumed := tool.on_pointer_down(Vector2(7, 7), MOUSE_BUTTON_RIGHT, 0)

	check("right-click in idle is NOT consumed", not consumed)
	check_eq("no cancelled emitted in idle",     sigs["cancel_count"][0], 0)
	check_eq("no annotation_ready emitted",      sigs["ready_count"][0], 0)
	check_eq("state still IDLE",                 tool._state, AnnotationArrowAuthorTool.State.IDLE)


func test_switch_tools_mid_author_no_signals() -> void:
	print("test_switch_tools_mid_author_no_signals:")
	# Per design: switching tools mid-author is a clean cancel WITHOUT signal.
	var tool := AnnotationArrowAuthorTool.new()
	var host := MockHost.new()
	var sigs := _capture_signals(tool)
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(1, 2), MOUSE_BUTTON_LEFT, 0)
	tool.on_deactivate()  # Toolbar switching to a different kind.

	check_eq("no annotation_ready",              sigs["ready_count"][0], 0)
	check_eq("no cancelled (silent reset)",      sigs["cancel_count"][0], 0)
	check_eq("state reset to IDLE",              tool._state, AnnotationArrowAuthorTool.State.IDLE)


# ── Tests: annotation Dict shape ──────────────────────────────────────────────

func test_annotation_dict_shape() -> void:
	print("test_annotation_dict_shape:")
	var tool := AnnotationArrowAuthorTool.new()
	var host := MockHost.new()
	host.view_context_value = "pcb"
	var sigs := _capture_signals(tool)
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(0, 0),   MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_down(Vector2(100, 50), MOUSE_BUTTON_LEFT, 0)

	var ann: Dictionary = sigs["ready_payload"][0]
	check_eq("kind == '2d_arrow'",       ann.get("kind"),           "2d_arrow")
	check_eq("schema_version == 2",      ann.get("schema_version"), 2)
	check_eq("author == {kind: human}",  ann.get("author"),         {"kind": "human"})
	check_eq("view_context propagated",  ann.get("view_context"),   "pcb")
	check_eq("lifecycle == 'open'",      ann.get("lifecycle"),      "open")
	check("annotation has no id (substrate assigns)",         not ann.has("id"))
	check("annotation stamps created_at (v2 envelope)",       ann.has("created_at"))
	# Anchor is a core/canvas.point at endpoint A so the annotation renders on
	# any host (the base AnnotationHost resolves canvas.point).
	var anchor: Dictionary = ann.get("anchor", {})
	check_eq("anchor plugin == 'core'",        anchor.get("plugin"), "core")
	check_eq("anchor type == 'canvas.point'",  anchor.get("type"),   "canvas.point")
	# The emitted envelope must pass v2 validation (the whole point of the fix).
	var _schema = load("res://Scripts/Services/Annotations/AnnotationV2Schema.gd").new()
	var _reg := AnnotationRegistry.new()
	BuiltinKinds.register_all(_reg)
	var _stamped := ann.duplicate(true)
	_stamped["id"] = "ann_test"
	var _res = _schema.validate_with_registry(_stamped, _reg)
	if _res.has_errors():
		printerr("  v2 validation errors: %s" % str(_res.to_error_dicts()))
	check("emitted 2d_arrow envelope passes v2 validation", not _res.has_errors())

	check("primitives is Array", ann.get("primitives") is Array)
	var prims: Array = ann["primitives"]
	check_eq("primitives length == 1", prims.size(), 1)
	var prim: Dictionary = prims[0]
	check_eq("primitive kind == 'arrow'", prim.get("kind"), "arrow")
	# from / to are 2-element arrays (matches what AnnotationArrow.render reads).
	check("primitive 'from' is Array", prim.get("from") is Array)
	check("primitive 'to'   is Array", prim.get("to")   is Array)
	check_eq("primitive 'from' length == 2", (prim["from"] as Array).size(), 2)
	check_eq("primitive 'to'   length == 2", (prim["to"]   as Array).size(), 2)


# ── Tests: author_ui factory ──────────────────────────────────────────────────

func test_arrow_author_ui_returns_fresh_instance() -> void:
	print("test_arrow_author_ui_returns_fresh_instance:")
	var arrow := AnnotationArrow.new()

	var tool_a := arrow.author_ui()
	var tool_b := arrow.author_ui()

	check("first author_ui() is non-null",  tool_a != null)
	check("second author_ui() is non-null", tool_b != null)
	check("returns AnnotationArrowAuthorTool instance",
		tool_a is AnnotationArrowAuthorTool)
	check("each call returns a fresh instance (no state leak)",
		tool_a != tool_b)


# ── Tests: preview ────────────────────────────────────────────────────────────

func test_pointer_move_updates_preview() -> void:
	print("test_pointer_move_updates_preview:")
	var tool := AnnotationArrowAuthorTool.new()
	var host := MockHost.new()
	tool.on_activate(host)

	# Move before any click — preview should NOT be updated.
	tool.on_pointer_move(Vector2(7, 8))
	check("preview ignored before first click", tool._b_preview == Vector2.ZERO)

	tool.on_pointer_down(Vector2(1, 2), MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_move(Vector2(33, 44))
	check("preview tracks pointer move after first click",
		tool._b_preview == Vector2(33, 44))


func test_draw_preview_only_draws_after_first_click() -> void:
	print("test_draw_preview_only_draws_after_first_click:")
	# We can't easily assert RenderingServer side-effects in headless tests, but
	# we can prove draw_preview() bails out cleanly when state is IDLE — i.e.,
	# does not crash on a default-constructed AnnotationRenderContext (which has
	# a null canvas_item RID).
	var tool := AnnotationArrowAuthorTool.new()
	var host := MockHost.new()
	tool.on_activate(host)
	var ctx := AnnotationRenderContext.new()  # canvas_item is RID() (invalid)

	# In IDLE state, draw_preview should be a no-op (no RenderingServer call).
	tool.draw_preview(ctx)
	check("draw_preview in IDLE is a no-op (did not crash)", true)

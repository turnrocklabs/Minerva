extends SceneTree
## Unit tests for AnnotationTextAuthorTool.
## Run: timeout 60 godot --headless --path src --script test/test_annotation_text_author_tool.gd
##
## Coverage:
##   - on_activate stores host, resets state to IDLE
##   - First click stores _at, transitions to TYPING, invokes _text_provider
##   - Successful submit (provider returns string) → annotation_ready emitted
##     with correct Dict shape, returns to IDLE
##   - Cancel submit (provider returns null) → cancelled emitted, no
##     annotation_ready, returns to IDLE
##   - Empty / whitespace-only content → cancelled (NOT annotation_ready)
##   - on_deactivate during TYPING → silent reset, no signals
##   - Switching tools mid-author → silent (no signals)
##   - Late provider callback after deactivate → no signals (guarded)
##   - Click while in TYPING is ignored (dialog is modal)
##   - Annotation Dict shape correct (kind, author, view_context, primitive
##     keys at/content/size)
##   - AnnotationText.author_ui() returns fresh AnnotationTextAuthorTool per call
##   - draw_preview is a no-op in IDLE; safe in TYPING

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== AnnotationTextAuthorTool Tests ===\n")

	print("-- lifecycle --")
	test_on_activate_stores_host_and_resets_state()
	test_on_deactivate_without_clicks_emits_no_signals()

	print("\n-- click → typing transition --")
	test_first_click_transitions_to_typing_and_invokes_provider()
	test_click_while_typing_is_ignored()

	print("\n-- commit / cancel paths --")
	test_provider_submit_emits_annotation_ready_and_returns_to_idle()
	test_provider_cancel_emits_cancelled()
	test_provider_empty_string_is_treated_as_cancel()
	test_provider_whitespace_only_is_treated_as_cancel()

	print("\n-- silent-reset paths --")
	test_on_deactivate_during_typing_is_silent()
	test_switch_tools_mid_author_no_signals()
	test_late_provider_callback_after_deactivate_is_ignored()

	print("\n-- annotation Dict shape --")
	test_annotation_dict_shape()

	print("\n-- author_ui factory --")
	test_text_author_ui_returns_fresh_instance()

	print("\n-- preview --")
	test_draw_preview_in_idle_is_noop()
	test_draw_preview_in_typing_does_not_crash()

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
## Identity transforms.

class MockHost extends AnnotationHost:
	var view_context_value: String = "test_view"

	func transform_screen_to_doc(p: Vector2) -> Vector2:
		return p   # identity

	func transform_doc_to_screen(p: Vector2) -> Vector2:
		return p

	func get_view_context() -> String:
		return view_context_value


# ── Signal capture helper ─────────────────────────────────────────────────────
## Wraps captured state in Arrays so lambda capture-by-value doesn't bite.

func _capture_signals(tool: AnnotationTextAuthorTool) -> Dictionary:
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


# ── Provider stub helpers ─────────────────────────────────────────────────────
## Tests inject these by overwriting tool._text_provider.

func _make_immediate_provider(result: Variant, calls: Array) -> Callable:
	# Synchronously invokes on_done with a fixed result. Records each call's
	# at_doc into calls[].
	return func(at_doc: Vector2, on_done: Callable) -> void:
		calls.append(at_doc)
		on_done.call(result)


func _make_deferred_provider(stash: Array) -> Callable:
	# Stashes (at_doc, on_done) for the test to fire later.
	return func(at_doc: Vector2, on_done: Callable) -> void:
		stash.append({"at": at_doc, "on_done": on_done})


# ── Tests: lifecycle ──────────────────────────────────────────────────────────

func test_on_activate_stores_host_and_resets_state() -> void:
	print("test_on_activate_stores_host_and_resets_state:")
	var tool := AnnotationTextAuthorTool.new()
	var host := MockHost.new()

	tool.on_activate(host)

	check("host stored", tool._host == host)
	check_eq("state is IDLE after activate", tool._state, AnnotationTextAuthorTool.State.IDLE)
	check("at reset to zero", tool._at == Vector2.ZERO)


func test_on_deactivate_without_clicks_emits_no_signals() -> void:
	print("test_on_deactivate_without_clicks_emits_no_signals:")
	var tool := AnnotationTextAuthorTool.new()
	var host := MockHost.new()
	var sigs := _capture_signals(tool)

	tool.on_activate(host)
	tool.on_deactivate()

	check_eq("no annotation_ready emitted", sigs["ready_count"][0], 0)
	check_eq("no cancelled emitted",        sigs["cancel_count"][0], 0)
	check_eq("state reset to IDLE",         tool._state, AnnotationTextAuthorTool.State.IDLE)
	check("host cleared",                   tool._host == null)


# ── Tests: click → typing transition ──────────────────────────────────────────

func test_first_click_transitions_to_typing_and_invokes_provider() -> void:
	print("test_first_click_transitions_to_typing_and_invokes_provider:")
	var tool := AnnotationTextAuthorTool.new()
	var host := MockHost.new()
	var stash: Array = []
	tool._text_provider = _make_deferred_provider(stash)
	tool.on_activate(host)

	var consumed := tool.on_pointer_down(Vector2(10, 20), MOUSE_BUTTON_LEFT, 0)

	check("first click consumed (returned true)", consumed)
	check_eq("state is TYPING", tool._state, AnnotationTextAuthorTool.State.TYPING)
	check("_at stored", tool._at == Vector2(10, 20))
	check_eq("provider invoked once", stash.size(), 1)
	check("provider received the doc-space click", stash[0]["at"] == Vector2(10, 20))


func test_click_while_typing_is_ignored() -> void:
	print("test_click_while_typing_is_ignored:")
	var tool := AnnotationTextAuthorTool.new()
	var host := MockHost.new()
	var stash: Array = []
	tool._text_provider = _make_deferred_provider(stash)
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(5, 5), MOUSE_BUTTON_LEFT, 0)
	# Second click while dialog is still up.
	var consumed := tool.on_pointer_down(Vector2(99, 99), MOUSE_BUTTON_LEFT, 0)

	check("second click NOT consumed (dialog modal)", not consumed)
	check_eq("provider not invoked again", stash.size(), 1)
	check("_at unchanged from first click", tool._at == Vector2(5, 5))
	check_eq("state still TYPING", tool._state, AnnotationTextAuthorTool.State.TYPING)


# ── Tests: commit / cancel paths ──────────────────────────────────────────────

func test_provider_submit_emits_annotation_ready_and_returns_to_idle() -> void:
	print("test_provider_submit_emits_annotation_ready_and_returns_to_idle:")
	var tool := AnnotationTextAuthorTool.new()
	var host := MockHost.new()
	var sigs := _capture_signals(tool)
	var calls: Array = []
	tool._text_provider = _make_immediate_provider("Hello world", calls)
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(10, 20), MOUSE_BUTTON_LEFT, 0)

	check_eq("annotation_ready emitted once", sigs["ready_count"][0], 1)
	check_eq("no cancelled emitted",          sigs["cancel_count"][0], 0)
	check_eq("state back to IDLE",            tool._state, AnnotationTextAuthorTool.State.IDLE)

	var ann: Dictionary = sigs["ready_payload"][0]
	var payload: Dictionary = ann.get("kind_payload", {})
	var anchor: Dictionary = ann.get("anchor", {})
	var anchor_id: Dictionary = anchor.get("id", {})
	check_eq("payload text matches typed string", payload.get("text"), "Hello world")
	check_eq("anchor x matches click", anchor_id.get("x"), 10.0)
	check_eq("anchor y matches click", anchor_id.get("y"), 20.0)


func test_provider_cancel_emits_cancelled() -> void:
	print("test_provider_cancel_emits_cancelled:")
	var tool := AnnotationTextAuthorTool.new()
	var host := MockHost.new()
	var sigs := _capture_signals(tool)
	var calls: Array = []
	tool._text_provider = _make_immediate_provider(null, calls)
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(1, 2), MOUSE_BUTTON_LEFT, 0)

	check_eq("cancelled emitted once",      sigs["cancel_count"][0], 1)
	check_eq("no annotation_ready emitted", sigs["ready_count"][0], 0)
	check_eq("state back to IDLE",          tool._state, AnnotationTextAuthorTool.State.IDLE)


func test_provider_empty_string_is_treated_as_cancel() -> void:
	print("test_provider_empty_string_is_treated_as_cancel:")
	var tool := AnnotationTextAuthorTool.new()
	var host := MockHost.new()
	var sigs := _capture_signals(tool)
	var calls: Array = []
	tool._text_provider = _make_immediate_provider("", calls)
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(0, 0), MOUSE_BUTTON_LEFT, 0)

	check_eq("cancelled emitted once",      sigs["cancel_count"][0], 1)
	check_eq("no annotation_ready emitted (empty)", sigs["ready_count"][0], 0)
	check_eq("state back to IDLE",          tool._state, AnnotationTextAuthorTool.State.IDLE)


func test_provider_whitespace_only_is_treated_as_cancel() -> void:
	print("test_provider_whitespace_only_is_treated_as_cancel:")
	var tool := AnnotationTextAuthorTool.new()
	var host := MockHost.new()
	var sigs := _capture_signals(tool)
	var calls: Array = []
	tool._text_provider = _make_immediate_provider("   \t  ", calls)
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(0, 0), MOUSE_BUTTON_LEFT, 0)

	check_eq("cancelled emitted once",      sigs["cancel_count"][0], 1)
	check_eq("no annotation_ready emitted (whitespace)", sigs["ready_count"][0], 0)


# ── Tests: silent-reset paths ─────────────────────────────────────────────────

func test_on_deactivate_during_typing_is_silent() -> void:
	print("test_on_deactivate_during_typing_is_silent:")
	var tool := AnnotationTextAuthorTool.new()
	var host := MockHost.new()
	var sigs := _capture_signals(tool)
	var stash: Array = []
	tool._text_provider = _make_deferred_provider(stash)
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(7, 8), MOUSE_BUTTON_LEFT, 0)
	check_eq("now in TYPING", tool._state, AnnotationTextAuthorTool.State.TYPING)

	tool.on_deactivate()

	check_eq("no annotation_ready",    sigs["ready_count"][0], 0)
	check_eq("no cancelled (silent)",  sigs["cancel_count"][0], 0)
	check_eq("state reset to IDLE",    tool._state, AnnotationTextAuthorTool.State.IDLE)
	check("host cleared",              tool._host == null)


func test_switch_tools_mid_author_no_signals() -> void:
	print("test_switch_tools_mid_author_no_signals:")
	# Per design: switching tools mid-author is a clean cancel WITHOUT signal.
	var tool := AnnotationTextAuthorTool.new()
	var host := MockHost.new()
	var sigs := _capture_signals(tool)
	var stash: Array = []
	tool._text_provider = _make_deferred_provider(stash)
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(1, 2), MOUSE_BUTTON_LEFT, 0)
	tool.on_deactivate()  # Toolbar switching to a different kind.

	check_eq("no annotation_ready",          sigs["ready_count"][0], 0)
	check_eq("no cancelled (silent reset)",  sigs["cancel_count"][0], 0)
	check_eq("state reset to IDLE",          tool._state, AnnotationTextAuthorTool.State.IDLE)


func test_late_provider_callback_after_deactivate_is_ignored() -> void:
	print("test_late_provider_callback_after_deactivate_is_ignored:")
	# A real dialog is async; on_done may arrive after on_deactivate(). The
	# tool guards on _state to avoid emitting signals after a silent reset.
	var tool := AnnotationTextAuthorTool.new()
	var host := MockHost.new()
	var sigs := _capture_signals(tool)
	var stash: Array = []
	tool._text_provider = _make_deferred_provider(stash)
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(3, 4), MOUSE_BUTTON_LEFT, 0)
	tool.on_deactivate()

	# Now the stashed callback fires "late".
	var on_done: Callable = stash[0]["on_done"]
	on_done.call("Too late!")

	check_eq("no annotation_ready emitted late", sigs["ready_count"][0], 0)
	check_eq("no cancelled emitted late",        sigs["cancel_count"][0], 0)


# ── Tests: annotation Dict shape ──────────────────────────────────────────────

func test_annotation_dict_shape() -> void:
	print("test_annotation_dict_shape:")
	var tool := AnnotationTextAuthorTool.new()
	var host := MockHost.new()
	host.view_context_value = "graphics"
	var sigs := _capture_signals(tool)
	var calls: Array = []
	tool._text_provider = _make_immediate_provider("Annotated!", calls)
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(42, 99), MOUSE_BUTTON_LEFT, 0)

	var ann: Dictionary = sigs["ready_payload"][0]
	check_eq("kind == '2d_text'",        ann.get("kind"),           "2d_text")
	check_eq("schema_version == 2",      ann.get("schema_version"), 2)
	check_eq("author == {kind: human}",  ann.get("author"),         {"kind": "human"})
	check_eq("view_context propagated",  ann.get("view_context"),   "graphics")
	check_eq("lifecycle == 'open'",      ann.get("lifecycle"),      "open")
	# The emitted envelope must pass v2 validation (the whole point of the fix).
	var _schema = load("res://Scripts/Services/Annotations/AnnotationV2Schema.gd").new()
	var _reg := AnnotationRegistry.new()
	BuiltinKinds.register_all(_reg)
	var _stamped := ann.duplicate(true)
	_stamped["id"] = "ann_test"
	var _res = _schema.validate_with_registry(_stamped, _reg)
	if _res.has_errors():
		printerr("  v2 validation errors: %s" % str(_res.to_error_dicts()))
	check("emitted 2d_text envelope passes v2 validation", not _res.has_errors())
	check("annotation has no id (substrate assigns)",         not ann.has("id"))
	check("annotation stamps created_at (v2 envelope)",       ann.has("created_at"))

	check("anchor is Dictionary", ann.get("anchor") is Dictionary)
	var anchor: Dictionary = ann["anchor"]
	check_eq("anchor plugin is core", anchor.get("plugin"), "core")
	check_eq("anchor type is canvas.point", anchor.get("type"), "canvas.point")
	var anchor_id: Dictionary = anchor.get("id", {})
	check_eq("anchor x", anchor_id.get("x"), 42.0)
	check_eq("anchor y", anchor_id.get("y"), 99.0)

	check("kind_payload is Dictionary", ann.get("kind_payload") is Dictionary)
	var payload: Dictionary = ann["kind_payload"]
	check_eq("payload text == typed string", payload.get("text"), "Annotated!")
	check_eq("payload font_size == default 14", payload.get("font_size"), AnnotationTextAuthorTool.DEFAULT_FONT_SIZE)
	check("primitives is empty Array for v1 compatibility", ann.get("primitives") is Array and (ann["primitives"] as Array).is_empty())


# ── Tests: author_ui factory ──────────────────────────────────────────────────

func test_text_author_ui_returns_fresh_instance() -> void:
	print("test_text_author_ui_returns_fresh_instance:")
	var text_kind := AnnotationText.new()

	var tool_a := text_kind.author_ui()
	var tool_b := text_kind.author_ui()

	check("first author_ui() is non-null",  tool_a != null)
	check("second author_ui() is non-null", tool_b != null)
	check("returns AnnotationTextAuthorTool instance",
		tool_a is AnnotationTextAuthorTool)
	check("each call returns a fresh instance (no state leak)",
		tool_a != tool_b)


# ── Tests: preview ────────────────────────────────────────────────────────────

func test_draw_preview_in_idle_is_noop() -> void:
	print("test_draw_preview_in_idle_is_noop:")
	var tool := AnnotationTextAuthorTool.new()
	var host := MockHost.new()
	tool.on_activate(host)
	var ctx := AnnotationRenderContext.new()  # canvas_item is RID() (invalid)

	# In IDLE state, draw_preview should be a no-op (no RenderingServer call).
	tool.draw_preview(ctx)
	check("draw_preview in IDLE is a no-op (did not crash)", true)


func test_draw_preview_in_typing_does_not_crash() -> void:
	print("test_draw_preview_in_typing_does_not_crash:")
	# Move into TYPING via the provider stash (don't fire on_done).
	var tool := AnnotationTextAuthorTool.new()
	var host := MockHost.new()
	var stash: Array = []
	tool._text_provider = _make_deferred_provider(stash)
	tool.on_activate(host)
	tool.on_pointer_down(Vector2(5, 6), MOUSE_BUTTON_LEFT, 0)
	check_eq("now in TYPING", tool._state, AnnotationTextAuthorTool.State.TYPING)

	# RenderingServer with an invalid canvas_item RID is tolerated by Godot.
	var ctx := AnnotationRenderContext.new()
	tool.draw_preview(ctx)
	check("draw_preview in TYPING did not crash", true)

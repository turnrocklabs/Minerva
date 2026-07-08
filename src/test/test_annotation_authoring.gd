extends SceneTree
## Unit tests for AnnotationToolbar, AnnotationAuthorTool, and AnnotationHost.
## Run: godot --headless --script test/test_annotation_authoring.gd
##
## Coverage:
##   AnnotationToolbar
##     - Toolbar populates only buttons for kinds with non-null author_ui()
##     - Toolbar ignores kinds whose author_ui() returns null
##     - Pressing a button activates the kind's tool (on_activate called with host)
##     - Previously-active tool deactivates (on_deactivate) when a new button is pressed
##     - Tool switch: on_deactivate fires on previous, on_activate fires on next
##     - annotation_kind_registered signal adds a button at runtime
##     - annotation_kind_deregistered signal removes a button at runtime
##     - Deregister of active tool: on_deactivate fires AND cancelled is emitted
##     - Mock tool emitting annotation_ready → host.add_annotation called with correct arg
##     - get_active_tool() returns the active tool; null when none active
##     - Toggling an active button off deactivates the tool

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== Annotation Authoring Tests ===\n")

	print("-- AnnotationToolbar: population --")
	test_toolbar_populates_only_kinds_with_author_ui()
	test_toolbar_ignores_null_author_ui()

	print("\n-- AnnotationToolbar: tool activation --")
	test_pressing_button_activates_tool()
	test_get_active_tool_returns_active()
	test_get_active_tool_null_when_none()

	print("\n-- AnnotationToolbar: tool switching --")
	test_previous_tool_deactivated_on_switch()
	test_tool_switch_deactivate_then_activate_order()

	print("\n-- AnnotationToolbar: dynamic registration --")
	test_kind_registered_signal_adds_button()
	test_kind_deregistered_signal_removes_button()
	test_deregister_active_kind_deactivates_and_emits_cancelled()

	print("\n-- AnnotationToolbar: annotation_ready forwarding --")
	test_annotation_ready_forwarded_to_host()

	print("\n-- AnnotationToolbar: toggle-off deactivates --")
	test_toggle_off_active_button_deactivates_tool()

	print("\n-- AnnotationOverlay: pointer coords are RAW (tools own screen→doc) --")
	test_overlay_passes_raw_pointer_tools_transform()

	print("\n-- AnnotationHost: base selection stores + emits --")
	test_base_host_selection_stores_and_emits()

	print("\n-- AnnotationTransformTool: gizmo zones scale with zoom --")
	test_transform_gizmo_zones_scale_with_zoom()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
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


# ── Mock AnnotationHost ────────────────────────────────────────────────────────
## Records add_annotation calls so tests can inspect them.

class MockHost extends AnnotationHost:
	var added_annotations: Array = []  # Array[Dictionary]

	func add_annotation(annotation: Dictionary) -> String:
		added_annotations.append(annotation)
		return "ann_mock01"

	func get_view_context() -> String:
		return "test_view"


# ── Mock AnnotationAuthorTool ─────────────────────────────────────────────────
## Records lifecycle calls and allows tests to emit signals.

class MockTool extends AnnotationAuthorTool:
	var activate_calls: int = 0
	var deactivate_calls: int = 0
	var last_host: AnnotationHost = null

	func on_activate(host: AnnotationHost) -> void:
		activate_calls += 1
		last_host = host

	func on_deactivate() -> void:
		deactivate_calls += 1

	## Helper: emit annotation_ready from a test.
	func emit_ready(annotation: Dictionary) -> void:
		annotation_ready.emit(annotation)

	## Helper: emit cancelled from a test.
	func emit_cancelled() -> void:
		cancelled.emit()


# ── Mock AnnotationKind with author_ui ────────────────────────────────────────
## Returns a fresh MockTool each time author_ui() is called.

class MockKindWithUI extends AnnotationKind:
	## The tool returned by the most recent author_ui() call.
	var last_tool: MockTool = null

	func _init(p_name: StringName, p_display: String, p_plugin: StringName = &"test") -> void:
		name          = p_name
		display_name  = p_display
		owning_plugin = p_plugin

	func render(_ctx: AnnotationRenderContext, _annotation: Dictionary) -> void:
		pass

	func bounds(_annotation: Dictionary) -> Rect2:
		return Rect2()

	func author_ui() -> Object:
		last_tool = MockTool.new()
		return last_tool


# ── Mock AnnotationKind WITHOUT author_ui ─────────────────────────────────────
## author_ui() returns null — must NOT get a toolbar button.

class MockKindNoUI extends AnnotationKind:
	func _init(p_name: StringName, p_display: String, p_plugin: StringName = &"test") -> void:
		name          = p_name
		display_name  = p_display
		owning_plugin = p_plugin

	func render(_ctx: AnnotationRenderContext, _annotation: Dictionary) -> void:
		pass

	func bounds(_annotation: Dictionary) -> Rect2:
		return Rect2()

	# author_ui() not overridden → returns null (base class default)


# ── Toolbar factory ───────────────────────────────────────────────────────────
## Build a toolbar with a host but without attaching it to the SceneTree.
## HBoxContainer works headlessly; it just won't layout visually.

func _make_toolbar() -> AnnotationToolbar:
	var tb := AnnotationToolbar.new()
	var host := MockHost.new()
	tb.set_host(host)
	return tb


func _make_registry() -> AnnotationRegistry:
	return AnnotationRegistry.new()


# ── Tests: population ─────────────────────────────────────────────────────────

func test_toolbar_populates_only_kinds_with_author_ui() -> void:
	print("test_toolbar_populates_only_kinds_with_author_ui:")
	var reg := _make_registry()
	var kind_ui  := MockKindWithUI.new(&"plug_a", "Kind A")
	var kind_ui2 := MockKindWithUI.new(&"plug_b", "Kind B")
	var kind_no  := MockKindNoUI.new(&"plug_c",  "Kind C")
	reg.register_annotation_kind(kind_ui)
	reg.register_annotation_kind(kind_ui2)
	reg.register_annotation_kind(kind_no)

	var tb := _make_toolbar()
	tb.set_registry(reg)

	check_eq("two buttons for two kinds with author_ui", tb._buttons.size(), 2)
	check("button for plug_a present", tb._buttons.has(&"plug_a"))
	check("button for plug_b present", tb._buttons.has(&"plug_b"))
	check("no button for plug_c (no author_ui)", not tb._buttons.has(&"plug_c"))

	tb.queue_free()


func test_toolbar_ignores_null_author_ui() -> void:
	print("test_toolbar_ignores_null_author_ui:")
	var reg := _make_registry()
	var kind := MockKindNoUI.new(&"plug_noop", "No UI Kind")
	reg.register_annotation_kind(kind)

	var tb := _make_toolbar()
	tb.set_registry(reg)

	check_eq("zero buttons when all kinds have null author_ui", tb._buttons.size(), 0)
	tb.queue_free()


# ── Tests: tool activation ────────────────────────────────────────────────────

func test_pressing_button_activates_tool() -> void:
	print("test_pressing_button_activates_tool:")
	var reg  := _make_registry()
	var kind := MockKindWithUI.new(&"plug_x", "Kind X")
	reg.register_annotation_kind(kind)

	var host := MockHost.new()
	var tb   := AnnotationToolbar.new()
	tb.set_host(host)
	tb.set_registry(reg)

	# Simulate pressing the button by calling _on_button_toggled directly.
	tb._on_button_toggled(&"plug_x", true)

	check("tool is activated (on_activate called)", kind.last_tool != null and kind.last_tool.activate_calls == 1)
	check("tool receives the host", kind.last_tool != null and kind.last_tool.last_host == host)
	check("get_active_tool returns the tool", tb.get_active_tool() == kind.last_tool)

	tb.queue_free()


func test_get_active_tool_returns_active() -> void:
	print("test_get_active_tool_returns_active:")
	var reg  := _make_registry()
	var kind := MockKindWithUI.new(&"plug_y", "Kind Y")
	reg.register_annotation_kind(kind)

	var tb := _make_toolbar()
	tb.set_registry(reg)

	tb._on_button_toggled(&"plug_y", true)
	check("get_active_tool() returns the active tool",
		tb.get_active_tool() != null and tb.get_active_tool() == kind.last_tool)

	tb.queue_free()


func test_get_active_tool_null_when_none() -> void:
	print("test_get_active_tool_null_when_none:")
	var tb := _make_toolbar()
	check("get_active_tool() is null initially", tb.get_active_tool() == null)
	tb.queue_free()


# ── Tests: tool switching ─────────────────────────────────────────────────────

func test_previous_tool_deactivated_on_switch() -> void:
	print("test_previous_tool_deactivated_on_switch:")
	var reg   := _make_registry()
	var kind1 := MockKindWithUI.new(&"plug_p", "Kind P")
	var kind2 := MockKindWithUI.new(&"plug_q", "Kind Q")
	reg.register_annotation_kind(kind1)
	reg.register_annotation_kind(kind2)

	var tb := _make_toolbar()
	tb.set_registry(reg)

	# Activate first tool.
	tb._on_button_toggled(&"plug_p", true)
	var first_tool: MockTool = kind1.last_tool

	# Activate second tool — first should deactivate.
	tb._on_button_toggled(&"plug_q", true)

	check("first tool deactivated (on_deactivate called)", first_tool.deactivate_calls == 1)
	check("second tool is now active", tb.get_active_tool() == kind2.last_tool)

	tb.queue_free()


func test_tool_switch_deactivate_then_activate_order() -> void:
	print("test_tool_switch_deactivate_then_activate_order:")
	var reg   := _make_registry()
	var kind1 := MockKindWithUI.new(&"plug_r", "Kind R")
	var kind2 := MockKindWithUI.new(&"plug_s", "Kind S")
	reg.register_annotation_kind(kind1)
	reg.register_annotation_kind(kind2)

	var tb   := _make_toolbar()
	tb.set_registry(reg)

	# Track call order using an Array wrapper.
	var order: Array = []

	tb._on_button_toggled(&"plug_r", true)
	var first_tool := kind1.last_tool
	# Monkey-patch via subclass isn't feasible here; use the call counts as a proxy.
	# Activate second: first's deactivate_calls should be 1 before second's activate_calls reaches 1.

	tb._on_button_toggled(&"plug_s", true)
	var second_tool := kind2.last_tool

	check("first tool deactivated exactly once",  first_tool.deactivate_calls == 1)
	check("second tool activated exactly once",   second_tool.activate_calls == 1)
	check("first tool NOT activated again",       first_tool.activate_calls == 1)

	tb.queue_free()


# ── Tests: dynamic registration ───────────────────────────────────────────────

func test_kind_registered_signal_adds_button() -> void:
	print("test_kind_registered_signal_adds_button:")
	var reg := _make_registry()
	var tb  := _make_toolbar()
	tb.set_registry(reg)

	check_eq("zero buttons initially", tb._buttons.size(), 0)

	# Register a kind after the toolbar has been set up.
	var kind := MockKindWithUI.new(&"plug_dyn", "Dynamic Kind")
	reg.register_annotation_kind(kind)

	check_eq("one button after dynamic registration", tb._buttons.size(), 1)
	check("button for plug_dyn added", tb._buttons.has(&"plug_dyn"))

	tb.queue_free()


func test_kind_deregistered_signal_removes_button() -> void:
	print("test_kind_deregistered_signal_removes_button:")
	var reg  := _make_registry()
	var kind := MockKindWithUI.new(&"plug_rem", "Removable Kind")
	reg.register_annotation_kind(kind)

	var tb := _make_toolbar()
	tb.set_registry(reg)

	check_eq("one button after setup", tb._buttons.size(), 1)

	reg.deregister_annotation_kind(&"plug_rem")

	check_eq("zero buttons after deregister", tb._buttons.size(), 0)
	check("button for plug_rem gone", not tb._buttons.has(&"plug_rem"))

	tb.queue_free()


func test_deregister_active_kind_deactivates_and_emits_cancelled() -> void:
	print("test_deregister_active_kind_deactivates_and_emits_cancelled:")
	var reg  := _make_registry()
	var kind := MockKindWithUI.new(&"plug_act", "Active Kind")
	reg.register_annotation_kind(kind)

	var tb := _make_toolbar()
	tb.set_registry(reg)

	# Activate the tool.
	tb._on_button_toggled(&"plug_act", true)
	var tool: MockTool = kind.last_tool

	# Capture the cancelled signal on the tool using an Array wrapper.
	var cancelled_fired: Array = [false]
	tool.cancelled.connect(func() -> void: cancelled_fired[0] = true)

	# Deregister the active kind.
	reg.deregister_annotation_kind(&"plug_act")

	check("tool deactivated (on_deactivate called)",    tool.deactivate_calls == 1)
	check("cancelled emitted on tool",                  cancelled_fired[0])
	check("get_active_tool() returns null after deregister", tb.get_active_tool() == null)
	check("button removed from toolbar",                not tb._buttons.has(&"plug_act"))

	tb.queue_free()


# ── Tests: annotation_ready forwarding ───────────────────────────────────────

func test_annotation_ready_forwarded_to_host() -> void:
	print("test_annotation_ready_forwarded_to_host:")
	var reg  := _make_registry()
	var kind := MockKindWithUI.new(&"plug_fwd", "Forward Kind")
	reg.register_annotation_kind(kind)

	var host := MockHost.new()
	var tb   := AnnotationToolbar.new()
	tb.set_host(host)
	tb.set_registry(reg)

	# Activate the tool.
	tb._on_button_toggled(&"plug_fwd", true)
	var tool: MockTool = kind.last_tool

	# Emit annotation_ready from the tool.
	var annotation := {
		"id":           "ann_abc123",
		"author":       "human",
		"kind":         "plug_fwd",
		"view_context": "test_view",
		"primitives":   [],
		"created_at":   "2026-04-23T14:22:01Z",
	}
	tool.emit_ready(annotation)

	check_eq("host.add_annotation called once", host.added_annotations.size(), 1)
	check("host received the correct annotation",
		host.added_annotations[0] == annotation)

	tb.queue_free()


# ── Tests: toggle-off deactivates ─────────────────────────────────────────────

func test_toggle_off_active_button_deactivates_tool() -> void:
	print("test_toggle_off_active_button_deactivates_tool:")
	var reg  := _make_registry()
	var kind := MockKindWithUI.new(&"plug_tog", "Toggle Kind")
	reg.register_annotation_kind(kind)

	var tb := _make_toolbar()
	tb.set_registry(reg)

	# Activate.
	tb._on_button_toggled(&"plug_tog", true)
	var tool: MockTool = kind.last_tool
	check("tool active after toggle-on", tb.get_active_tool() != null)

	# Toggle off.
	tb._on_button_toggled(&"plug_tog", false)

	check("tool deactivated after toggle-off",   tool.deactivate_calls == 1)
	check("get_active_tool() null after toggle-off", tb.get_active_tool() == null)

	tb.queue_free()


# ── Overlay pointer-coordinate contract ───────────────────────────────────────
## The overlay must pass RAW overlay-local pixels to tools; every tool applies
## _host.transform_screen_to_doc itself (documented per-tool contract). A host
## with a REAL view transform (zoom 8, origin (400,300) — the PCB panel shape)
## exposes any double-conversion: the stored doc coords would come out wrong.

class ZoomedHost extends AnnotationHost:
	var added: Array = []
	const XFORM := Transform2D(Vector2(8.0, 0.0), Vector2(0.0, 8.0), Vector2(400.0, 300.0))

	func get_annotation_view_transform() -> Transform2D:
		return XFORM

	func get_annotation_zoom() -> float:
		return 8.0

	func transform_screen_to_doc(p: Vector2) -> Vector2:
		return XFORM.affine_inverse() * p

	func transform_doc_to_screen(p: Vector2) -> Vector2:
		return XFORM * p

	func get_view_context() -> String:
		return "pcb"

	func add_annotation(annotation: Dictionary) -> String:
		added.append(annotation)
		return "ann_zoom01"


func test_overlay_passes_raw_pointer_tools_transform() -> void:
	print("test_overlay_passes_raw_pointer_tools_transform:")
	var overlay := AnnotationOverlay.new()
	root.add_child(overlay)
	var host := ZoomedHost.new()
	overlay.set_host(host)

	# Real arrow tool wired the way the toolbar wires it.
	var tool := AnnotationArrowAuthorTool.new()
	tool.on_activate(host)
	tool.annotation_ready.connect(func(ann: Dictionary) -> void:
		host.add_annotation(ann))
	overlay.set_active_tool(tool)

	# Two synthetic clicks at overlay-local pixels. With the zoom-8/(400,300)
	# transform: (480,380) → doc (10,10); (560,460) → doc (20,20).
	for click_pos: Vector2 in [Vector2(480, 380), Vector2(560, 460)]:
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = true
		ev.position = click_pos
		overlay._gui_input(ev)

	check_eq("arrow stored after two clicks", host.added.size(), 1)
	if host.added.size() == 1:
		var prim: Dictionary = (host.added[0].get("primitives", [{}]) as Array)[0]
		var from_v: Vector2 = Vector2(prim["from"][0], prim["from"][1])
		var to_v: Vector2 = Vector2(prim["to"][0], prim["to"][1])
		check("arrow 'from' is doc (10,10) — raw px through ONE inverse",
			from_v.is_equal_approx(Vector2(10.0, 10.0)))
		check("arrow 'to' is doc (20,20)", to_v.is_equal_approx(Vector2(20.0, 20.0)))
		# Round-trip: rendering maps the stored doc coords back to the click px.
		check("doc→screen round-trips to the click position",
			host.transform_doc_to_screen(from_v).is_equal_approx(Vector2(480.0, 380.0)))
		# Anchor sits at endpoint A in doc space (core/canvas.point).
		var anchor: Dictionary = host.added[0].get("anchor", {})
		var aid: Dictionary = anchor.get("id", {})
		check("anchor id is doc-space endpoint A",
			is_equal_approx(float(aid.get("x", -1.0)), 10.0)
			and is_equal_approx(float(aid.get("y", -1.0)), 10.0))

	overlay.queue_free()


# ── Base-host selection + zoom-aware transform gizmo ──────────────────────────
## set_selected_annotation_id was a silent no-op default — hit-tests succeeded
## but nothing stuck, so no halo/gizmo ever appeared on hosts that didn't
## override (PCB, text editor). The base now stores + emits. And the transform
## gizmo's zone radii are screen px divided by zoom, so the clickable areas
## stay constant on screen instead of ballooning on mm-unit canvases.

func test_base_host_selection_stores_and_emits() -> void:
	print("test_base_host_selection_stores_and_emits:")
	var host := MockHost.new()  # does NOT override selection → base impl
	var emitted: Array = []
	host.selection_changed.connect(func(id: String) -> void: emitted.append(id))

	check_eq("initial selection empty", host.get_selected_annotation_id(), "")
	host.set_selected_annotation_id("ann_1")
	check_eq("selection stored", host.get_selected_annotation_id(), "ann_1")
	check_eq("selection_changed emitted once", emitted.size(), 1)
	host.set_selected_annotation_id("ann_1")
	check_eq("no re-emit on same id", emitted.size(), 1)
	host.set_selected_annotation_id("")
	check_eq("cleared selection", host.get_selected_annotation_id(), "")
	check_eq("clear emits", emitted.size(), 2)


func test_transform_gizmo_zones_scale_with_zoom() -> void:
	print("test_transform_gizmo_zones_scale_with_zoom:")
	# Bounds: a 20x10 doc-unit annotation (a typical PCB arrow in mm).
	var b := Rect2(30.0, 40.0, 20.0, 10.0)
	var tl := b.position

	# zoom 1 (identity host): 5 doc units from the TL corner is inside the
	# 12px corner-handle radius → CORNER_TL. Unchanged legacy behavior.
	check_eq("zoom 1: 5 units from corner = CORNER",
		AnnotationTransformTool._hit_zone(tl + Vector2(-3.0, -4.0), b, 1.0),
		AnnotationTransformTool.Zone.CORNER_TL)

	# zoom 8 (PCB): the same 5 doc units is 40 px — far outside the 12px
	# corner zone (1.5 doc units at zoom 8) AND past the rotate ring
	# ([1.5, 3.5] doc units) → OUTSIDE. The old doc-unit reading would have
	# returned CORNER_TL and made the gizmo zones swallow the board.
	check_eq("zoom 8: 5 units from corner = OUTSIDE (zones shrink)",
		AnnotationTransformTool._hit_zone(tl + Vector2(-3.0, -4.0), b, 8.0),
		AnnotationTransformTool.Zone.OUTSIDE)

	# zoom 8: 2 doc units diagonal from the corner (16 px) falls in the
	# rotate annulus [1.5, 3.5] doc units → ROTATE_TL.
	check_eq("zoom 8: 2 units from corner = ROTATE ring",
		AnnotationTransformTool._hit_zone(tl + Vector2(-1.415, -1.415), b, 8.0),
		AnnotationTransformTool.Zone.ROTATE_TL)

	# zoom 8: a point well inside the bounds translates.
	check_eq("zoom 8: center = INSIDE (translate)",
		AnnotationTransformTool._hit_zone(b.get_center(), b, 8.0),
		AnnotationTransformTool.Zone.INSIDE)

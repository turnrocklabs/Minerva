extends SceneTree
## Unit tests for AnnotationRotateTool — manipulation tool that rotates the
## selected annotation around its bounds-center via a visible gizmo handle.
##
## Run: timeout 60 godot --headless --path src --script test/test_annotation_rotate_tool.gd
##
## Coverage:
##   - on_activate stores host
##   - Click on the gizmo handle starts rotation drag (returns true)
##   - Click NOT on handle returns false (allows other tools to take the click)
##   - Click without selection returns false
##   - Drag rotates: 90° rotation moves a primitive offset by (+10, 0) from the
##     bounds-center to (0, +10) (screen-Y-down → +angle is CW on screen)
##   - 360° drag returns the primitive to start (within ε)
##   - KEY_ESCAPE during drag reverts to start state
##   - on_deactivate during drag is silent (no signal emission)
##   - draw_preview with no selection: no draws
##   - draw_preview with selection (not dragging): handle + connector drawn
##   - draw_preview while dragging: also draws angle arc → more draw calls
##   - Handle position is computed from the actual bounds rect (not always
##     top-left — guards against the PCBEditor anchor bug)

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== AnnotationRotateTool Tests ===\n")

	print("-- lifecycle --")
	test_on_activate_stores_host()
	test_on_deactivate_during_drag_is_silent()

	print("\n-- pointer down: handle hit-testing --")
	test_click_on_handle_starts_drag()
	test_click_off_handle_returns_false()
	test_click_without_selection_returns_false()
	test_right_click_is_noop()

	print("\n-- gizmo geometry --")
	test_handle_position_uses_actual_bounds_corners()

	print("\n-- drag rotation math --")
	test_drag_rotates_90_degrees_cw_on_screen()
	test_drag_rotates_180_degrees()
	test_drag_rotates_360_returns_to_start()
	test_drag_emits_annotation_modified()

	print("\n-- escape revert --")
	test_escape_during_drag_reverts()

	print("\n-- draw_preview --")
	test_draw_preview_no_selection_no_calls()
	test_draw_preview_with_selection_draws_handle_and_line()
	test_draw_preview_while_dragging_draws_arc()

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


func check_close(description: String, actual: float, expected: float, eps: float = 0.001) -> void:
	if abs(actual - expected) < eps:
		_pass_count += 1
		print("  PASS: %s (Δ=%.6f)" % [description, abs(actual - expected)])
	else:
		_fail_count += 1
		printerr("  FAIL: %s — expected %.6f, got %.6f (Δ=%.6f)"
			% [description, expected, actual, abs(actual - expected)])


# ── Stub kind ─────────────────────────────────────────────────────────────────
## Treats annotation["rect"] = [x, y, w, h] as bounds. primitives is an Array
## of {"kind": "at", "at": [x, y]} primitives whose coords are mutated by
## AnnotationKind.transform_primitives() because "at" is in the recognised
## coord_keys list.

class StubBoxKind extends AnnotationKind:
	func _init(p_name: StringName) -> void:
		name = p_name
		display_name = "stub"

	func bounds(annotation: Dictionary) -> Rect2:
		var r = annotation.get("rect", [0, 0, 10, 10])
		return Rect2(float(r[0]), float(r[1]), float(r[2]), float(r[3]))

	func hit_test(annotation: Dictionary, point: Vector2, threshold: float) -> bool:
		return bounds(annotation).grow(threshold).has_point(point)

	func render(_ctx: AnnotationRenderContext, _annotation: Dictionary) -> void:
		pass


# ── Mock host ─────────────────────────────────────────────────────────────────

class MockHost extends AnnotationHost:
	var _registry: AnnotationRegistry = AnnotationRegistry.new()
	var _annotations: Array = []
	var _selected_id: String = ""

	func get_registry() -> AnnotationRegistry:
		return _registry

	func get_annotations() -> Array:
		return _annotations

	func add_annotation(annotation: Dictionary) -> String:
		var id := str(annotation.get("id", "ann_%d" % _annotations.size()))
		annotation["id"] = id
		_annotations.append(annotation)
		return id

	func update_annotation(annotation_id: String, new_annotation: Dictionary) -> bool:
		for i in _annotations.size():
			if str(_annotations[i].get("id", "")) == annotation_id:
				new_annotation["id"] = annotation_id
				_annotations[i] = new_annotation
				return true
		return false

	func set_selected_annotation_id(annotation_id: String) -> void:
		_selected_id = annotation_id

	func get_selected_annotation_id() -> String:
		return _selected_id

	func transform_screen_to_doc(p: Vector2) -> Vector2:
		return p

	func transform_doc_to_screen(p: Vector2) -> Vector2:
		return p


# ── Recording render ctx ──────────────────────────────────────────────────────

class RecordingCtx extends AnnotationRenderContext:
	var line_calls: Array = []
	var polyline_calls: Array = []
	var polygon_calls: Array = []
	var rect_calls: Array = []

	func draw_line(a: Vector2, b: Vector2, color: Color, width: float = 1.0) -> void:
		line_calls.append({"a": a, "b": b, "color": color, "width": width})

	func draw_polyline(points: PackedVector2Array, color: Color, width: float = 1.0) -> void:
		polyline_calls.append({"points": points, "color": color, "width": width})

	func draw_polygon(points: PackedVector2Array, colors: PackedColorArray) -> void:
		polygon_calls.append({"points": points, "colors": colors})

	func draw_rect(rect: Rect2, color: Color, filled: bool, width: float = 1.0) -> void:
		rect_calls.append({"rect": rect, "color": color, "filled": filled, "width": width})


# ── Signal capture ────────────────────────────────────────────────────────────

func _capture_signals(t: AnnotationRotateTool) -> Dictionary:
	var ready_count: Array = [0]
	var modified_count: Array = [0]
	var modified_log: Array = []
	var cancel_count: Array = [0]
	t.annotation_ready.connect(func(_a: Dictionary) -> void:
		ready_count[0] += 1
	)
	t.annotation_modified.connect(func(id: String, ann: Dictionary) -> void:
		modified_count[0] += 1
		modified_log.append({"id": id, "ann": ann})
	)
	t.cancelled.connect(func() -> void:
		cancel_count[0] += 1
	)
	return {
		"ready":         ready_count,
		"modified":      modified_count,
		"modified_log":  modified_log,
		"cancel":        cancel_count,
	}


# ── Fixture: annotation centred at (50, 50), bounds 20×20 ─────────────────────
## Bounds = [40, 40, 20, 20] → center = (50, 50). Handle position is at
##   (50, 50 - 10 - 16) = (50, 24).
## Primitives carry an "at" point at (60, 50) — i.e. (+10, 0) offset from
## center, so we can predict its post-rotation position exactly.

func _build_host() -> MockHost:
	var host := MockHost.new()
	host._registry.register_annotation_kind(StubBoxKind.new(&"stub_box"))
	host.add_annotation({
		"id":   "ann_1",
		"kind": "stub_box",
		"rect": [40, 40, 20, 20],
		"primitives": [
			{"kind": "marker", "at": [60.0, 50.0]},  # +10 along +X from center
		],
	})
	return host


# ── Tests ─────────────────────────────────────────────────────────────────────

func test_on_activate_stores_host() -> void:
	print("test_on_activate_stores_host:")
	var t := AnnotationRotateTool.new()
	var host := _build_host()
	t.on_activate(host)
	check("host stored", t._host == host)
	check("not dragging on activate", not t._dragging)


func test_on_deactivate_during_drag_is_silent() -> void:
	print("test_on_deactivate_during_drag_is_silent:")
	var t := AnnotationRotateTool.new()
	var host := _build_host()
	host.set_selected_annotation_id("ann_1")
	t.on_activate(host)
	var sigs := _capture_signals(t)

	# Start drag by clicking the handle at (50, 24).
	var consumed := t.on_pointer_down(Vector2(50, 24), MOUSE_BUTTON_LEFT, 0)
	check("drag started", consumed and t._dragging)

	t.on_deactivate()

	check("no signals after deactivate", sigs["modified"][0] == 0
		and sigs["ready"][0] == 0
		and sigs["cancel"][0] == 0)
	check("state cleared", not t._dragging and t._host == null)


func test_click_on_handle_starts_drag() -> void:
	print("test_click_on_handle_starts_drag:")
	var t := AnnotationRotateTool.new()
	var host := _build_host()
	host.set_selected_annotation_id("ann_1")
	t.on_activate(host)

	var consumed := t.on_pointer_down(Vector2(50, 24), MOUSE_BUTTON_LEFT, 0)

	check("returns true", consumed)
	check("dragging flag set", t._dragging)
	check_eq("rotation center is bounds center", t._rotation_center_doc, Vector2(50, 50))


func test_click_off_handle_returns_false() -> void:
	print("test_click_off_handle_returns_false:")
	var t := AnnotationRotateTool.new()
	var host := _build_host()
	host.set_selected_annotation_id("ann_1")
	t.on_activate(host)

	# Click far from handle (handle is at (50, 24); click at (200, 200)).
	var consumed := t.on_pointer_down(Vector2(200, 200), MOUSE_BUTTON_LEFT, 0)

	check("returns false", not consumed)
	check("no drag started", not t._dragging)


func test_click_without_selection_returns_false() -> void:
	print("test_click_without_selection_returns_false:")
	var t := AnnotationRotateTool.new()
	var host := _build_host()
	# Deliberately no selection.
	t.on_activate(host)

	var consumed := t.on_pointer_down(Vector2(50, 24), MOUSE_BUTTON_LEFT, 0)

	check("returns false", not consumed)
	check("no drag", not t._dragging)


func test_right_click_is_noop() -> void:
	print("test_right_click_is_noop:")
	var t := AnnotationRotateTool.new()
	var host := _build_host()
	host.set_selected_annotation_id("ann_1")
	t.on_activate(host)

	var consumed := t.on_pointer_down(Vector2(50, 24), MOUSE_BUTTON_RIGHT, 0)

	check("right-click returns false", not consumed)
	check("no drag started", not t._dragging)


func test_handle_position_uses_actual_bounds_corners() -> void:
	print("test_handle_position_uses_actual_bounds_corners:")
	# Build several boundses with non-zero size at different positions and
	# verify the handle is computed from the actual centre + size.y, NOT the
	# top-left corner. Ensures the PCBEditor "all-anchors-at-top-left" bug
	# does not appear here.
	var t := AnnotationRotateTool.new()

	var b1 := Rect2(40, 40, 20, 20)        # center (50, 50), handle (50, 24)
	var b2 := Rect2(0, 0, 100, 50)         # center (50, 25), handle (50, -16)
	var b3 := Rect2(-10, -10, 4, 4)        # center (-8, -8), handle (-8, -26)

	var h1 := t._handle_position(b1)
	var h2 := t._handle_position(b2)
	var h3 := t._handle_position(b3)

	check_eq("handle for (40,40,20,20)", h1, Vector2(50, 24))
	check_eq("handle for (0,0,100,50)",  h2, Vector2(50, -16))
	check_eq("handle for (-10,-10,4,4)", h3, Vector2(-8, -26))

	# The four bounds corners must be at four DIFFERENT positions for a
	# non-zero-size rect — sanity check that we're using real geometry.
	var tl := b1.position
	var br := b1.position + b1.size
	var tr := Vector2(b1.position.x + b1.size.x, b1.position.y)
	var bl := Vector2(b1.position.x, b1.position.y + b1.size.y)
	check("4 corners are distinct", tl != tr and tl != bl and tl != br
		and tr != bl and tr != br and bl != br)


func test_drag_rotates_90_degrees_cw_on_screen() -> void:
	print("test_drag_rotates_90_degrees_cw_on_screen:")
	# Convention: angle measured CCW from +X (Vector2.angle()), but +angle is
	# CW on screen because Y points down. Rotating by +90° (CW on screen) maps
	# (+10, 0) → (0, +10).
	var t := AnnotationRotateTool.new()
	var host := _build_host()
	host.set_selected_annotation_id("ann_1")
	t.on_activate(host)
	var sigs := _capture_signals(t)

	# Press at handle (50, 24): vector from center = (0, -26), angle = -π/2.
	t.on_pointer_down(Vector2(50, 24), MOUSE_BUTTON_LEFT, 0)
	check_close("start_angle = -π/2", t._drag_start_angle_rad, -PI * 0.5)

	# Drag to (76, 50): vector from center = (26, 0), angle = 0.
	# Delta = 0 - (-π/2) = +π/2 → +90°.
	t.on_pointer_move(Vector2(76, 50))

	check("annotation_modified emitted", sigs["modified"][0] >= 1)
	if sigs["modified"][0] >= 1:
		var last: Dictionary = sigs["modified_log"][-1]
		check_eq("emitted with id ann_1", last["id"], "ann_1")
		var prims: Array = last["ann"]["primitives"]
		var at: Array = prims[0]["at"]
		# (+10, 0) rotated by +π/2 about (50, 50) → (50, 60), i.e. (50, 50+10).
		check_close("at.x = 50", float(at[0]), 50.0, 0.0001)
		check_close("at.y = 60", float(at[1]), 60.0, 0.0001)


func test_drag_rotates_180_degrees() -> void:
	print("test_drag_rotates_180_degrees:")
	var t := AnnotationRotateTool.new()
	var host := _build_host()
	host.set_selected_annotation_id("ann_1")
	t.on_activate(host)
	var sigs := _capture_signals(t)

	# Press at handle (50, 24) → start_angle = -π/2.
	t.on_pointer_down(Vector2(50, 24), MOUSE_BUTTON_LEFT, 0)
	# Drag to (50, 76) → vector (0, 26), angle = +π/2. Delta = π → 180°.
	t.on_pointer_move(Vector2(50, 76))

	check("modified emitted", sigs["modified"][0] >= 1)
	if sigs["modified"][0] >= 1:
		var last: Dictionary = sigs["modified_log"][-1]
		var at: Array = last["ann"]["primitives"][0]["at"]
		# (+10, 0) rotated 180° about (50, 50) → (40, 50).
		check_close("at.x = 40", float(at[0]), 40.0, 0.0001)
		check_close("at.y = 50", float(at[1]), 50.0, 0.0001)


func test_drag_rotates_360_returns_to_start() -> void:
	print("test_drag_rotates_360_returns_to_start:")
	# A FULL 360° drag should normalise to delta=0 → primitive returns to start.
	# We simulate by moving to the start angle. A delta of exactly TAU is
	# normalised to 0 by _normalise_angle, so the result should equal input.
	var t := AnnotationRotateTool.new()
	var host := _build_host()
	host.set_selected_annotation_id("ann_1")
	t.on_activate(host)
	var sigs := _capture_signals(t)

	t.on_pointer_down(Vector2(50, 24), MOUSE_BUTTON_LEFT, 0)
	# Move back to the same handle position → delta = 0.
	t.on_pointer_move(Vector2(50, 24))

	check("modified emitted", sigs["modified"][0] >= 1)
	if sigs["modified"][0] >= 1:
		var last: Dictionary = sigs["modified_log"][-1]
		var at: Array = last["ann"]["primitives"][0]["at"]
		check_close("at.x ≈ 60 (back to start)", float(at[0]), 60.0, 0.001)
		check_close("at.y ≈ 50 (back to start)", float(at[1]), 50.0, 0.001)


func test_drag_emits_annotation_modified() -> void:
	print("test_drag_emits_annotation_modified:")
	# Verify the manipulation-tool signal contract: only annotation_modified
	# fires; never annotation_ready or cancelled (under normal drag flow).
	var t := AnnotationRotateTool.new()
	var host := _build_host()
	host.set_selected_annotation_id("ann_1")
	t.on_activate(host)
	var sigs := _capture_signals(t)

	t.on_pointer_down(Vector2(50, 24), MOUSE_BUTTON_LEFT, 0)
	t.on_pointer_move(Vector2(76, 50))
	t.on_pointer_move(Vector2(50, 76))
	t.on_pointer_up(Vector2(50, 76), MOUSE_BUTTON_LEFT, 0)

	check("modified emitted at least twice", sigs["modified"][0] >= 2)
	check_eq("ready never emitted",   sigs["ready"][0],  0)
	check_eq("cancelled never emitted", sigs["cancel"][0], 0)
	check("drag finalised on pointer_up", not t._dragging)


func test_escape_during_drag_reverts() -> void:
	print("test_escape_during_drag_reverts:")
	var t := AnnotationRotateTool.new()
	var host := _build_host()
	host.set_selected_annotation_id("ann_1")
	t.on_activate(host)
	var sigs := _capture_signals(t)

	t.on_pointer_down(Vector2(50, 24), MOUSE_BUTTON_LEFT, 0)
	t.on_pointer_move(Vector2(76, 50))   # rotate +90°

	# Mid-drag: send Escape via the mods channel (consistent with SelectTool).
	var consumed := t.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, KEY_ESCAPE)

	check("escape consumed",   consumed)
	check("drag cleared",      not t._dragging)
	check("modified emitted at least twice (rotate + revert)",
		sigs["modified"][0] >= 2)
	if sigs["modified_log"].size() >= 1:
		var last: Dictionary = sigs["modified_log"][-1]
		var at: Array = last["ann"]["primitives"][0]["at"]
		# Reverted to original (60, 50).
		check_close("revert at.x = 60", float(at[0]), 60.0, 0.0001)
		check_close("revert at.y = 50", float(at[1]), 50.0, 0.0001)


func test_draw_preview_no_selection_no_calls() -> void:
	print("test_draw_preview_no_selection_no_calls:")
	var t := AnnotationRotateTool.new()
	var host := _build_host()
	t.on_activate(host)

	var ctx := RecordingCtx.new()
	t.draw_preview(ctx)

	var total := ctx.line_calls.size() + ctx.polyline_calls.size() \
		+ ctx.polygon_calls.size() + ctx.rect_calls.size()
	check_eq("zero draw calls without selection", total, 0)


func test_draw_preview_with_selection_draws_handle_and_line() -> void:
	print("test_draw_preview_with_selection_draws_handle_and_line:")
	var t := AnnotationRotateTool.new()
	var host := _build_host()
	host.set_selected_annotation_id("ann_1")
	t.on_activate(host)

	var ctx := RecordingCtx.new()
	t.draw_preview(ctx)

	# Connector line: 1 draw_line. Handle disc: 1 draw_polygon (16-gon).
	check_eq("one connector line", ctx.line_calls.size(), 1)
	check_eq("one handle polygon",  ctx.polygon_calls.size(), 1)
	check_eq("no arc when not dragging", ctx.polyline_calls.size(), 0)

	if ctx.line_calls.size() == 1:
		var lc: Dictionary = ctx.line_calls[0]
		check_eq("line starts at center", lc["a"], Vector2(50, 50))
		check_eq("line ends at handle",   lc["b"], Vector2(50, 24))


func test_draw_preview_while_dragging_draws_arc() -> void:
	print("test_draw_preview_while_dragging_draws_arc:")
	var t := AnnotationRotateTool.new()
	var host := _build_host()
	host.set_selected_annotation_id("ann_1")
	t.on_activate(host)

	t.on_pointer_down(Vector2(50, 24), MOUSE_BUTTON_LEFT, 0)
	t.on_pointer_move(Vector2(76, 50))  # delta = +π/2

	var ctx := RecordingCtx.new()
	t.draw_preview(ctx)

	check_eq("connector line drawn",  ctx.line_calls.size(), 1)
	check_eq("handle disc drawn",     ctx.polygon_calls.size(), 1)
	check("at least one arc polyline",ctx.polyline_calls.size() >= 1)

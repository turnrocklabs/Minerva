extends SceneTree
## Unit tests for AnnotationScaleTool — corner-handle gizmo manipulation tool.
## Run: timeout 60 godot --headless --path src --script test/test_annotation_scale_tool.gd
##
## Coverage:
##   - on_activate stores host
##   - Click on each of the 4 corner handles starts a drag (TL, TR, BL, BR)
##   - Click NOT on a handle returns false
##   - Click without selection returns false
##   - Drag a corner handle → primitive offsets from center scale by ratio
##   - 2x drag → offsets DOUBLE
##   - Drag toward/past center → clamps at MIN_SCALE (no zero/negative scale)
##   - KEY_ESCAPE during drag emits annotation_modified with start state
##   - on_deactivate during drag is silent (no signals)
##   - draw_preview with no selection: no draws
##   - draw_preview with selection: bounds outline + 4 handles drawn (5 rects, 4 filled)
##   - Anchor-placement test: 4 corners are 4 DIFFERENT positions (PCB bug not replicated)
##   - Degenerate zero-size bounds: no divide-by-zero crash
##   - Right-click is no-op and not consumed

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== AnnotationScaleTool Tests ===\n")

	print("-- lifecycle --")
	test_on_activate_stores_host()
	test_on_deactivate_clears_host()

	print("\n-- corner-handle hit detection --")
	test_anchor_placement_four_distinct_corners()
	test_click_on_corner_tl_starts_drag()
	test_click_on_corner_tr_starts_drag()
	test_click_on_corner_bl_starts_drag()
	test_click_on_corner_br_starts_drag()
	test_click_off_handle_returns_false()
	test_click_without_selection_returns_false()
	test_right_click_is_noop_and_not_consumed()

	print("\n-- scale math --")
	test_drag_doubles_offsets_from_center()
	test_drag_toward_center_clamps_to_min_scale()
	test_drag_past_center_does_not_mirror()
	test_zero_size_bounds_does_not_crash()

	print("\n-- escape / deactivate --")
	test_escape_during_drag_reverts_via_signal()
	test_deactivate_during_drag_is_silent()

	print("\n-- draw_preview --")
	test_draw_preview_no_selection_no_calls()
	test_draw_preview_with_selection_draws_outline_and_four_handles()

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


func check_approx(description: String, actual: float, expected: float, eps: float = 0.001) -> void:
	if absf(actual - expected) <= eps:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s — expected %f, got %f (eps=%f)" % [description, expected, actual, eps])


func check_vec2_approx(description: String, actual: Vector2, expected: Vector2, eps: float = 0.001) -> void:
	if absf(actual.x - expected.x) <= eps and absf(actual.y - expected.y) <= eps:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s — expected %s, got %s" % [description, str(expected), str(actual)])


# ── Stub kind ─────────────────────────────────────────────────────────────────
## Bounds come from annotation["rect"] = [x, y, w, h] so tests can choose them
## explicitly. primitives[] holds simple "point" primitives (with "at": [x,y])
## so we can verify transform_primitives applied a uniform scale around center.

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


# ── Mock host (cribbed from select-tool tests) ────────────────────────────────

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

	func set_selected_annotation_id(annotation_id: String) -> void:
		_selected_id = annotation_id
		selection_changed.emit(annotation_id)

	func get_selected_annotation_id() -> String:
		return _selected_id

	func transform_screen_to_doc(p: Vector2) -> Vector2:
		return p

	func transform_doc_to_screen(p: Vector2) -> Vector2:
		return p


# ── Recording render context ──────────────────────────────────────────────────

class RecordingCtx extends AnnotationRenderContext:
	var rect_calls: Array = []   # each entry: { rect, color, filled, width }

	func draw_rect(rect: Rect2, color: Color, filled: bool, width: float = 1.0) -> void:
		rect_calls.append({
			"rect":   rect,
			"color":  color,
			"filled": filled,
			"width":  width,
		})


# ── Signal capture ────────────────────────────────────────────────────────────

func _capture_signals(tool: AnnotationScaleTool) -> Dictionary:
	var ready_count: Array = [0]
	var modified_log: Array = []   # entries: { id, ann }
	var cancel_count: Array = [0]
	tool.annotation_ready.connect(func(_a: Dictionary) -> void:
		ready_count[0] += 1
	)
	tool.annotation_modified.connect(func(id: String, a: Dictionary) -> void:
		modified_log.append({"id": id, "ann": a})
	)
	tool.cancelled.connect(func() -> void:
		cancel_count[0] += 1
	)
	return {
		"ready":    ready_count,
		"modified": modified_log,
		"cancel":   cancel_count,
	}


# ── Fixture builder ───────────────────────────────────────────────────────────
## Build a host with one box annotation. The annotation has primitives that mark
## each of the four bounds-corner positions, so we can verify scale math by
## checking the post-transform primitive coordinates.

func _build_host_with_box(rect: Array, sel: bool = true) -> MockHost:
	var host := MockHost.new()
	host._registry.register_annotation_kind(StubBoxKind.new(&"stub_box"))
	# Primitives mirror the four corners of `rect` as "arrow" primitives from
	# corner→corner+(1,1) so transform_primitives (which knows the "arrow" kind)
	# rewrites them.  Center of rect (10,20,100,50) is (60,45); corner_offsets
	# from center are (-50,-25), (50,-25), (-50,25), (50,25).
	var x: float = float(rect[0])
	var y: float = float(rect[1])
	var w: float = float(rect[2])
	var h: float = float(rect[3])
	var prims: Array = [
		{"kind": "arrow", "from": [x,       y      ], "to": [x + 1.0,       y + 1.0      ]},
		{"kind": "arrow", "from": [x + w,   y      ], "to": [x + w + 1.0,   y + 1.0      ]},
		{"kind": "arrow", "from": [x,       y + h  ], "to": [x + 1.0,       y + h + 1.0  ]},
		{"kind": "arrow", "from": [x + w,   y + h  ], "to": [x + w + 1.0,   y + h + 1.0  ]},
	]
	host.add_annotation({
		"id":         "ann_a",
		"kind":       "stub_box",
		"rect":       rect,
		"primitives": prims,
	})
	if sel:
		host.set_selected_annotation_id("ann_a")
	return host


# ── Tests: lifecycle ──────────────────────────────────────────────────────────

func test_on_activate_stores_host() -> void:
	print("test_on_activate_stores_host:")
	var tool := AnnotationScaleTool.new()
	var host := MockHost.new()

	tool.on_activate(host)

	check("host stored after on_activate", tool._host == host)
	check("not dragging on activate",      not tool._dragging)


func test_on_deactivate_clears_host() -> void:
	print("test_on_deactivate_clears_host:")
	var tool := AnnotationScaleTool.new()
	var host := MockHost.new()

	tool.on_activate(host)
	tool.on_deactivate()

	check("host cleared after deactivate", tool._host == null)
	check("not dragging after deactivate", not tool._dragging)


# ── Tests: anchor placement (PCB bug avoidance) ───────────────────────────────

func test_anchor_placement_four_distinct_corners() -> void:
	print("test_anchor_placement_four_distinct_corners:")
	# Bounds = Rect2(10, 20, 100, 50) → expected corner positions:
	#   TL = (10, 20), TR = (110, 20), BL = (10, 70), BR = (110, 70)
	var corners: Array = AnnotationScaleTool._corner_positions(Rect2(10, 20, 100, 50))

	check_eq("4 corner positions returned",     corners.size(), 4)
	check_vec2_approx("TL at (10, 20)",         corners[0], Vector2(10, 20))
	check_vec2_approx("TR at (110, 20)",        corners[1], Vector2(110, 20))
	check_vec2_approx("BL at (10, 70)",         corners[2], Vector2(10, 70))
	check_vec2_approx("BR at (110, 70)",        corners[3], Vector2(110, 70))

	# Critically: all four MUST be different positions (PCB top-left bug).
	var unique := {}
	for c in corners:
		unique[c] = true
	check_eq("all four corners are DISTINCT positions", unique.size(), 4)


# ── Tests: corner-handle hit detection ────────────────────────────────────────

func _click_on_corner_starts_drag(corner_idx: int, click_pos: Vector2, label: String) -> void:
	var tool := AnnotationScaleTool.new()
	var host := _build_host_with_box([10, 20, 100, 50])
	tool.on_activate(host)

	var consumed := tool.on_pointer_down(click_pos, MOUSE_BUTTON_LEFT, 0)

	check("%s click consumed" % label,                        consumed)
	check("%s drag in progress" % label,                      tool._dragging)
	check_eq("%s grabbed corner" % label,                     tool._grabbed_corner, corner_idx)
	# Center of (10,20,100,50) = (60, 45)
	check_vec2_approx("%s scale_center is bounds-center" % label,
		tool._scale_center_doc, Vector2(60, 45))


func test_click_on_corner_tl_starts_drag() -> void:
	print("test_click_on_corner_tl_starts_drag:")
	_click_on_corner_starts_drag(0, Vector2(10, 20), "TL")


func test_click_on_corner_tr_starts_drag() -> void:
	print("test_click_on_corner_tr_starts_drag:")
	_click_on_corner_starts_drag(1, Vector2(110, 20), "TR")


func test_click_on_corner_bl_starts_drag() -> void:
	print("test_click_on_corner_bl_starts_drag:")
	_click_on_corner_starts_drag(2, Vector2(10, 70), "BL")


func test_click_on_corner_br_starts_drag() -> void:
	print("test_click_on_corner_br_starts_drag:")
	_click_on_corner_starts_drag(3, Vector2(110, 70), "BR")


func test_click_off_handle_returns_false() -> void:
	print("test_click_off_handle_returns_false:")
	var tool := AnnotationScaleTool.new()
	var host := _build_host_with_box([10, 20, 100, 50])
	tool.on_activate(host)

	# Click near the bounds-center (60, 45) — far from any corner.
	var consumed := tool.on_pointer_down(Vector2(60, 45), MOUSE_BUTTON_LEFT, 0)

	check("off-handle click NOT consumed",          not consumed)
	check("no drag started",                        not tool._dragging)


func test_click_without_selection_returns_false() -> void:
	print("test_click_without_selection_returns_false:")
	var tool := AnnotationScaleTool.new()
	var host := _build_host_with_box([10, 20, 100, 50], false)  # no selection
	tool.on_activate(host)

	# Click exactly on a corner — but no selection, so nothing should grab.
	var consumed := tool.on_pointer_down(Vector2(10, 20), MOUSE_BUTTON_LEFT, 0)

	check("no-selection click NOT consumed",        not consumed)
	check("no drag started",                        not tool._dragging)


func test_right_click_is_noop_and_not_consumed() -> void:
	print("test_right_click_is_noop_and_not_consumed:")
	var tool := AnnotationScaleTool.new()
	var host := _build_host_with_box([10, 20, 100, 50])
	tool.on_activate(host)

	# Right-click directly on a corner — should still no-op.
	var consumed := tool.on_pointer_down(Vector2(10, 20), MOUSE_BUTTON_RIGHT, 0)

	check("right-click NOT consumed",               not consumed)
	check("no drag started",                        not tool._dragging)


# ── Tests: scale math ─────────────────────────────────────────────────────────

func test_drag_doubles_offsets_from_center() -> void:
	print("test_drag_doubles_offsets_from_center:")
	# Bounds (10,20,100,50) → center (60,45). Grab BR corner at (110,70).
	# Start handle offset from center = (50, 25).
	# Move pointer to (160, 95) → new offset = (100, 50) → ratio = 2x on both axes.
	var tool := AnnotationScaleTool.new()
	var host := _build_host_with_box([10, 20, 100, 50])
	var sigs := _capture_signals(tool)
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(110, 70), MOUSE_BUTTON_LEFT, 0)
	check("dragging started",                       tool._dragging)

	tool.on_pointer_move(Vector2(160, 95))

	var modified_log: Array = sigs["modified"]
	check_eq("annotation_modified emitted once",    modified_log.size(), 1)
	if modified_log.size() >= 1:
		var entry: Dictionary = modified_log[0]
		check_eq("emitted id",                      entry["id"], "ann_a")
		var new_ann: Dictionary = entry["ann"]
		var prims: Array = new_ann.get("primitives", [])
		check_eq("primitives preserved (count=4)",  prims.size(), 4)

		# After 2x scale around center (60,45):
		#   TL corner (10,20) → (60 + (10-60)*2, 45 + (20-45)*2) = (-40, -5)
		#   BR corner (110,70) → (60 + 50*2, 45 + 25*2)          = (160, 95)
		# So prims[0].from (was [10,20]) should now be [-40,-5]; prims[3].from
		# (was [110,70]) should be [160,95].
		var p0_from: Array = (prims[0] as Dictionary).get("from", [])
		var p3_from: Array = (prims[3] as Dictionary).get("from", [])
		check_vec2_approx("TL prim scaled to (-40, -5)",
			Vector2(float(p0_from[0]), float(p0_from[1])), Vector2(-40, -5))
		check_vec2_approx("BR prim scaled to (160, 95)",
			Vector2(float(p3_from[0]), float(p3_from[1])), Vector2(160, 95))


func test_drag_toward_center_clamps_to_min_scale() -> void:
	print("test_drag_toward_center_clamps_to_min_scale:")
	# Grab BR (110,70). Start offset from center (60,45) = (50,25).
	# Move pointer to the center exactly → ratio 0/0 → should clamp to MIN_SCALE.
	var tool := AnnotationScaleTool.new()
	var host := _build_host_with_box([10, 20, 100, 50])
	var sigs := _capture_signals(tool)
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(110, 70), MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_move(Vector2(60, 45))   # pointer ON center

	var modified_log: Array = sigs["modified"]
	check_eq("annotation_modified emitted once",    modified_log.size(), 1)
	if modified_log.size() >= 1:
		var new_ann: Dictionary = modified_log[0]["ann"]
		var prims: Array = new_ann.get("primitives", [])
		# At MIN_SCALE = 0.05 around center (60,45):
		#   BR (110,70) → (60 + 50*0.05, 45 + 25*0.05) = (62.5, 46.25)
		var p3_from: Array = (prims[3] as Dictionary).get("from", [])
		check_vec2_approx("BR prim clamped at MIN_SCALE",
			Vector2(float(p3_from[0]), float(p3_from[1])), Vector2(62.5, 46.25), 0.01)


func test_drag_past_center_does_not_mirror() -> void:
	print("test_drag_past_center_does_not_mirror:")
	# Grab BR (110,70). Drag to (10, 20) — across center, would normally yield
	# negative scale (= mirror). Should clamp at MIN_SCALE (no mirror).
	var tool := AnnotationScaleTool.new()
	var host := _build_host_with_box([10, 20, 100, 50])
	var sigs := _capture_signals(tool)
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(110, 70), MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_move(Vector2(10, 20))   # exact opposite corner of center

	var modified_log: Array = sigs["modified"]
	check_eq("annotation_modified emitted once",    modified_log.size(), 1)
	if modified_log.size() >= 1:
		var new_ann: Dictionary = modified_log[0]["ann"]
		var prims: Array = new_ann.get("primitives", [])
		# Negative ratio (-1) would mirror BR to (10,20). Clamp at +MIN_SCALE
		# instead → BR (110,70) → (62.5, 46.25). Definitely NOT (10,20).
		var p3_from: Array = (prims[3] as Dictionary).get("from", [])
		var got := Vector2(float(p3_from[0]), float(p3_from[1]))
		check("BR did NOT mirror to (10,20)",       got.distance_to(Vector2(10, 20)) > 1.0)
		check_vec2_approx("BR clamped to MIN_SCALE position",
			got, Vector2(62.5, 46.25), 0.01)


func test_zero_size_bounds_does_not_crash() -> void:
	print("test_zero_size_bounds_does_not_crash:")
	# Degenerate bounds — all four corners collapse to the same point.
	# Tool must defensively avoid divide-by-zero. We don't expect a useful
	# scale, but the tool must not crash.
	var tool := AnnotationScaleTool.new()
	var host := _build_host_with_box([50, 50, 0, 0])
	tool.on_activate(host)

	# Click at the degenerate corner — should hit (since all four are at (50,50)).
	var consumed := tool.on_pointer_down(Vector2(50, 50), MOUSE_BUTTON_LEFT, 0)
	check("degenerate-bounds click handled (consumed)", consumed)
	check("drag started",                               tool._dragging)

	# Move — this would divide by zero without the guard.
	tool.on_pointer_move(Vector2(80, 80))
	check("survived pointer_move on zero bounds",       tool._dragging)


# ── Tests: escape / deactivate ────────────────────────────────────────────────

func test_escape_during_drag_reverts_via_signal() -> void:
	print("test_escape_during_drag_reverts_via_signal:")
	var tool := AnnotationScaleTool.new()
	var host := _build_host_with_box([10, 20, 100, 50])
	var sigs := _capture_signals(tool)
	tool.on_activate(host)

	# Begin a drag and move — produces one annotation_modified.
	tool.on_pointer_down(Vector2(110, 70), MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_move(Vector2(160, 95))
	check_eq("one modified emission from drag",     (sigs["modified"] as Array).size(), 1)

	# Escape during drag → re-emit start state.
	var consumed := tool.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, KEY_ESCAPE)

	check("escape consumed",                        consumed)
	check("no longer dragging",                     not tool._dragging)

	var modified_log: Array = sigs["modified"]
	check_eq("escape added a 2nd modified emission", modified_log.size(), 2)
	if modified_log.size() >= 2:
		var revert: Dictionary = modified_log[1]
		check_eq("revert id matches",               revert["id"], "ann_a")
		# Revert annotation should match the original primitives (corner-marker [10,20] etc.).
		var ann: Dictionary = revert["ann"]
		var prims: Array = ann.get("primitives", [])
		var p0: Dictionary = prims[0]
		var from0: Array = p0.get("from", [])
		check_vec2_approx("revert restored original TL primitive",
			Vector2(float(from0[0]), float(from0[1])), Vector2(10, 20))


func test_deactivate_during_drag_is_silent() -> void:
	print("test_deactivate_during_drag_is_silent:")
	var tool := AnnotationScaleTool.new()
	var host := _build_host_with_box([10, 20, 100, 50])
	var sigs := _capture_signals(tool)
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(110, 70), MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_move(Vector2(160, 95))
	var pre_count := (sigs["modified"] as Array).size()

	tool.on_deactivate()

	check("not dragging after deactivate",          not tool._dragging)
	check_eq("no extra modified from deactivate",   (sigs["modified"] as Array).size(), pre_count)
	check_eq("no cancelled emitted",                sigs["cancel"][0], 0)
	check_eq("no annotation_ready emitted",         sigs["ready"][0], 0)


# ── Tests: draw_preview ───────────────────────────────────────────────────────

func test_draw_preview_no_selection_no_calls() -> void:
	print("test_draw_preview_no_selection_no_calls:")
	var tool := AnnotationScaleTool.new()
	var host := _build_host_with_box([10, 20, 100, 50], false)  # no selection
	tool.on_activate(host)

	var ctx := RecordingCtx.new()
	tool.draw_preview(ctx)

	check_eq("no draw_rect calls when nothing selected", ctx.rect_calls.size(), 0)


func test_draw_preview_with_selection_draws_outline_and_four_handles() -> void:
	print("test_draw_preview_with_selection_draws_outline_and_four_handles:")
	var tool := AnnotationScaleTool.new()
	var host := _build_host_with_box([10, 20, 100, 50])  # selected
	tool.on_activate(host)

	var ctx := RecordingCtx.new()
	tool.draw_preview(ctx)

	# Expect 5 rects: 1 bounds outline (filled=false) + 4 handle squares (filled=true).
	check_eq("5 draw_rect calls (outline + 4 handles)", ctx.rect_calls.size(), 5)

	var filled_count := 0
	var outline_count := 0
	var handle_centers: Array = []
	for call in ctx.rect_calls:
		if (call as Dictionary)["filled"]:
			filled_count += 1
			var r: Rect2 = (call as Dictionary)["rect"]
			handle_centers.append(r.position + r.size * 0.5)
		else:
			outline_count += 1

	check_eq("4 filled handles",                      filled_count, 4)
	check_eq("1 outline rect",                        outline_count, 1)

	# Each handle's center should be at one of the four bounds-corners.
	var expected_corners := [
		Vector2(10, 20), Vector2(110, 20), Vector2(10, 70), Vector2(110, 70)
	]
	var matched := 0
	for ec in expected_corners:
		for hc in handle_centers:
			if ec.distance_to(hc) <= 0.001:
				matched += 1
				break
	check_eq("each of the 4 expected corners has a handle", matched, 4)

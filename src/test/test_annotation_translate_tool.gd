extends SceneTree
## Unit tests for AnnotationTranslateTool — drag-to-move manipulation tool.
## Run: timeout 60 godot --headless --path src --script test/test_annotation_translate_tool.gd
##
## Coverage:
##   Lifecycle:
##     - on_activate stores host; _dragging reset to false
##     - on_deactivate clears host and state (no signal, even mid-drag)
##   Drag start (on_pointer_down):
##     - Click on selected annotation starts drag (returns true, _dragging = true)
##     - Click on selected annotation when kind miss → no drag (returns false)
##     - Click when no selection → returns false
##     - Right-click → no-op, returns false
##   Drag move (on_pointer_move):
##     - Emits annotation_modified with correctly translated primitives (math check)
##     - Emits on every pointer_move call while dragging
##     - No emission after pointer_up (drag ended)
##     - No emission if not dragging
##   Drag end (on_pointer_up):
##     - Pointer-up while dragging returns true, stops drag
##     - Subsequent moves don't emit
##   Escape:
##     - KEY_ESCAPE during drag emits annotation_modified reverting to start state
##     - _dragging becomes false after escape
##     - KEY_ESCAPE when not dragging returns false
##   Deactivate mid-drag:
##     - on_deactivate is silent (no signal) even when dragging
##   Right-click:
##     - Right-click is always a no-op regardless of drag state
##   transform_primitives static helper:
##     - Passthrough for non-Dict entries
##     - Deep-copy semantics (input not mutated)
##     - Arrow primitives: translates "from" and "to"
##     - Text primitives: translates "at"
##     - Polyline: translates all entries in "points"
##     - p0/p1/p2 keys translated
##     - Identity transform leaves values unchanged

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== AnnotationTranslateTool Tests ===\n")

	print("-- lifecycle --")
	test_on_activate_stores_host()
	test_on_activate_resets_dragging()
	test_on_deactivate_clears_host_and_state()
	test_on_deactivate_mid_drag_is_silent()

	print("\n-- drag start --")
	test_click_on_selected_starts_drag()
	test_click_on_selected_miss_does_not_start_drag()
	test_click_with_no_selection_returns_false()
	test_right_click_is_noop()

	print("\n-- drag move --")
	test_pointer_move_emits_annotation_modified_with_correct_translation()
	test_pointer_move_emits_on_every_call()
	test_pointer_move_does_not_emit_when_not_dragging()

	print("\n-- drag end --")
	test_pointer_up_ends_drag_returns_true()
	test_pointer_move_after_pointer_up_does_not_emit()

	print("\n-- escape --")
	test_escape_during_drag_reverts_and_emits()
	test_escape_not_dragging_returns_false()

	print("\n-- transform_primitives static helper --")
	test_transform_primitives_passthrough_non_dict()
	test_transform_primitives_deep_copy_input_not_mutated()
	test_transform_primitives_arrow_from_to()
	test_transform_primitives_text_at()
	test_transform_primitives_polyline_points()
	test_transform_primitives_p0_p1_p2()
	test_transform_primitives_identity_unchanged()

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


func check_approx(description: String, actual: float, expected: float, tolerance: float = 0.001) -> void:
	if absf(actual - expected) <= tolerance:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s — expected %.4f, got %.4f" % [description, expected, actual])


# ── Stub kind ─────────────────────────────────────────────────────────────────
## Minimal box kind: bounds from annotation["rect"] = [x, y, w, h].
## hit_test returns true when point is inside the grown rect.

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


# ── Mock AnnotationHost ───────────────────────────────────────────────────────
## Mirrors the mock from test_annotation_select_tool.gd; additionally tracks
## update_annotation calls for verifying annotation_modified signal dispatch.

class MockHost extends AnnotationHost:
	var _registry: AnnotationRegistry = AnnotationRegistry.new()
	var _annotations: Array = []
	var _selected_id: String = ""
	var removed_ids: Array = []
	var updated_annotations: Array = []  # [{id, dict}, …]

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
		updated_annotations.append({"id": annotation_id, "dict": new_annotation.duplicate(true)})
		for i in _annotations.size():
			var ann: Dictionary = _annotations[i]
			if str(ann.get("id", "")) == annotation_id:
				_annotations[i] = new_annotation.duplicate(true)
				_annotations[i]["id"] = annotation_id
				return true
		return false

	func remove_annotation(annotation_id: String) -> bool:
		removed_ids.append(annotation_id)
		for i in _annotations.size():
			var ann: Dictionary = _annotations[i]
			if str(ann.get("id", "")) == annotation_id:
				_annotations.remove_at(i)
				if _selected_id == annotation_id:
					set_selected_annotation_id("")
				return true
		return false

	func set_selected_annotation_id(annotation_id: String) -> void:
		if _selected_id == annotation_id:
			return
		_selected_id = annotation_id
		selection_changed.emit(annotation_id)

	func get_selected_annotation_id() -> String:
		return _selected_id

	func transform_screen_to_doc(p: Vector2) -> Vector2:
		return p  # identity

	func transform_doc_to_screen(p: Vector2) -> Vector2:
		return p


# ── Signal capture helpers ─────────────────────────────────────────────────────

func _capture_translate_signals(tool: AnnotationTranslateTool) -> Dictionary:
	var modified_ids: Array = []
	var modified_dicts: Array = []
	var cancel_count: Array = [0]
	tool.annotation_modified.connect(func(id: String, d: Dictionary) -> void:
		modified_ids.append(id)
		modified_dicts.append(d.duplicate(true))
	)
	tool.cancelled.connect(func() -> void:
		cancel_count[0] += 1
	)
	return {
		"modified_ids":   modified_ids,
		"modified_dicts": modified_dicts,
		"cancel_count":   cancel_count,
	}


# ── Fixture helpers ────────────────────────────────────────────────────────────

func _build_host_with_arrow() -> MockHost:
	## Arrow annotation at (10,20)→(30,40); bounding rect used by StubBoxKind as
	## "rect": [10, 20, 20, 20] so that point (15,25) hits.
	var host := MockHost.new()
	host._registry.register_annotation_kind(StubBoxKind.new(&"stub_box"))
	host.add_annotation({
		"id":   "ann_arrow",
		"kind": "stub_box",
		"rect": [10, 20, 20, 20],
		"primitives": [{
			"kind": "arrow",
			"from": [10.0, 20.0],
			"to":   [30.0, 40.0],
		}],
	})
	return host


func _build_selected_host() -> MockHost:
	var host := _build_host_with_arrow()
	host.set_selected_annotation_id("ann_arrow")
	return host


# ── Tests: lifecycle ──────────────────────────────────────────────────────────

func test_on_activate_stores_host() -> void:
	print("test_on_activate_stores_host:")
	var tool := AnnotationTranslateTool.new()
	var host := MockHost.new()
	tool.on_activate(host)
	check("_host stored after on_activate", tool._host == host)


func test_on_activate_resets_dragging() -> void:
	print("test_on_activate_resets_dragging:")
	var tool := AnnotationTranslateTool.new()
	var host := _build_selected_host()
	# Manually force dragging = true to simulate dirty state.
	tool._dragging = true
	tool.on_activate(host)
	check("_dragging is false after on_activate", not tool._dragging)


func test_on_deactivate_clears_host_and_state() -> void:
	print("test_on_deactivate_clears_host_and_state:")
	var tool := AnnotationTranslateTool.new()
	var host := _build_selected_host()
	tool.on_activate(host)
	# Start a drag.
	tool.on_pointer_down(Vector2(15, 25), MOUSE_BUTTON_LEFT, 0)
	check("_dragging is true before deactivate", tool._dragging)

	tool.on_deactivate()
	check("_host cleared after deactivate",      tool._host == null)
	check("_dragging cleared after deactivate",  not tool._dragging)


func test_on_deactivate_mid_drag_is_silent() -> void:
	print("test_on_deactivate_mid_drag_is_silent:")
	var tool := AnnotationTranslateTool.new()
	var host := _build_selected_host()
	tool.on_activate(host)

	var sigs := _capture_translate_signals(tool)

	# Start a drag, move a bit, then deactivate.
	tool.on_pointer_down(Vector2(15, 25), MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_move(Vector2(20, 30))
	var emits_before_deactivate: int = sigs["modified_ids"].size()

	tool.on_deactivate()

	# Deactivate must NOT emit any additional signal.
	check_eq("no extra modified signal on deactivate",
		sigs["modified_ids"].size(),
		emits_before_deactivate
	)
	check_eq("no cancelled signal on deactivate", sigs["cancel_count"][0], 0)


# ── Tests: drag start ─────────────────────────────────────────────────────────

func test_click_on_selected_starts_drag() -> void:
	print("test_click_on_selected_starts_drag:")
	var tool := AnnotationTranslateTool.new()
	var host := _build_selected_host()
	tool.on_activate(host)

	# Click at (15, 25) — inside the stub box [10,20,20,20].
	var consumed := tool.on_pointer_down(Vector2(15, 25), MOUSE_BUTTON_LEFT, 0)

	check("click consumed",                         consumed)
	check("_dragging is true",                      tool._dragging)
	check_eq("_drag_id set to ann_arrow",           tool._drag_id, "ann_arrow")


func test_click_on_selected_miss_does_not_start_drag() -> void:
	print("test_click_on_selected_miss_does_not_start_drag:")
	var tool := AnnotationTranslateTool.new()
	var host := _build_selected_host()
	tool.on_activate(host)

	# Click far outside the annotation box — StubBoxKind.hit_test will miss.
	# box is [10,20,20,20] grown by threshold=8; click at (200,200) is a clear miss.
	var consumed := tool.on_pointer_down(Vector2(200, 200), MOUSE_BUTTON_LEFT, 0)

	check("click NOT consumed on miss", not consumed)
	check("_dragging remains false",    not tool._dragging)


func test_click_with_no_selection_returns_false() -> void:
	print("test_click_with_no_selection_returns_false:")
	var tool := AnnotationTranslateTool.new()
	var host := _build_host_with_arrow()  # no selection set
	tool.on_activate(host)

	var consumed := tool.on_pointer_down(Vector2(15, 25), MOUSE_BUTTON_LEFT, 0)

	check("click NOT consumed when no selection", not consumed)
	check("_dragging remains false",              not tool._dragging)


func test_right_click_is_noop() -> void:
	print("test_right_click_is_noop:")
	var tool := AnnotationTranslateTool.new()
	var host := _build_selected_host()
	tool.on_activate(host)

	var consumed := tool.on_pointer_down(Vector2(15, 25), MOUSE_BUTTON_RIGHT, 0)

	check("right-click NOT consumed",     not consumed)
	check("_dragging still false",        not tool._dragging)

	# Also test right-click during an active drag.
	# First start a valid drag.
	tool.on_pointer_down(Vector2(15, 25), MOUSE_BUTTON_LEFT, 0)
	check("drag active (precondition)",   tool._dragging)

	var consumed2 := tool.on_pointer_down(Vector2(20, 30), MOUSE_BUTTON_RIGHT, 0)
	check("right-click during drag NOT consumed", not consumed2)
	check("drag still active after right-click",  tool._dragging)


# ── Tests: drag move ─────────────────────────────────────────────────────────

func test_pointer_move_emits_annotation_modified_with_correct_translation() -> void:
	print("test_pointer_move_emits_annotation_modified_with_correct_translation:")
	## Input annotation: primitives[0].from = [10, 20], .to = [30, 40]
	## Drag started at doc pos (15, 25). Move to (20, 22).
	## Expected delta = (5, -3).
	## Expected new from = [15, 17], new to = [35, 37].
	var tool := AnnotationTranslateTool.new()
	var host := _build_selected_host()
	tool.on_activate(host)

	var sigs := _capture_translate_signals(tool)

	# Start drag at (15, 25).
	tool.on_pointer_down(Vector2(15, 25), MOUSE_BUTTON_LEFT, 0)
	# Move to (20, 22) → delta = (5, -3).
	tool.on_pointer_move(Vector2(20, 22))

	check_eq("one modified signal emitted", sigs["modified_ids"].size(), 1)
	check_eq("modified id is ann_arrow",    sigs["modified_ids"][0], "ann_arrow")

	var emitted_dict: Dictionary = sigs["modified_dicts"][0]
	var prims: Array = emitted_dict.get("primitives", [])
	check_eq("one primitive in emitted dict", prims.size(), 1)

	var prim: Dictionary = prims[0]
	var new_from: Array = prim.get("from", [])
	var new_to:   Array = prim.get("to",   [])

	check_approx("from.x = 15.0", float(new_from[0]), 15.0)
	check_approx("from.y = 17.0", float(new_from[1]), 17.0)
	check_approx("to.x   = 35.0", float(new_to[0]),   35.0)
	check_approx("to.y   = 37.0", float(new_to[1]),   37.0)


func test_pointer_move_emits_on_every_call() -> void:
	print("test_pointer_move_emits_on_every_call:")
	var tool := AnnotationTranslateTool.new()
	var host := _build_selected_host()
	tool.on_activate(host)

	var sigs := _capture_translate_signals(tool)

	tool.on_pointer_down(Vector2(15, 25), MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_move(Vector2(16, 25))
	tool.on_pointer_move(Vector2(17, 25))
	tool.on_pointer_move(Vector2(18, 25))

	check_eq("three modified signals (one per move)", sigs["modified_ids"].size(), 3)


func test_pointer_move_does_not_emit_when_not_dragging() -> void:
	print("test_pointer_move_does_not_emit_when_not_dragging:")
	var tool := AnnotationTranslateTool.new()
	var host := _build_selected_host()
	tool.on_activate(host)

	var sigs := _capture_translate_signals(tool)

	# Move without starting a drag.
	tool.on_pointer_move(Vector2(50, 50))

	check_eq("no signal when not dragging", sigs["modified_ids"].size(), 0)


# ── Tests: drag end ───────────────────────────────────────────────────────────

func test_pointer_up_ends_drag_returns_true() -> void:
	print("test_pointer_up_ends_drag_returns_true:")
	var tool := AnnotationTranslateTool.new()
	var host := _build_selected_host()
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(15, 25), MOUSE_BUTTON_LEFT, 0)
	check("_dragging true before up (precondition)", tool._dragging)

	var consumed := tool.on_pointer_up(Vector2(20, 25), MOUSE_BUTTON_LEFT, 0)

	check("pointer_up consumed when dragging", consumed)
	check("_dragging false after pointer_up",  not tool._dragging)


func test_pointer_move_after_pointer_up_does_not_emit() -> void:
	print("test_pointer_move_after_pointer_up_does_not_emit:")
	var tool := AnnotationTranslateTool.new()
	var host := _build_selected_host()
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(15, 25), MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_move(Vector2(20, 25))

	var sigs := _capture_translate_signals(tool)
	# Reconnect fresh signal capture after the drag-start emit.

	var emit_count_at_up: Array = [0]
	tool.annotation_modified.connect(func(_id: String, _d: Dictionary) -> void:
		emit_count_at_up[0] += 1
	)

	tool.on_pointer_up(Vector2(20, 25), MOUSE_BUTTON_LEFT, 0)
	# Pointer moves after pointer_up must not emit.
	tool.on_pointer_move(Vector2(25, 30))
	tool.on_pointer_move(Vector2(30, 35))

	check_eq("no signal after pointer_up", emit_count_at_up[0], 0)


# ── Tests: escape ─────────────────────────────────────────────────────────────

func test_escape_during_drag_reverts_and_emits() -> void:
	print("test_escape_during_drag_reverts_and_emits:")
	var tool := AnnotationTranslateTool.new()
	var host := _build_selected_host()
	tool.on_activate(host)

	var sigs := _capture_translate_signals(tool)

	# Start drag at (15,25). Snapshot: from=[10,20], to=[30,40].
	tool.on_pointer_down(Vector2(15, 25), MOUSE_BUTTON_LEFT, 0)
	# Move to (20,22) → delta=(5,-3) emits modified with translated coords.
	tool.on_pointer_move(Vector2(20, 22))
	check_eq("one move signal (precondition)", sigs["modified_ids"].size(), 1)

	# Escape via mods channel.
	var consumed := tool.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, KEY_ESCAPE)

	check("escape consumed",                 consumed)
	check("_dragging false after escape",    not tool._dragging)
	check_eq("two modified signals total (move + revert)", sigs["modified_ids"].size(), 2)

	# Second signal must be the revert: original from=[10,20], to=[30,40].
	var revert_dict: Dictionary = sigs["modified_dicts"][1]
	var prims: Array = revert_dict.get("primitives", [])
	check_eq("revert has one primitive", prims.size(), 1)
	var prim: Dictionary = prims[0]
	check_eq("revert from.x = 10", int(float(prim.get("from", [0, 0])[0])), 10)
	check_eq("revert from.y = 20", int(float(prim.get("from", [0, 0])[1])), 20)
	check_eq("revert to.x   = 30", int(float(prim.get("to",   [0, 0])[0])), 30)
	check_eq("revert to.y   = 40", int(float(prim.get("to",   [0, 0])[1])), 40)


func test_escape_not_dragging_returns_false() -> void:
	print("test_escape_not_dragging_returns_false:")
	var tool := AnnotationTranslateTool.new()
	var host := _build_selected_host()
	tool.on_activate(host)

	var sigs := _capture_translate_signals(tool)
	var consumed := tool.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, KEY_ESCAPE)

	check("escape NOT consumed when not dragging", not consumed)
	check_eq("no signal when not dragging",        sigs["modified_ids"].size(), 0)


# ── Tests: transform_primitives static helper ─────────────────────────────────

func test_transform_primitives_passthrough_non_dict() -> void:
	print("test_transform_primitives_passthrough_non_dict:")
	var input := ["hello", 42, null]
	var t := Transform2D(0.0, Vector2(5, 3))
	var result := AnnotationKind.transform_primitives(input, t)

	check_eq("result has same size", result.size(), input.size())
	check_eq("non-dict string passthrough", result[0], "hello")
	check_eq("non-dict int passthrough",    result[1], 42)
	check("non-dict null passthrough",      result[2] == null)


func test_transform_primitives_deep_copy_input_not_mutated() -> void:
	print("test_transform_primitives_deep_copy_input_not_mutated:")
	var original_from := [10.0, 20.0]
	var input := [{
		"kind": "arrow",
		"from": original_from,
		"to":   [30.0, 40.0],
	}]
	var t := Transform2D(0.0, Vector2(5.0, -3.0))

	# Keep a reference to the original dict to verify no mutation.
	var original_dict: Dictionary = input[0]
	var result := AnnotationKind.transform_primitives(input, t)

	# The input array's dict must be unmutated.
	var input_from: Array = original_dict.get("from", [])
	check_approx("input from.x unchanged after transform", float(input_from[0]), 10.0)
	check_approx("input from.y unchanged after transform", float(input_from[1]), 20.0)

	# The result dict must have translated values.
	var out_from: Array = (result[0] as Dictionary).get("from", [])
	check_approx("output from.x = 15.0", float(out_from[0]), 15.0)
	check_approx("output from.y = 17.0", float(out_from[1]), 17.0)


func test_transform_primitives_arrow_from_to() -> void:
	print("test_transform_primitives_arrow_from_to:")
	var input := [{
		"kind": "arrow",
		"from": [10.0, 20.0],
		"to":   [30.0, 40.0],
	}]
	var delta := Vector2(5.0, -3.0)
	var t := Transform2D(0.0, delta)
	var result := AnnotationKind.transform_primitives(input, t)

	var prim: Dictionary = result[0]
	var from_arr: Array = prim.get("from", [])
	var to_arr:   Array = prim.get("to",   [])

	check_approx("arrow from.x = 15.0", float(from_arr[0]), 15.0)
	check_approx("arrow from.y = 17.0", float(from_arr[1]), 17.0)
	check_approx("arrow to.x   = 35.0", float(to_arr[0]),   35.0)
	check_approx("arrow to.y   = 37.0", float(to_arr[1]),   37.0)


func test_transform_primitives_text_at() -> void:
	print("test_transform_primitives_text_at:")
	var input := [{
		"kind":    "text",
		"at":      [100.0, 200.0],
		"content": "hello",
	}]
	var delta := Vector2(-10.0, 5.0)
	var t := Transform2D(0.0, delta)
	var result := AnnotationKind.transform_primitives(input, t)

	var prim: Dictionary = result[0]
	var at_arr: Array = prim.get("at", [])

	check_approx("text at.x = 90.0",  float(at_arr[0]), 90.0)
	check_approx("text at.y = 205.0", float(at_arr[1]), 205.0)
	# Non-coord key should be untouched.
	check_eq("content unchanged", prim.get("content", ""), "hello")


func test_transform_primitives_polyline_points() -> void:
	print("test_transform_primitives_polyline_points:")
	var input := [{
		"kind":   "polyline",
		"points": [[0.0, 0.0], [10.0, 0.0], [10.0, 10.0]],
	}]
	var delta := Vector2(1.0, 2.0)
	var t := Transform2D(0.0, delta)
	var result := AnnotationKind.transform_primitives(input, t)

	var prim: Dictionary = result[0]
	var pts: Array = prim.get("points", [])

	check_eq("three points output", pts.size(), 3)
	check_approx("pt0.x = 1.0",  float(pts[0][0]), 1.0)
	check_approx("pt0.y = 2.0",  float(pts[0][1]), 2.0)
	check_approx("pt1.x = 11.0", float(pts[1][0]), 11.0)
	check_approx("pt1.y = 2.0",  float(pts[1][1]), 2.0)
	check_approx("pt2.x = 11.0", float(pts[2][0]), 11.0)
	check_approx("pt2.y = 12.0", float(pts[2][1]), 12.0)


func test_transform_primitives_p0_p1_p2() -> void:
	print("test_transform_primitives_p0_p1_p2:")
	var input := [{
		"kind": "custom_triangle",
		"p0":   [0.0,  0.0],
		"p1":   [10.0, 0.0],
		"p2":   [5.0,  8.0],
	}]
	var delta := Vector2(3.0, 4.0)
	var t := Transform2D(0.0, delta)
	var result := AnnotationKind.transform_primitives(input, t)

	var prim: Dictionary = result[0]
	var p0: Array = prim.get("p0", [])
	var p1: Array = prim.get("p1", [])
	var p2: Array = prim.get("p2", [])

	check_approx("p0.x = 3.0",  float(p0[0]), 3.0)
	check_approx("p0.y = 4.0",  float(p0[1]), 4.0)
	check_approx("p1.x = 13.0", float(p1[0]), 13.0)
	check_approx("p1.y = 4.0",  float(p1[1]), 4.0)
	check_approx("p2.x = 8.0",  float(p2[0]), 8.0)
	check_approx("p2.y = 12.0", float(p2[1]), 12.0)


func test_transform_primitives_identity_unchanged() -> void:
	print("test_transform_primitives_identity_unchanged:")
	var input := [{
		"kind": "arrow",
		"from": [7.0, 11.0],
		"to":   [13.0, 17.0],
	}]
	var result := AnnotationKind.transform_primitives(input, Transform2D.IDENTITY)

	var prim: Dictionary = result[0]
	var from_arr: Array = prim.get("from", [])
	var to_arr:   Array = prim.get("to",   [])

	check_approx("identity from.x unchanged", float(from_arr[0]), 7.0)
	check_approx("identity from.y unchanged", float(from_arr[1]), 11.0)
	check_approx("identity to.x unchanged",   float(to_arr[0]),   13.0)
	check_approx("identity to.y unchanged",   float(to_arr[1]),   17.0)

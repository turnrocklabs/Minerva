extends SceneTree
## Unit tests for AnnotationSelectTool — first manipulation tool.
## Run: timeout 60 godot --headless --path src --script test/test_annotation_select_tool.gd
##
## Coverage:
##   - on_activate stores host
##   - Click on no annotations → selection = ""
##   - Click hits an annotation → selection = ann's id
##   - Click on a stack of overlapping annotations → topmost (last in array) wins
##   - Click outside any annotation → selection cleared (and consumed)
##   - Delete key with selection → host.remove_annotation called with that id
##   - Delete key with no selection → host.remove_annotation NOT called
##   - Escape with selection → selection cleared
##   - Right-click → no-op, no selection change, NOT consumed
##   - draw_preview with no selection → no draw_rect calls
##   - draw_preview with selection → exactly one draw_rect call at the kind's bounds
##   - Selection persists across on_deactivate / on_activate (HOST state, not tool state)

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== AnnotationSelectTool Tests ===\n")

	print("-- lifecycle --")
	test_on_activate_stores_host()
	test_selection_persists_across_deactivate_activate()

	print("\n-- left-click selection --")
	test_click_empty_doc_sets_selection_empty()
	test_click_on_annotation_sets_selection()
	test_click_topmost_wins_when_overlapping()
	test_click_outside_clears_existing_selection()
	test_unknown_kind_is_skipped_during_hit_test()

	print("\n-- keyboard (Delete / Escape) --")
	test_delete_with_selection_calls_remove_annotation()
	test_delete_without_selection_is_noop()
	test_escape_with_selection_clears_selection()

	print("\n-- right-click --")
	test_right_click_is_noop_and_not_consumed()

	print("\n-- halo / draw_preview --")
	test_draw_preview_no_selection_no_calls()
	test_draw_preview_with_selection_draws_one_rect()
	test_draw_preview_with_unknown_id_does_not_draw()

	print("\n-- no-signal contract --")
	test_select_emits_no_annotation_ready_or_modified()

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


# ── Stub kinds ────────────────────────────────────────────────────────────────
## Minimal kinds whose bounds() / hit_test() are predictable and cheap.

class StubBoxKind extends AnnotationKind:
	## Treats annotation["rect"] = [x, y, w, h] as its bounds.
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

class MockHost extends AnnotationHost:
	var _registry: AnnotationRegistry = AnnotationRegistry.new()
	var _annotations: Array = []
	var _selected_id: String = ""
	var removed_ids: Array = []
	var selection_change_log: Array = []

	func get_registry() -> AnnotationRegistry:
		return _registry

	func get_annotations() -> Array:
		return _annotations

	func add_annotation(annotation: Dictionary) -> String:
		var id := str(annotation.get("id", "ann_%d" % _annotations.size()))
		annotation["id"] = id
		_annotations.append(annotation)
		return id

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
		selection_change_log.append(annotation_id)
		selection_changed.emit(annotation_id)

	func get_selected_annotation_id() -> String:
		return _selected_id

	func transform_screen_to_doc(p: Vector2) -> Vector2:
		return p   # identity

	func transform_doc_to_screen(p: Vector2) -> Vector2:
		return p


# ── Instrumented render context ───────────────────────────────────────────────
## Records draw_rect calls so we can assert halo behaviour without a real
## RenderingServer canvas item.

class RecordingCtx extends AnnotationRenderContext:
	var rect_calls: Array = []   # each entry: { rect, color, filled, width }

	func draw_rect(rect: Rect2, color: Color, filled: bool, width: float = 1.0) -> void:
		rect_calls.append({
			"rect":   rect,
			"color":  color,
			"filled": filled,
			"width":  width,
		})


# ── Signal capture helper ─────────────────────────────────────────────────────

func _capture_signals(tool: AnnotationSelectTool) -> Dictionary:
	var ready_count: Array = [0]
	var modified_count: Array = [0]
	var cancel_count: Array = [0]
	tool.annotation_ready.connect(func(_a: Dictionary) -> void:
		ready_count[0] += 1
	)
	tool.annotation_modified.connect(func(_id: String, _a: Dictionary) -> void:
		modified_count[0] += 1
	)
	tool.cancelled.connect(func() -> void:
		cancel_count[0] += 1
	)
	return {
		"ready":    ready_count,
		"modified": modified_count,
		"cancel":   cancel_count,
	}


# ── Fixture builders ──────────────────────────────────────────────────────────

func _build_host_with_two_boxes() -> MockHost:
	# Box A spans (0,0)-(20,20); Box B spans (50,50)-(70,70). Disjoint.
	var host := MockHost.new()
	host._registry.register_annotation_kind(StubBoxKind.new(&"stub_box"))
	host.add_annotation({
		"id":   "ann_a",
		"kind": "stub_box",
		"rect": [0, 0, 20, 20],
	})
	host.add_annotation({
		"id":   "ann_b",
		"kind": "stub_box",
		"rect": [50, 50, 20, 20],
	})
	return host


func _build_host_with_overlapping_boxes() -> MockHost:
	# Both boxes overlap at point (10, 10). ann_top is appended LAST → topmost.
	var host := MockHost.new()
	host._registry.register_annotation_kind(StubBoxKind.new(&"stub_box"))
	host.add_annotation({
		"id":   "ann_bottom",
		"kind": "stub_box",
		"rect": [0, 0, 30, 30],
	})
	host.add_annotation({
		"id":   "ann_top",
		"kind": "stub_box",
		"rect": [5, 5, 20, 20],
	})
	return host


# ── Tests: lifecycle ──────────────────────────────────────────────────────────

func test_on_activate_stores_host() -> void:
	print("test_on_activate_stores_host:")
	var tool := AnnotationSelectTool.new()
	var host := MockHost.new()

	tool.on_activate(host)

	check("host stored after on_activate", tool._host == host)


func test_selection_persists_across_deactivate_activate() -> void:
	print("test_selection_persists_across_deactivate_activate:")
	var tool := AnnotationSelectTool.new()
	var host := _build_host_with_two_boxes()

	tool.on_activate(host)
	tool.on_pointer_down(Vector2(5, 5), MOUSE_BUTTON_LEFT, 0)
	check_eq("selected after click", host.get_selected_annotation_id(), "ann_a")

	tool.on_deactivate()
	check("host cleared after deactivate", tool._host == null)
	check_eq(
		"selection survives deactivate (HOST state)",
		host.get_selected_annotation_id(),
		"ann_a"
	)

	tool.on_activate(host)
	check_eq(
		"selection still present after re-activate",
		host.get_selected_annotation_id(),
		"ann_a"
	)


# ── Tests: left-click selection ───────────────────────────────────────────────

func test_click_empty_doc_sets_selection_empty() -> void:
	print("test_click_empty_doc_sets_selection_empty:")
	var tool := AnnotationSelectTool.new()
	var host := MockHost.new()  # zero annotations
	host._registry.register_annotation_kind(StubBoxKind.new(&"stub_box"))
	tool.on_activate(host)

	var consumed := tool.on_pointer_down(Vector2(99, 99), MOUSE_BUTTON_LEFT, 0)

	check("click consumed",                             consumed)
	check_eq("selection is empty",                      host.get_selected_annotation_id(), "")


func test_click_on_annotation_sets_selection() -> void:
	print("test_click_on_annotation_sets_selection:")
	var tool := AnnotationSelectTool.new()
	var host := _build_host_with_two_boxes()
	tool.on_activate(host)

	# Click inside Box B at (60, 60).
	var consumed := tool.on_pointer_down(Vector2(60, 60), MOUSE_BUTTON_LEFT, 0)

	check("click consumed",                             consumed)
	check_eq("Box B is selected",                       host.get_selected_annotation_id(), "ann_b")


func test_click_topmost_wins_when_overlapping() -> void:
	print("test_click_topmost_wins_when_overlapping:")
	var tool := AnnotationSelectTool.new()
	var host := _build_host_with_overlapping_boxes()
	tool.on_activate(host)

	# Click at (10, 10) — inside both boxes. Topmost (ann_top, last in array) wins.
	tool.on_pointer_down(Vector2(10, 10), MOUSE_BUTTON_LEFT, 0)

	check_eq("topmost ann selected",                    host.get_selected_annotation_id(), "ann_top")


func test_click_outside_clears_existing_selection() -> void:
	print("test_click_outside_clears_existing_selection:")
	var tool := AnnotationSelectTool.new()
	var host := _build_host_with_two_boxes()
	tool.on_activate(host)

	# First select ann_a, then click in empty space.
	tool.on_pointer_down(Vector2(5, 5), MOUSE_BUTTON_LEFT, 0)
	check_eq("ann_a selected (precondition)",           host.get_selected_annotation_id(), "ann_a")

	var consumed := tool.on_pointer_down(Vector2(200, 200), MOUSE_BUTTON_LEFT, 0)

	check("empty-space click consumed",                 consumed)
	check_eq("selection cleared by empty-space click",  host.get_selected_annotation_id(), "")


func test_unknown_kind_is_skipped_during_hit_test() -> void:
	print("test_unknown_kind_is_skipped_during_hit_test:")
	# An annotation whose kind is not registered should be skipped — not crash.
	var tool := AnnotationSelectTool.new()
	var host := MockHost.new()
	host._registry.register_annotation_kind(StubBoxKind.new(&"stub_box"))
	host.add_annotation({
		"id":   "ann_ghost",
		"kind": "unknown_kind",     # NOT registered
		"rect": [0, 0, 100, 100],
	})
	host.add_annotation({
		"id":   "ann_real",
		"kind": "stub_box",
		"rect": [0, 0, 100, 100],
	})
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(50, 50), MOUSE_BUTTON_LEFT, 0)

	# Even though both boxes contain (50,50), the unknown-kind one is skipped
	# and the registered one is selected.
	check_eq("registered kind is selected, unknown skipped",
		host.get_selected_annotation_id(), "ann_real")


# ── Tests: keyboard (Delete / Escape) ────────────────────────────────────────

func test_delete_with_selection_calls_remove_annotation() -> void:
	print("test_delete_with_selection_calls_remove_annotation:")
	var tool := AnnotationSelectTool.new()
	var host := _build_host_with_two_boxes()
	tool.on_activate(host)

	# Select ann_b first.
	tool.on_pointer_down(Vector2(60, 60), MOUSE_BUTTON_LEFT, 0)

	# Delete via mods=KEY_DELETE.
	var consumed := tool.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, KEY_DELETE)

	check("delete consumed",                            consumed)
	check_eq("remove_annotation called once",           host.removed_ids.size(), 1)
	check_eq("remove_annotation called with ann_b",     host.removed_ids[0], "ann_b")


func test_delete_without_selection_is_noop() -> void:
	print("test_delete_without_selection_is_noop:")
	var tool := AnnotationSelectTool.new()
	var host := _build_host_with_two_boxes()
	tool.on_activate(host)

	# No selection set — Delete should not call remove_annotation.
	var consumed := tool.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, KEY_DELETE)

	check("delete still consumed",                      consumed)
	check_eq("remove_annotation NOT called",            host.removed_ids.size(), 0)


func test_escape_with_selection_clears_selection() -> void:
	print("test_escape_with_selection_clears_selection:")
	var tool := AnnotationSelectTool.new()
	var host := _build_host_with_two_boxes()
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(5, 5), MOUSE_BUTTON_LEFT, 0)
	check_eq("ann_a selected (precondition)",           host.get_selected_annotation_id(), "ann_a")

	var consumed := tool.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, KEY_ESCAPE)

	check("escape consumed",                            consumed)
	check_eq("selection cleared by Escape",             host.get_selected_annotation_id(), "")
	check_eq("remove_annotation NOT called by Escape",  host.removed_ids.size(), 0)


# ── Tests: right-click ────────────────────────────────────────────────────────

func test_right_click_is_noop_and_not_consumed() -> void:
	print("test_right_click_is_noop_and_not_consumed:")
	var tool := AnnotationSelectTool.new()
	var host := _build_host_with_two_boxes()
	tool.on_activate(host)

	# Pre-select Box A so we can verify the right-click doesn't disturb it.
	tool.on_pointer_down(Vector2(5, 5), MOUSE_BUTTON_LEFT, 0)
	var pre_change_log_size := host.selection_change_log.size()

	var consumed := tool.on_pointer_down(Vector2(60, 60), MOUSE_BUTTON_RIGHT, 0)

	check("right-click NOT consumed (host can handle)", not consumed)
	check_eq("selection unchanged",                     host.get_selected_annotation_id(), "ann_a")
	check_eq(
		"no new selection_changed events",
		host.selection_change_log.size(),
		pre_change_log_size,
	)
	check_eq("remove_annotation NOT called",            host.removed_ids.size(), 0)


# ── Tests: halo / draw_preview ────────────────────────────────────────────────

func test_draw_preview_no_selection_no_calls() -> void:
	print("test_draw_preview_no_selection_no_calls:")
	var tool := AnnotationSelectTool.new()
	var host := _build_host_with_two_boxes()
	tool.on_activate(host)

	var ctx := RecordingCtx.new()
	tool.draw_preview(ctx)

	check_eq("no draw_rect calls when nothing selected", ctx.rect_calls.size(), 0)


func test_draw_preview_with_selection_draws_one_rect() -> void:
	print("test_draw_preview_with_selection_draws_one_rect:")
	var tool := AnnotationSelectTool.new()
	var host := _build_host_with_two_boxes()
	tool.on_activate(host)

	# Select ann_a (rect 0,0,20,20). Halo should be drawn at bounds grown by inset.
	tool.on_pointer_down(Vector2(5, 5), MOUSE_BUTTON_LEFT, 0)

	var ctx := RecordingCtx.new()
	tool.draw_preview(ctx)

	check_eq("exactly one draw_rect call",              ctx.rect_calls.size(), 1)
	if ctx.rect_calls.size() == 1:
		var call: Dictionary = ctx.rect_calls[0]
		check("filled is false (outline only)",         call["filled"] == false)
		check("width >= 1.0",                           float(call["width"]) >= 1.0)
		# rect should be the kind's bounds, possibly grown by an inset. We
		# verify the bounding rect at least contains the underlying ann's
		# bounds (0,0,20,20) — i.e. the halo encloses the annotation.
		var halo_rect: Rect2 = call["rect"]
		var ann_bounds := Rect2(0, 0, 20, 20)
		check(
			"halo encloses annotation bounds",
			halo_rect.position.x <= ann_bounds.position.x
				and halo_rect.position.y <= ann_bounds.position.y
				and halo_rect.end.x >= ann_bounds.end.x
				and halo_rect.end.y >= ann_bounds.end.y
		)


func test_draw_preview_with_unknown_id_does_not_draw() -> void:
	print("test_draw_preview_with_unknown_id_does_not_draw:")
	# Force-set a selection id that doesn't match any annotation. Shouldn't crash.
	var tool := AnnotationSelectTool.new()
	var host := _build_host_with_two_boxes()
	tool.on_activate(host)
	host.set_selected_annotation_id("ann_does_not_exist")

	var ctx := RecordingCtx.new()
	tool.draw_preview(ctx)

	check_eq("no draw_rect when selection id is stale", ctx.rect_calls.size(), 0)


# ── Tests: no-signal contract ─────────────────────────────────────────────────

func test_select_emits_no_annotation_ready_or_modified() -> void:
	print("test_select_emits_no_annotation_ready_or_modified:")
	# Select is a selection-only tool — it MUST NOT emit annotation_ready
	# (authoring) or annotation_modified (manipulation-mutation). Selection
	# and deletion go through the host's own change signals.
	var tool := AnnotationSelectTool.new()
	var host := _build_host_with_two_boxes()
	var sigs := _capture_signals(tool)
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(5, 5), MOUSE_BUTTON_LEFT, 0)            # select
	tool.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, KEY_DELETE)    # delete
	tool.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, KEY_ESCAPE)    # escape
	tool.on_pointer_down(Vector2(99, 99), MOUSE_BUTTON_RIGHT, 0)         # right-click

	check_eq("no annotation_ready emitted",             sigs["ready"][0],    0)
	check_eq("no annotation_modified emitted",          sigs["modified"][0], 0)
	check_eq("no cancelled emitted",                    sigs["cancel"][0],   0)

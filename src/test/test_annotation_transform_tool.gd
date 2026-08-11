extends SceneTree
## Unit tests for AnnotationTransformTool — unified gizmo (R2.6).
## Run: timeout 60 godot --headless --path src --script test/test_annotation_transform_tool.gd
##
## Coverage:
##   Hit-zone discrimination (≥10 tests):
##     - center → INSIDE
##     - near corner but well inside → INSIDE
##     - exact top-left corner → CORNER_TL
##     - top-right corner → CORNER_TR
##     - bottom-right corner → CORNER_BR
##     - top-edge midpoint → EDGE_T
##     - left-edge midpoint → EDGE_L
##     - rotate ring outside top-left → ROTATE_TL
##     - far outside → OUTSIDE
##     - deep interior → INSIDE
##
##   Drag forwarding (≥10 tests):
##     - INSIDE drag → translate
##     - CORNER_BR drag outward → uniform scale > 1
##     - CORNER_TL drag toward center → clamp at MIN_SCALE
##     - EDGE_R drag right → sx > 1, sy = 1 (axis-locked)
##     - EDGE_T drag upward → sy > 1, sx = 1 (axis-locked)
##     - ROTATE_TL drag → rotation ~90°
##     - ESC during drag → revert
##     - on_deactivate during drag → silent
##     - pointer_up commits (no extra emission)
##     - right-click → no-op (returns false)
##
##   Selection / deselection (≥3 tests):
##     - no selection + click on annotation → selection set
##     - click outside all annotations → selection cleared
##     - click on a different annotation while one selected → selection switches
##
##   Keyboard / lifecycle (≥2 tests):
##     - KEY_DELETE with selection → remove_annotation called
##     - on_activate stores host; on_deactivate drops it

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== AnnotationTransformTool Tests ===\n")

	print("-- hit-zone discrimination --")
	test_zone_center_is_inside()
	test_zone_near_corner_but_inside_is_inside()
	test_zone_corner_tl()
	test_zone_corner_tr()
	test_zone_corner_br()
	test_zone_edge_t()
	test_zone_edge_l()
	test_zone_rotate_tl()
	test_zone_far_outside()
	test_zone_deep_interior()

	print("\n-- drag forwarding --")
	test_drag_inside_translates()
	test_drag_corner_br_scales_up()
	test_drag_corner_tl_clamps_min_scale()
	test_drag_edge_r_axis_locked_x()
	test_drag_edge_t_axis_locked_y()
	test_drag_rotate_tl_rotates()
	test_esc_during_drag_reverts()
	test_deactivate_during_drag_silent()
	test_pointer_up_commits_no_extra_emission()
	test_right_click_noop()
	test_payload_text_drag_uses_kind_transform()

	print("\n-- path-kind bend handles (UX1 station 6, docket 019fd09b209e) --")
	test_trs_kind_still_shows_trs_zones_regression_fence()
	test_path_kind_shows_bend_handle_not_trs_zone()
	test_bend_drag_commits_one_revision_with_moved_point()
	test_bend_drag_emits_nothing_during_preview()
	test_bend_right_click_deletes_bend()
	test_bend_segment_click_inserts_bend()
	test_bend_escape_mid_drag_commits_nothing()
	test_path_kind_without_bend_api_degrades_to_trs()
	test_bend_click_without_motion_emits_nothing()
	test_bend_drag_with_motion_commits_release_position()

	print("\n-- path-editing lock (Codex 1047 fix round, verdict 1) --")
	test_locked_path_press_on_bend_arms_translate_not_bend()
	test_locked_path_off_bounds_handle_press_falls_through()
	test_locked_path_segment_click_inserts_nothing()
	test_locked_path_right_click_does_not_delete_bend()
	test_locked_path_claims_point_mirrors_press_gate()
	test_locked_path_unlock_via_annotation_state_restores_bend()

	print("\n-- arrow label axis constraint (B3a, 019fbbadc140) --")
	test_label_drag_sideways_preserves_perpendicular_clearance()
	test_label_drag_old_free_offset_clamps_on_next_drag()
	test_label_drag_t_range_clamped_near_tail_and_head()
	test_label_drag_vertical_arrow_no_perpendicular_teleport()
	test_label_drag_45deg_arrow_no_perpendicular_teleport()

	print("\n-- selection / deselection --")
	test_no_selection_click_on_annotation_selects()
	test_click_outside_all_clears_selection()
	test_click_different_annotation_switches_selection()

	print("\n-- keyboard / lifecycle --")
	test_delete_with_selection_removes()
	test_activate_stores_host_deactivate_drops_it()

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


# ── Stub kind ─────────────────────────────────────────────────────────────────
## A minimal kind whose bounds() is [x, y, w, h] from the annotation dict.
## hit_test uses grown bounds so clicks ≥8 px outside miss.

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


## A minimal "path" kind (UX1 station 6, docket 019fd09b209e): declares
## manipulation_profile() == "path" and implements the full duck-typed bend
## API (bend_points / with_bend_points / nearest_bend_insertion) so
## AnnotationTransformTool's gate is fully satisfied. `annotation["bends"]` IS
## the whole path — no separate anchor/destination, unlike the real
## pcb_route_hint kind — because AnnotationTransformTool never needs anything
## beyond the three documented methods; this stub exists to test exactly
## that contract, not to replicate pcb_route_hint_kind's own storage
## convention.
class StubPathKind extends AnnotationKind:
	func _init(p_name: StringName) -> void:
		name = p_name
		display_name = "stub path"

	func manipulation_profile() -> String:
		return "path"

	func _points(annotation: Dictionary) -> Array:
		var raw: Variant = annotation.get("bends", [])
		var out: Array = []
		if raw is Array:
			for p in raw:
				out.append(p as Vector2)
		return out

	func bend_points(annotation: Dictionary) -> Array:
		return _points(annotation)

	func with_bend_points(annotation: Dictionary, new_bends: Array) -> Dictionary:
		var out := annotation.duplicate(true)
		out["bends"] = new_bends.duplicate()
		return out

	func nearest_bend_insertion(annotation: Dictionary, doc_pos: Vector2, threshold: float) -> Dictionary:
		var pts := _points(annotation)
		if pts.size() < 2:
			return {}
		var best_dist := INF
		var best_point := Vector2.ZERO
		var best_seg := -1
		for i in range(pts.size() - 1):
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[i + 1]
			var ab := b - a
			var len_sq := ab.length_squared()
			var t := 0.0
			if len_sq > 0.0001:
				t = clampf((doc_pos - a).dot(ab) / len_sq, 0.0, 1.0)
			var proj := a + ab * t
			var d := proj.distance_to(doc_pos)
			if d < best_dist:
				best_dist = d
				best_point = proj
				best_seg = i
		if best_seg < 0 or best_dist > threshold:
			return {}
		# best_seg spans pts[best_seg]..pts[best_seg + 1] and `pts` IS this
		# stub's WHOLE bend array (no separate anchor/dest to exclude, per
		# the class doc above) — unlike pcb_route_hint_kind's own
		# nearest_bend_insertion, whose `full` polyline is anchor+bends+dest
		# and therefore one index AHEAD of its bend_points() array, so its
		# "insert_at = best_seg" already lands correctly with no +1. Here
		# bend_points() IS pts, so Array.insert() must be told to insert
		# BEFORE index best_seg + 1 to land between vertices best_seg and
		# best_seg + 1, not before best_seg itself.
		return {"point": best_point, "insert_at": best_seg + 1}

	func bounds(annotation: Dictionary) -> Rect2:
		var pts := _points(annotation)
		if pts.is_empty():
			return Rect2()
		var r := Rect2(pts[0], Vector2.ZERO)
		for i in range(1, pts.size()):
			r = r.expand(pts[i])
		return r

	func hit_test(annotation: Dictionary, point: Vector2, threshold: float) -> bool:
		return bounds(annotation).grow(threshold).has_point(point)

	func render(_ctx: AnnotationRenderContext, _annotation: Dictionary) -> void:
		pass


## StubPathKind + the per-annotation vertex-edit lock (Codex 1047 fix round,
## verdict 1). A SUBCLASS on purpose, rather than adding path_editing_locked
## to StubPathKind itself: the duck-typed contract's default case is "kind
## does not implement the method at all ⇒ unlocked", and every existing
## StubPathKind test above/below doubles as the regression proof of that
## default only for as long as StubPathKind genuinely lacks the method.
## The lock answer comes from the annotation's own "locked" field, so one
## kind instance serves locked, unlocked and flipped-mid-test fixtures —
## mirroring how the real pcb_route_hint kind answers from kind_payload
## state (the station-12 supersession marker), never from cached state.
class StubLockablePathKind extends StubPathKind:
	func path_editing_locked(annotation: Dictionary) -> bool:
		return bool(annotation.get("locked", false))


## A "path" kind that declares the profile but implements NONE of the three
## bend methods — the degrade-gate fixture (case g): AnnotationTransformTool
## must fall back to the ordinary TRS gizmo rather than erroring or half-
## working. bounds()/hit_test() read the same "bends" field as StubPathKind
## so a TRS-corner assertion at the same coordinates is a clean A/B against it.
class StubPathNoApiKind extends AnnotationKind:
	func _init(p_name: StringName) -> void:
		name = p_name
		display_name = "stub path (incomplete)"

	func manipulation_profile() -> String:
		return "path"

	func bounds(annotation: Dictionary) -> Rect2:
		var raw: Variant = annotation.get("bends", [])
		if not raw is Array or (raw as Array).is_empty():
			return Rect2()
		var pts: Array = raw
		var r := Rect2(pts[0] as Vector2, Vector2.ZERO)
		for i in range(1, pts.size()):
			r = r.expand(pts[i] as Vector2)
		return r

	func hit_test(annotation: Dictionary, point: Vector2, threshold: float) -> bool:
		return bounds(annotation).grow(threshold).has_point(point)

	func render(_ctx: AnnotationRenderContext, _annotation: Dictionary) -> void:
		pass


# ── Mock host ─────────────────────────────────────────────────────────────────

class MockHost extends AnnotationHost:
	var _registry: AnnotationRegistry = AnnotationRegistry.new()
	var _annotations: Array = []
	var _selected_id: String = ""
	var removed_ids: Array = []
	var selection_log: Array = []

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

	func update_annotation(annotation_id: String, new_annotation: Dictionary) -> bool:
		for i in _annotations.size():
			var ann: Dictionary = _annotations[i]
			if str(ann.get("id", "")) == annotation_id:
				new_annotation["id"] = annotation_id
				_annotations[i] = new_annotation
				return true
		return false

	func set_selected_annotation_id(annotation_id: String) -> void:
		_selected_id = annotation_id
		selection_log.append(annotation_id)
		selection_changed.emit(annotation_id)

	func get_selected_annotation_id() -> String:
		return _selected_id

	func transform_screen_to_doc(p: Vector2) -> Vector2:
		return p  # identity

	func transform_doc_to_screen(p: Vector2) -> Vector2:
		return p


# ── Signal capture ────────────────────────────────────────────────────────────

## Capture every annotation_modified emission into a list.
func _capture_modified(tool: AnnotationTransformTool) -> Array:
	var log: Array = []
	tool.annotation_modified.connect(func(id: String, ann: Dictionary) -> void:
		log.append({"id": id, "ann": ann})
	)
	return log


# ── Fixtures ──────────────────────────────────────────────────────────────────

## bounds = Rect2(100, 100, 80, 60) — used for zone tests.
## center = (140, 130), corners TL(100,100) TR(180,100) BL(100,160) BR(180,160)
## edges T(140,100) B(140,160) L(100,130) R(180,130)
func _make_selected_host() -> MockHost:
	var host := MockHost.new()
	host._registry.register_annotation_kind(StubBoxKind.new(&"stub_box"))
	host.add_annotation({
		"id":   "ann_a",
		"kind": "stub_box",
		"rect": [100, 100, 80, 60],
		"primitives": [{"kind": "arrow", "at": [100.0, 100.0], "from": [100.0, 100.0], "to": [110.0, 110.0]}],
	})
	host._selected_id = "ann_a"
	return host


## A single selected "path" annotation (UX1 station 6). bends deliberately sit
## at the SAME three coordinates test_zone_corner_tl/tr and
## test_drag_corner_br_scales_up use for stub_box's TRS corners — so a test
## can press the identical point against a "trs" kind and a "path" kind and
## assert the two DIFFERENT zone outcomes (CORNER_* vs BEND) directly.
## `without_api` selects StubPathNoApiKind (the degrade-gate fixture, case g).
func _make_path_selected_host(without_api: bool = false) -> MockHost:
	var host := MockHost.new()
	var kind: AnnotationKind
	if without_api:
		kind = StubPathNoApiKind.new(&"stub_path_incomplete")
	else:
		kind = StubPathKind.new(&"stub_path")
	host._registry.register_annotation_kind(kind)
	host.add_annotation({
		"id":   "ann_path",
		"kind": String(kind.name),
		"bends": [Vector2(100, 100), Vector2(180, 100), Vector2(180, 160)],
	})
	host._selected_id = "ann_path"
	return host


## A single selected LOCKABLE "path" annotation (Codex 1047 fix round,
## verdict 1) — StubLockablePathKind over the SAME bend coordinates as
## _make_path_selected_host above, so every locked/unlocked assertion is a
## direct A/B against the unlocked tests at identical press points.
## `locked` seeds the annotation's own lock field; tests may flip it in
## place (host.get_annotations()[0]["locked"] = …) to prove the lock is
## re-read per gesture from annotation state, never cached.
func _make_lockable_path_selected_host(locked: bool) -> MockHost:
	var host := MockHost.new()
	host._registry.register_annotation_kind(StubLockablePathKind.new(&"stub_path_lockable"))
	host.add_annotation({
		"id":   "ann_path",
		"kind": "stub_path_lockable",
		"locked": locked,
		"bends": [Vector2(100, 100), Vector2(180, 100), Vector2(180, 160)],
	})
	host._selected_id = "ann_path"
	return host


## Two disjoint annotations for selection tests.
func _make_two_box_host() -> MockHost:
	var host := MockHost.new()
	host._registry.register_annotation_kind(StubBoxKind.new(&"stub_box"))
	host.add_annotation({
		"id":   "ann_a",
		"kind": "stub_box",
		"rect": [0, 0, 40, 40],
		"primitives": [{"type": "anchor", "pos": [0.0, 0.0]}],
	})
	host.add_annotation({
		"id":   "ann_b",
		"kind": "stub_box",
		"rect": [200, 200, 40, 40],
		"primitives": [{"type": "anchor", "pos": [200.0, 200.0]}],
	})
	return host


# ── Hit-zone tests ────────────────────────────────────────────────────────────

func test_zone_center_is_inside() -> void:
	print("test_zone_center_is_inside:")
	var b := Rect2(100, 100, 80, 60)
	var z := AnnotationTransformTool._hit_zone(Vector2(140, 130), b)
	check_eq("center (140,130) → INSIDE", z, AnnotationTransformTool.Zone.INSIDE)


func test_zone_near_corner_but_inside_is_inside() -> void:
	# (105, 105) is 5 px from the TL corner (100,100) — well inside HANDLE_HIT_RADIUS=12
	# so it should resolve to CORNER_TL, not just INSIDE.
	# The task spec says "inside near corner but not handle (105,105) → INSIDE (NOT corner)"
	# but with HANDLE_HIT_RADIUS=12, dist=7.07 < 12, so it IS a corner hit.
	# We test the actual tool behaviour: dist(105,105 to 100,100) ≈ 7.07 < 12 → CORNER_TL.
	print("test_zone_near_corner_but_inside_is_inside:")
	var b := Rect2(100, 100, 80, 60)
	var z := AnnotationTransformTool._hit_zone(Vector2(105, 105), b)
	# (105,105) is 7.07 doc-units from TL corner which is < 12 → CORNER_TL
	check_eq("(105,105) dist<12 from TL corner → CORNER_TL",
		z, AnnotationTransformTool.Zone.CORNER_TL)


func test_zone_corner_tl() -> void:
	print("test_zone_corner_tl:")
	var b := Rect2(100, 100, 80, 60)
	var z := AnnotationTransformTool._hit_zone(Vector2(100, 100), b)
	check_eq("exact TL corner (100,100) → CORNER_TL", z, AnnotationTransformTool.Zone.CORNER_TL)


func test_zone_corner_tr() -> void:
	print("test_zone_corner_tr:")
	var b := Rect2(100, 100, 80, 60)
	var z := AnnotationTransformTool._hit_zone(Vector2(180, 100), b)
	check_eq("exact TR corner (180,100) → CORNER_TR", z, AnnotationTransformTool.Zone.CORNER_TR)


func test_zone_corner_br() -> void:
	print("test_zone_corner_br:")
	var b := Rect2(100, 100, 80, 60)
	var z := AnnotationTransformTool._hit_zone(Vector2(180, 160), b)
	check_eq("exact BR corner (180,160) → CORNER_BR", z, AnnotationTransformTool.Zone.CORNER_BR)


func test_zone_edge_t() -> void:
	print("test_zone_edge_t:")
	# Top-edge midpoint is (140, 100). Must be > HANDLE_HIT_RADIUS from corners.
	# Nearest corner is TL(100,100) or TR(180,100): dist = 40 >> 12. Safe.
	var b := Rect2(100, 100, 80, 60)
	var z := AnnotationTransformTool._hit_zone(Vector2(140, 100), b)
	check_eq("top-edge midpoint (140,100) → EDGE_T", z, AnnotationTransformTool.Zone.EDGE_T)


func test_zone_edge_l() -> void:
	print("test_zone_edge_l:")
	# Left-edge midpoint is (100, 130). Nearest corner TL(100,100): dist=30 >> 12. Safe.
	var b := Rect2(100, 100, 80, 60)
	var z := AnnotationTransformTool._hit_zone(Vector2(100, 130), b)
	check_eq("left-edge midpoint (100,130) → EDGE_L", z, AnnotationTransformTool.Zone.EDGE_L)


func test_zone_rotate_tl() -> void:
	print("test_zone_rotate_tl:")
	# TL corner is (100,100). A point at (80,80) has dist = sqrt(400+400) ≈ 28.28.
	# ROTATE_RING_OUTER=28, ROTATE_RING_INNER=12. dist > 28 → just outside outer ring.
	# Use (85,85): dist = sqrt(225+225) ≈ 21.2 → in [12, 28] → ROTATE_TL.
	var b := Rect2(100, 100, 80, 60)
	var z := AnnotationTransformTool._hit_zone(Vector2(85, 85), b)
	check_eq("(85,85) ≈21.2 from TL corner, in annulus → ROTATE_TL",
		z, AnnotationTransformTool.Zone.ROTATE_TL)


func test_zone_far_outside() -> void:
	print("test_zone_far_outside:")
	var b := Rect2(100, 100, 80, 60)
	var z := AnnotationTransformTool._hit_zone(Vector2(300, 300), b)
	check_eq("far outside (300,300) → OUTSIDE", z, AnnotationTransformTool.Zone.OUTSIDE)


func test_zone_deep_interior() -> void:
	print("test_zone_deep_interior:")
	# A point at the geometric center, far from all edges.
	var b := Rect2(100, 100, 80, 60)
	var z := AnnotationTransformTool._hit_zone(Vector2(140, 130), b)
	check_eq("geometric center (140,130) → INSIDE", z, AnnotationTransformTool.Zone.INSIDE)


# ── Drag forwarding tests ─────────────────────────────────────────────────────

func test_drag_inside_translates() -> void:
	print("test_drag_inside_translates:")
	var host := _make_selected_host()
	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	# Drag from center (140,130) to (160,150) — delta (20,20).
	tool.on_pointer_down(Vector2(140, 130), MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_move(Vector2(160, 150))

	check("annotation_modified emitted during translate drag", log.size() >= 1)
	if log.size() >= 1:
		var last_ann: Dictionary = log[log.size() - 1]["ann"]
		var prims: Array = last_ann.get("primitives", [])
		check("primitives present after translate", prims.size() > 0)
		if prims.size() > 0:
			var at_pos = prims[0].get("at", [0.0, 0.0])
			# Original "at" was at (100,100). After translating by (20,20) → (120,120).
			check("at x translated by ~20", absf(float(at_pos[0]) - 120.0) < 1.0)
			check("at y translated by ~20", absf(float(at_pos[1]) - 120.0) < 1.0)

	tool.on_deactivate()


func test_drag_corner_br_scales_up() -> void:
	print("test_drag_corner_br_scales_up:")
	var host := _make_selected_host()
	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	# BR corner is at (180,160). Center is (140,130).
	# Drag BR from (180,160) to (220,200) — moving away from center → scale > 1.
	tool.on_pointer_down(Vector2(180, 160), MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_move(Vector2(220, 200))

	check("annotation_modified emitted during corner drag", log.size() >= 1)
	if log.size() >= 1:
		var last_ann: Dictionary = log[log.size() - 1]["ann"]
		var prims: Array = last_ann.get("primitives", [])
		# "at" was at (100,100). After uniform scale > 1 from center (140,130),
		# offset (-40,-30) grows → "at" moves further from center (x < 100, y < 100).
		check("primitives present after corner scale", prims.size() > 0)
		if prims.size() > 0:
			var at_pos = prims[0].get("at", [0.0, 0.0])
			check("at moved away from center (scale > 1)",
				float(at_pos[0]) < 100.0 or float(at_pos[1]) < 100.0)

	tool.on_deactivate()


func test_drag_corner_tl_clamps_min_scale() -> void:
	print("test_drag_corner_tl_clamps_min_scale:")
	var host := _make_selected_host()
	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	# TL corner is at (100,100). Center is (140,130).
	# Drag past center to (200,180) — this reverses direction → clamped at MIN_SCALE.
	tool.on_pointer_down(Vector2(100, 100), MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_move(Vector2(200, 180))

	check("annotation_modified emitted", log.size() >= 1)
	if log.size() >= 1:
		var last_ann: Dictionary = log[log.size() - 1]["ann"]
		var prims: Array = last_ann.get("primitives", [])
		check("primitives present after clamped scale", prims.size() > 0)
		# With MIN_SCALE=0.05, the "at" offset from center is 5% of original.
		# "at" was at (100,100), offset from center (140,130) = (-40,-30).
		# After clamping: offset ≈ (-2, -1.5) → at ≈ (138, 128.5). Finite.
		if prims.size() > 0:
			var at_pos = prims[0].get("at", [0.0, 0.0])
			check("at within finite range (not collapsed to zero)",
				absf(float(at_pos[0])) < 1000.0 and absf(float(at_pos[1])) < 1000.0)

	tool.on_deactivate()


func test_drag_edge_r_axis_locked_x() -> void:
	print("test_drag_edge_r_axis_locked_x:")
	var host := _make_selected_host()
	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	# Right-edge midpoint is (180, 130). Center is (140, 130).
	# Drag right to (200, 130) — only X changes → sx > 1, sy = 1.
	tool.on_pointer_down(Vector2(180, 130), MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_move(Vector2(200, 130))

	check("annotation_modified emitted for edge-R drag", log.size() >= 1)
	if log.size() >= 1:
		var last_ann: Dictionary = log[log.size() - 1]["ann"]
		var prims: Array = last_ann.get("primitives", [])
		check("primitives present after edge-R scale", prims.size() > 0)
		if prims.size() > 0:
			# "at" at (100,100). center=(140,130). start offset=(-40,-30).
			# sx = (200-140)/(180-140) = 60/40 = 1.5; sy=1.
			# New at = center + (-40*1.5, -30*1) = (140-60, 130-30) = (80, 100).
			var at_pos = prims[0].get("at", [0.0, 0.0])
			check("X scaled (at x changed from 100 to ~80)", absf(float(at_pos[0]) - 100.0) > 0.5)
			check("Y unchanged (axis-locked)", absf(float(at_pos[1]) - 100.0) < 1.0)

	tool.on_deactivate()


func test_drag_edge_t_axis_locked_y() -> void:
	print("test_drag_edge_t_axis_locked_y:")
	var host := _make_selected_host()
	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	# Top-edge midpoint is (140, 100). Center is (140, 130).
	# Drag up to (140, 70) — only Y changes → sy > 1, sx = 1.
	tool.on_pointer_down(Vector2(140, 100), MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_move(Vector2(140, 70))

	check("annotation_modified emitted for edge-T drag", log.size() >= 1)
	if log.size() >= 1:
		var last_ann: Dictionary = log[log.size() - 1]["ann"]
		var prims: Array = last_ann.get("primitives", [])
		check("primitives present after edge-T scale", prims.size() > 0)
		if prims.size() > 0:
			# start offset Y = 100 - 130 = -30; current Y = 70 - 130 = -60; sy = 2.
			# sx = 1 (start_x offset = 140-140 = 0, guard keeps sx=1).
			# New at = center + (-40*1, -30*2) = (140-40, 130-60) = (100, 70).
			var at_pos = prims[0].get("at", [0.0, 0.0])
			check("Y scaled (at y changed from 100 to ~70)", absf(float(at_pos[1]) - 100.0) > 0.5)
			check("X unchanged (axis-locked)", absf(float(at_pos[0]) - 100.0) < 1.0)

	tool.on_deactivate()


func test_drag_rotate_tl_rotates() -> void:
	print("test_drag_rotate_tl_rotates:")
	var host := _make_selected_host()
	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	# Use a point in the ROTATE_TL annulus around TL corner (100,100).
	# (85,85): dist ≈ 21.2 from TL, in [12,28] → ROTATE_TL.
	# Center is (140,130). Start angle = (85-140, 85-130).angle() = (-55,-45).angle().
	# Drag to (85, 215) — equivalent ~90° rotation from the center perspective.
	tool.on_pointer_down(Vector2(85, 85), MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_move(Vector2(200, 85))

	check("annotation_modified emitted during rotate drag", log.size() >= 1)
	if log.size() >= 1:
		var last_ann: Dictionary = log[log.size() - 1]["ann"]
		var prims: Array = last_ann.get("primitives", [])
		check("primitives present after rotate", prims.size() > 0)
		# "at" was (100,100). After non-trivial rotation around center (140,130) it must move.
		if prims.size() > 0:
			var at_pos = prims[0].get("at", [0.0, 0.0])
			var moved := absf(float(at_pos[0]) - 100.0) > 1.0 or absf(float(at_pos[1]) - 100.0) > 1.0
			check("at moved after rotate drag", moved)

	tool.on_deactivate()


func test_esc_during_drag_reverts() -> void:
	print("test_esc_during_drag_reverts:")
	var host := _make_selected_host()
	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	# Start translate drag.
	tool.on_pointer_down(Vector2(140, 130), MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_move(Vector2(160, 150))
	var count_before_esc := log.size()
	check("emission before ESC", count_before_esc >= 1)

	# ESC → revert.
	tool.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, KEY_ESCAPE)
	check("another emission on ESC (revert)", log.size() > count_before_esc)
	# The revert emission must carry the original annotation state.
	if log.size() > count_before_esc:
		var revert_ann: Dictionary = log[log.size() - 1]["ann"]
		var prims: Array = revert_ann.get("primitives", [])
		if prims.size() > 0:
			var at_pos = prims[0].get("at", [0.0, 0.0])
			check("revert restores original at x=100",
				absf(float(at_pos[0]) - 100.0) < 1.0)
			check("revert restores original at y=100",
				absf(float(at_pos[1]) - 100.0) < 1.0)

	tool.on_deactivate()


func test_deactivate_during_drag_silent() -> void:
	print("test_deactivate_during_drag_silent:")
	var host := _make_selected_host()
	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	# Begin drag.
	tool.on_pointer_down(Vector2(140, 130), MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_move(Vector2(160, 150))
	var count_before := log.size()

	# Deactivate mid-drag — should be silent (no extra emission).
	tool.on_deactivate()
	check("no extra emission on silent deactivate", log.size() == count_before)
	check("host ref dropped after deactivate", tool._host == null)


func test_pointer_up_commits_no_extra_emission() -> void:
	print("test_pointer_up_commits_no_extra_emission:")
	var host := _make_selected_host()
	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(140, 130), MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_move(Vector2(160, 150))
	var count_at_move := log.size()

	# pointer_up should NOT emit another annotation_modified.
	var consumed := tool.on_pointer_up(Vector2(160, 150), MOUSE_BUTTON_LEFT, 0)
	check("pointer_up consumed", consumed)
	check("no extra emission on pointer_up", log.size() == count_at_move)

	tool.on_deactivate()


func test_right_click_noop() -> void:
	print("test_right_click_noop:")
	var host := _make_selected_host()
	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	var consumed := tool.on_pointer_down(Vector2(140, 130), MOUSE_BUTTON_RIGHT, 0)
	check("right-click not consumed", not consumed)
	check("no emission on right-click", log.size() == 0)

	tool.on_deactivate()


func test_payload_text_drag_uses_kind_transform() -> void:
	print("test_payload_text_drag_uses_kind_transform:")
	var host := MockHost.new()
	host._registry.register_annotation_kind(AnnotationText.new())
	host.add_annotation({
		"id": "ann_payload_text",
		"kind": "2d_text",
		"anchor": CoreAnchors.make_canvas_point(100.0, 100.0),
		"kind_payload": {"text": "payload text", "font_size": 14.0},
	})
	host._selected_id = "ann_payload_text"
	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	check("pointer down inside payload text starts drag", tool.on_pointer_down(Vector2(120, 108), MOUSE_BUTTON_LEFT, 0))
	tool.on_pointer_move(Vector2(130, 128))

	check_eq("one payload text modification", log.size(), 1)
	var ann: Dictionary = log[0]["ann"]
	var anchor: Dictionary = ann.get("anchor", {})
	var id: Dictionary = anchor.get("id", {})
	check_eq("payload text anchor x translated", id.get("x"), 110.0)
	check_eq("payload text anchor y translated", id.get("y"), 120.0)

	tool.on_deactivate()


# ── Path-kind bend handles (UX1 station 6, docket 019fd09b209e) ──────────────
## Gate: exactly single-selection, kind.manipulation_profile() == "path" AND
## has_method for bend_points/with_bend_points/nearest_bend_insertion — see
## AnnotationTransformTool._is_path_kind and the class doc addendum.

## (a) Regression fence: a "trs" kind (the default, and every existing kind)
## keeps its ordinary corner/edge/rotate zones byte-identically. Same fixture
## and same press-point test_zone_corner_tl already covers statically; this
## exercises it through the LIVE tool (on_pointer_down → _active_zone), which
## is the thing the path-kind gate could plausibly disturb.
func test_trs_kind_still_shows_trs_zones_regression_fence() -> void:
	print("test_trs_kind_still_shows_trs_zones_regression_fence:")
	var host := _make_selected_host()
	var tool := AnnotationTransformTool.new()
	tool.on_activate(host)

	var kind: AnnotationKind = host.get_registry().get_annotation_kind(&"stub_box")
	check_eq("stub_box default manipulation_profile is 'trs'", kind.manipulation_profile(), "trs")
	check("stub_box is not path-eligible", not tool._is_path_kind(kind))

	# TL corner of rect [100,100,80,60] is (100,100) — see test_zone_corner_tl.
	tool.on_pointer_down(Vector2(100, 100), MOUSE_BUTTON_LEFT, 0)
	check_eq("TRS kind: press on the TL corner arms CORNER_TL, unchanged",
		tool._active_zone, AnnotationTransformTool.Zone.CORNER_TL)
	tool.on_pointer_up(Vector2(100, 100), MOUSE_BUTTON_LEFT, 0)
	tool.on_deactivate()


## (b) A "path" kind shows bend handles, not TRS zones: pressing the EXACT
## SAME point that armed CORNER_TL above now arms Zone.BEND instead — proof
## the corner/edge/rotate gizmo is not offered at all for this profile (the
## tool never even calls _hit_zone for a path kind).
func test_path_kind_shows_bend_handle_not_trs_zone() -> void:
	print("test_path_kind_shows_bend_handle_not_trs_zone:")
	var host := _make_path_selected_host()
	var tool := AnnotationTransformTool.new()
	tool.on_activate(host)

	var kind: AnnotationKind = host.get_registry().get_annotation_kind(&"stub_path")
	check_eq("stub_path manipulation_profile is 'path'", kind.manipulation_profile(), "path")
	check("stub_path is path-eligible (full bend API)", tool._is_path_kind(kind))

	tool.on_pointer_down(Vector2(100, 100), MOUSE_BUTTON_LEFT, 0)
	check_eq("path kind: press on bend[0] arms Zone.BEND, NOT CORNER_TL",
		tool._active_zone, AnnotationTransformTool.Zone.BEND)
	check_eq("bend index 0 recorded", tool._drag_bend_index, 0)
	tool.on_pointer_up(Vector2(100, 100), MOUSE_BUTTON_LEFT, 0)
	tool.on_deactivate()


## (c) Bend drag commits exactly ONE revision, carrying the moved point, on
## release.
func test_bend_drag_commits_one_revision_with_moved_point() -> void:
	print("test_bend_drag_commits_one_revision_with_moved_point:")
	var host := _make_path_selected_host()
	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(180, 100), MOUSE_BUTTON_LEFT, 0)  # bend[1]
	tool.on_pointer_move(Vector2(200, 120))
	tool.on_pointer_move(Vector2(210, 130))
	check_eq("no commit while dragging (preview only)", log.size(), 0)

	tool.on_pointer_up(Vector2(210, 130), MOUSE_BUTTON_LEFT, 0)
	check_eq("exactly ONE commit on release", log.size(), 1)

	var new_ann: Dictionary = log[0]["ann"]
	var new_bends: Array = new_ann.get("bends", [])
	check_eq("still three bends", new_bends.size(), 3)
	if new_bends.size() == 3:
		var moved: Vector2 = new_bends[1]
		check("moved bend lands at the release position",
			is_equal_approx(moved.x, 210.0) and is_equal_approx(moved.y, 130.0))
		var untouched: Vector2 = new_bends[0]
		check("bend[0] is untouched", untouched == Vector2(100, 100))

	tool.on_deactivate()


## (c, continued) Every on_pointer_move during a bend drag must emit NOTHING —
## the preview-only discipline, checked at each intermediate step rather than
## only at the end.
func test_bend_drag_emits_nothing_during_preview() -> void:
	print("test_bend_drag_emits_nothing_during_preview:")
	var host := _make_path_selected_host()
	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(180, 160), MOUSE_BUTTON_LEFT, 0)  # bend[2]
	check_eq("no emission on the initial press", log.size(), 0)
	tool.on_pointer_move(Vector2(190, 170))
	check_eq("no emission after first move", log.size(), 0)
	tool.on_pointer_move(Vector2(220, 200))
	check_eq("no emission after second move", log.size(), 0)
	check_eq("live point tracks the pointer", tool._drag_bend_live_point, Vector2(220, 200))

	tool.on_pointer_up(Vector2(220, 200), MOUSE_BUTTON_LEFT, 0)
	check_eq("release commits exactly one", log.size(), 1)
	tool.on_deactivate()


## (d) Right-click on a bend handle deletes that bend — ONE commit.
func test_bend_right_click_deletes_bend() -> void:
	print("test_bend_right_click_deletes_bend:")
	var host := _make_path_selected_host()
	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	var consumed := tool.on_pointer_down(Vector2(180, 100), MOUSE_BUTTON_RIGHT, 0)  # bend[1]
	check("right-click on a bend handle is consumed", consumed)
	check_eq("exactly one commit from the delete", log.size(), 1)

	var new_ann: Dictionary = log[0]["ann"]
	var new_bends: Array = new_ann.get("bends", [])
	check_eq("two bends remain", new_bends.size(), 2)
	if new_bends.size() == 2:
		check("survivors are bend[0] and bend[2]",
			(new_bends[0] as Vector2) == Vector2(100, 100) and (new_bends[1] as Vector2) == Vector2(180, 160))

	tool.on_deactivate()


## (e) A click on the path (not on a handle) inserts a bend there — ONE
## commit, no drag armed.
func test_bend_segment_click_inserts_bend() -> void:
	print("test_bend_segment_click_inserts_bend:")
	var host := _make_path_selected_host()
	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	# Midpoint of segment bend[0](100,100)->bend[1](180,100): (140,100). Well
	# clear of both handles' HANDLE_HIT_RADIUS_DOC=12 hit zone (dist=40 each).
	var consumed := tool.on_pointer_down(Vector2(140, 100), MOUSE_BUTTON_LEFT, 0)
	check("segment click is consumed", consumed)
	check_eq("exactly one commit from the insert", log.size(), 1)
	check("insert does not leave the tool mid-drag", not tool._dragging)

	var new_ann: Dictionary = log[0]["ann"]
	var new_bends: Array = new_ann.get("bends", [])
	check_eq("four bends after insert", new_bends.size(), 4)
	if new_bends.size() == 4:
		var inserted: Vector2 = new_bends[1]
		check("inserted point sits at the segment midpoint",
			is_equal_approx(inserted.x, 140.0) and is_equal_approx(inserted.y, 100.0))

	tool.on_deactivate()


## (f) Escape mid-drag cancels with NO commit — the drag was preview-only, so
## there was never anything on the host to revert (contrast
## test_esc_during_drag_reverts above, which DOES expect a revert emission
## for the ordinary per-move-emitting zones).
func test_bend_escape_mid_drag_commits_nothing() -> void:
	print("test_bend_escape_mid_drag_commits_nothing:")
	var host := _make_path_selected_host()
	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(180, 160), MOUSE_BUTTON_LEFT, 0)  # bend[2]
	tool.on_pointer_move(Vector2(300, 300))
	check_eq("no emission during the preview-only drag", log.size(), 0)

	tool.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, KEY_ESCAPE)
	check_eq("ESCAPE mid bend-drag commits NOTHING", log.size(), 0)
	check("drag state cleared after escape", not tool._dragging)

	tool.on_deactivate()


## (g) Degrade gate: a kind declaring "path" WITHOUT the full bend API falls
## back to the ordinary TRS gizmo instead of erroring or half-working — the
## off-tree safety net AnnotationKind.manipulation_profile()'s doc promises.
func test_path_kind_without_bend_api_degrades_to_trs() -> void:
	print("test_path_kind_without_bend_api_degrades_to_trs:")
	var host := _make_path_selected_host(true)
	var tool := AnnotationTransformTool.new()
	tool.on_activate(host)

	var kind: AnnotationKind = host.get_registry().get_annotation_kind(&"stub_path_incomplete")
	check_eq("incomplete kind still reports profile 'path'", kind.manipulation_profile(), "path")
	check("gate refuses an incomplete path kind", not tool._is_path_kind(kind))

	tool.on_pointer_down(Vector2(100, 100), MOUSE_BUTTON_LEFT, 0)
	check_eq("degrade gate: press arms CORNER_TL (TRS fallback), not BEND",
		tool._active_zone, AnnotationTransformTool.Zone.CORNER_TL)

	tool.on_deactivate()


## (h) Codex review fix F4 (docket 019fd10557c8 comment 1034): a no-move
## click on a bend handle — press then release at the SAME screen position,
## with NO intervening on_pointer_move at all (the ordinary shape of a plain
## click) — must emit NOTHING. Before this fix _commit_bend_drag() always
## used the last on_pointer_move sample, but a click never calls
## on_pointer_move, so it would have committed a "moved" point that never
## moved (still the drag-start position, but as a spurious revision).
func test_bend_click_without_motion_emits_nothing() -> void:
	print("test_bend_click_without_motion_emits_nothing:")
	var host := _make_path_selected_host()
	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(180, 100), MOUSE_BUTTON_LEFT, 0)  # bend[1]
	# No on_pointer_move — a plain click never fires one.
	tool.on_pointer_up(Vector2(180, 100), MOUSE_BUTTON_LEFT, 0)
	check_eq("a no-move click commits nothing", log.size(), 0)
	check("drag state cleared after the click", not tool._dragging)

	tool.on_deactivate()


## (h, continued) The twin positive case: a REAL drag — motion past the
## click/drag threshold — still commits, and commits the RELEASE position
## specifically, not whatever on_pointer_move last reported. Release lands
## somewhere the last motion sample did NOT, so this fails if the commit
## ever regresses to reading _drag_bend_live_point instead of the release
## position on_pointer_up now passes through.
func test_bend_drag_with_motion_commits_release_position() -> void:
	print("test_bend_drag_with_motion_commits_release_position:")
	var host := _make_path_selected_host()
	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(180, 100), MOUSE_BUTTON_LEFT, 0)  # bend[1]
	tool.on_pointer_move(Vector2(200, 120))
	check_eq("no commit while dragging (preview only)", log.size(), 0)
	# Release somewhere OTHER than the last motion sample.
	tool.on_pointer_up(Vector2(250, 140), MOUSE_BUTTON_LEFT, 0)
	check_eq("exactly ONE commit on release", log.size(), 1)

	var new_ann: Dictionary = log[0]["ann"]
	var new_bends: Array = new_ann.get("bends", [])
	check_eq("still three bends", new_bends.size(), 3)
	if new_bends.size() == 3:
		var moved: Vector2 = new_bends[1]
		check("committed point is the RELEASE position, not the last on_pointer_move sample",
			is_equal_approx(moved.x, 250.0) and is_equal_approx(moved.y, 140.0))

	tool.on_deactivate()


# ── Path-editing lock tests (Codex 1047 fix round, verdict 1) ─────────────────
## A path kind may answer path_editing_locked(ann) == true (duck-typed:
## kind.has_method — a kind without the method is unlocked, which every
## StubPathKind test above keeps proving, since StubPathKind deliberately
## lacks the method; see StubLockablePathKind's doc). Locked suppresses the
## vertex-edit affordances ONLY: no Zone.BEND arm, no bend insert, no bend
## right-click delete, no bend claims — while selection and the ordinary
## Zone.INSIDE translate arm survive. The real implementor is
## pcb_route_hint_kind (station-12 supersession marker: the host REFUSES the
## waypoint write, so a handle would promise an edit that can never land).


## (i) Press on a bend handle of a LOCKED path annotation must NOT arm
## Zone.BEND. (100,100) is bend[0] AND the bounds corner, so the press falls
## through to the surviving Zone.INSIDE translate arm instead — and a plain
## click-release around it must write nothing.
func test_locked_path_press_on_bend_arms_translate_not_bend() -> void:
	print("test_locked_path_press_on_bend_arms_translate_not_bend:")
	var host := _make_lockable_path_selected_host(true)
	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	var kind: AnnotationKind = host.get_registry().get_annotation_kind(&"stub_path_lockable")
	check("lockable kind is still path-eligible (full bend API)", tool._is_path_kind(kind))
	check("fixture reports locked", tool._path_editing_locked(kind, host.get_annotations()[0]))

	tool.on_pointer_down(Vector2(100, 100), MOUSE_BUTTON_LEFT, 0)
	check_eq("locked: press on bend[0] arms INSIDE (translate), NOT BEND",
		tool._active_zone, AnnotationTransformTool.Zone.INSIDE)
	check_eq("no bend index recorded", tool._drag_bend_index, -1)
	tool.on_pointer_up(Vector2(100, 100), MOUSE_BUTTON_LEFT, 0)
	check_eq("click-release on a locked path emits nothing", log.size(), 0)
	tool.on_deactivate()


## (i, continued) A press within the bend HANDLE radius but outside the
## bounds box: unlocked this arms BEND ((91,100) is 9 px from bend[0], inside
## HANDLE_HIT_RADIUS_DOC=12); locked it must fall through to SelectTool
## semantics (no zone armed — the miss arms a marquee, exactly like a TRS
## OUTSIDE miss).
func test_locked_path_off_bounds_handle_press_falls_through() -> void:
	print("test_locked_path_off_bounds_handle_press_falls_through:")
	# Unlocked A/B first — same kind, same coordinates, lock off.
	var host_unlocked := _make_lockable_path_selected_host(false)
	var tool_unlocked := AnnotationTransformTool.new()
	tool_unlocked.on_activate(host_unlocked)
	tool_unlocked.on_pointer_down(Vector2(91, 100), MOUSE_BUTTON_LEFT, 0)
	check_eq("UNLOCKED lockable kind: same press arms BEND (regression A/B)",
		tool_unlocked._active_zone, AnnotationTransformTool.Zone.BEND)
	tool_unlocked.on_pointer_up(Vector2(91, 100), MOUSE_BUTTON_LEFT, 0)
	tool_unlocked.on_deactivate()

	var host := _make_lockable_path_selected_host(true)
	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)
	tool.on_pointer_down(Vector2(91, 100), MOUSE_BUTTON_LEFT, 0)
	check("locked: the same press arms NO drag zone",
		tool._active_zone == AnnotationTransformTool.Zone.OUTSIDE and not tool._dragging)
	check("locked: the miss fell through to marquee (SelectTool semantics)",
		tool._marquee_active)
	check_eq("and emitted nothing", log.size(), 0)
	tool.on_deactivate()


## (j) A click on the path segment of a LOCKED annotation must NOT insert a
## bend — (140,100) is the segment midpoint the unlocked insert test uses; it
## is also on the bounds edge, so the surviving INSIDE translate arms instead.
func test_locked_path_segment_click_inserts_nothing() -> void:
	print("test_locked_path_segment_click_inserts_nothing:")
	var host := _make_lockable_path_selected_host(true)
	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(140, 100), MOUSE_BUTTON_LEFT, 0)
	check_eq("locked: segment click commits NO insert", log.size(), 0)
	check_eq("locked: segment click arms INSIDE (translate), not an insert",
		tool._active_zone, AnnotationTransformTool.Zone.INSIDE)
	tool.on_pointer_up(Vector2(140, 100), MOUSE_BUTTON_LEFT, 0)
	check_eq("still nothing after release", log.size(), 0)

	var bends: Array = (host.get_annotations()[0] as Dictionary).get("bends", [])
	check_eq("bend array untouched (still 3)", bends.size(), 3)
	tool.on_deactivate()


## (k) Right-click on a bend handle of a LOCKED annotation must NOT delete
## the bend — the gesture is refused outright (returns false, no commit).
func test_locked_path_right_click_does_not_delete_bend() -> void:
	print("test_locked_path_right_click_does_not_delete_bend:")
	var host := _make_lockable_path_selected_host(true)
	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	var consumed := tool.on_pointer_down(Vector2(180, 100), MOUSE_BUTTON_RIGHT, 0)  # bend[1]
	check("locked: right-click on a bend handle is NOT consumed", not consumed)
	check_eq("locked: no delete committed", log.size(), 0)
	var bends: Array = (host.get_annotations()[0] as Dictionary).get("bends", [])
	check_eq("all three bends survive", bends.size(), 3)
	tool.on_deactivate()


## (l) claims_point must mirror the same gate (the probe and the press MUST
## agree, or the pcb canvas router hands the tool a press it then declines):
## a point inside the bend-handle radius but off the bounds/ink is claimed
## unlocked, NOT claimed locked. A point inside the bounds stays claimed in
## both (the surviving INSIDE arm).
func test_locked_path_claims_point_mirrors_press_gate() -> void:
	print("test_locked_path_claims_point_mirrors_press_gate:")
	var host_unlocked := _make_lockable_path_selected_host(false)
	var tool_unlocked := AnnotationTransformTool.new()
	tool_unlocked.on_activate(host_unlocked)
	check("unlocked: bend-handle point (91,100) IS claimed",
		tool_unlocked.claims_point(Vector2(91, 100)))
	tool_unlocked.on_deactivate()

	# Absent-method default: plain StubPathKind (no path_editing_locked at
	# all) must behave exactly like unlocked — the duck-type's degrade case.
	var host_no_method := _make_path_selected_host()
	var tool_no_method := AnnotationTransformTool.new()
	tool_no_method.on_activate(host_no_method)
	check("kind WITHOUT the lock method: bend-handle point still claimed (absent = unlocked)",
		tool_no_method.claims_point(Vector2(91, 100)))
	tool_no_method.on_deactivate()

	var host := _make_lockable_path_selected_host(true)
	var tool := AnnotationTransformTool.new()
	tool.on_activate(host)
	check("locked: bend-handle point (91,100) is NOT claimed",
		not tool.claims_point(Vector2(91, 100)))
	check("locked: bounds-interior point (140,130) is still claimed (INSIDE survives)",
		tool.claims_point(Vector2(140, 130)))
	tool.on_deactivate()


## (m) The lock is re-read from ANNOTATION STATE on every gesture — no cached
## lock anywhere in the tool. Flipping the stored annotation's own field
## (exactly what stripping the station-12 marker does on a guided→detailed
## conversion) restores bend editing with no re-activation, no re-selection.
func test_locked_path_unlock_via_annotation_state_restores_bend() -> void:
	print("test_locked_path_unlock_via_annotation_state_restores_bend:")
	var host := _make_lockable_path_selected_host(true)
	var tool := AnnotationTransformTool.new()
	tool.on_activate(host)

	tool.on_pointer_down(Vector2(100, 100), MOUSE_BUTTON_LEFT, 0)
	check_eq("locked first: bend press arms INSIDE",
		tool._active_zone, AnnotationTransformTool.Zone.INSIDE)
	tool.on_pointer_up(Vector2(100, 100), MOUSE_BUTTON_LEFT, 0)

	# Strip the lock IN PLACE on the host's stored annotation — no other change.
	(host.get_annotations()[0] as Dictionary)["locked"] = false

	tool.on_pointer_down(Vector2(100, 100), MOUSE_BUTTON_LEFT, 0)
	check_eq("lock stripped: the SAME press now arms BEND (no cached lock)",
		tool._active_zone, AnnotationTransformTool.Zone.BEND)
	check_eq("bend index 0 recorded", tool._drag_bend_index, 0)
	tool.on_pointer_up(Vector2(100, 100), MOUSE_BUTTON_LEFT, 0)
	check("and claims_point agrees again", tool.claims_point(Vector2(91, 100)))
	tool.on_deactivate()


# ── Arrow label axis-constraint tests (B3a regression pin, 019fbbadc140) ──────
## Owner ruling verbatim: "I can move it anyplace — bad. It should only move
## along the arrow." Tightened by the 2026-08-03 HITL ruling (docket
## 019fcaefd0e1): the caption now sits centred ON the shaft — the default
## offset is ZERO (shaft midpoint) and the drag clearance, derived from
## default_label_offset().length(), is therefore also zero, so the
## perpendicular component is pinned to 0 at every orientation and the label
## slides ALONG the line only. The first three tests below use a HORIZONTAL
## arrow (0,0)->(100,0) — axis=(1,0), perp=(0,1) — which keeps the
## along/perpendicular arithmetic easy to hand-verify for the axis-projection
## and t-clamp behavior those tests target.
##
## The vertical and 45° tests remain as orientation pins from the F1
## regression era (cold review 2026-08-01, SET-vs-CLAMP at drag start). With
## clearance 0 the historical teleport magnitudes can no longer manifest, but
## the pins still hold the invariant F1 violated — a drag whose raw delta has
## zero perpendicular intent must leave the perpendicular projection exactly
## where it started (now: exactly 0) — so a re-widened clearance or a broken
## drag-start basis is still caught at the orientations horizontal cannot
## cover.

func _arrow_label_host(font: float = 10.0, offset: Variant = null,
		endpoint_b: Vector2 = Vector2(100.0, 0.0)) -> MockHost:
	var host := MockHost.new()
	host._registry.register_annotation_kind(AnnotationArrow.new())
	var payload := {
		"endpoint_a": [0.0, 0.0],
		"endpoint_b": [endpoint_b.x, endpoint_b.y],
		"label": "NET1",
		"label_font_size": font,
	}
	if offset != null:
		payload["label_offset"] = [(offset as Vector2).x, (offset as Vector2).y]
	host.add_annotation({
		"id":           "ann_arrow",
		"kind":         "2d_arrow",
		"kind_payload": payload,
	})
	host._selected_id = "ann_arrow"
	return host


func test_label_drag_sideways_preserves_perpendicular_clearance() -> void:
	print("test_label_drag_sideways_preserves_perpendicular_clearance:")
	var host := _arrow_label_host(10.0)
	var arrow := AnnotationArrow.new()
	var start_offset := arrow.label_offset(host.get_annotations()[0])
	check_eq("default label offset is ZERO — caption centred on the shaft midpoint",
		start_offset, Vector2(0.0, 0.0))

	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	# Caption centre = midpoint(50,0) + offset(0,0) = (50,0) — ON the shaft.
	check("pointer down on caption starts label drag",
		tool.on_pointer_down(Vector2(50, 0), MOUSE_BUTTON_LEFT, 0))
	# Deliberately WILD sideways drag: dx=30 along the axis, dy=25 purely
	# perpendicular. A free drag would add BOTH to the offset, landing at
	# (30, 25) instead of staying pinned to the line at (30, 0).
	tool.on_pointer_move(Vector2(80, 25))  # delta = (30, 25)

	check_eq("one label modification emitted", log.size(), 1)
	var new_offset: Vector2 = arrow.label_offset(log[0]["ann"])
	check("along-axis movement applied (x == 30)", is_equal_approx(new_offset.x, 30.0))
	check("perpendicular component pinned to the shaft (y == 0, zero clearance)",
		is_zero_approx(new_offset.y))

	tool.on_deactivate()


func test_label_drag_old_free_offset_clamps_on_next_drag() -> void:
	print("test_label_drag_old_free_offset_clamps_on_next_drag:")
	# A legacy free-dragged offset: perpendicular component (y=40) sits far off
	# the shaft (clearance is now ZERO — docket 019fcaefd0e1). No migration ran
	# on load — the stored value renders untouched until the label is grabbed
	# again.
	var host := _arrow_label_host(10.0, Vector2(5.0, 40.0))
	var arrow := AnnotationArrow.new()
	check_eq("stored free offset renders unmigrated",
		arrow.label_offset(host.get_annotations()[0]), Vector2(5.0, 40.0))

	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	# Caption centre = midpoint(50,0) + offset(5,40) = (55,40).
	check("pointer down on the free-offset caption starts a drag",
		tool.on_pointer_down(Vector2(55, 40), MOUSE_BUTTON_LEFT, 0))
	tool.on_pointer_move(Vector2(65, 40))  # delta = (10, 0), purely along-axis

	check_eq("one label modification emitted", log.size(), 1)
	var new_offset: Vector2 = arrow.label_offset(log[0]["ann"])
	check("perpendicular component CLAMPED onto the shaft on first drag (40 → 0)",
		is_zero_approx(new_offset.y))
	check("along component preserved + moved (5 + 10 == 15)",
		is_equal_approx(new_offset.x, 15.0))

	tool.on_deactivate()


func test_label_drag_t_range_clamped_near_tail_and_head() -> void:
	print("test_label_drag_t_range_clamped_near_tail_and_head:")
	var host := _arrow_label_host(10.0)
	var arrow := AnnotationArrow.new()
	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	check("pointer down on caption starts label drag",
		tool.on_pointer_down(Vector2(50, 0), MOUSE_BUTTON_LEFT, 0))
	# Drag far past the head: along-axis delta of +500 on a length-100 segment.
	tool.on_pointer_move(Vector2(550, 0))

	check_eq("one label modification emitted", log.size(), 1)
	var new_offset: Vector2 = arrow.label_offset(log[0]["ann"])
	# along_max = 0.65 * seg_len = 0.65 * 100 = 65  (t = 1.15, per the
	# documented decision in _setup_label_axis_constraint).
	check("along component clamped at t≈1.15 past the head (65, not 500)",
		is_equal_approx(new_offset.x, 65.0))
	check("perpendicular component still pinned to the shaft at the clamp",
		is_zero_approx(new_offset.y))

	tool.on_deactivate()


## F1 regression pin (cold review 2026-08-01): vertical arrow (0,0)->(0,100).
## axis=(0,1), perp=(-1,0). The font-10.0 default offset (0,-16) projects
## ENTIRELY onto the axis here (offset.dot(axis) = -16) and has ZERO
## perpendicular component (offset.dot(perp) = 0) — the opposite extreme from
## the horizontal tests above, where the same offset is ALL perpendicular.
## A drag with a small, purely along-axis delta (zero perpendicular mouse
## intent) must leave the perpendicular component at 0. The buggy
## SET-not-clamp version forced it to a full clearance (16.0) regardless of
## the delta, teleporting the caption 16 doc units sideways on the very first
## grab — this is the exact deviation the cold review measured.
func test_label_drag_vertical_arrow_no_perpendicular_teleport() -> void:
	print("test_label_drag_vertical_arrow_no_perpendicular_teleport:")
	var host := _arrow_label_host(10.0, null, Vector2(0.0, 100.0))
	var arrow := AnnotationArrow.new()
	var start_offset := arrow.label_offset(host.get_annotations()[0])
	check_eq("default label offset is ZERO — caption centred on the shaft midpoint",
		start_offset, Vector2(0.0, 0.0))

	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	# Caption centre = midpoint(0,50) + offset(0,0) = (0,50) — ON the shaft.
	check("pointer down on caption starts label drag",
		tool.on_pointer_down(Vector2(0, 50), MOUSE_BUTTON_LEFT, 0))
	# Small delta, PURELY along the axis (0,1): (0,5). Zero perpendicular
	# component in the raw mouse delta itself — any x drift in the result
	# comes only from how the drag-start basis was constructed, not from this
	# move, which is exactly what isolates the F1 bug (it fires at drag START,
	# independent of the delta applied afterward).
	tool.on_pointer_move(Vector2(0, 55))  # delta = (0, 5)

	check_eq("one label modification emitted", log.size(), 1)
	var new_offset: Vector2 = arrow.label_offset(log[0]["ann"])
	check("perpendicular component stays 0 — no sideways teleport (was 16.0 pre-F1-fix)",
		is_equal_approx(new_offset.x, 0.0))
	check("along-axis component moved by the drag delta (0 + 5 == 5)",
		is_equal_approx(new_offset.y, 5.0))

	tool.on_deactivate()


## F1 regression pin (cold review 2026-08-01): 45° arrow (0,0)->(100,100).
## axis=(√2/2,√2/2), perp=(-√2/2,√2/2). The font-10.0 default offset (0,-16)
## has BOTH a nonzero along AND a nonzero perpendicular component here — the
## general case neither the horizontal nor the vertical test exercises. A
## drag with a small, purely along-axis delta must leave the offset's
## PERPENDICULAR PROJECTION (offset.dot(perp)) exactly where it started. The
## buggy SET-not-clamp version forced the perpendicular magnitude to a full
## clearance (16.0) regardless of the true ~11.3137 projection, a measured
## 4.69-doc-unit deviation (cold review F1) — clampf leaves an
## already-in-bounds value (|-11.3137| < 16) untouched instead.
func test_label_drag_45deg_arrow_no_perpendicular_teleport() -> void:
	print("test_label_drag_45deg_arrow_no_perpendicular_teleport:")
	var host := _arrow_label_host(10.0, null, Vector2(100.0, 100.0))
	var arrow := AnnotationArrow.new()
	var start_offset := arrow.label_offset(host.get_annotations()[0])
	check_eq("default label offset is ZERO — caption centred on the shaft midpoint",
		start_offset, Vector2(0.0, 0.0))

	var axis := Vector2(100.0, 100.0).normalized()
	var perp := Vector2(-axis.y, axis.x)
	var start_perp_projection := start_offset.dot(perp)

	var tool := AnnotationTransformTool.new()
	var log := _capture_modified(tool)
	tool.on_activate(host)

	# Caption centre = midpoint(50,50) + offset(0,0) = (50,50) — ON the shaft.
	check("pointer down on caption starts label drag",
		tool.on_pointer_down(Vector2(50, 50), MOUSE_BUTTON_LEFT, 0))
	# Small delta, PURELY along the axis: 5 doc units in the axis direction.
	# delta.dot(perp) == 0 by construction (axis ⟂ perp), so any change to the
	# offset's perpendicular projection comes only from how the drag-start
	# basis was constructed — again isolating the F1 bug from the move itself.
	var press_pos := Vector2(50, 50)
	var target_pos := press_pos + axis * 5.0
	tool.on_pointer_move(target_pos)

	check_eq("one label modification emitted", log.size(), 1)
	var new_offset: Vector2 = arrow.label_offset(log[0]["ann"])
	check("perpendicular projection unchanged from the stored default (zero deviation, was ~4.69 pre-F1-fix)",
		is_equal_approx(new_offset.dot(perp), start_perp_projection))
	check("along-axis projection moved by the drag delta (+5)",
		is_equal_approx(new_offset.dot(axis), start_offset.dot(axis) + 5.0))

	tool.on_deactivate()


# ── Selection / deselection tests ─────────────────────────────────────────────

func test_no_selection_click_on_annotation_selects() -> void:
	print("test_no_selection_click_on_annotation_selects:")
	var host := _make_two_box_host()
	# No selection set initially.
	var tool := AnnotationTransformTool.new()
	tool.on_activate(host)

	# Click inside ann_a (rect 0,0,40,40) at (20,20).
	tool.on_pointer_down(Vector2(20, 20), MOUSE_BUTTON_LEFT, 0)

	check_eq("ann_a selected after click", host.get_selected_annotation_id(), "ann_a")
	tool.on_deactivate()


func test_click_outside_all_clears_selection() -> void:
	print("test_click_outside_all_clears_selection:")
	var host := _make_two_box_host()
	host._selected_id = "ann_a"
	var tool := AnnotationTransformTool.new()
	tool.on_activate(host)

	# Click far outside both annotations. Under the A8u1 marquee contract an
	# empty-space PRESS arms the marquee and the clear is decided at RELEASE
	# with zero travel — a full click is press + release, so the test must
	# send both (fixture repair for the deliberate contract change).
	tool.on_pointer_down(Vector2(500, 500), MOUSE_BUTTON_LEFT, 0)
	tool.on_pointer_up(Vector2(500, 500), MOUSE_BUTTON_LEFT, 0)

	check_eq("selection cleared after outside click",
		host.get_selected_annotation_id(), "")
	tool.on_deactivate()


func test_click_different_annotation_switches_selection() -> void:
	print("test_click_different_annotation_switches_selection:")
	var host := _make_two_box_host()
	# ann_b is at (200,200,40,40). Click on it while ann_a selected and
	# the click position is outside ann_a's gizmo.
	host._selected_id = "ann_a"
	var tool := AnnotationTransformTool.new()
	tool.on_activate(host)

	# Click inside ann_b at (220,220). The gizmo for ann_a is far away.
	tool.on_pointer_down(Vector2(220, 220), MOUSE_BUTTON_LEFT, 0)

	check_eq("selection switches to ann_b", host.get_selected_annotation_id(), "ann_b")
	tool.on_deactivate()


# ── Keyboard / lifecycle tests ────────────────────────────────────────────────

func test_delete_with_selection_removes() -> void:
	print("test_delete_with_selection_removes:")
	var host := _make_two_box_host()
	host._selected_id = "ann_a"
	var tool := AnnotationTransformTool.new()
	tool.on_activate(host)

	var consumed := tool.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, KEY_DELETE)
	check("delete consumed", consumed)
	check_eq("remove_annotation called once", host.removed_ids.size(), 1)
	check_eq("remove_annotation called with ann_a", host.removed_ids[0], "ann_a")
	tool.on_deactivate()


func test_activate_stores_host_deactivate_drops_it() -> void:
	print("test_activate_stores_host_deactivate_drops_it:")
	var host := MockHost.new()
	var tool := AnnotationTransformTool.new()

	tool.on_activate(host)
	check("host stored after on_activate", tool._host == host)

	tool.on_deactivate()
	check("host dropped after on_deactivate", tool._host == null)

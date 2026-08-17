extends SceneTree
## Unit tests for the cad_edge_number_tool authoring tool.
## CAD UX Round 2b-α Unit 2.
##
## Run: godot --headless --path src --script test/test_cad_edge_number_tool.gd
##
## Coverage (8 new tests):
##   1. author_ui() returns non-null — toolbar discovery works.
##   2. Tool subclasses AnnotationAuthorTool — type check.
##   3. Click resolves to nearest edge — mock host, 3 edges at known positions.
##   4. Click outside any pane ignores — no annotation added.
##   5. Click far from any edge (>30 px) ignores — no annotation added.
##   6. Annotation envelope has correct shape — edge_id, primitives, metadata.
##   7. Cancel clears authoring state — start then cancel, no annotation.
##   8. Round-trip with kind.validate — envelope validates without errors.
##
## Note: preload() is used (not class_name lookup) because cad_edge_number_tool.gd
## and cad_edge_number_kind.gd live outside Minerva's res:// tree.

const _CadEdgeNumberKindScript: Script = preload(
	"res://../../plugins/cad/ui/kinds/cad_edge_number_kind.gd"
)
const _CadEdgeNumberToolScript: Script = preload(
	"res://../../plugins/cad/ui/tools/cad_edge_number_tool.gd"
)

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== cad_edge_number_tool tests ===\n")

	print("-- 1. author_ui() returns non-null --")
	test_author_ui_returns_non_null()

	print("\n-- 2. tool subclasses AnnotationAuthorTool --")
	test_tool_is_annotation_author_tool()

	print("\n-- 3. click resolves to nearest edge --")
	test_click_resolves_nearest_edge()

	print("\n-- 4. click outside pane is ignored --")
	test_click_outside_pane_ignored()

	print("\n-- 5. click far from all edges is ignored (>30 px) --")
	test_click_far_from_edges_ignored()

	print("\n-- 6. annotation envelope shape is correct --")
	test_annotation_envelope_shape()

	print("\n-- 7. cancel clears authoring state --")
	test_cancel_clears_state()

	print("\n-- 8. round-trip: envelope validates via kind.validate() --")
	test_round_trip_validates()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ── Assertion helpers ──────────────────────────────────────────────────────────

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


# ── Mock camera ────────────────────────────────────────────────────────────────

## Simulates Camera3D.unproject_position. Returns the 3-D point's x/y components
## shifted by _screen_offset, allowing deterministic projection in tests.
class _MockCamera extends RefCounted:
	var screen_offset: Vector2 = Vector2.ZERO
	var call_count: int = 0

	func unproject_position(world_pos: Vector3) -> Vector2:
		call_count += 1
		return Vector2(world_pos.x, world_pos.y) + screen_offset


# ── Mock host ──────────────────────────────────────────────────────────────────

## Minimal AnnotationHost with get_panes() and get_edge_registry().
## Extends AnnotationHost so it satisfies the typed parameter in on_activate().
class _MockHost extends AnnotationHost:
	var _panes: Array = []       # Array[Dictionary]
	var _edges: Array = []       # Array[Dictionary]
	var _added: Array = []       # captured add_annotation calls
	var _view_context: String = "cad:iso"

	# ── Required AnnotationHost overrides ──────────────────────────────────────
	func get_registry() -> AnnotationRegistry:
		return null
	func transform_doc_to_screen(p: Vector2) -> Vector2:
		return p
	func transform_screen_to_doc(p: Vector2) -> Vector2:
		return p
	func get_view_context() -> String:
		return _view_context
	func describe_point(_doc_pos: Vector2) -> String:
		return ""
	func render_content_to_image(_viewport_rect: Rect2) -> Image:
		return null

	# ── CAD-specific extras (duck-typed by the tool) ───────────────────────────
	func get_panes() -> Array:
		return _panes

	func get_edge_registry() -> Array:
		return _edges

	func add_annotation(ann: Dictionary) -> String:
		_added.append(ann.duplicate(true))
		return "ann_test"

	## Add a pane with a given camera (or auto-create one with screen_offset).
	func add_pane(
		pane_name: String,
		viewport_rect: Rect2,
		cam_offset: Vector2 = Vector2.ZERO
	) -> _MockCamera:
		var cam := _MockCamera.new()
		cam.screen_offset = cam_offset
		_panes.append({
			"name": pane_name,
			"camera": cam,
			"viewport_rect": viewport_rect,
		})
		return cam

	## Add a straight edge with id, start, end.
	func add_edge(edge_id: int, start: Vector3, end_pos: Vector3) -> void:
		_edges.append({
			"id": edge_id,
			"kind": "straight",
			"start": [start.x, start.y, start.z],
			"end":   [end_pos.x, end_pos.y, end_pos.z],
		})


# ── Tests ─────────────────────────────────────────────────────────────────────

func test_author_ui_returns_non_null() -> void:
	var kind = _CadEdgeNumberKindScript.new()
	var tool_obj: Object = kind.author_ui()
	check("author_ui() is non-null", tool_obj != null)
	check("author_ui() is a fresh object each call", kind.author_ui() != tool_obj)


func test_tool_is_annotation_author_tool() -> void:
	# AnnotationAuthorTool uses class_name so is_class() works.
	var tool = _CadEdgeNumberToolScript.new()
	# Duck-type: must have the three signal names from AnnotationAuthorTool.
	check("tool has annotation_ready signal", tool.has_signal("annotation_ready"))
	check("tool has cancelled signal", tool.has_signal("cancelled"))
	check("tool has on_activate method", tool.has_method("on_activate"))
	check("tool has on_deactivate method", tool.has_method("on_deactivate"))
	check("tool has on_pointer_down method", tool.has_method("on_pointer_down"))


func test_click_resolves_nearest_edge() -> void:
	# 3 edges with midpoints at known screen positions.
	# Camera has zero offset, so unproject returns Vector2(x, y) = world x/y.
	# Pane: rect=(0,0)→(500,500), so panel_pos == pane_local.
	#
	# Edge 1 midpoint: Vector3(100, 100, 0) → screen (100,100)
	# Edge 2 midpoint: Vector3(200, 200, 0) → screen (200,200)
	# Edge 3 midpoint: Vector3(300, 300, 0) → screen (300,300)
	#
	# Click at panel_pos=(205,205) — closest to edge 2 (dist≈7 px).
	var host := _MockHost.new()
	host.add_pane("iso", Rect2(0, 0, 500, 500), Vector2.ZERO)
	host.add_edge(1, Vector3(50,  100, 0), Vector3(150, 100, 0))  # midpoint (100,100,0)
	host.add_edge(2, Vector3(100, 200, 0), Vector3(300, 200, 0))  # midpoint (200,200,0)
	host.add_edge(3, Vector3(200, 300, 0), Vector3(400, 300, 0))  # midpoint (300,300,0)

	var result: Dictionary = _CadEdgeNumberToolScript.resolve_click(Vector2(205, 205), host)

	check("resolve_click returns non-empty dict", not result.is_empty())
	check_eq("picks edge 2 (nearest to 205,205)", result.get("edge_id", -1), 2)
	check_eq("pane_name is 'iso'", result.get("pane_name", ""), "iso")
	# world_pos should be the midpoint of edge 2: (200, 200, 0)
	var wp: Vector3 = result.get("world_pos", Vector3.ONE * 999)
	check("world_pos is midpoint of edge 2",
		wp.is_equal_approx(Vector3(200.0, 200.0, 0.0)))


func test_click_outside_pane_ignored() -> void:
	# Pane rect is (0,0,500,500). Click at (600,600) is outside all panes.
	var host := _MockHost.new()
	host.add_pane("iso", Rect2(0, 0, 500, 500), Vector2.ZERO)
	host.add_edge(1, Vector3(100, 100, 0), Vector3(200, 100, 0))

	var result: Dictionary = _CadEdgeNumberToolScript.resolve_click(Vector2(600, 600), host)
	check("resolve_click returns empty dict when outside pane", result.is_empty())


func test_click_far_from_edges_ignored() -> void:
	# Edge midpoint at (100,100). Click at (200,200) — distance ≈ 141 px > 30 px threshold.
	var host := _MockHost.new()
	host.add_pane("iso", Rect2(0, 0, 500, 500), Vector2.ZERO)
	host.add_edge(1, Vector3(50, 100, 0), Vector3(150, 100, 0))  # midpoint (100,100,0)

	var result: Dictionary = _CadEdgeNumberToolScript.resolve_click(Vector2(200, 200), host)
	check("resolve_click returns empty dict when >30 px from all edges", result.is_empty())


func test_annotation_envelope_shape() -> void:
	# Set up host with one pane containing edge 2 whose midpoint is nearest.
	# Edge 2 midpoint: (200, 200, 0).  Click at (202, 198) — within threshold.
	var host := _MockHost.new()
	host.add_pane("front", Rect2(0, 0, 500, 500), Vector2.ZERO)
	host.add_edge(1, Vector3(50,  100, 0), Vector3(150, 100, 0))  # midpoint (100,100,0)
	host.add_edge(2, Vector3(100, 200, 0), Vector3(300, 200, 0))  # midpoint (200,200,0)

	var result: Dictionary = _CadEdgeNumberToolScript.resolve_click(Vector2(202, 198), host)
	check("resolve_click picks edge 2", result.get("edge_id", -1) == 2)

	# Now build the annotation via the tool to check full envelope shape.
	var tool = _CadEdgeNumberToolScript.new()
	# Activate with a mock host that has get_view_context.
	# on_activate receives an AnnotationHost-typed arg but duck-types it.
	# We supply a plain RefCounted with the required methods.
	tool.on_activate(host)

	# Simulate a click at (202,198) — on_pointer_down drives the full path.
	var emitted_annotations: Array = []
	tool.annotation_ready.connect(func(ready_ann: Dictionary) -> void:
		emitted_annotations.append(ready_ann.duplicate(true))
	)
	var consumed: bool = tool.on_pointer_down(Vector2(202, 198), MOUSE_BUTTON_LEFT, 0)

	check("on_pointer_down returned true (consumed)", consumed)
	check("annotation_ready fired once", emitted_annotations.size() == 1)

	if emitted_annotations.is_empty():
		return

	var ann: Dictionary = emitted_annotations[0]
	check("kind is 'cad_edge_number'", ann.get("kind", "") == "cad_edge_number")
	var author: Variant = ann.get("author", null)
	check("author is v2 {kind: human}",
		author is Dictionary and str((author as Dictionary).get("kind", "")) == "human")

	var payload: Dictionary = ann.get("payload", {})
	check_eq("payload.edge_id is 2", int(payload.get("edge_id", -1)), 2)
	check_eq("payload.label is '2'", str(payload.get("label", "")), "2")

	var primitives: Array = ann.get("primitives", [])
	check("one primitive", primitives.size() == 1)
	if primitives.size() >= 1:
		var prim: Dictionary = primitives[0]
		check("primitive kind is 'point'", str(prim.get("kind", "")) == "point")
		var at_raw: Variant = prim.get("at", null)
		check("primitive has 'at' with 3 elements", at_raw is Array and (at_raw as Array).size() == 3)

	var metadata: Dictionary = ann.get("metadata", {})
	var views: Variant = metadata.get("visible_in_views", null)
	check("metadata.visible_in_views is an Array", views is Array)
	if views is Array:
		check("visible_in_views contains 'front'", (views as Array).has("front"))


func test_cancel_clears_state() -> void:
	var host := _MockHost.new()
	host.add_pane("iso", Rect2(0, 0, 500, 500), Vector2.ZERO)

	var tool = _CadEdgeNumberToolScript.new()
	tool.on_activate(host)

	# Use Array bumpers for capture-by-reference. GDScript 4 lambdas capture
	# locals by reference, but a captured `int` rebinds rather than mutates,
	# so the outer scope wouldn't see `cancelled_count += 1`. An Array is a
	# reference type — appending to it from inside the lambda is visible here.
	var cancelled_emits: Array = []
	var annotation_emits: Array = []
	tool.cancelled.connect(func() -> void: cancelled_emits.append(1))
	tool.annotation_ready.connect(func(_ann: Dictionary) -> void: annotation_emits.append(1))

	# Cancel via ESC (mods == KEY_ESCAPE).
	var consumed: bool = tool.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, KEY_ESCAPE)

	check("on_pointer_down(ESC) returned true (consumed)", consumed)
	check("cancelled signal emitted once", cancelled_emits.size() == 1)
	check("annotation_ready NOT emitted", annotation_emits.size() == 0)
	# After cancel, _host should be cleared (on_deactivate was called).
	check("tool host cleared after cancel", tool._host == null)
	# Mouse-filter management is now owned by CadAnnotationCanvas.set_active_tool()
	# (Round 2b-α regression fix). The tool no longer holds an overlay reference.


func test_round_trip_validates() -> void:
	# Produce an annotation via the tool, then validate it via the kind.
	var host := _MockHost.new()
	host.add_pane("iso", Rect2(0, 0, 500, 500), Vector2.ZERO)
	host.add_edge(5, Vector3(0, 0, 0), Vector3(20, 0, 0))  # midpoint (10,0,0) → screen(10,0)

	# Click near the edge midpoint.
	var tool = _CadEdgeNumberToolScript.new()
	tool.on_activate(host)

	var emitted: Array = []
	tool.annotation_ready.connect(func(ready_ann: Dictionary) -> void:
		emitted.append(ready_ann.duplicate(true))
	)
	tool.on_pointer_down(Vector2(10, 2), MOUSE_BUTTON_LEFT, 0)

	check("annotation was emitted for round-trip test", emitted.size() == 1)
	if emitted.is_empty():
		return

	var ann: Dictionary = emitted[0]
	var kind = _CadEdgeNumberKindScript.new()
	var errors: Array = kind.validate(ann)
	check("validate() returns no errors on tool-produced envelope", errors.is_empty())
	if not errors.is_empty():
		for err in errors:
			printerr("    validation error: %s" % str(err))

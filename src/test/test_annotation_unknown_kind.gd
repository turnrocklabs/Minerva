extends SceneTree
## Unit tests for unknown-kind placeholder rendering in AnnotationRegistry.
## Run: godot --headless --path src --script test/test_annotation_unknown_kind.gd
##
## Coverage:
##   dispatch_render — unknown kind → placeholder rendered (draw calls fired)
##   dispatch_render — kind registered later → real render used, not placeholder
##   dispatch_render — kind deregistered mid-session → falls back to placeholder
##   Empty primitives → fixed-size default placeholder rendered (no crash)
##   Once-per-load logging — rapid re-renders don't spam warn calls
##   dispatch_hit_test — unknown kind → true inside placeholder bounds
##   _placeholder_bounds — annotation with no primitives uses default 100×40 rect
##   _warned_unknown_kinds reset on register / deregister

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== Annotation Unknown-Kind Tests ===\n")

	print("-- dispatch_render: placeholder drawing --")
	test_unknown_kind_draws_placeholder()
	test_unknown_kind_placeholder_draws_string()
	test_unknown_kind_placeholder_draws_lines()

	print("\n-- dispatch_render: plugin installs later --")
	test_kind_registered_later_uses_real_render()

	print("\n-- dispatch_render: plugin deregisters --")
	test_kind_deregistered_falls_back_to_placeholder()

	print("\n-- Empty primitives → default 100×40 placeholder --")
	test_empty_primitives_renders_default_placeholder()
	test_no_primitives_key_renders_default_placeholder()

	print("\n-- Once-per-kind logging --")
	test_log_once_per_kind()
	test_log_resets_on_register()
	test_log_resets_on_deregister()

	print("\n-- dispatch_hit_test: unknown kind uses placeholder bounds --")
	test_hit_test_inside_placeholder_bounds()
	test_hit_test_outside_placeholder_bounds()
	test_hit_test_empty_prims_hits_default_placeholder()

	print("\n-- _placeholder_bounds: fixed-size default --")
	test_placeholder_bounds_empty_prims_default_size()
	test_placeholder_bounds_known_prims_uses_aabb()
	test_placeholder_bounds_unknown_prim_type_uses_default()

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


# ── Mock render context ───────────────────────────────────────────────────────
## Counts draw_* calls without touching RenderingServer (headless-safe).

class MockRenderContext extends AnnotationRenderContext:
	var line_calls: int   = 0
	var string_calls: int = 0
	var polyline_calls: int = 0
	var rect_calls: int   = 0

	func _init() -> void:
		transform     = Transform2D.IDENTITY
		viewport_rect = Rect2(0, 0, 1000, 1000)
		zoom          = 1.0
		view_context  = "pcb"
		unit          = "mm"

	func draw_line(_a: Vector2, _b: Vector2, _color: Color, _width: float = 1.0) -> void:
		line_calls += 1

	func draw_polyline(_pts: PackedVector2Array, _color: Color, _width: float = 1.0) -> void:
		polyline_calls += 1

	func draw_polygon(_pts: PackedVector2Array, _cols: PackedColorArray) -> void:
		pass

	func draw_string(_font: Font, _pos: Vector2, _text: String, _color: Color, _size: int = 16) -> void:
		string_calls += 1

	func draw_rect(_rect: Rect2, _color: Color, _filled: bool, _width: float = 1.0) -> void:
		rect_calls += 1

	func to_screen(p: Vector2) -> Vector2:
		return p

	func from_screen(p: Vector2) -> Vector2:
		return p

	func reset() -> void:
		line_calls    = 0
		string_calls  = 0
		polyline_calls = 0
		rect_calls    = 0


# ── Mock AnnotationKind for tracking real-render calls ────────────────────────

class MockKind extends AnnotationKind:
	var render_calls: int = 0

	func _init(p_name: StringName, p_plugin: StringName) -> void:
		name          = p_name
		display_name  = str(p_name)
		owning_plugin = p_plugin

	func render(_ctx: AnnotationRenderContext, _ann: Dictionary) -> void:
		render_calls += 1

	func bounds(_ann: Dictionary) -> Rect2:
		return Rect2(0, 0, 50, 50)


# ── Fixture helpers ───────────────────────────────────────────────────────────

func _ann_unknown(kind_str: String, prims: Array) -> Dictionary:
	return {
		"id":           "ann_unk001",
		"author":       "human",
		"kind":         kind_str,
		"view_context": "pcb",
		"primitives":   prims,
		"created_at":   "2026-04-23T10:00:00Z",
	}


# ── Tests: placeholder drawing ────────────────────────────────────────────────

func test_unknown_kind_draws_placeholder() -> void:
	print("test_unknown_kind_draws_placeholder:")
	var reg := AnnotationRegistry.new()
	var ctx := MockRenderContext.new()
	var ann := _ann_unknown("plugin_foo", [{"kind": "arrow", "from": [0.0, 0.0], "to": [50.0, 0.0]}])
	reg.dispatch_render(ctx, ann)
	# Placeholder draws dashed edges — each edge produces multiple draw_line calls.
	check("unknown kind render → at least one draw_line (dashed edges)", ctx.line_calls > 0)


func test_unknown_kind_placeholder_draws_string() -> void:
	print("test_unknown_kind_placeholder_draws_string:")
	var reg := AnnotationRegistry.new()
	var ctx := MockRenderContext.new()
	var ann := _ann_unknown("plugin_bar", [{"kind": "highlight", "rect": [10.0, 10.0, 40.0, 20.0]}])
	reg.dispatch_render(ctx, ann)
	check("unknown kind render → draw_string called (kind name label)", ctx.string_calls >= 1)


func test_unknown_kind_placeholder_draws_lines() -> void:
	print("test_unknown_kind_placeholder_draws_lines:")
	var reg := AnnotationRegistry.new()
	var ctx := MockRenderContext.new()
	# Use a region primitive so bounds are non-trivial.
	var ann := _ann_unknown("plugin_baz",
		[{"kind": "region", "points": [[0.0,0.0],[80.0,0.0],[40.0,60.0]]}])
	reg.dispatch_render(ctx, ann)
	# 4 edges × multiple dashes = many draw_line calls.
	check("unknown kind render → multiple draw_line calls (dashed rect)", ctx.line_calls >= 4)


# ── Tests: plugin installs later ──────────────────────────────────────────────

func test_kind_registered_later_uses_real_render() -> void:
	print("test_kind_registered_later_uses_real_render:")
	var reg := AnnotationRegistry.new()
	var ctx := MockRenderContext.new()
	var ann := _ann_unknown("myplugin_thing", [{"kind": "arrow", "from": [0.0,0.0], "to": [10.0,0.0]}])

	# First render: kind unknown → placeholder.
	reg.dispatch_render(ctx, ann)
	var placeholder_lines := ctx.line_calls
	check("before registration: placeholder draws lines", placeholder_lines > 0)

	# Register the kind.
	var mock_kind := MockKind.new(&"myplugin_thing", &"myplugin")
	reg.register_annotation_kind(mock_kind)

	# Second render: kind known → real render(), not placeholder.
	ctx.reset()
	reg.dispatch_render(ctx, ann)
	check("after registration: real render() called", mock_kind.render_calls == 1)
	# The mock render() does nothing, so no draw calls from it — lines reset to 0.
	check("after registration: placeholder lines NOT drawn (real kind took over)", ctx.line_calls == 0)


# ── Tests: plugin deregisters ─────────────────────────────────────────────────

func test_kind_deregistered_falls_back_to_placeholder() -> void:
	print("test_kind_deregistered_falls_back_to_placeholder:")
	var reg := AnnotationRegistry.new()
	var ctx := MockRenderContext.new()
	var mock_kind := MockKind.new(&"myplugin_thing2", &"myplugin")
	reg.register_annotation_kind(mock_kind)

	var ann := _ann_unknown("myplugin_thing2", [{"kind": "highlight", "rect": [0.0,0.0,50.0,30.0]}])

	# With kind registered → real render.
	reg.dispatch_render(ctx, ann)
	check("registered: real render() called once", mock_kind.render_calls == 1)
	check("registered: no placeholder lines", ctx.line_calls == 0)

	# Deregister.
	reg.deregister_annotation_kind(&"myplugin_thing2")
	ctx.reset()

	# After deregister → placeholder.
	reg.dispatch_render(ctx, ann)
	check("deregistered: placeholder draws lines", ctx.line_calls > 0)
	check("deregistered: placeholder draws kind name string", ctx.string_calls >= 1)


# ── Tests: empty primitives → fixed-size default placeholder ──────────────────

func test_empty_primitives_renders_default_placeholder() -> void:
	print("test_empty_primitives_renders_default_placeholder:")
	var reg := AnnotationRegistry.new()
	var ctx := MockRenderContext.new()
	var ann := _ann_unknown("plugin_empty", [])
	# Must not crash; must draw something.
	reg.dispatch_render(ctx, ann)
	check("empty primitives: does not crash and draws lines", ctx.line_calls > 0)
	check("empty primitives: draws kind name string", ctx.string_calls >= 1)


func test_no_primitives_key_renders_default_placeholder() -> void:
	print("test_no_primitives_key_renders_default_placeholder:")
	var reg := AnnotationRegistry.new()
	var ctx := MockRenderContext.new()
	# Annotation with no "primitives" key at all.
	var ann: Dictionary = {
		"id": "ann_noprim",
		"author": "ai",
		"kind": "plugin_noprim",
		"view_context": "graphics",
		"created_at": "2026-04-23T10:00:00Z",
	}
	reg.dispatch_render(ctx, ann)
	check("absent primitives key: does not crash and draws lines", ctx.line_calls > 0)


# ── Tests: once-per-kind logging ──────────────────────────────────────────────

func test_log_once_per_kind() -> void:
	print("test_log_once_per_kind:")
	var reg := AnnotationRegistry.new()
	# Inspect _warned_unknown_kinds directly — it's the deduplication structure.
	var ann := _ann_unknown("plugin_spam", [])
	var ctx := MockRenderContext.new()

	# First render → kind logged, entry added.
	reg.dispatch_render(ctx, ann)
	check("first render: kind added to warned set",
		reg._warned_unknown_kinds.has("plugin_spam"))

	# Render again many times — the set entry remains (not re-added) but is
	# idempotent.  We can't intercept push_warning in headless GDScript, so we
	# verify state: the warned set still contains exactly the one key.
	for _i in range(9):
		ctx.reset()
		reg.dispatch_render(ctx, ann)

	check("after 10 renders: warned set has exactly 1 entry for this kind",
		reg._warned_unknown_kinds.size() == 1)


func test_log_resets_on_register() -> void:
	print("test_log_resets_on_register:")
	var reg := AnnotationRegistry.new()
	var ctx := MockRenderContext.new()
	var ann := _ann_unknown("plugin_reset_test", [])

	reg.dispatch_render(ctx, ann)
	check("before register: warned set non-empty", reg._warned_unknown_kinds.size() > 0)

	# Registering any kind clears the warned set.
	var mock_kind := MockKind.new(&"other_kind", &"other")
	reg.register_annotation_kind(mock_kind)
	check("after register: warned set cleared", reg._warned_unknown_kinds.size() == 0)


func test_log_resets_on_deregister() -> void:
	print("test_log_resets_on_deregister:")
	var reg := AnnotationRegistry.new()
	var ctx := MockRenderContext.new()
	var mock_kind := MockKind.new(&"plugin_tmp_kind", &"plugin")
	reg.register_annotation_kind(mock_kind)

	var ann := _ann_unknown("plugin_reset_test2", [])
	reg.dispatch_render(ctx, ann)
	check("after first render: warned set non-empty", reg._warned_unknown_kinds.size() > 0)

	# Deregistering clears the warned set.
	reg.deregister_annotation_kind(&"plugin_tmp_kind")
	check("after deregister: warned set cleared", reg._warned_unknown_kinds.size() == 0)


# ── Tests: hit_test on unknown kind ──────────────────────────────────────────

func test_hit_test_inside_placeholder_bounds() -> void:
	print("test_hit_test_inside_placeholder_bounds:")
	var reg := AnnotationRegistry.new()
	# highlight at (0,0) 100×50
	var ann := _ann_unknown("plugin_hittest",
		[{"kind": "highlight", "rect": [0.0, 0.0, 100.0, 50.0]}])
	# Centre of the highlight — explicit min/max check below but hit_test
	# uses Rect2.grow() which IS closed, so (50,25) is definitely inside.
	var inside := reg.dispatch_hit_test(ann, Vector2(50.0, 25.0), 0.0)
	check("unknown kind hit inside placeholder bounds → true", inside)


func test_hit_test_outside_placeholder_bounds() -> void:
	print("test_hit_test_outside_placeholder_bounds:")
	var reg := AnnotationRegistry.new()
	var ann := _ann_unknown("plugin_hittest2",
		[{"kind": "highlight", "rect": [0.0, 0.0, 100.0, 50.0]}])
	var outside := reg.dispatch_hit_test(ann, Vector2(500.0, 500.0), 0.0)
	check("unknown kind hit far outside → false", not outside)


## REGRESSION (was: dispatch_bounds returned Rect2() for empty primitives,
## but _render_unknown_placeholder drew a 100×40 default — user clicked the
## visible placeholder and nothing selected).  Verifies render-bounds and
## hit-bounds are now consistent via _placeholder_bounds.
func test_hit_test_empty_prims_hits_default_placeholder() -> void:
	print("test_hit_test_empty_prims_hits_default_placeholder:")
	var reg := AnnotationRegistry.new()
	var ann := _ann_unknown("plugin_empty_prims", [])
	# Default placeholder is 100×40 CENTRED at the centroid (origin for empty
	# prims), i.e. Rect2(-50, -20, 100, 40).  Origin is the centre of that box,
	# so (0, 0) must be a hit with zero threshold.
	check("unknown kind with empty prims: centre of placeholder hits",
		reg.dispatch_hit_test(ann, Vector2(0.0, 0.0), 0.0))
	# Far-outside must still miss.
	check("unknown kind with empty prims: far outside misses",
		not reg.dispatch_hit_test(ann, Vector2(9999.0, 9999.0), 0.0))


# ── Tests: _placeholder_bounds ────────────────────────────────────────────────

func test_placeholder_bounds_empty_prims_default_size() -> void:
	print("test_placeholder_bounds_empty_prims_default_size:")
	var reg := AnnotationRegistry.new()
	var ann := _ann_unknown("plugin_bounds_test", [])
	var b := reg._placeholder_bounds(ann)
	check("empty prims → width == 100", b.size.x == 100.0)
	check("empty prims → height == 40", b.size.y == 40.0)


func test_placeholder_bounds_known_prims_uses_aabb() -> void:
	print("test_placeholder_bounds_known_prims_uses_aabb:")
	var reg := AnnotationRegistry.new()
	var ann := _ann_unknown("plugin_bounds_test2",
		[{"kind": "arrow", "from": [10.0, 20.0], "to": [60.0, 80.0]}])
	var b := reg._placeholder_bounds(ann)
	# AABB of arrow: x=10,y=20 size=50x60. Not default 100x40.
	check("known prim → bounds uses AABB width 50", b.size.x == 50.0)
	check("known prim → bounds uses AABB height 60", b.size.y == 60.0)
	check("known prim → bounds x starts at 10", b.position.x == 10.0)


func test_placeholder_bounds_unknown_prim_type_uses_default() -> void:
	print("test_placeholder_bounds_unknown_prim_type_uses_default:")
	var reg := AnnotationRegistry.new()
	# A primitive with an unrecognised kind — bounds_from_primitives returns
	# Rect2() for it, so placeholder falls back to default 100×40.
	var ann := _ann_unknown("plugin_bounds_test3",
		[{"kind": "future_prim_xyz", "data": [1, 2, 3]}])
	var b := reg._placeholder_bounds(ann)
	check("unrecognised prim type → default width 100", b.size.x == 100.0)
	check("unrecognised prim type → default height 40", b.size.y == 40.0)

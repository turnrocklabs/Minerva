extends SceneTree
## Unit tests for AnnotationHost anchor-stamping helpers and
## AnnotationKind.primary_anchor_point() virtuals.
##
## Run: godot --headless --path src --script test/test_annotation_host_stamping.gd

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== AnnotationHost Stamping Tests ===\n")

	print("-- primary_anchor_point: default (bounds-center) --")
	test_primary_anchor_default_bounds_center()

	print("\n-- primary_anchor_point: AnnotationArrow --")
	test_arrow_primary_anchor_returns_to()
	test_arrow_primary_anchor_no_arrow_prim_falls_back()

	print("\n-- primary_anchor_point: AnnotationText --")
	test_text_primary_anchor_returns_at()
	test_text_primary_anchor_no_text_prim_falls_back()

	print("\n-- _stamp_anchor: guard cases --")
	test_stamp_anchor_null_host_noop()
	test_stamp_anchor_null_registry_noop()
	test_stamp_anchor_unknown_kind_noop()

	print("\n-- _stamp_anchor: happy path --")
	test_stamp_anchor_writes_describe_point_result()
	test_stamp_anchor_empty_string_overwrites()
	test_stamp_anchor_overwrites_existing_value()

	print("\n-- refresh_all_anchors --")
	test_refresh_all_anchors_walks_list()
	test_refresh_all_anchors_skips_non_dict()

	print("\n-- describe_target_point: AnnotationKind default --")
	test_describe_target_point_default_delegates_to_host()
	test_describe_target_point_default_null_host_returns_empty()

	print("\n-- describe_target_point: AnnotationArrow override --")
	test_arrow_describe_target_point_hits_head_directly()
	test_arrow_describe_target_point_falls_through_to_projection()
	test_arrow_describe_target_point_zero_length_arrow_no_projection()
	test_arrow_describe_target_point_head_wins_over_projection()

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


# ── primary_anchor_point tests ────────────────────────────────────────────────

func test_primary_anchor_default_bounds_center() -> void:
	print("test_primary_anchor_default_bounds_center:")
	# Use a minimal kind that has a fixed bounds() — no override of primary_anchor_point.
	var kind := _MockKindFixedBounds.new()
	# bounds() returns Rect2(0, 0, 10, 20) → center = (5, 10)
	var annotation: Dictionary = {}
	var pt := kind.primary_anchor_point(annotation)
	check_eq("default primary_anchor_point x = bounds center x", pt.x, 5.0)
	check_eq("default primary_anchor_point y = bounds center y", pt.y, 10.0)


func test_arrow_primary_anchor_returns_to() -> void:
	print("test_arrow_primary_anchor_returns_to:")
	var kind := AnnotationArrow.new()
	var annotation := {
		"primitives": [{"kind": "arrow", "from": [1.0, 2.0], "to": [30.0, 40.0]}]
	}
	var pt := kind.primary_anchor_point(annotation)
	check_eq("arrow primary_anchor_point x = to.x", pt.x, 30.0)
	check_eq("arrow primary_anchor_point y = to.y", pt.y, 40.0)


func test_arrow_primary_anchor_no_arrow_prim_falls_back() -> void:
	print("test_arrow_primary_anchor_no_arrow_prim_falls_back:")
	var kind := AnnotationArrow.new()
	# Only a text primitive — no arrow prim → should fall back to super (bounds center)
	var annotation := {
		"primitives": [{"kind": "text", "at": [5.0, 5.0], "content": "hi"}]
	}
	# bounds() on AnnotationArrow with only a text prim gives Rect2(5,5,50,12)
	# center = (5+25, 5+6) = (30, 11)
	var pt := kind.primary_anchor_point(annotation)
	check("arrow fallback: returns a Vector2 (not crash)", pt is Vector2)


func test_text_primary_anchor_returns_at() -> void:
	print("test_text_primary_anchor_returns_at:")
	var kind := AnnotationText.new()
	var annotation := {
		"primitives": [{"kind": "text", "at": [12.0, 34.0], "content": "hello"}]
	}
	var pt := kind.primary_anchor_point(annotation)
	check_eq("text primary_anchor_point x = at.x", pt.x, 12.0)
	check_eq("text primary_anchor_point y = at.y", pt.y, 34.0)


func test_text_primary_anchor_no_text_prim_falls_back() -> void:
	print("test_text_primary_anchor_no_text_prim_falls_back:")
	var kind := AnnotationText.new()
	var annotation := {"primitives": []}
	var pt := kind.primary_anchor_point(annotation)
	check("text fallback: returns a Vector2 (not crash)", pt is Vector2)


# ── _stamp_anchor guard cases ─────────────────────────────────────────────────

func test_stamp_anchor_null_host_noop() -> void:
	print("test_stamp_anchor_null_host_noop:")
	var annotation := {"kind": "2d_arrow", "primitives": []}
	AnnotationHost._stamp_anchor(annotation, null)
	check("null host: annotation unchanged (no anchored_to key)", not annotation.has("anchored_to"))


func test_stamp_anchor_null_registry_noop() -> void:
	print("test_stamp_anchor_null_registry_noop:")
	# Base AnnotationHost.get_registry() returns null (push_warning)
	var host := AnnotationHost.new()
	var annotation := {"kind": "2d_arrow", "primitives": []}
	AnnotationHost._stamp_anchor(annotation, host)
	check("null registry: annotation unchanged", not annotation.has("anchored_to"))


func test_stamp_anchor_unknown_kind_noop() -> void:
	print("test_stamp_anchor_unknown_kind_noop:")
	var host := _MockHost.new("ui:foo")
	# Register nothing — kind "2d_arrow" is not in the registry
	var annotation := {"kind": "2d_arrow", "primitives": []}
	AnnotationHost._stamp_anchor(annotation, host)
	check("unknown kind: annotation unchanged", not annotation.has("anchored_to"))


# ── _stamp_anchor happy path ──────────────────────────────────────────────────

func test_stamp_anchor_writes_describe_point_result() -> void:
	print("test_stamp_anchor_writes_describe_point_result:")
	var host := _MockHost.new("ui:foo")
	host.register_kind(AnnotationText.new())
	var annotation := {
		"kind": "2d_text",
		"primitives": [{"kind": "text", "at": [0.0, 0.0], "content": "hi"}]
	}
	AnnotationHost._stamp_anchor(annotation, host)
	check_eq("anchored_to = describe_point result", annotation.get("anchored_to", "<missing>"), "ui:foo")


func test_stamp_anchor_empty_string_overwrites() -> void:
	print("test_stamp_anchor_empty_string_overwrites:")
	var host := _MockHost.new("")  # describe_point returns ""
	host.register_kind(AnnotationText.new())
	var annotation := {
		"kind": "2d_text",
		"primitives": [{"kind": "text", "at": [0.0, 0.0], "content": "hi"}]
	}
	AnnotationHost._stamp_anchor(annotation, host)
	check("anchored_to key present even when empty", annotation.has("anchored_to"))
	check_eq("anchored_to = '' when describe_point returns ''",
		annotation.get("anchored_to"), "")


func test_stamp_anchor_overwrites_existing_value() -> void:
	print("test_stamp_anchor_overwrites_existing_value:")
	var host := _MockHost.new("comp:R12")
	host.register_kind(AnnotationArrow.new())
	var annotation := {
		"kind": "2d_arrow",
		"anchored_to": "stale:value",
		"primitives": [{"kind": "arrow", "from": [0.0, 0.0], "to": [5.0, 5.0]}]
	}
	AnnotationHost._stamp_anchor(annotation, host)
	check_eq("existing anchored_to is overwritten", annotation.get("anchored_to"), "comp:R12")


# ── refresh_all_anchors ───────────────────────────────────────────────────────

func test_refresh_all_anchors_walks_list() -> void:
	print("test_refresh_all_anchors_walks_list:")
	var host := _MockHost.new("label.word:hello")
	host.register_kind(AnnotationText.new())
	var ann1 := {
		"kind": "2d_text",
		"primitives": [{"kind": "text", "at": [0.0, 0.0], "content": "a"}]
	}
	var ann2 := {
		"kind": "2d_text",
		"primitives": [{"kind": "text", "at": [1.0, 1.0], "content": "b"}]
	}
	var list := [ann1, ann2]
	AnnotationHost.refresh_all_anchors(list, host)
	check_eq("first annotation stamped", ann1.get("anchored_to"), "label.word:hello")
	check_eq("second annotation stamped", ann2.get("anchored_to"), "label.word:hello")


func test_refresh_all_anchors_skips_non_dict() -> void:
	print("test_refresh_all_anchors_skips_non_dict:")
	var host := _MockHost.new("ui:x")
	host.register_kind(AnnotationText.new())
	var ann := {
		"kind": "2d_text",
		"primitives": [{"kind": "text", "at": [0.0, 0.0], "content": "hi"}]
	}
	# Mix in a non-dict entry — should not crash
	var list: Array = ["not-a-dict", ann, 42]
	AnnotationHost.refresh_all_anchors(list, host)
	check_eq("dict entry in mixed list is stamped", ann.get("anchored_to"), "ui:x")
	check("no crash on non-dict entries", true)


# ── Mock helpers ──────────────────────────────────────────────────────────────

## AnnotationKind with a fixed bounds() Rect2(0, 0, 10, 20).
## Does NOT override primary_anchor_point — exercises the base default.
class _MockKindFixedBounds extends AnnotationKind:
	func _init() -> void:
		name          = &"mock_fixed"
		display_name  = "MockFixed"
		owning_plugin = &"test"

	func render(_ctx: AnnotationRenderContext, _annotation: Dictionary) -> void:
		pass

	func bounds(_annotation: Dictionary) -> Rect2:
		return Rect2(0.0, 0.0, 10.0, 20.0)


## Minimal AnnotationHost that returns a fixed string from describe_point and
## owns a private AnnotationRegistry that callers can populate.
class _MockHost extends AnnotationHost:
	var _fixed_point_label: String
	var _registry: AnnotationRegistry

	func _init(fixed_label: String) -> void:
		_fixed_point_label = fixed_label
		_registry = AnnotationRegistry.new()

	func get_registry() -> AnnotationRegistry:
		return _registry

	func describe_point(_doc_pos: Vector2) -> String:
		return _fixed_point_label

	## Convenience: register a kind into this host's private registry.
	func register_kind(kind: AnnotationKind) -> void:
		_registry.register_annotation_kind(kind)


## AnnotationHost whose describe_point returns a result based on a lookup
## Dictionary {Vector2: String}. Points not matching any key return "".
## Used for projection tests where head and projected point return different strings.
class _CallbackHost extends AnnotationHost:
	## Map of point → label. Lookups compare rounded integer coords for robustness.
	var _point_map: Dictionary  # Dictionary[Vector2, String]
	var _registry: AnnotationRegistry

	func _init(point_map: Dictionary) -> void:
		_point_map = point_map
		_registry = AnnotationRegistry.new()

	func get_registry() -> AnnotationRegistry:
		return _registry

	func describe_point(doc_pos: Vector2) -> String:
		# Round to nearest integer for comparison (projection yields float coords).
		var key := Vector2(roundf(doc_pos.x), roundf(doc_pos.y))
		if _point_map.has(key):
			return _point_map[key]
		return ""

	func register_kind(kind: AnnotationKind) -> void:
		_registry.register_annotation_kind(kind)


# ── describe_target_point: AnnotationKind default ────────────────────────────

func test_describe_target_point_default_delegates_to_host() -> void:
	print("test_describe_target_point_default_delegates_to_host:")
	var kind := _MockKindFixedBounds.new()
	var host := _MockHost.new("ui:SomeWidget")
	var annotation: Dictionary = {}
	var result := kind.describe_target_point(annotation, Vector2(5.0, 10.0), host)
	check_eq("default describe_target_point delegates to host.describe_point",
		result, "ui:SomeWidget")


func test_describe_target_point_default_null_host_returns_empty() -> void:
	print("test_describe_target_point_default_null_host_returns_empty:")
	var kind := _MockKindFixedBounds.new()
	var result := kind.describe_target_point({}, Vector2(5.0, 10.0), null)
	check_eq("default describe_target_point with null host returns ''", result, "")


# ── describe_target_point: AnnotationArrow override ──────────────────────────

func test_arrow_describe_target_point_hits_head_directly() -> void:
	print("test_arrow_describe_target_point_hits_head_directly:")
	# Head at (100, 200) → host returns "ui:HeadWidget" directly, no projection needed.
	var head := Vector2(100.0, 200.0)
	var host := _MockHost.new("ui:HeadWidget")
	var kind := AnnotationArrow.new()
	var annotation := {
		"primitives": [{"kind": "arrow", "from": [0.0, 0.0], "to": [100.0, 200.0]}]
	}
	var result := kind.describe_target_point(annotation, head, host)
	check_eq("arrow: head hit returns immediately without projection", result, "ui:HeadWidget")


func test_arrow_describe_target_point_falls_through_to_projection() -> void:
	print("test_arrow_describe_target_point_falls_through_to_projection:")
	# Head at (100, 200), tail at (0, 0).
	# direction = normalize(100,200) → approx (0.447, 0.894)
	# projected = (100 + 0.447*32, 200 + 0.894*32) = approx (114.3, 228.6) → rounds to (114, 229)
	var head := Vector2(100.0, 200.0)
	var tail := Vector2(0.0, 0.0)
	var direction := (head - tail).normalized()
	var projected := head + direction * 32.0
	var projected_key := Vector2(roundf(projected.x), roundf(projected.y))

	# Host: head returns "", projected point returns "ui:TargetLabel".
	var point_map: Dictionary = {projected_key: "ui:TargetLabel"}
	var host := _CallbackHost.new(point_map)
	var kind := AnnotationArrow.new()
	var annotation := {
		"primitives": [{"kind": "arrow", "from": [tail.x, tail.y], "to": [head.x, head.y]}]
	}
	var result := kind.describe_target_point(annotation, head, host)
	check_eq("arrow: projection resolves to widget past the head", result, "ui:TargetLabel")


func test_arrow_describe_target_point_zero_length_arrow_no_projection() -> void:
	print("test_arrow_describe_target_point_zero_length_arrow_no_projection:")
	# Degenerate arrow: from == to → direction is zero-length → skip projection.
	# Both head and projected (if it were attempted) return "".
	var host := _MockHost.new("")
	var kind := AnnotationArrow.new()
	var annotation := {
		"primitives": [{"kind": "arrow", "from": [50.0, 50.0], "to": [50.0, 50.0]}]
	}
	var result := kind.describe_target_point(annotation, Vector2(50.0, 50.0), host)
	check_eq("zero-length arrow: no projection, returns ''", result, "")


func test_arrow_describe_target_point_head_wins_over_projection() -> void:
	print("test_arrow_describe_target_point_head_wins_over_projection:")
	# Head lands on a widget. Even though a projected point might also resolve,
	# we should return the head result immediately without projection.
	var head := Vector2(50.0, 100.0)
	# Make head resolve to "ui:HeadTarget" and projected also resolve (if queried)
	# to "ui:ProjectedTarget". Only head should be returned.
	var tail := Vector2(0.0, 0.0)
	var direction := (head - tail).normalized()
	var projected := head + direction * 32.0
	var projected_key := Vector2(roundf(projected.x), roundf(projected.y))
	var head_key := Vector2(roundf(head.x), roundf(head.y))

	var point_map: Dictionary = {
		head_key: "ui:HeadTarget",
		projected_key: "ui:ProjectedTarget"
	}
	var host := _CallbackHost.new(point_map)
	var kind := AnnotationArrow.new()
	var annotation := {
		"primitives": [{"kind": "arrow", "from": [tail.x, tail.y], "to": [head.x, head.y]}]
	}
	var result := kind.describe_target_point(annotation, head, host)
	check_eq("arrow: head wins, projection not used when head resolves",
		result, "ui:HeadTarget")

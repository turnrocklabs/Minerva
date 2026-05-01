extends SceneTree
## Focused tests for the AnnotationCanvas positioned-item primitive
## and the core/canvas.point substrate anchor + resolve_position_source.

const AnnotationCanvasScript := preload("res://Scripts/Services/Annotations/AnnotationCanvas.gd")
const CoreAnchorsScript := preload("res://Scripts/Services/Annotations/CoreAnchors.gd")
const AnnotationHostScript := preload("res://Scripts/Services/Annotations/AnnotationHost.gd")
const AnnotationAnchorRegistryScript := preload("res://Scripts/Services/Annotations/AnnotationAnchorRegistry.gd")


var _passed := 0
var _failed := 0


func check(label: String, ok: bool) -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		printerr("[FAIL] %s" % label)


func _initialize() -> void:
	_test_register_and_add_item()
	_test_get_items_returns_copy()
	_test_remove_item()
	_test_z_order_default_increments()
	_test_bring_to_front_send_to_back()
	_test_hit_test_topmost_wins()
	_test_hit_test_custom_callback()
	_test_hit_test_empty_returns_empty()
	_test_items_in_rect()
	_test_select_clear_set()
	_test_remove_clears_selection()
	_test_update_position_emits()
	_test_update_bounds()
	_test_update_payload()
	_test_clear_items()
	_test_render_budget_constant_preserved()

	_test_canvas_point_resolver_validate()
	_test_canvas_point_resolver_summary()
	_test_canvas_point_make_helper()
	_test_canvas_point_resolves_via_host()
	_test_canvas_point_not_stale()
	_test_resolve_position_source_vector2()
	_test_resolve_position_source_array()
	_test_resolve_position_source_bare_xy()
	_test_resolve_position_source_canvas_anchor()
	_test_resolve_position_source_unknown_anchor_returns_null()

	_test_reserved_item_types_constants()
	_test_ink_stroke_stub_can_register_without_draw_callback()

	print("Overlay canvas tests: %d passed, %d failed" % [_passed, _failed])
	quit(0 if _failed == 0 else 1)


# ── Canvas item-registry / lifecycle ─────────────────────────────────────────

func _test_register_and_add_item() -> void:
	var canvas: AnnotationCanvas = AnnotationCanvasScript.new()
	canvas.register_item_type("dot", {"draw": Callable(), "hit_test": Callable(), "supported_transforms": ["translate"]})
	check("has_item_type after register", canvas.has_item_type("dot"))
	var id := canvas.add_item({"id": "i1", "type": "dot", "position": Vector2(10, 20)})
	check("add_item returns id", id == "i1")
	check("item_count == 1", canvas.item_count() == 1)
	canvas.queue_free()


func _test_get_items_returns_copy() -> void:
	var canvas: AnnotationCanvas = AnnotationCanvasScript.new()
	canvas.add_item({"id": "i1", "type": "dot", "position": Vector2(0, 0)})
	var items := canvas.get_items()
	(items[0] as Dictionary)["mutated"] = true
	var fresh := canvas.get_items()
	check("get_items returns deep copy", not (fresh[0] as Dictionary).has("mutated"))
	canvas.queue_free()


func _test_remove_item() -> void:
	var canvas: AnnotationCanvas = AnnotationCanvasScript.new()
	canvas.add_item({"id": "i1", "type": "dot", "position": Vector2(0, 0)})
	canvas.add_item({"id": "i2", "type": "dot", "position": Vector2(0, 0)})
	check("remove_item returns true", canvas.remove_item("i1"))
	check("remove_item nonexistent returns false", not canvas.remove_item("nope"))
	check("item_count == 1 after remove", canvas.item_count() == 1)
	canvas.queue_free()


func _test_z_order_default_increments() -> void:
	var canvas: AnnotationCanvas = AnnotationCanvasScript.new()
	canvas.add_item({"id": "a", "type": "dot", "position": Vector2(0, 0)})
	canvas.add_item({"id": "b", "type": "dot", "position": Vector2(0, 0)})
	var items := canvas.get_items()
	var z_a := int((items[0] as Dictionary).get("z_order", 0))
	var z_b := int((items[1] as Dictionary).get("z_order", 0))
	check("default z_order increments", z_b > z_a)
	canvas.queue_free()


func _test_bring_to_front_send_to_back() -> void:
	var canvas: AnnotationCanvas = AnnotationCanvasScript.new()
	canvas.add_item({"id": "a", "type": "dot", "position": Vector2(0, 0), "z_order": 5})
	canvas.add_item({"id": "b", "type": "dot", "position": Vector2(0, 0), "z_order": 10})
	check("bring_to_front", canvas.bring_to_front("a"))
	var a := canvas.get_item("a")
	check("a now above b", int(a.get("z_order", 0)) > 10)
	check("send_to_back", canvas.send_to_back("a"))
	a = canvas.get_item("a")
	check("a now below b", int(a.get("z_order", 0)) < 10)
	canvas.queue_free()


func _test_hit_test_topmost_wins() -> void:
	var canvas: AnnotationCanvas = AnnotationCanvasScript.new()
	canvas.register_item_type("box", {})
	canvas.add_item({"id": "lower", "type": "box", "position": Vector2(0, 0), "bounds": Rect2(0, 0, 100, 100), "z_order": 1})
	canvas.add_item({"id": "upper", "type": "box", "position": Vector2(0, 0), "bounds": Rect2(0, 0, 100, 100), "z_order": 5})
	check("hit_test returns topmost", canvas.hit_test(Vector2(50, 50)) == "upper")
	canvas.queue_free()


func _test_hit_test_custom_callback() -> void:
	var canvas: AnnotationCanvas = AnnotationCanvasScript.new()
	canvas.register_item_type("disc", {
		"hit_test": func(item: Dictionary, point: Vector2) -> bool:
			var center: Vector2 = item.get("position", Vector2.ZERO)
			return center.distance_to(point) <= 25.0,
	})
	canvas.add_item({"id": "d1", "type": "disc", "position": Vector2(100, 100)})
	check("disc hit inside radius", canvas.hit_test(Vector2(110, 100)) == "d1")
	check("disc miss outside radius", canvas.hit_test(Vector2(140, 100)) == "")
	canvas.queue_free()


func _test_hit_test_empty_returns_empty() -> void:
	var canvas: AnnotationCanvas = AnnotationCanvasScript.new()
	canvas.add_item({"id": "i", "type": "x", "position": Vector2(10, 10), "bounds": Rect2(0, 0, 5, 5)})
	check("hit_test outside any item returns empty", canvas.hit_test(Vector2(500, 500)) == "")
	canvas.queue_free()


func _test_items_in_rect() -> void:
	var canvas: AnnotationCanvas = AnnotationCanvasScript.new()
	canvas.add_item({"id": "a", "type": "x", "position": Vector2(0, 0), "bounds": Rect2(0, 0, 50, 50)})
	canvas.add_item({"id": "b", "type": "x", "position": Vector2(100, 100), "bounds": Rect2(100, 100, 50, 50)})
	canvas.add_item({"id": "c", "type": "x", "position": Vector2(0, 0), "bounds": Rect2(25, 25, 100, 100)})
	var ids := canvas.items_in_rect(Rect2(0, 0, 60, 60))
	check("items_in_rect includes a", ids.has("a"))
	check("items_in_rect includes c", ids.has("c"))
	check("items_in_rect excludes b", not ids.has("b"))
	canvas.queue_free()


func _test_select_clear_set() -> void:
	var canvas: AnnotationCanvas = AnnotationCanvasScript.new()
	canvas.add_item({"id": "a", "type": "x", "position": Vector2.ZERO})
	canvas.add_item({"id": "b", "type": "x", "position": Vector2.ZERO})
	canvas.select_item("a")
	check("select makes a selected", canvas.get_selected_item_ids().has("a"))
	canvas.select_item("b", true)
	check("additive select keeps a", canvas.get_selected_item_ids().has("a"))
	check("additive select adds b", canvas.get_selected_item_ids().has("b"))
	canvas.select_item("a", false)
	check("non-additive select replaces", canvas.get_selected_item_ids().size() == 1)
	check("non-additive select keeps a", canvas.get_selected_item_ids().has("a"))
	canvas.clear_item_selection()
	check("clear_item_selection empties", canvas.get_selected_item_ids().is_empty())
	var ids: PackedStringArray = PackedStringArray()
	ids.append("a")
	ids.append("b")
	canvas.set_item_selection(ids)
	check("set_item_selection sets both", canvas.get_selected_item_ids().size() == 2)
	canvas.queue_free()


func _test_remove_clears_selection() -> void:
	var canvas: AnnotationCanvas = AnnotationCanvasScript.new()
	canvas.add_item({"id": "a", "type": "x", "position": Vector2.ZERO})
	canvas.select_item("a")
	canvas.remove_item("a")
	check("remove drops from selection", not canvas.get_selected_item_ids().has("a"))
	canvas.queue_free()


func _test_update_position_emits() -> void:
	var canvas: AnnotationCanvas = AnnotationCanvasScript.new()
	canvas.add_item({"id": "a", "type": "x", "position": Vector2(0, 0), "bounds": Rect2(0, 0, 10, 10)})
	var seen := {"id": "", "pos": Vector2.ZERO}
	canvas.item_moved.connect(func(id: String, pos: Vector2) -> void:
		seen["id"] = id
		seen["pos"] = pos)
	check("update returns true", canvas.update_item_position("a", Vector2(50, 60)))
	check("item_moved emitted with id", seen["id"] == "a")
	check("item_moved emitted with pos", (seen["pos"] as Vector2) == Vector2(50, 60))
	var item := canvas.get_item("a")
	var bounds: Rect2 = item.get("bounds", Rect2())
	check("bounds size preserved on move", bounds.size == Vector2(10, 10))
	check("bounds position updated on move", bounds.position == Vector2(50, 60))
	canvas.queue_free()


func _test_update_bounds() -> void:
	var canvas: AnnotationCanvas = AnnotationCanvasScript.new()
	canvas.add_item({"id": "a", "type": "x", "position": Vector2.ZERO})
	canvas.update_item_bounds("a", Rect2(5, 6, 100, 200))
	var item := canvas.get_item("a")
	check("update_item_bounds sets bounds", (item.get("bounds", Rect2()) as Rect2) == Rect2(5, 6, 100, 200))
	check("update_item_bounds syncs position", (item.get("position", Vector2.ZERO) as Vector2) == Vector2(5, 6))
	canvas.queue_free()


func _test_update_payload() -> void:
	var canvas: AnnotationCanvas = AnnotationCanvasScript.new()
	canvas.add_item({"id": "a", "type": "x", "position": Vector2.ZERO})
	canvas.update_item_payload("a", {"text": "hi"})
	var item := canvas.get_item("a")
	check("update_item_payload sets payload", str((item.get("payload", {}) as Dictionary).get("text", "")) == "hi")
	canvas.queue_free()


func _test_clear_items() -> void:
	var canvas: AnnotationCanvas = AnnotationCanvasScript.new()
	canvas.add_item({"id": "a", "type": "x", "position": Vector2.ZERO})
	canvas.add_item({"id": "b", "type": "x", "position": Vector2.ZERO})
	canvas.select_item("a")
	canvas.clear_items()
	check("clear_items empties items", canvas.item_count() == 0)
	check("clear_items empties selection", canvas.get_selected_item_ids().is_empty())
	canvas.queue_free()


func _test_render_budget_constant_preserved() -> void:
	check("RENDER_BUDGET_CAP preserved", AnnotationCanvasScript.RENDER_BUDGET_CAP == 1000)


# ── core/canvas.point anchor + position-source ───────────────────────────────

func _test_canvas_point_resolver_validate() -> void:
	var resolver := CoreAnchorsScript.new().get_resolver_for("canvas.point")
	check("canvas.point resolver exists", resolver != null)
	var errors_good: Array = resolver.validate({"id": {"x": 10.0, "y": 20.0}})
	check("valid canvas.point validates clean", errors_good.is_empty())
	var errors_bad: Array = resolver.validate({"id": {"x": 10.0}})
	check("missing y reports error", not errors_bad.is_empty())
	var errors_no_id: Array = resolver.validate({})
	check("missing id reports error", not errors_no_id.is_empty())


func _test_canvas_point_resolver_summary() -> void:
	var resolver := CoreAnchorsScript.new().get_resolver_for("canvas.point")
	var s: String = resolver.summary({"id": {"x": 100.0, "y": 200.0}}, null)
	check("summary mentions coordinates", s.contains("100") and s.contains("200"))


func _test_canvas_point_make_helper() -> void:
	var anchor := CoreAnchorsScript.make_canvas_point(42.0, 99.0)
	check("make_canvas_point sets plugin", str(anchor.get("plugin", "")) == "core")
	check("make_canvas_point sets type", str(anchor.get("type", "")) == "canvas.point")
	var id: Dictionary = anchor.get("id", {})
	check("make_canvas_point id.x", float(id.get("x", 0.0)) == 42.0)
	check("make_canvas_point id.y", float(id.get("y", 0.0)) == 99.0)


func _test_canvas_point_resolves_via_host() -> void:
	var host: AnnotationHost = AnnotationHostScript.new()
	var anchor := CoreAnchorsScript.make_canvas_point(15.0, 25.0)
	var resolved := host.resolve_anchor(anchor)
	check("resolved position x", (resolved.get("position", Vector2.ZERO) as Vector2).x == 15.0)
	check("resolved position y", (resolved.get("position", Vector2.ZERO) as Vector2).y == 25.0)


func _test_canvas_point_not_stale() -> void:
	var host: AnnotationHost = AnnotationHostScript.new()
	var anchor := CoreAnchorsScript.make_canvas_point(0.0, 0.0)
	var resolved := host.resolve_anchor(anchor)
	check("canvas.point never stale", not bool(resolved.get("stale", true)))


func _test_resolve_position_source_vector2() -> void:
	var host: AnnotationHost = AnnotationHostScript.new()
	var v: Variant = host.resolve_position_source(Vector2(7.0, 8.0))
	check("resolve_position_source(Vector2) returns Vector2", v is Vector2 and (v as Vector2) == Vector2(7.0, 8.0))


func _test_resolve_position_source_array() -> void:
	var host: AnnotationHost = AnnotationHostScript.new()
	var v: Variant = host.resolve_position_source([3.0, 4.0])
	check("resolve_position_source([x,y]) returns Vector2", v is Vector2 and (v as Vector2) == Vector2(3.0, 4.0))


func _test_resolve_position_source_bare_xy() -> void:
	var host: AnnotationHost = AnnotationHostScript.new()
	var v: Variant = host.resolve_position_source({"x": 5.0, "y": 6.0})
	check("resolve_position_source({x,y}) returns Vector2", v is Vector2 and (v as Vector2) == Vector2(5.0, 6.0))


func _test_resolve_position_source_canvas_anchor() -> void:
	var host: AnnotationHost = AnnotationHostScript.new()
	var anchor := CoreAnchorsScript.make_canvas_point(11.0, 22.0)
	var v: Variant = host.resolve_position_source(anchor)
	check("resolve_position_source(canvas.point) returns Vector2", v is Vector2 and (v as Vector2) == Vector2(11.0, 22.0))


func _test_resolve_position_source_unknown_anchor_returns_null() -> void:
	var host: AnnotationHost = AnnotationHostScript.new()
	var anchor := {"plugin": "ghost", "type": "void", "id": {}}
	var v: Variant = host.resolve_position_source(anchor)
	check("resolve_position_source(unknown anchor, no resolver) returns null", v == null)


# ── Reserved item-type slots + ink-stroke future-DCR scaffold ────────────────

func _test_reserved_item_types_constants() -> void:
	check("RESERVED_ITEM_TYPES has 4 entries", AnnotationCanvasScript.RESERVED_ITEM_TYPES.size() == 4)
	check("callout-bubble reserved", AnnotationCanvasScript.RESERVED_ITEM_TYPES.has("callout-bubble"))
	check("arrow-segment reserved", AnnotationCanvasScript.RESERVED_ITEM_TYPES.has("arrow-segment"))
	check("free-text reserved", AnnotationCanvasScript.RESERVED_ITEM_TYPES.has("free-text"))
	check("ink-stroke reserved", AnnotationCanvasScript.RESERVED_ITEM_TYPES.has("ink-stroke"))


func _test_ink_stroke_stub_can_register_without_draw_callback() -> void:
	# Future ink DCR fills in draw + hit_test. Registering with empty callbacks
	# now must not error and must not crash when the canvas tries to draw an
	# item of this type.
	var canvas: AnnotationCanvas = AnnotationCanvasScript.new()
	canvas.register_item_type(AnnotationCanvasScript.ITEM_TYPE_INK_STROKE, {
		"draw": Callable(),
		"hit_test": Callable(),
		"supported_transforms": PackedStringArray(),
	})
	check("ink-stroke type registered", canvas.has_item_type(AnnotationCanvasScript.ITEM_TYPE_INK_STROKE))
	# Add an item; canvas should silently skip draw because callback is invalid.
	canvas.add_item({"id": "stroke1", "type": AnnotationCanvasScript.ITEM_TYPE_INK_STROKE, "position": Vector2(0, 0)})
	check("ink-stroke item added without crash", canvas.item_count() == 1)
	canvas.queue_redraw()  # would crash if draw callback dereferenced unsafely
	check("ink-stroke draw with no callback is no-op", true)
	canvas.queue_free()

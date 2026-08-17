class_name AnnotationCanvas
extends AnnotationOverlay
## Substrate-owned positioned-item canvas for editor annotations.
##
## Extends AnnotationOverlay (mouse-filter discipline + active-tool routing) with
## a positioned-item model. Annotation kinds register item types; the canvas owns
## items, hit-testing, z-order, selection state, and selection-handle rendering.
## Item interaction (drag, marquee) is driven by the manipulation tool — the
## canvas exposes hit_test() / select() / update_item_position() so the tool can
## call them from its handle_input callback.
##
## Items are plain Dictionaries on purpose so kinds can attach payload without
## subclassing a base item Resource. Required item fields: id, type, position.
## Optional: bounds (Rect2), z_order (int), payload (Dict).

const RENDER_BUDGET_CAP := 1000

## Reserved item-type names. Substrate ships drawing for the first three;
## INK_STROKE is reserved for a future ink DCR — registering it now with no
## draw callback is allowed (the canvas simply skips drawing) so the future
## ink work does not need to re-architect the registry.
const ITEM_TYPE_CALLOUT_BUBBLE := "callout-bubble"
const ITEM_TYPE_ARROW_SEGMENT := "arrow-segment"
const ITEM_TYPE_FREE_TEXT := "free-text"
const ITEM_TYPE_INK_STROKE := "ink-stroke"

const RESERVED_ITEM_TYPES: PackedStringArray = [
	ITEM_TYPE_CALLOUT_BUBBLE,
	ITEM_TYPE_ARROW_SEGMENT,
	ITEM_TYPE_FREE_TEXT,
	ITEM_TYPE_INK_STROKE,
]

const _SELECTION_COLOR := Color(0.4, 0.6, 1.0, 1.0)
const _HANDLE_SIZE := Vector2(6, 6)

signal item_added(item_id: String)
signal item_removed(item_id: String)
signal item_moved(item_id: String, position: Vector2)
signal item_selection_changed(item_ids: PackedStringArray)

var _item_types: Dictionary = {}
var _items: Array = []
var _selected_ids: PackedStringArray = PackedStringArray()


# ── Item-type registry ────────────────────────────────────────────────────────

## Register an item type owned by an annotation kind.
## descriptor: {
##   "draw":                Callable(canvas: AnnotationCanvas, item: Dictionary) -> void,
##   "hit_test":            Callable(item: Dictionary, point: Vector2) -> bool,  # optional; falls back to bounds
##   "supported_transforms": PackedStringArray,  # subset of ["translate", "rotate", "scale"]
## }
func register_item_type(type_name: String, descriptor: Dictionary) -> void:
	if type_name.strip_edges().is_empty():
		push_warning("[AnnotationCanvas] register_item_type: type_name required")
		return
	_item_types[type_name] = descriptor


func unregister_item_type(type_name: String) -> void:
	_item_types.erase(type_name)


func has_item_type(type_name: String) -> bool:
	return _item_types.has(type_name)


func get_item_type(type_name: String) -> Dictionary:
	var d: Variant = _item_types.get(type_name, {})
	return d if d is Dictionary else {}


# ── Item lifecycle ────────────────────────────────────────────────────────────

func add_item(item: Dictionary) -> String:
	if not item.has("id") or str(item["id"]).strip_edges().is_empty():
		push_warning("[AnnotationCanvas] add_item: id is required")
		return ""
	if not item.has("type"):
		push_warning("[AnnotationCanvas] add_item: type is required")
		return ""
	if not item.has("position"):
		push_warning("[AnnotationCanvas] add_item: position is required")
		return ""
	var entry: Dictionary = item.duplicate(true)
	if not entry.has("z_order"):
		entry["z_order"] = _next_z_order()
	if not entry.has("bounds"):
		var pos: Vector2 = _to_vec2(entry["position"])
		entry["bounds"] = Rect2(pos, Vector2.ZERO)
	_items.append(entry)
	queue_redraw()
	item_added.emit(str(entry["id"]))
	return str(entry["id"])


func remove_item(item_id: String) -> bool:
	for i in range(_items.size()):
		if str((_items[i] as Dictionary).get("id", "")) == item_id:
			_items.remove_at(i)
			if _selected_ids.has(item_id):
				_selected_ids = _filter_ids(_selected_ids, item_id)
				item_selection_changed.emit(_selected_ids.duplicate())
			queue_redraw()
			item_removed.emit(item_id)
			return true
	return false


func update_item_position(item_id: String, new_position: Vector2) -> bool:
	for item_v in _items:
		var item: Dictionary = item_v
		if str(item.get("id", "")) != item_id:
			continue
		item["position"] = new_position
		var bounds: Variant = item.get("bounds", Rect2(new_position, Vector2.ZERO))
		if bounds is Rect2:
			item["bounds"] = Rect2(new_position, (bounds as Rect2).size)
		else:
			item["bounds"] = Rect2(new_position, Vector2.ZERO)
		queue_redraw()
		item_moved.emit(item_id, new_position)
		return true
	return false


func update_item_bounds(item_id: String, bounds: Rect2) -> bool:
	for item_v in _items:
		var item: Dictionary = item_v
		if str(item.get("id", "")) != item_id:
			continue
		item["bounds"] = bounds
		item["position"] = bounds.position
		queue_redraw()
		return true
	return false


func update_item_payload(item_id: String, payload: Dictionary) -> bool:
	for item_v in _items:
		var item: Dictionary = item_v
		if str(item.get("id", "")) != item_id:
			continue
		item["payload"] = payload.duplicate(true)
		queue_redraw()
		return true
	return false


func get_item(item_id: String) -> Dictionary:
	for item_v in _items:
		var item: Dictionary = item_v
		if str(item.get("id", "")) == item_id:
			return item.duplicate(true)
	return {}


func get_items() -> Array:
	var out: Array = []
	for item_v in _items:
		out.append((item_v as Dictionary).duplicate(true))
	return out


func clear_items() -> void:
	if _items.is_empty():
		return
	_items.clear()
	if not _selected_ids.is_empty():
		_selected_ids = PackedStringArray()
		item_selection_changed.emit(_selected_ids.duplicate())
	queue_redraw()


func item_count() -> int:
	return _items.size()


# ── Z-order ───────────────────────────────────────────────────────────────────

func bring_to_front(item_id: String) -> bool:
	var max_z := _max_z_order()
	for item_v in _items:
		var item: Dictionary = item_v
		if str(item.get("id", "")) == item_id:
			item["z_order"] = max_z + 1
			queue_redraw()
			return true
	return false


func send_to_back(item_id: String) -> bool:
	var min_z := _min_z_order()
	for item_v in _items:
		var item: Dictionary = item_v
		if str(item.get("id", "")) == item_id:
			item["z_order"] = min_z - 1
			queue_redraw()
			return true
	return false


# ── Selection model ───────────────────────────────────────────────────────────

func select_item(item_id: String, additive: bool = false) -> void:
	if item_id.is_empty():
		return
	if not _has_item(item_id):
		return
	if not additive:
		_selected_ids = PackedStringArray()
	if not _selected_ids.has(item_id):
		_selected_ids.append(item_id)
	queue_redraw()
	item_selection_changed.emit(_selected_ids.duplicate())


func deselect_item(item_id: String) -> void:
	if not _selected_ids.has(item_id):
		return
	_selected_ids = _filter_ids(_selected_ids, item_id)
	queue_redraw()
	item_selection_changed.emit(_selected_ids.duplicate())


func clear_item_selection() -> void:
	if _selected_ids.is_empty():
		return
	_selected_ids = PackedStringArray()
	queue_redraw()
	item_selection_changed.emit(_selected_ids.duplicate())


func set_item_selection(item_ids: PackedStringArray) -> void:
	var filtered: PackedStringArray = PackedStringArray()
	for id in item_ids:
		if _has_item(id) and not filtered.has(id):
			filtered.append(id)
	_selected_ids = filtered
	queue_redraw()
	item_selection_changed.emit(_selected_ids.duplicate())


func get_selected_item_ids() -> PackedStringArray:
	return _selected_ids.duplicate()


# ── Hit testing ───────────────────────────────────────────────────────────────

## Returns the id of the topmost item under the point, or "" if none.
## Topmost = highest z_order. Each item type may register a custom hit_test
## callback; otherwise bounds-based hit-test applies.
func hit_test(point: Vector2) -> String:
	var sorted: Array = _items.duplicate()
	sorted.sort_custom(func(a, b): return int((a as Dictionary).get("z_order", 0)) > int((b as Dictionary).get("z_order", 0)))
	for item_v in sorted:
		var item: Dictionary = item_v
		if _hit_test_item(item, point):
			return str(item.get("id", ""))
	return ""


## Returns ids of all items whose bounds intersect the rect, in z-order asc.
func items_in_rect(rect: Rect2) -> PackedStringArray:
	var ids: PackedStringArray = PackedStringArray()
	var sorted: Array = _items.duplicate()
	sorted.sort_custom(func(a, b): return int((a as Dictionary).get("z_order", 0)) < int((b as Dictionary).get("z_order", 0)))
	for item_v in sorted:
		var item: Dictionary = item_v
		var bounds: Variant = item.get("bounds", Rect2(_to_vec2(item.get("position", Vector2.ZERO)), Vector2.ZERO))
		if bounds is Rect2 and rect.intersects(bounds):
			ids.append(str(item.get("id", "")))
	return ids


# ── Rendering ─────────────────────────────────────────────────────────────────

func _draw() -> void:
	var sorted: Array = _items.duplicate()
	sorted.sort_custom(func(a, b): return int((a as Dictionary).get("z_order", 0)) < int((b as Dictionary).get("z_order", 0)))
	for item_v in sorted:
		var item: Dictionary = item_v
		_draw_item(item)
		if _selected_ids.has(str(item.get("id", ""))):
			_draw_selection_handles(item)


func _draw_item(item: Dictionary) -> void:
	var type_name := str(item.get("type", ""))
	var descriptor: Dictionary = get_item_type(type_name)
	var draw_cb: Variant = descriptor.get("draw", null)
	if draw_cb is Callable and (draw_cb as Callable).is_valid():
		(draw_cb as Callable).call(self, item)


func _draw_selection_handles(item: Dictionary) -> void:
	var bounds: Variant = item.get("bounds", null)
	var rect: Rect2
	if bounds is Rect2 and (bounds as Rect2).size != Vector2.ZERO:
		rect = bounds
	else:
		var pos: Vector2 = _to_vec2(item.get("position", Vector2.ZERO))
		rect = Rect2(pos - Vector2(4, 4), Vector2(8, 8))
	draw_rect(rect, _SELECTION_COLOR, false, 1.5)
	var corners: Array = [
		rect.position,
		Vector2(rect.end.x, rect.position.y),
		rect.end,
		Vector2(rect.position.x, rect.end.y),
	]
	for corner_v in corners:
		var corner: Vector2 = corner_v
		draw_rect(Rect2(corner - _HANDLE_SIZE * 0.5, _HANDLE_SIZE), _SELECTION_COLOR, true)


# ── Internals ─────────────────────────────────────────────────────────────────

func _has_item(item_id: String) -> bool:
	for item_v in _items:
		if str((item_v as Dictionary).get("id", "")) == item_id:
			return true
	return false


func _hit_test_item(item: Dictionary, point: Vector2) -> bool:
	var type_name := str(item.get("type", ""))
	var descriptor: Dictionary = get_item_type(type_name)
	var hit_cb: Variant = descriptor.get("hit_test", null)
	if hit_cb is Callable and (hit_cb as Callable).is_valid():
		return bool((hit_cb as Callable).call(item, point))
	var bounds: Variant = item.get("bounds", null)
	if bounds is Rect2 and (bounds as Rect2).size != Vector2.ZERO:
		return (bounds as Rect2).has_point(point)
	return false


func _next_z_order() -> int:
	if _items.is_empty():
		return 0
	return _max_z_order() + 1


func _max_z_order() -> int:
	var z := 0
	var first := true
	for item_v in _items:
		var v := int((item_v as Dictionary).get("z_order", 0))
		if first or v > z:
			z = v
			first = false
	return z


func _min_z_order() -> int:
	var z := 0
	var first := true
	for item_v in _items:
		var v := int((item_v as Dictionary).get("z_order", 0))
		if first or v < z:
			z = v
			first = false
	return z


func _filter_ids(ids: PackedStringArray, drop_id: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for id in ids:
		if id != drop_id:
			out.append(id)
	return out


func _to_vec2(value: Variant) -> Vector2:
	if value is Vector2:
		return value
	if value is Vector3:
		return Vector2(value.x, value.y)
	if value is Array and (value as Array).size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return Vector2.ZERO

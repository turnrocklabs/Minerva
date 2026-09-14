class_name AnnotationTextBoxResize
extends RefCounted
## Box resizing changes persisted layout geometry without scaling glyphs or
## moving an arrow's endpoints and midpoint-relative caption offset.

const TextBoxLayout = preload("res://Scripts/Services/Annotations/kinds/AnnotationTextBoxLayout.gd")
const KindBase = preload("res://Scripts/Services/Annotations/AnnotationKind.gd")

static func supports(annotation: Dictionary) -> bool:
	var kind := str(annotation.get("kind", ""))
	if kind == "2d_text":
		var container := _text_container(annotation)
		return TextBoxLayout.decode_size(container.get("box_size", null)) is Vector2
	if kind == "2d_arrow":
		return not str(annotation.get("kind_payload", {}).get("label", "")).strip_edges().is_empty()
	return false

static func open_text_editor(editor: Object, host: Object, annotation: Dictionary,
		text_kind: Object, zoom: float) -> Dictionary:
	var font: float = text_kind.text_effective_font_size(annotation)
	var at: Vector2 = text_kind.editing_origin(annotation, host)
	var opened := bool(editor.open(host.transform_doc_to_screen(at), zoom, font,
		text_kind.raw_text(annotation), "Text…", Color(0, 0, 0, 0), false,
		text_kind.text_box_size(annotation), text_kind.text_rotation(annotation)))
	return {"opened": opened, "font": font, "position": at}

static func resize_handle_hit(rect: Rect2, point: Vector2, radius: float) -> bool:
	return point.distance_to(rect.end) <= radius

static func resize(annotation: Dictionary, _start_bounds: Rect2, pointer_delta: Vector2,
		horizontal_side: int, vertical_side: int) -> Dictionary:
	var kind := str(annotation.get("kind", ""))
	var desired := Vector2.ZERO
	if kind == "2d_arrow":
		var arrow_payload: Dictionary = annotation.get("kind_payload", {})
		var font := float(arrow_payload.get("label_font_size", 14.0))
		var label := str(arrow_payload.get("label", ""))
		desired = _stored_size(arrow_payload, "label_box_size",
			Vector2(maxf(label.length() * font * 0.55, font), font * 1.2))
		if horizontal_side != 0:
			desired.x = maxf(desired.x + pointer_delta.x * horizontal_side * 2.0, 0.01)
		if vertical_side != 0:
			desired.y = maxf(desired.y + pointer_delta.y * vertical_side * 2.0, 0.01)
	var out := annotation.duplicate(true)
	if kind == "2d_arrow":
		var payload: Dictionary = out.get("kind_payload", {}).duplicate(true)
		_set_size(payload, "label_box_size", str(payload.get("label", "")),
			float(payload.get("label_font_size", 14.0)), float(payload.get("scale", 1.0)), desired)
		out["kind_payload"] = payload
		return out
	var payload_v: Variant = out.get("kind_payload", {})
	if payload_v is Dictionary and (payload_v as Dictionary).has("text"):
		var payload: Dictionary = (payload_v as Dictionary).duplicate(true)
		var old_size := _stored_size(payload, "box_size", TextBoxLayout.default_size(
			float(payload.get("font_size", 14.0)), float(payload.get("scale", 1.0))))
		desired = _desired_text_size(payload, old_size, pointer_delta,
			horizontal_side, vertical_side, true)
		_set_size(payload, "box_size", str(payload.get("text", "")),
			float(payload.get("font_size", 14.0)), float(payload.get("scale", 1.0)), desired)
		out["kind_payload"] = payload
		_move_text_origin(out, old_size, _stored_size(payload, "box_size", old_size),
			horizontal_side, vertical_side, float(payload.get("rotation_rad", 0.0)))
		return out
	var primitives: Array = out.get("primitives", []).duplicate(true)
	var changed_primitive: Dictionary = {}
	var old_primitive_size := Vector2.ZERO
	for index in primitives.size():
		if primitives[index] is Dictionary and str(primitives[index].get("kind", "")) == "text":
			var primitive: Dictionary = primitives[index].duplicate(true)
			old_primitive_size = _stored_size(primitive, "box_size", TextBoxLayout.default_size(
				float(primitive.get("size", 14.0)), float(primitive.get("scale", 1.0))))
			desired = _desired_text_size(primitive, old_primitive_size, pointer_delta,
				horizontal_side, vertical_side, false)
			_set_size(primitive, "box_size", str(primitive.get("content", "")),
				float(primitive.get("size", 14.0)), float(primitive.get("scale", 1.0)), desired)
			primitives[index] = primitive
			changed_primitive = primitive
			break
	out["primitives"] = primitives
	if not changed_primitive.is_empty():
		_move_primitive_origin(out, old_primitive_size,
			_stored_size(changed_primitive, "box_size", old_primitive_size),
			horizontal_side, vertical_side, float(changed_primitive.get("rotation_rad", 0.0)))
	return out

static func _set_size(container: Dictionary, key: String, text: String, font: float,
		scale: float, desired: Vector2) -> void:
	var measured: Dictionary = TextBoxLayout.layout(text, font, scale, desired)
	var size: Vector2 = measured["size"]
	container[key] = [size.x, size.y]

static func _text_container(annotation: Dictionary) -> Dictionary:
	var payload: Variant = annotation.get("kind_payload", {})
	if payload is Dictionary and (payload as Dictionary).has("text"):
		return payload
	for primitive: Variant in annotation.get("primitives", []):
		if primitive is Dictionary and str((primitive as Dictionary).get("kind", "")) == "text":
			return primitive
	return {}

static func _stored_size(container: Dictionary, key: String, fallback: Vector2) -> Vector2:
	var raw: Variant = container.get(key, null)
	var decoded: Variant = TextBoxLayout.decode_size(raw)
	if decoded is Vector2:
		return decoded
	return fallback

static func _desired_text_size(container: Dictionary, old_size: Vector2,
		pointer_delta: Vector2, horizontal_side: int, vertical_side: int, _payload_path: bool) -> Vector2:
	var rotation := float(container.get("rotation_rad", 0.0))
	var local := Transform2D(-rotation, Vector2.ZERO) * pointer_delta
	var result := old_size
	if horizontal_side != 0:
		result.x = maxf(old_size.x + local.x * horizontal_side, 0.01)
	if vertical_side != 0:
		result.y = maxf(old_size.y + local.y * vertical_side, 0.01)
	return result

static func _origin_delta(old_size: Vector2, new_size: Vector2, horizontal_side: int,
		vertical_side: int, rotation: float) -> Vector2:
	var local := Vector2(old_size.x - new_size.x if horizontal_side < 0 else 0.0,
		old_size.y - new_size.y if vertical_side < 0 else 0.0)
	return Transform2D(rotation, Vector2.ZERO) * local

static func _move_text_origin(annotation: Dictionary, old_size: Vector2, new_size: Vector2,
		horizontal_side: int, vertical_side: int, rotation: float) -> void:
	var delta := _origin_delta(old_size, new_size, horizontal_side, vertical_side, rotation)
	if delta == Vector2.ZERO:
		return
	annotation["anchor"] = KindBase.transform_position_source(annotation.get("anchor", null),
		Transform2D(0.0, delta))

static func _move_primitive_origin(annotation: Dictionary, old_size: Vector2, new_size: Vector2,
		horizontal_side: int, vertical_side: int, rotation: float) -> void:
	var delta := _origin_delta(old_size, new_size, horizontal_side, vertical_side, rotation)
	var primitives: Array = annotation.get("primitives", []).duplicate(true)
	for index in primitives.size():
		if primitives[index] is Dictionary and str(primitives[index].get("kind", "")) == "text":
			var primitive: Dictionary = primitives[index].duplicate(true)
			var at := KindBase._to_vec2(primitive.get("at", [0, 0])) + delta
			primitive["at"] = [at.x, at.y]
			primitives[index] = primitive
			break
	annotation["primitives"] = primitives

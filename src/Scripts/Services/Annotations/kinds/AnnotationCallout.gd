class_name AnnotationCallout
extends AnnotationKind
## Built-in annotation kind: callout.
##
## Callout is generic-plus-plugin-anchor-capable: it can attach to any anchor
## type. The host owns resolution/projection for plugin anchors; this kind owns
## the default leader + label rendering and text/structured chat summary.

const _DEFAULT_OFFSET := Vector2(44.0, -28.0)
const _PADDING := Vector2(8.0, 5.0)
const _FONT_SIZE := 13


func _init() -> void:
	name = &"callout"
	display_name = "Callout"
	schema_version = 1
	owning_plugin = &"core"
	default_payload = {"text": "", "offset": [_DEFAULT_OFFSET.x, _DEFAULT_OFFSET.y], "preferred_side": "right"}
	primitives_optional = true


func accepted_anchor_types() -> Array:
	return ["*/*"]


func summary(annotation: Dictionary) -> String:
	var payload: Dictionary = annotation.get("kind_payload", {})
	var text := str(payload.get("text", annotation.get("summary", ""))).strip_edges()
	if text.is_empty():
		text = "Callout"
	var anchor: Dictionary = annotation.get("anchor", {})
	var anchor_type := "%s/%s" % [str(anchor.get("plugin", "")), str(anchor.get("type", ""))]
	return "%s [%s]" % [text, anchor_type] if not anchor_type == "/" else text


func to_chat_context(annotation: Dictionary, capabilities: Dictionary) -> Array:
	var copy := annotation.duplicate(true)
	if str(copy.get("summary", "")).is_empty():
		copy["summary"] = summary(annotation)
	return super(copy, capabilities)


func render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
	var anchor_pos := _anchor_snapshot_pos(annotation)
	var label_pos := anchor_pos + _payload_offset(annotation)
	var color := _annotation_color(annotation)
	var text := _payload_text(annotation)
	if text.is_empty():
		text = "Callout"

	ctx.draw_line(anchor_pos, label_pos, Color(color.r, color.g, color.b, 0.82), 1.25)
	ctx.draw_badge(anchor_pos)

	var label_rect := _label_rect(label_pos, text)
	ctx.draw_rect(label_rect, Color(0.05, 0.06, 0.07, 0.82), true)
	ctx.draw_rect(label_rect, color, false, 1.0)
	ctx.draw_string(null, label_pos + Vector2(_PADDING.x, _PADDING.y + _FONT_SIZE), text, Color.WHITE, _FONT_SIZE)


func render_broken(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
	ctx.is_stale = true
	var copy := annotation.duplicate(true)
	var payload: Dictionary = copy.get("kind_payload", {}).duplicate(true)
	var text := str(payload.get("text", "")).strip_edges()
	payload["text"] = "[Broken] %s" % text if not text.is_empty() else "[Broken] Callout"
	copy["kind_payload"] = payload
	render(ctx, copy)


func hit_test(annotation: Dictionary, point: Vector2, threshold: float) -> bool:
	return bounds(annotation).grow(threshold).has_point(point)


func bounds(annotation: Dictionary) -> Rect2:
	var anchor_pos := _anchor_snapshot_pos(annotation)
	var label_pos := anchor_pos + _payload_offset(annotation)
	return Rect2(anchor_pos, Vector2.ZERO).merge(_label_rect(label_pos, _payload_text(annotation)))


func primary_anchor_point(annotation: Dictionary) -> Vector2:
	return _anchor_snapshot_pos(annotation)


static func _anchor_snapshot_pos(annotation: Dictionary) -> Vector2:
	var anchor: Variant = annotation.get("anchor", {})
	if not anchor is Dictionary:
		return Vector2.ZERO
	var snapshot: Variant = (anchor as Dictionary).get("snapshot", {})
	if not snapshot is Dictionary:
		return Vector2.ZERO
	return AnnotationKind._to_vec2((snapshot as Dictionary).get("position", [0, 0]))


static func _payload_offset(annotation: Dictionary) -> Vector2:
	var payload: Variant = annotation.get("kind_payload", {})
	if payload is Dictionary:
		return AnnotationKind._to_vec2((payload as Dictionary).get("offset", [_DEFAULT_OFFSET.x, _DEFAULT_OFFSET.y]))
	return _DEFAULT_OFFSET


static func _payload_text(annotation: Dictionary) -> String:
	var payload: Variant = annotation.get("kind_payload", {})
	if payload is Dictionary:
		return str((payload as Dictionary).get("text", ""))
	return str(annotation.get("summary", ""))


static func _label_rect(position: Vector2, text: String) -> Rect2:
	var width := maxf(52.0, float(text.length()) * 7.0 + _PADDING.x * 2.0)
	var height := float(_FONT_SIZE) + _PADDING.y * 2.0 + 4.0
	return Rect2(position, Vector2(width, height))


static func _annotation_color(annotation: Dictionary) -> Color:
	var payload: Dictionary = annotation.get("payload", {})
	if payload.has("color"):
		return Color(str(payload["color"]))
	var author: Variant = annotation.get("author", "")
	if author is Dictionary:
		return AnnotationRenderContext.author_color(str((author as Dictionary).get("kind", "")))
	return AnnotationRenderContext.author_color(str(author))

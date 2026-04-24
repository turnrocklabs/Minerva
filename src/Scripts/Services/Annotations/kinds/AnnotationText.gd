class_name AnnotationText
extends AnnotationKind
## Built-in 2D annotation kind: 2d_text.
##
## Primitives: [text]
## Render:    draw_string at primitive "at" position; font size clamped so text
##            stays readable at extreme zoom levels.
## Hit-test:  point inside text AABB grown by threshold.
## Bounds:    text AABB (approximate; real font metrics require a Font resource).
##
## Design §5 / AnnotationKind contract §4.1.


func _init() -> void:
	name           = &"2d_text"
	display_name   = "Text"
	schema_version = 1
	owning_plugin  = &"core"
	default_payload = {}


# ── Required overrides ────────────────────────────────────────────────────────

func render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
	var color := _annotation_color(annotation)
	var prims: Array = annotation.get("primitives", [])
	for prim in prims:
		if prim is Dictionary and prim.get("kind", "") == "text":
			_render_text(ctx, prim, color)


func hit_test(annotation: Dictionary, point: Vector2, threshold: float) -> bool:
	var prims: Array = annotation.get("primitives", [])
	for prim in prims:
		if not (prim is Dictionary and prim.get("kind", "") == "text"):
			continue
		var r := _text_aabb(prim).grow(threshold)
		if r.has_point(point):
			return true
	return false


func bounds(annotation: Dictionary) -> Rect2:
	var prims: Array = annotation.get("primitives", [])
	var result := Rect2()
	var initialized := false
	for prim in prims:
		if not (prim is Dictionary and prim.get("kind", "") == "text"):
			continue
		var r := _text_aabb(prim)
		if not initialized:
			result = r
			initialized = true
		else:
			result = result.merge(r)
	return result


# ── Private helpers ───────────────────────────────────────────────────────────

func _render_text(ctx: AnnotationRenderContext, prim: Dictionary, color: Color) -> void:
	var at   := AnnotationKind._to_vec2(prim.get("at", [0, 0]))
	var text := str(prim.get("content", ""))
	# Clamp size so text stays legible: pixel size = primitive size * zoom, min 8, max 64.
	var base_size := float(prim.get("size", 14.0))
	var px_size   := int(clampf(base_size * ctx.zoom, 8.0, 64.0))
	ctx.draw_string(null, at, text, color, px_size)


static func _text_aabb(prim: Dictionary) -> Rect2:
	var at      := AnnotationKind._to_vec2(prim.get("at", [0, 0]))
	var content := str(prim.get("content", ""))
	# Approximate: 7px per character width, 14px height at default size.
	var base := float(prim.get("size", 14.0))
	var w    := content.length() * base * 0.55
	var h    := base * 1.2
	return Rect2(at, Vector2(w, h))


static func _annotation_color(annotation: Dictionary) -> Color:
	var payload: Dictionary = annotation.get("payload", {})
	if payload.has("color"):
		return Color(str(payload["color"]))
	return AnnotationRenderContext.author_color(annotation.get("author", ""))

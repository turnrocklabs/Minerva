class_name AnnotationPolyline
extends AnnotationKind
## Built-in 2D annotation kind: 2d_polyline.
##
## Primitives: [polyline] + optional [text]
## Render:    stroked open polyline (no auto-close); optional text label.
## Hit-test:  swept-distance to the polyline ≤ threshold; label AABB if present.
## Bounds:    AABB of all points merged with label AABB if present.
##
## Added per plan-decision §8 (enables lossless PCB annotation migration).
## Design §5 / AnnotationKind contract §4.1.

## Approximate on-screen footprint of the [text] primitive's glyph run, in SCREEN
## pixels — _render_text_label draws at a fixed pixel size, so the document-space
## extent shrinks as the view zooms in. bounds()/hit_test() convert it via
## px_to_doc_size(); only the placement point is document space.
const _TEXT_PRIMITIVE_APPROX_PX := Vector2(50.0, 12.0)


func _init() -> void:
	name           = &"2d_polyline"
	display_name   = "Polyline"
	schema_version = 1
	owning_plugin  = &"core"
	default_payload = {}
	toolbar_icon   = preload("uid://crvgt6o3lsbr1")


# ── Required overrides ────────────────────────────────────────────────────────

func render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
	var color := _annotation_color(annotation)
	var prims: Array = annotation.get("primitives", [])
	for prim in prims:
		if not prim is Dictionary:
			continue
		match prim.get("kind", ""):
			"polyline":
				_render_polyline(ctx, prim, color)
			"text":
				_render_text_label(ctx, prim, color)


func hit_test(annotation: Dictionary, point: Vector2, threshold: float) -> bool:
	var prims: Array = annotation.get("primitives", [])
	for prim in prims:
		if not prim is Dictionary:
			continue
		match prim.get("kind", ""):
			"polyline":
				var pts := _get_points(prim)
				if _near_polyline(point, pts, threshold):
					return true
			"text":
				var at := AnnotationKind._to_vec2(prim.get("at", [0, 0]))
				if Rect2(at, px_to_doc_size(_TEXT_PRIMITIVE_APPROX_PX)).grow(threshold).has_point(point):
					return true
	return false


func bounds(annotation: Dictionary) -> Rect2:
	var prims: Array = annotation.get("primitives", [])
	var result := Rect2()
	var initialized := false

	for prim in prims:
		if not prim is Dictionary:
			continue
		var r := Rect2()
		var got_r := false
		match prim.get("kind", ""):
			"polyline":
				var pts := _get_points(prim)
				if pts.size() > 0:
					r = Rect2(pts[0], Vector2.ZERO)
					for i in range(1, pts.size()):
						r = r.expand(pts[i])
					got_r = true
			"text":
				var at := AnnotationKind._to_vec2(prim.get("at", [0, 0]))
				r = Rect2(at, px_to_doc_size(_TEXT_PRIMITIVE_APPROX_PX))
				got_r = true
		if got_r:
			if not initialized:
				result = r
				initialized = true
			else:
				result = result.merge(r)

	return result


# ── Private helpers ───────────────────────────────────────────────────────────

func _render_polyline(ctx: AnnotationRenderContext, prim: Dictionary, color: Color) -> void:
	var pts := _get_points(prim)
	if pts.size() < 2:
		return
	ctx.draw_polyline(pts, color, 1.0)


func _render_text_label(ctx: AnnotationRenderContext, prim: Dictionary, color: Color) -> void:
	var at   := AnnotationKind._to_vec2(prim.get("at", [0, 0]))
	var text := str(prim.get("content", ""))
	var size := int(prim.get("size", 14))
	ctx.draw_string(null, at, text, color, size)


static func _get_points(prim: Dictionary) -> PackedVector2Array:
	var raw = prim.get("points", [])
	if not (raw is Array):
		return PackedVector2Array()
	var result := PackedVector2Array()
	for pt in (raw as Array):
		result.append(AnnotationKind._to_vec2(pt))
	return result


static func _near_polyline(point: Vector2, pts: PackedVector2Array, threshold: float) -> bool:
	for i in range(pts.size() - 1):
		if _dist_point_to_segment(point, pts[i], pts[i + 1]) <= threshold:
			return true
	return false


static func _dist_point_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab     := b - a
	var len_sq := ab.length_squared()
	if len_sq < 0.0001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	return p.distance_to(a + ab * t)


static func _annotation_color(annotation: Dictionary) -> Color:
	var payload: Dictionary = annotation.get("payload", {})
	if payload.has("color"):
		return Color(str(payload["color"]))
	return AnnotationRenderContext.author_color(annotation.get("author", ""))

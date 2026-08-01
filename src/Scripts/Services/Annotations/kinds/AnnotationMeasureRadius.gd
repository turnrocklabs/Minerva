class_name AnnotationMeasureRadius
extends AnnotationKind
## Built-in 2D annotation kind: 2d_measure_radius.
##
## Primitives: [measure_radius]  — center point + a point on the circumference.
## Render:    circle outline; radial line from center to edge; numeric label.
## Hit-test:  point near circumference (annulus test ≤ threshold); near radial
##            line; near label AABB.
## Bounds:    circle bounding rect ∪ label AABB.
##
## Design §5 / AnnotationKind contract §4.1.

const CIRCLE_SEGMENTS := 48  # polygon segment count for the circle outline

## Radius-label footprint in SCREEN pixels — the label is drawn at a fixed pixel
## size, so its document-space extent shrinks as the view zooms in.
## bounds()/hit_test() convert it via px_to_doc_size(); _label_pos is document
## space and is shared with render(), so it is left alone.
const _LABEL_BOX_PX := Vector2(60.0, 12.0)


func _init() -> void:
	name           = &"2d_measure_radius"
	display_name   = "Measure Radius"
	schema_version = 1
	owning_plugin  = &"core"
	default_payload = {}
	# TODO(019dc632a7dd7fdfb4f22974651333a9): set toolbar_icon once a radius/circle-measure icon asset is added to the repo.
	# No suitable asset found under src/assets/icons/ at time of wiring task.


# ── Required overrides ────────────────────────────────────────────────────────

func render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
	var color := _annotation_color(annotation)
	var prims: Array = annotation.get("primitives", [])
	for prim in prims:
		if prim is Dictionary and prim.get("kind", "") == "measure_radius":
			_render_measure_radius(ctx, prim, color)


func hit_test(annotation: Dictionary, point: Vector2, threshold: float) -> bool:
	var prims: Array = annotation.get("primitives", [])
	for prim in prims:
		if not (prim is Dictionary and prim.get("kind", "") == "measure_radius"):
			continue
		var center := AnnotationKind._to_vec2(prim.get("center", [0, 0]))
		var edge   := AnnotationKind._to_vec2(prim.get("edge",   [0, 0]))
		var radius := center.distance_to(edge)

		# Annulus test: near circumference.
		var dist_from_center := point.distance_to(center)
		if absf(dist_from_center - radius) <= threshold:
			return true
		# Near radial line center→edge.
		if _dist_point_to_segment(point, center, edge) <= threshold:
			return true
		# Near label.
		var label_pos := _label_pos(center, edge)
		if Rect2(label_pos, px_to_doc_size(_LABEL_BOX_PX)).grow(threshold).has_point(point):
			return true
	return false


func bounds(annotation: Dictionary) -> Rect2:
	var prims: Array = annotation.get("primitives", [])
	var result := Rect2()
	var initialized := false
	for prim in prims:
		if not (prim is Dictionary and prim.get("kind", "") == "measure_radius"):
			continue
		var center := AnnotationKind._to_vec2(prim.get("center", [0, 0]))
		var edge   := AnnotationKind._to_vec2(prim.get("edge",   [0, 0]))
		var radius := center.distance_to(edge)
		var circle_rect := Rect2(center - Vector2(radius, radius), Vector2(radius * 2, radius * 2))
		var label_rect  := Rect2(_label_pos(center, edge), px_to_doc_size(_LABEL_BOX_PX))
		var r := circle_rect.merge(label_rect)
		if not initialized:
			result = r
			initialized = true
		else:
			result = result.merge(r)
	return result


# ── Private helpers ───────────────────────────────────────────────────────────

func _render_measure_radius(ctx: AnnotationRenderContext, prim: Dictionary, color: Color) -> void:
	var center := AnnotationKind._to_vec2(prim.get("center", [0, 0]))
	var edge   := AnnotationKind._to_vec2(prim.get("edge",   [0, 0]))
	var radius := center.distance_to(edge)
	if radius < 0.0001:
		return

	# Circle outline.
	var circle_pts := PackedVector2Array()
	for i in (CIRCLE_SEGMENTS + 1):
		var theta := (float(i) / float(CIRCLE_SEGMENTS)) * TAU
		circle_pts.append(center + Vector2(cos(theta), sin(theta)) * radius)
	ctx.draw_polyline(circle_pts, color, 1.0)

	# Radial line.
	ctx.draw_line(center, edge, color, 1.0)

	# Label.
	var unit  := ctx.effective_unit(prim)
	var label := "r=%.2f %s" % [radius, unit]
	ctx.draw_string(null, _label_pos(center, edge), label, color, 12)


static func _label_pos(center: Vector2, edge: Vector2) -> Vector2:
	# Place label just past the edge point along the center→edge direction.
	if center.distance_to(edge) < 0.001:
		return center + Vector2(4, -12)
	var dir := (edge - center).normalized()
	return edge + dir * 6.0 + Vector2(0, -8)


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

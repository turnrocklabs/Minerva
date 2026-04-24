class_name AnnotationRegion
extends AnnotationKind
## Built-in 2D annotation kind: 2d_region.
##
## Primitives: [region] (closed polygon; rect is a 4-point special case)
## Render:    stroked polygon; low-alpha fill when primitive "filled" is true.
## Hit-test:  point-in-polygon (even-odd rule) OR within threshold of any edge.
## Bounds:    AABB of polygon vertices.
##
## Design §5 / AnnotationKind contract §4.1.

const FILL_ALPHA := 0.18


func _init() -> void:
	name           = &"2d_region"
	display_name   = "Region"
	schema_version = 1
	owning_plugin  = &"core"
	default_payload = {"filled": false}


# ── Required overrides ────────────────────────────────────────────────────────

func render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
	var color := _annotation_color(annotation)
	var prims: Array = annotation.get("primitives", [])
	for prim in prims:
		if prim is Dictionary and prim.get("kind", "") == "region":
			_render_region(ctx, prim, color)


func hit_test(annotation: Dictionary, point: Vector2, threshold: float) -> bool:
	var prims: Array = annotation.get("primitives", [])
	for prim in prims:
		if not (prim is Dictionary and prim.get("kind", "") == "region"):
			continue
		var pts := _get_points(prim)
		if pts.size() < 3:
			continue
		# Edge distance check (fat outline).
		if _near_polygon_edge(point, pts, threshold):
			return true
		# Point-in-polygon even-odd rule.
		if _point_in_polygon(point, pts):
			return true
	return false


func bounds(annotation: Dictionary) -> Rect2:
	var prims: Array = annotation.get("primitives", [])
	var result := Rect2()
	var initialized := false
	for prim in prims:
		if not (prim is Dictionary and prim.get("kind", "") == "region"):
			continue
		var pts := _get_points(prim)
		if pts.size() == 0:
			continue
		var r := Rect2(pts[0], Vector2.ZERO)
		for i in range(1, pts.size()):
			r = r.expand(pts[i])
		if not initialized:
			result = r
			initialized = true
		else:
			result = result.merge(r)
	return result


# ── Private helpers ───────────────────────────────────────────────────────────

func _render_region(ctx: AnnotationRenderContext, prim: Dictionary, color: Color) -> void:
	var pts := _get_points(prim)
	if pts.size() < 3:
		return
	var filled: bool = prim.get("filled", false)
	if filled:
		var fill_color := Color(color.r, color.g, color.b, FILL_ALPHA)
		var cols := PackedColorArray()
		cols.resize(pts.size())
		cols.fill(fill_color)
		ctx.draw_polygon(pts, cols)
	# Always draw the stroke.
	var closed_pts := PackedVector2Array(pts)
	closed_pts.append(pts[0])  # close the polygon
	ctx.draw_polyline(closed_pts, color, 1.0)


static func _get_points(prim: Dictionary) -> PackedVector2Array:
	var raw = prim.get("points", [])
	if not raw is Array:
		return PackedVector2Array()
	var result := PackedVector2Array()
	for pt in (raw as Array):
		result.append(AnnotationKind._to_vec2(pt))
	return result


static func _near_polygon_edge(point: Vector2, pts: PackedVector2Array, threshold: float) -> bool:
	var n := pts.size()
	for i in n:
		var a := pts[i]
		var b := pts[(i + 1) % n]
		if _dist_point_to_segment(point, a, b) <= threshold:
			return true
	return false


static func _point_in_polygon(point: Vector2, pts: PackedVector2Array) -> bool:
	# Even-odd ray casting.
	var inside := false
	var n := pts.size()
	var j := n - 1
	for i in n:
		var xi := pts[i].x
		var yi := pts[i].y
		var xj := pts[j].x
		var yj := pts[j].y
		if ((yi > point.y) != (yj > point.y)) and \
		   (point.x < (xj - xi) * (point.y - yi) / (yj - yi) + xi):
			inside = not inside
		j = i
	return inside


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

class_name AnnotationMeasureAngle
extends AnnotationKind
## Built-in 2D annotation kind: 2d_measure_angle.
##
## Primitives: [measure_angle]  — three points a, b, c; angle measured at vertex b.
## Render:    two rays b→a and b→c; arc sweep between the rays; numeric label
##            inside the arc (angle in degrees, or radians when ctx.unit == "rad").
## Hit-test:  point near either ray segment, arc, or label AABB.
## Bounds:    three-point AABB grown by arc radius plus a label margin.
##
## Design §5 / AnnotationKind contract §4.1.

const ARC_SEGMENTS := 24   # polygon segments used to approximate the arc
const ARC_RADIUS_FACTOR := 0.25  # arc drawn at 25 % of the shorter arm length

## Angle-label footprint in SCREEN pixels (the label is drawn at a fixed pixel
## size), and the matching bounds margin. bounds()/hit_test() convert both via
## px_to_doc*(); the arc radius itself is already document space.
const _LABEL_BOX_PX := Vector2(40.0, 16.0)
const _LABEL_MARGIN_PX := 20.0


func _init() -> void:
	name           = &"2d_measure_angle"
	display_name   = "Measure Angle"
	schema_version = 1
	owning_plugin  = &"core"
	default_payload = {}
	# TODO(019dc632a7dd7fdfb4f22974651333a9): set toolbar_icon once a protractor/measure-angle icon asset is added to the repo.
	# No suitable asset found under src/assets/icons/ at time of wiring task.


# ── Required overrides ────────────────────────────────────────────────────────

func render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
	var color := _annotation_color(annotation)
	var prims: Array = annotation.get("primitives", [])
	for prim in prims:
		if prim is Dictionary and prim.get("kind", "") == "measure_angle":
			_render_measure_angle(ctx, prim, color)


func hit_test(annotation: Dictionary, point: Vector2, threshold: float) -> bool:
	var prims: Array = annotation.get("primitives", [])
	for prim in prims:
		if not (prim is Dictionary and prim.get("kind", "") == "measure_angle"):
			continue
		var a := AnnotationKind._to_vec2(prim.get("a", [0, 0]))
		var b := AnnotationKind._to_vec2(prim.get("b", [0, 0]))
		var c := AnnotationKind._to_vec2(prim.get("c", [0, 0]))
		# Near ray b→a or b→c.
		if _dist_point_to_segment(point, b, a) <= threshold:
			return true
		if _dist_point_to_segment(point, b, c) <= threshold:
			return true
		# Near arc (check label region as approximation).
		var arc_r := _arc_radius(a, b, c)
		var label_pos := _label_pos(a, b, c, arc_r)
		var label_box := px_to_doc_size(_LABEL_BOX_PX)
		if Rect2(label_pos - label_box * 0.5, label_box).grow(threshold).has_point(point):
			return true
	return false


func bounds(annotation: Dictionary) -> Rect2:
	var prims: Array = annotation.get("primitives", [])
	var result := Rect2()
	var initialized := false
	for prim in prims:
		if not (prim is Dictionary and prim.get("kind", "") == "measure_angle"):
			continue
		var a := AnnotationKind._to_vec2(prim.get("a", [0, 0]))
		var b := AnnotationKind._to_vec2(prim.get("b", [0, 0]))
		var c := AnnotationKind._to_vec2(prim.get("c", [0, 0]))
		var arc_r := _arc_radius(a, b, c)
		# Three-point AABB grown by arc radius (document units) + a small label
		# margin (SCREEN pixels — the label is drawn at a fixed pixel size).
		var r := Rect2(a, Vector2.ZERO).expand(b).expand(c).grow(arc_r + px_to_doc(_LABEL_MARGIN_PX))
		if not initialized:
			result = r
			initialized = true
		else:
			result = result.merge(r)
	return result


# ── Private helpers ───────────────────────────────────────────────────────────

func _render_measure_angle(ctx: AnnotationRenderContext, prim: Dictionary, color: Color) -> void:
	var a := AnnotationKind._to_vec2(prim.get("a", [0, 0]))
	var b := AnnotationKind._to_vec2(prim.get("b", [0, 0]))
	var c := AnnotationKind._to_vec2(prim.get("c", [0, 0]))

	# Draw the two rays (arms).
	ctx.draw_line(b, a, color, 1.0)
	ctx.draw_line(b, c, color, 1.0)

	# Compute arc.
	var arc_r := _arc_radius(a, b, c)
	var angle_a := (a - b).angle()
	var angle_c := (c - b).angle()

	# Build arc polyline (open, no fill) using ARC_SEGMENTS steps.
	var arc_pts := PackedVector2Array()
	# Sweep from angle_a to angle_c in the shorter direction.
	var sweep := _short_sweep(angle_a, angle_c)
	for i in (ARC_SEGMENTS + 1):
		var t := float(i) / float(ARC_SEGMENTS)
		var theta := angle_a + sweep * t
		arc_pts.append(b + Vector2(cos(theta), sin(theta)) * arc_r)
	ctx.draw_polyline(arc_pts, color, 1.0)

	# Label: show angle in degrees (or rad if ctx.unit == "rad").
	var angle_rad := absf(sweep)
	var unit      := ctx.effective_unit(prim)
	var label: String
	if unit == "rad":
		label = "%.3f rad" % angle_rad
	else:
		label = "%.1f°" % rad_to_deg(angle_rad)
	ctx.draw_string(null, _label_pos(a, b, c, arc_r), label, color, 12)


static func _arc_radius(a: Vector2, b: Vector2, c: Vector2) -> float:
	var la := b.distance_to(a)
	var lc := b.distance_to(c)
	return maxf(minf(la, lc) * ARC_RADIUS_FACTOR, 4.0)


static func _short_sweep(from_angle: float, to_angle: float) -> float:
	var diff := fmod(to_angle - from_angle, TAU)
	# Bring into [-PI, PI]
	if diff > PI:
		diff -= TAU
	elif diff < -PI:
		diff += TAU
	return diff


static func _label_pos(a: Vector2, b: Vector2, c: Vector2, arc_r: float) -> Vector2:
	# Place label midway along the arc sweep, slightly beyond the arc radius.
	var angle_a := (a - b).angle()
	var angle_c := (c - b).angle()
	var mid_angle := angle_a + _short_sweep(angle_a, angle_c) * 0.5
	return b + Vector2(cos(mid_angle), sin(mid_angle)) * (arc_r * 1.4)


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

class_name AnnotationMeasureDistance
extends AnnotationKind
## Built-in 2D annotation kind: 2d_measure_distance.
##
## Primitives: [measure_distance] + optional [text]
## Render:    dimension line between "from" and "to" with perpendicular end ticks;
##            midpoint label showing computed distance (formatted with unit).
##            If a [text] primitive is also present, it overrides the auto-label.
## Hit-test:  distance-to-segment ≤ threshold; label AABB.
## Bounds:    endpoints ∪ label AABB.
##
## Units (design §5): ctx.unit is the display unit. Numeric values are unchanged;
## only the label string uses the unit. Per-primitive "unit" field overrides ctx.unit.
##
## Design §5 / AnnotationKind contract §4.1.

const TICK_SIZE := 4.0  # screen-space perpendicular tick half-length

## Approximate on-screen footprint of the [text] primitive's glyph run, in SCREEN
## pixels — _render_text_label draws at a fixed pixel size, so the document-space
## extent shrinks as the view zooms in. bounds()/hit_test() convert it via
## px_to_doc_size(); only the placement point is document space.
const _TEXT_PRIMITIVE_APPROX_PX := Vector2(60.0, 12.0)


func _init() -> void:
	name           = &"2d_measure_distance"
	display_name   = "Measure Distance"
	schema_version = 1
	owning_plugin  = &"core"
	default_payload = {}
	# TODO(019dc632a7dd7fdfb4f22974651333a9): set toolbar_icon once a ruler/measure-distance icon asset is added to the repo.
	# No suitable asset found under src/assets/icons/ at time of wiring task.


# ── Required overrides ────────────────────────────────────────────────────────

func render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
	var color := _annotation_color(annotation)
	var prims: Array = annotation.get("primitives", [])
	var has_text_override := false

	for prim in prims:
		if prim is Dictionary and prim.get("kind", "") == "text":
			has_text_override = true
			break

	for prim in prims:
		if not prim is Dictionary:
			continue
		match prim.get("kind", ""):
			"measure_distance":
				_render_measure_distance(ctx, prim, color, has_text_override)
			"text":
				_render_text_label(ctx, prim, color)


func hit_test(annotation: Dictionary, point: Vector2, threshold: float) -> bool:
	var prims: Array = annotation.get("primitives", [])
	for prim in prims:
		if not prim is Dictionary:
			continue
		match prim.get("kind", ""):
			"measure_distance":
				var a := AnnotationKind._to_vec2(prim.get("from", [0, 0]))
				var b := AnnotationKind._to_vec2(prim.get("to",   [0, 0]))
				if _dist_point_to_segment(point, a, b) <= threshold:
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
			"measure_distance":
				var a := AnnotationKind._to_vec2(prim.get("from", [0, 0]))
				var b := AnnotationKind._to_vec2(prim.get("to",   [0, 0]))
				# TICK_SIZE is screen pixels — _render_measure_distance divides it
				# by ctx.zoom for exactly this reason. Growing the AABB by the raw
				# value inflated it by 4 MILLIMETRES per side on the PCB canvas.
				r = Rect2(a, Vector2.ZERO).expand(b).grow(px_to_doc(TICK_SIZE))
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

func _render_measure_distance(
	ctx: AnnotationRenderContext,
	prim: Dictionary,
	color: Color,
	skip_label: bool
) -> void:
	var a := AnnotationKind._to_vec2(prim.get("from", [0, 0]))
	var b := AnnotationKind._to_vec2(prim.get("to",   [0, 0]))
	ctx.draw_line(a, b, color, 1.0)

	# End ticks perpendicular to the line.
	if a.distance_to(b) > 0.001:
		var dir  := (b - a).normalized()
		var perp := Vector2(-dir.y, dir.x)
		# Draw ticks in document space; TICK_SIZE is meant as screen pixels, so scale by zoom.
		var tick := perp * (TICK_SIZE / maxf(ctx.zoom, 0.01))
		ctx.draw_line(a - tick, a + tick, color, 1.0)
		ctx.draw_line(b - tick, b + tick, color, 1.0)

	if skip_label:
		return

	# Auto-computed midpoint label.
	var dist    := a.distance_to(b)
	var unit    := ctx.effective_unit(prim)
	var label   := "%.2f %s" % [dist, unit]
	var mid     := (a + b) * 0.5
	ctx.draw_string(null, mid, label, color, 12)


func _render_text_label(ctx: AnnotationRenderContext, prim: Dictionary, color: Color) -> void:
	var at   := AnnotationKind._to_vec2(prim.get("at", [0, 0]))
	var text := str(prim.get("content", ""))
	var size := int(prim.get("size", 12))
	ctx.draw_string(null, at, text, color, size)


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

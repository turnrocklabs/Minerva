class_name AnnotationArrow
extends AnnotationKind
## Built-in 2D annotation kind: 2d_arrow.
##
## Primitives: [arrow] or [arrow, text]
## Render:    line + filled triangle head at "to"; optional text label near midpoint.
## Hit-test:  distance-to-segment ≤ threshold, plus label AABB if present.
## Bounds:    AABB of endpoints grown by head_size, merged with label AABB if present.
##
## Design §5 / AnnotationKind contract §4.1.


func _init() -> void:
	name           = &"2d_arrow"
	display_name   = "Arrow"
	schema_version = 1
	owning_plugin  = &"core"
	default_payload = {}


# ── Required overrides ────────────────────────────────────────────────────────

func render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
	var color := _annotation_color(annotation)
	var prims: Array = annotation.get("primitives", [])

	for prim in prims:
		if not prim is Dictionary:
			continue
		match prim.get("kind", ""):
			"arrow":
				_render_arrow(ctx, prim, color)
			"text":
				_render_text_label(ctx, prim, color)


func hit_test(annotation: Dictionary, point: Vector2, threshold: float) -> bool:
	var prims: Array = annotation.get("primitives", [])
	for prim in prims:
		if not prim is Dictionary:
			continue
		match prim.get("kind", ""):
			"arrow":
				var a := AnnotationKind._to_vec2(prim.get("from", [0, 0]))
				var b := AnnotationKind._to_vec2(prim.get("to",   [0, 0]))
				if _dist_point_to_segment(point, a, b) <= threshold:
					return true
			"text":
				var at := AnnotationKind._to_vec2(prim.get("at", [0, 0]))
				var approx := Rect2(at, Vector2(50, 12)).grow(threshold)
				if approx.has_point(point):
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
		match prim.get("kind", ""):
			"arrow":
				var a := AnnotationKind._to_vec2(prim.get("from", [0, 0]))
				var b := AnnotationKind._to_vec2(prim.get("to",   [0, 0]))
				var head := float(prim.get("head_size", 1.5))
				r = Rect2(a, Vector2.ZERO).expand(b).grow(head)
			"text":
				var at := AnnotationKind._to_vec2(prim.get("at", [0, 0]))
				r = Rect2(at, Vector2(50, 12))
			_:
				continue
		if not initialized:
			result = r
			initialized = true
		else:
			result = result.merge(r)

	return result


# ── Private rendering helpers ─────────────────────────────────────────────────

func _render_arrow(ctx: AnnotationRenderContext, prim: Dictionary, color: Color) -> void:
	var a := AnnotationKind._to_vec2(prim.get("from", [0, 0]))
	var b := AnnotationKind._to_vec2(prim.get("to",   [0, 0]))
	var raw_head := float(prim.get("head_size", 1.5))
	# Floor zoom so head_size doesn't vanish at very low zoom.
	var head := raw_head * maxf(floor(ctx.zoom), 1.0)

	ctx.draw_line(a, b, color, 1.0)

	# Triangle arrowhead pointing from a→b.
	if a.distance_to(b) < 0.001:
		return
	var dir := (b - a).normalized()
	var perp := Vector2(-dir.y, dir.x)
	var tip   := b
	var base1 := b - dir * head + perp * (head * 0.4)
	var base2 := b - dir * head - perp * (head * 0.4)
	var pts   := PackedVector2Array([tip, base1, base2])
	var cols  := PackedColorArray([color, color, color])
	ctx.draw_polygon(pts, cols)


func _render_text_label(ctx: AnnotationRenderContext, prim: Dictionary, color: Color) -> void:
	var at   := AnnotationKind._to_vec2(prim.get("at", [0, 0]))
	var text := str(prim.get("content", ""))
	var size := int(prim.get("size", 14))
	ctx.draw_string(null, at, text, color, size)


# ── Shared helpers ────────────────────────────────────────────────────────────

static func _annotation_color(annotation: Dictionary) -> Color:
	var payload: Dictionary = annotation.get("payload", {})
	if payload.has("color"):
		return Color(str(payload["color"]))
	return AnnotationRenderContext.author_color(annotation.get("author", ""))


static func _dist_point_to_segment(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var len_sq := ab.length_squared()
	if len_sq < 0.0001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / len_sq, 0.0, 1.0)
	var closest := a + ab * t
	return p.distance_to(closest)

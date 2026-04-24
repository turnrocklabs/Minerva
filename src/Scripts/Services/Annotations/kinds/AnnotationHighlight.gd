class_name AnnotationHighlight
extends AnnotationKind
## Built-in 2D annotation kind: 2d_highlight.
##
## Primitives: [highlight]  — rectangular color wash over a document region.
## Render:    low-alpha filled rect; no stroke.
## Hit-test:  point in rect grown by threshold.
## Bounds:    the primitive rect itself.
##
## Design §5 / AnnotationKind contract §4.1.

const FILL_ALPHA := 0.30


func _init() -> void:
	name           = &"2d_highlight"
	display_name   = "Highlight"
	schema_version = 1
	owning_plugin  = &"core"
	default_payload = {}


# ── Required overrides ────────────────────────────────────────────────────────

func render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
	var color := _annotation_color(annotation)
	var fill_color := Color(color.r, color.g, color.b, FILL_ALPHA)
	var prims: Array = annotation.get("primitives", [])
	for prim in prims:
		if prim is Dictionary and prim.get("kind", "") == "highlight":
			var r := _prim_rect(prim)
			if r.size != Vector2.ZERO or r.position != Vector2.ZERO:
				ctx.draw_rect(r, fill_color, true)


func hit_test(annotation: Dictionary, point: Vector2, threshold: float) -> bool:
	var prims: Array = annotation.get("primitives", [])
	for prim in prims:
		if prim is Dictionary and prim.get("kind", "") == "highlight":
			if _prim_rect(prim).grow(threshold).has_point(point):
				return true
	return false


func bounds(annotation: Dictionary) -> Rect2:
	var prims: Array = annotation.get("primitives", [])
	var result := Rect2()
	var initialized := false
	for prim in prims:
		if not (prim is Dictionary and prim.get("kind", "") == "highlight"):
			continue
		var r := _prim_rect(prim)
		if not initialized:
			result = r
			initialized = true
		else:
			result = result.merge(r)
	return result


# ── Private helpers ───────────────────────────────────────────────────────────

static func _prim_rect(prim: Dictionary) -> Rect2:
	var raw = prim.get("rect", [0, 0, 0, 0])
	if (raw is Array) and (raw as Array).size() == 4:
		return Rect2(float(raw[0]), float(raw[1]), float(raw[2]), float(raw[3]))
	return Rect2()


static func _annotation_color(annotation: Dictionary) -> Color:
	var payload: Dictionary = annotation.get("payload", {})
	if payload.has("color"):
		return Color(str(payload["color"]))
	return AnnotationRenderContext.author_color(annotation.get("author", ""))

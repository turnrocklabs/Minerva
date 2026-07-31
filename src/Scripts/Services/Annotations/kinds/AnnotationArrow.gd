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

## Default arrowhead size in SCREEN pixels (a payload "head_size" overrides).
## Shared with AnnotationArrowAuthorTool's preview so the authoring glyph is
## the same size the committed render will be.
const DEFAULT_HEAD_SIZE_PX := 12.0


func _init() -> void:
	name           = &"2d_arrow"
	display_name   = "Arrow"
	schema_version = 1
	owning_plugin  = &"core"
	default_payload = {}
	toolbar_icon   = preload("uid://cln205u37w7n0")


# ── Authoring ─────────────────────────────────────────────────────────────────

## Returns a fresh AnnotationArrowAuthorTool instance.
##
## Each call returns a NEW instance so the toolbar can deactivate-then-reactivate
## without state leak. The toolbar calls author_ui() once per activation; the
## previous instance is dropped on the floor (RefCounted) once the toolbar lets
## it go.
func author_ui() -> Object:
	return AnnotationArrowAuthorTool.new()


# ── Optional overrides ────────────────────────────────────────────────────────

func summary(annotation: Dictionary) -> String:
	# Find the arrow primitive (skip text labels)
	var prims: Array = annotation.get("primitives", [])
	for prim in prims:
		if prim is Dictionary and prim.get("kind", "") == "arrow":
			var a := AnnotationKind._to_vec2(prim.get("from", [0, 0]))
			var b := AnnotationKind._to_vec2(prim.get("to", [0, 0]))
			var anchor := AnnotationSchema.get_anchored_to(annotation)
			var base := "arrow from (%.0f, %.0f) to (%.0f, %.0f)" % [a.x, a.y, b.x, b.y]
			if not anchor.is_empty():
				return "%s → %s" % [base, anchor]
			return base
	return super(annotation)  # fall through to default


# ── Required overrides ────────────────────────────────────────────────────────

## Arrow's canonical anchor is the head (the point being indicated).
func primary_anchor_point(annotation: Dictionary) -> Vector2:
	var payload: Variant = annotation.get("kind_payload", {})
	if payload is Dictionary and (payload as Dictionary).has("endpoint_b"):
		var endpoint_b: Variant = _resolve_endpoint(null, (payload as Dictionary).get("endpoint_b", null))
		if endpoint_b is Vector2:
			return endpoint_b
	var prims: Array = annotation.get("primitives", [])
	for prim in prims:
		if prim is Dictionary and prim.get("kind", "") == "arrow":
			return AnnotationKind._to_vec2(prim.get("to", [0, 0]))
	return super(annotation)


## Projection distance used when the head lands in empty space.
const _PROJECTION_DISTANCE: float = 32.0

## Override: try head first; if that misses, project 32px past the tip along the
## arrow direction and try again. Captures arrows whose head is drawn just off a
## widget — the projection often lands on the widget the arrow is pointing at.
func describe_target_point(annotation: Dictionary, base_pos: Vector2, host: AnnotationHost) -> String:
	if host == null:
		return ""

	# First: try the head position directly.
	var result: String = host.describe_point(base_pos)
	if not result.is_empty():
		return result

	# Second: compute direction (head - tail) and project forward by _PROJECTION_DISTANCE.
	var endpoints := _resolve_payload_endpoints(null, annotation)
	if not endpoints.is_empty():
		var payload_head: Vector2 = endpoints[1]
		var payload_tail: Vector2 = endpoints[0]
		var payload_direction: Vector2 = payload_head - payload_tail
		if payload_direction.length() < 0.001:
			return result
		payload_direction = payload_direction.normalized()
		return host.describe_point(payload_head + payload_direction * _PROJECTION_DISTANCE)

	var prims: Array = annotation.get("primitives", [])
	var first_arrow_prim: Dictionary = {}
	for prim in prims:
		if prim is Dictionary and prim.get("kind", "") == "arrow":
			first_arrow_prim = prim as Dictionary
			break

	if first_arrow_prim.is_empty():
		return result  # no arrow prim found; return whatever we got (empty)

	var head: Vector2 = base_pos
	var tail: Vector2 = AnnotationKind._to_vec2(first_arrow_prim.get("from", [0, 0]))
	var direction: Vector2 = head - tail
	# Guard against zero-length arrows — skip projection if nearly coincident.
	if direction.length() < 0.001:
		return result

	direction = direction.normalized()
	var projected: Vector2 = head + direction * _PROJECTION_DISTANCE
	return host.describe_point(projected)


func transform_annotation(annotation: Dictionary, transform: Transform2D, operation: String = "") -> Dictionary:
	var out: Dictionary = super(annotation, transform, operation)
	var payload_v: Variant = out.get("kind_payload", {})
	if not payload_v is Dictionary:
		return out
	var payload: Dictionary = (payload_v as Dictionary).duplicate(true)
	var changed := false
	if payload.has("endpoint_a"):
		payload["endpoint_a"] = AnnotationKind.transform_position_source(payload.get("endpoint_a", null), transform)
		changed = true
	if payload.has("endpoint_b"):
		payload["endpoint_b"] = AnnotationKind.transform_position_source(payload.get("endpoint_b", null), transform)
		changed = true
	if changed and operation == "scale":
		var scale_delta := AnnotationKind.transform_uniform_scale_delta(transform)
		if absf(scale_delta - 1.0) > 0.0001:
			payload["head_size"] = float(payload.get("head_size", 12.0)) * scale_delta
	if changed:
		out["kind_payload"] = payload
	return out


func render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
	var color := _annotation_color(annotation)

	# Anchor-aware payload path (Round 2: overlay-canvas DCR). When the
	# annotation carries kind_payload.endpoint_a/endpoint_b, resolve each via
	# ctx.host.resolve_position_source so the arrow can terminate on host
	# anchors (text.range, cad/edge.point, pcb/trace.point, …) or on free
	# canvas points uniformly.
	var endpoints: Array = _resolve_payload_endpoints(ctx, annotation)
	if not endpoints.is_empty():
		var head_size := float(annotation.get("kind_payload", {}).get("head_size", 12.0))
		_render_arrow_segment(ctx, endpoints[0], endpoints[1], color, head_size, _payload_head_style(annotation))
		return

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
	# Payload-endpoint path: hit-test against the resolved segment.
	var endpoints: Array = _resolve_payload_endpoints(null, annotation)
	if not endpoints.is_empty():
		return _dist_point_to_segment(point, endpoints[0], endpoints[1]) <= threshold

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
	var endpoints: Array = _resolve_payload_endpoints(null, annotation)
	if not endpoints.is_empty():
		var head := float(annotation.get("kind_payload", {}).get("head_size", 12.0))
		return Rect2(endpoints[0], Vector2.ZERO).expand(endpoints[1]).grow(head)

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
				var head := float(prim.get("head_size", 12.0))
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


# ── Anchor-aware endpoint resolution (Round 2 overlay-canvas DCR) ────────────

## Resolve the two endpoints from kind_payload.endpoint_a/endpoint_b. Each may
## be an anchor envelope or a {x, y} canvas point; resolution is delegated to
## ctx.host.resolve_position_source. Returns [Vector2, Vector2] on success or
## [] when the annotation is not in payload-endpoint mode (legacy primitives
## path) or when either endpoint cannot be resolved.
##
## ctx may be null for hit-test/bounds calls that have no render context. In
## that case we still try to resolve via inline {x,y} payloads but anchor-based
## sources will return null and we fall back to the snapshot.position on the
## anchor envelope so bounds/hit-test remain stable for stale data.
func _resolve_payload_endpoints(ctx: AnnotationRenderContext, annotation: Dictionary) -> Array:
	var payload: Variant = annotation.get("kind_payload", {})
	if not payload is Dictionary:
		return []
	var p: Dictionary = payload
	if not (p.has("endpoint_a") and p.has("endpoint_b")):
		return []
	var pos_a: Variant = _resolve_endpoint(ctx, p.get("endpoint_a", null))
	var pos_b: Variant = _resolve_endpoint(ctx, p.get("endpoint_b", null))
	if pos_a == null or pos_b == null:
		return []
	return [pos_a, pos_b]


func _resolve_endpoint(ctx: AnnotationRenderContext, source: Variant) -> Variant:
	# Inline points work without a host.
	if source is Vector2:
		return source
	if source is Array and (source as Array).size() >= 2:
		return Vector2(float((source as Array)[0]), float((source as Array)[1]))
	if source is Dictionary:
		var d: Dictionary = source
		if d.has("x") and d.has("y") and not d.has("plugin"):
			return Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
		# Anchor envelope — defer to host. If no host context (hit-test/bounds
		# called outside a render pass), fall back to anchor.snapshot.position.
		if ctx != null and ctx.host != null and ctx.host.has_method("resolve_position_source"):
			return ctx.host.resolve_position_source(d)
		var snapshot: Variant = d.get("snapshot", {})
		if snapshot is Dictionary and (snapshot as Dictionary).has("position"):
			return AnnotationKind._to_vec2((snapshot as Dictionary).get("position"))
	return null


func _payload_head_style(annotation: Dictionary) -> String:
	var payload: Variant = annotation.get("kind_payload", {})
	if payload is Dictionary:
		return str((payload as Dictionary).get("head_style", "single"))
	return "single"


func _render_arrow_segment(
	ctx: AnnotationRenderContext,
	a: Vector2,
	b: Vector2,
	color: Color,
	head_size: float,
	head_style: String,
) -> void:
	ctx.draw_line(a, b, color, 1.0)
	if a.distance_to(b) < 0.001 or head_style == "none":
		return
	# head_size is intended SCREEN pixels. Geometry here is in DOC units and
	# ctx.draw_polygon applies the doc→screen transform (× zoom), so divide by
	# zoom for a constant on-screen head (same pattern as MeasureDistance's
	# TICK_SIZE). The old `* floor(zoom)` double-scaled: screen size grew as
	# zoom², turning the head into a board-sized triangle on mm-unit canvases
	# (PCB at 4–10 px/mm) while looking fine at the text editor's zoom 1.
	var head := head_size / maxf(ctx.zoom, 0.01)
	draw_arrowhead(ctx, a, b, head, color)
	if head_style == "double":
		draw_arrowhead(ctx, b, a, head, color)


## Filled triangle head at `tip`, pointing tail→tip. Geometry is DOC units;
## `head` must already be zoom-compensated (see _render_arrow_segment).
## STATIC and public on purpose (work item 019fb582a283):
## AnnotationArrowAuthorTool draws this same glyph in its authoring preview —
## one head shape, defined once. Degenerate direction draws nothing.
static func draw_arrowhead(ctx: AnnotationRenderContext, tail: Vector2, tip: Vector2, head: float, color: Color) -> void:
	var dir := (tip - tail).normalized()
	if dir == Vector2.ZERO:
		return
	var perp := Vector2(-dir.y, dir.x)
	var base1 := tip - dir * head + perp * (head * 0.4)
	var base2 := tip - dir * head - perp * (head * 0.4)
	var pts := PackedVector2Array([tip, base1, base2])
	var cols := PackedColorArray([color, color, color])
	ctx.draw_polygon(pts, cols)


# ── Private rendering helpers ─────────────────────────────────────────────────

func _render_arrow(ctx: AnnotationRenderContext, prim: Dictionary, color: Color) -> void:
	var a := AnnotationKind._to_vec2(prim.get("from", [0, 0]))
	var b := AnnotationKind._to_vec2(prim.get("to",   [0, 0]))
	var raw_head := float(prim.get("head_size", 12.0))
	# head_size is SCREEN pixels; geometry is DOC units and ctx applies the
	# doc→screen transform, so divide by zoom (see _render_arrow_segment).
	var head := raw_head / maxf(ctx.zoom, 0.01)

	ctx.draw_line(a, b, color, 1.0)

	# Triangle arrowhead pointing from a→b — same shared glyph as
	# _render_arrow_segment (it guards the degenerate direction itself).
	draw_arrowhead(ctx, a, b, head, color)


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

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
##
## ── Visio-style label (A8u2, item 019fb5de8c81) ───────────────────────────────
## An arrow plus its caption is ONE annotation, never two. The caption lives in
## kind_payload as three keys and its position is DERIVED, never stored absolute:
##
##   "label"            String    the caption text ("" / absent = no label)
##   "label_offset"     [x, y]    doc-space offset from the ARROW MIDPOINT to the
##                                label's CENTRE. Arrow-relative on purpose: move
##                                either endpoint and the caption rides along.
##   "label_font_size"  float     doc-unit glyph height, mirroring 2d_text's
##                                kind_payload.font_size (screen px ÷ authoring
##                                zoom, so it is not 14 *millimetres* on a
##                                mm-unit canvas).
##
## Everything about the label works on BOTH endpoint storage paths — the
## kind_payload endpoint_a/endpoint_b anchor path AND the legacy [arrow, …]
## primitives path — because render/hit_test/bounds used to early-return on the
## payload path and would otherwise drop an anchored arrow's caption entirely.
##
## Authoring/editing lives in AnnotationTransformTool (double-click an arrow) and
## uses AnnotationInPlaceTextEditor. The label sub-handle drags label_offset ONLY.
## Like every annotation mutation, a label edit is NOT undoable — the annotation
## substrate has no undo stack at all.

## Default arrowhead size in SCREEN pixels (a payload "head_size" overrides).
## Shared with AnnotationArrowAuthorTool's preview so the authoring glyph is
## the same size the committed render will be.
const DEFAULT_HEAD_SIZE_PX := 12.0

## kind_payload keys for the one-annotation label. Named so the tool never
## spells them itself.
const LABEL_KEY := "label"
const LABEL_OFFSET_KEY := "label_offset"
const LABEL_FONT_SIZE_KEY := "label_font_size"

## Doc-unit fallback glyph height when a payload carries a label without an
## explicit size — same default as AnnotationText's kind_payload.font_size.
const DEFAULT_LABEL_FONT_SIZE := 14.0

## Default midpoint→label offset, in multiples of the glyph height, straight up
## the y axis. Font-relative rather than a fixed doc-unit constant because doc
## units are millimetres on the PCB canvas. THE one definition — every seed site
## goes through default_label_offset().
const DEFAULT_LABEL_OFFSET_FONTS := 1.6


## Offset that puts a fresh caption just clear of the shaft, for glyph height
## `font`. Single source of truth for the seed: AnnotationTransformTool's open
## and commit paths call this, and so do label_offset()/with_label() below.
static func default_label_offset(font: float) -> Vector2:
	return Vector2(0.0, -font * DEFAULT_LABEL_OFFSET_FONTS)


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

	# ── Label (A8u2) ──────────────────────────────────────────────────────────
	# The caption's POSITION is derived (midpoint + label_offset), so it follows
	# a translate for free. Rotation and scale, though, change what "up and to
	# the left of the midpoint" means — so the offset gets the transform's LINEAR
	# part (basis only, translation excluded by construction), applied to the
	# immutable drag-start value exactly like the endpoints above. Glyph size
	# tracks a scale so a scaled-up arrow doesn't keep a tiny caption.
	# NOTE the measured non-trap: label/label_offset/label_font_size were already
	# preserved by the deep duplicate above (and by super()'s duplicate(true) when
	# no endpoint key exists) — nothing dropped them. What follows is the
	# additional work of keeping the caption VISUALLY attached, not a fix.
	if payload.has(LABEL_KEY):
		if payload.has(LABEL_OFFSET_KEY):
			var moved := transform.basis_xform(AnnotationKind._to_vec2(payload.get(LABEL_OFFSET_KEY)))
			payload[LABEL_OFFSET_KEY] = [moved.x, moved.y]
			changed = true
		if operation == "scale":
			var label_delta := AnnotationKind.transform_uniform_scale_delta(transform)
			if absf(label_delta - 1.0) > 0.0001:
				payload[LABEL_FONT_SIZE_KEY] = float(
					payload.get(LABEL_FONT_SIZE_KEY, DEFAULT_LABEL_FONT_SIZE)) * label_delta
				changed = true

	if changed:
		out["kind_payload"] = payload
	return out


# ── Label: one-annotation caption (A8u2) ──────────────────────────────────────

## Caption text, or "" when this arrow carries none.
func label_text(annotation: Dictionary) -> String:
	var payload: Variant = annotation.get("kind_payload", {})
	if payload is Dictionary:
		return str((payload as Dictionary).get(LABEL_KEY, ""))
	return ""


func has_label(annotation: Dictionary) -> bool:
	return not label_text(annotation).strip_edges().is_empty()


## Doc-unit glyph height for the caption.
func label_font_size(annotation: Dictionary) -> float:
	var payload: Variant = annotation.get("kind_payload", {})
	if payload is Dictionary:
		return maxf(float((payload as Dictionary).get(LABEL_FONT_SIZE_KEY, DEFAULT_LABEL_FONT_SIZE)), 0.05)
	return DEFAULT_LABEL_FONT_SIZE


## Stored midpoint→label offset, or the seeded default (see
## default_label_offset) for a caption written without one — e.g. an LLM/MCP
## payload that sets only "label".
func label_offset(annotation: Dictionary) -> Vector2:
	var payload: Variant = annotation.get("kind_payload", {})
	if payload is Dictionary and (payload as Dictionary).has(LABEL_OFFSET_KEY):
		return AnnotationKind._to_vec2((payload as Dictionary).get(LABEL_OFFSET_KEY))
	return default_label_offset(label_font_size(annotation))


## Both endpoints regardless of storage path, or [] when neither yields a
## segment. ctx may be null (hit-test / bounds / tool calls).
func endpoints_any(ctx: AnnotationRenderContext, annotation: Dictionary) -> Array:
	var endpoints: Array = _resolve_payload_endpoints(ctx, annotation)
	if not endpoints.is_empty():
		return endpoints
	return _primitive_endpoints(annotation)


## Midpoint of the arrow shaft, or null when there is no segment.
func label_midpoint(annotation: Dictionary, endpoints: Array = []) -> Variant:
	var pts: Array = endpoints if not endpoints.is_empty() else endpoints_any(null, annotation)
	if pts.size() < 2:
		return null
	return ((pts[0] as Vector2) + (pts[1] as Vector2)) * 0.5


## CENTRE of the caption in document space — midpoint + offset. null when the
## arrow has no resolvable segment. The label position is always DERIVED; no
## absolute label point is ever stored.
func label_position(annotation: Dictionary, endpoints: Array = []) -> Variant:
	var mid: Variant = label_midpoint(annotation, endpoints)
	if not mid is Vector2:
		return null
	return (mid as Vector2) + label_offset(annotation)


## Caption AABB in document space, or null when there is no caption / no
## segment. Mirrors AnnotationText's AABB arithmetic (0.55 w, 1.2 h per glyph
## unit), centred on label_position.
func label_rect(annotation: Dictionary, endpoints: Array = []) -> Variant:
	var text := label_text(annotation).strip_edges()
	if text.is_empty():
		return null
	var centre: Variant = label_position(annotation, endpoints)
	if not centre is Vector2:
		return null
	var box := label_box_size(text, label_font_size(annotation))
	return Rect2((centre as Vector2) - box * 0.5, box)


## Caption box size for `text` at doc-unit glyph height `font`. STATIC and public
## so AnnotationTransformTool can place the in-place editor on a caption that
## does not exist yet (label_rect returns null in that case) using the exact
## arithmetic the committed render will use.
static func label_box_size(text: String, font: float) -> Vector2:
	return Vector2(maxf(float(text.length()) * font * 0.55, font), font * 1.2)


## Copy of `annotation` with the caption set to `text`. An EMPTY text CLEARS the
## label — the offset and size keys go with it, so a cleared arrow serialises
## byte-identical to one that never had a caption. `default_offset` /
## `default_font_size` seed the two derived keys the first time a caption is
## added and are ignored when they already exist.
func with_label(annotation: Dictionary, text: String,
		default_offset: Variant = null, default_font_size: float = -1.0) -> Dictionary:
	var out := annotation.duplicate(true)
	var payload_v: Variant = out.get("kind_payload", {})
	var payload: Dictionary = (payload_v as Dictionary) if payload_v is Dictionary else {}
	var clean := text.strip_edges()
	if clean.is_empty():
		payload.erase(LABEL_KEY)
		payload.erase(LABEL_OFFSET_KEY)
		payload.erase(LABEL_FONT_SIZE_KEY)
	else:
		payload[LABEL_KEY] = clean
		if not payload.has(LABEL_FONT_SIZE_KEY):
			payload[LABEL_FONT_SIZE_KEY] = default_font_size if default_font_size > 0.0 else DEFAULT_LABEL_FONT_SIZE
		if not payload.has(LABEL_OFFSET_KEY):
			var seed_offset: Vector2 = (default_offset as Vector2) if default_offset is Vector2 \
				else default_label_offset(float(payload[LABEL_FONT_SIZE_KEY]))
			payload[LABEL_OFFSET_KEY] = [seed_offset.x, seed_offset.y]
	# Never MINT a kind_payload on an annotation that had none: clearing a label
	# off such an arrow has to leave it byte-identical to one that never carried
	# a caption, which is exactly what the doc-comment above promises.
	if payload.is_empty() and not annotation.has("kind_payload"):
		out.erase("kind_payload")
	else:
		out["kind_payload"] = payload
	return out


## Copy of `annotation` with ONLY the caption offset changed. Used by the label
## sub-handle drag, which must never touch endpoints, text, or size.
func with_label_offset(annotation: Dictionary, offset: Vector2) -> Dictionary:
	var out := annotation.duplicate(true)
	var payload_v: Variant = out.get("kind_payload", {})
	var payload: Dictionary = (payload_v as Dictionary) if payload_v is Dictionary else {}
	payload[LABEL_OFFSET_KEY] = [offset.x, offset.y]
	out["kind_payload"] = payload
	return out


## Endpoints from the legacy primitives path, or [].
func _primitive_endpoints(annotation: Dictionary) -> Array:
	var prims: Variant = annotation.get("primitives", [])
	if not prims is Array:
		return []
	for prim in (prims as Array):
		if prim is Dictionary and str((prim as Dictionary).get("kind", "")) == "arrow":
			return [
				AnnotationKind._to_vec2((prim as Dictionary).get("from", [0, 0])),
				AnnotationKind._to_vec2((prim as Dictionary).get("to", [0, 0])),
			]
	return []


func _label_hit(annotation: Dictionary, endpoints: Array, point: Vector2, threshold: float) -> bool:
	var r: Variant = label_rect(annotation, endpoints)
	if not r is Rect2:
		return false
	return (r as Rect2).grow(threshold).has_point(point)


## Draw the caption centred on midpoint + offset. Pixel size mirrors
## AnnotationText._render_payload_text: doc size × zoom, clamped 8…64.
func _render_payload_label(ctx: AnnotationRenderContext, annotation: Dictionary,
		endpoints: Array, color: Color) -> void:
	var r: Variant = label_rect(annotation, endpoints)
	if not r is Rect2:
		return
	var rect: Rect2 = r
	var font := label_font_size(annotation)
	var px := int(clampf(font * ctx.zoom, 8.0, 64.0))
	# draw_string takes a BASELINE; the rect is a top-left box (same convention
	# as AnnotationText._baseline_position).
	ctx.draw_string(null, rect.position + Vector2(0.0, font), label_text(annotation), color, px)


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
		# The label is part of THIS annotation and must render on the payload
		# path too — this used to `return` here, which silently dropped the
		# caption of every anchored arrow.
		_render_payload_label(ctx, annotation, endpoints, color)
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
	_render_payload_label(ctx, annotation, _primitive_endpoints(annotation), color)


func hit_test(annotation: Dictionary, point: Vector2, threshold: float) -> bool:
	# Payload-endpoint path: hit-test against the resolved segment.
	var endpoints: Array = _resolve_payload_endpoints(null, annotation)
	if not endpoints.is_empty():
		if _dist_point_to_segment(point, endpoints[0], endpoints[1]) <= threshold:
			return true
		# Clicking the caption selects the arrow it belongs to.
		return _label_hit(annotation, endpoints, point, threshold)

	if _label_hit(annotation, _primitive_endpoints(annotation), point, threshold):
		return true

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
		var payload_box := Rect2(endpoints[0], Vector2.ZERO).expand(endpoints[1]).grow(head)
		# Label AABB participates, so zoom-to-fit consumers and the marquee see
		# the caption. Same reason the render early-return had to go.
		var payload_label: Variant = label_rect(annotation, endpoints)
		if payload_label is Rect2:
			payload_box = payload_box.merge(payload_label as Rect2)
		return payload_box

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

	var prim_label: Variant = label_rect(annotation, _primitive_endpoints(annotation))
	if prim_label is Rect2:
		result = (prim_label as Rect2) if not initialized else result.merge(prim_label as Rect2)

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

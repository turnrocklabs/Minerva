class_name AnnotationText
extends AnnotationKind
const TextBoxLayout = preload("res://Scripts/Services/Annotations/kinds/AnnotationTextBoxLayout.gd")
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
	toolbar_icon   = preload("uid://obermhq5hkgs")


# ── Authoring ─────────────────────────────────────────────────────────────────

## Returns a fresh AnnotationTextAuthorTool instance.
##
## Each call returns a NEW instance so the toolbar can deactivate-then-
## reactivate without state leak. The toolbar calls author_ui() once per
## activation; the previous instance is dropped on the floor (RefCounted)
## once the toolbar lets it go. Mirrors AnnotationArrow.author_ui().
func author_ui() -> Object:
	return AnnotationTextAuthorTool.new()


# ── Optional overrides ────────────────────────────────────────────────────────

func summary(annotation: Dictionary) -> String:
	var prims: Array = annotation.get("primitives", [])
	for prim in prims:
		if prim is Dictionary and prim.get("kind", "") == "text":
			var content := str(prim.get("content", ""))
			var at := AnnotationKind._to_vec2(prim.get("at", [0, 0]))
			var anchor := AnnotationSchema.get_anchored_to(annotation)
			# Truncate content to 30 chars for token efficiency
			var preview := content if content.length() <= 30 else content.substr(0, 27) + "..."
			var base := "text '%s' at (%.0f, %.0f)" % [preview, at.x, at.y]
			if not anchor.is_empty():
				return "%s → %s" % [base, anchor]
			return base
	return super(annotation)  # fall through to default


## The typed words ARE this kind's free text (see AnnotationKind.text_content):
## payload text (anchored path) first, else the text primitive's content.
func text_content(annotation: Dictionary) -> String:
	return raw_text(annotation).strip_edges()


func raw_text(annotation: Dictionary) -> String:
	var payload: Variant = annotation.get("kind_payload", {})
	if payload is Dictionary:
		var t := str((payload as Dictionary).get("text", ""))
		if (payload as Dictionary).has("text"):
			return t
	for prim in annotation.get("primitives", []):
		if prim is Dictionary and prim.get("kind", "") == "text":
			return str(prim.get("content", ""))
	return ""


func text_font_size(annotation: Dictionary) -> float:
	var payload: Variant = annotation.get("kind_payload", {})
	if payload is Dictionary and (payload as Dictionary).has("text"):
		return float((payload as Dictionary).get("font_size", 14.0))
	for primitive: Variant in annotation.get("primitives", []):
		if primitive is Dictionary and str((primitive as Dictionary).get("kind", "")) == "text":
			return float((primitive as Dictionary).get("size", 14.0))
	return 14.0


func text_effective_font_size(annotation: Dictionary) -> float:
	var payload: Variant = annotation.get("kind_payload", {})
	if payload is Dictionary and (payload as Dictionary).has("text"):
		return text_font_size(annotation) * float((payload as Dictionary).get("scale", 1.0))
	for primitive: Variant in annotation.get("primitives", []):
		if primitive is Dictionary and str((primitive as Dictionary).get("kind", "")) == "text":
			return text_font_size(annotation) * float((primitive as Dictionary).get("scale", 1.0))
	return text_font_size(annotation)


func text_rotation(annotation: Dictionary) -> float:
	var payload: Variant = annotation.get("kind_payload", {})
	if payload is Dictionary and (payload as Dictionary).has("text"):
		return float((payload as Dictionary).get("rotation_rad", 0.0))
	for primitive: Variant in annotation.get("primitives", []):
		if primitive is Dictionary and str((primitive as Dictionary).get("kind", "")) == "text":
			return float((primitive as Dictionary).get("rotation_rad", 0.0))
	return 0.0


func editing_origin(annotation: Dictionary, host: Object = null) -> Vector2:
	var payload: Variant = annotation.get("kind_payload", {})
	if payload is Dictionary and (payload as Dictionary).has("text"):
		var anchor: Variant = annotation.get("anchor", {})
		if anchor is Dictionary and host != null and host.has_method("resolve_position_source"):
			var resolved: Variant = host.resolve_position_source(anchor)
			if resolved is Vector2:
				return resolved
		if anchor is Dictionary:
			var snapshot: Variant = (anchor as Dictionary).get("snapshot", {})
			if snapshot is Dictionary and (snapshot as Dictionary).has("position"):
				return AnnotationKind._to_vec2((snapshot as Dictionary).get("position"))
	for primitive: Variant in annotation.get("primitives", []):
		if primitive is Dictionary and str((primitive as Dictionary).get("kind", "")) == "text":
			return AnnotationKind._to_vec2((primitive as Dictionary).get("at", [0, 0]))
	return primary_anchor_point(annotation)


func text_box_size(annotation: Dictionary) -> Vector2:
	var payload: Variant = annotation.get("kind_payload", {})
	if payload is Dictionary and (payload as Dictionary).has("text"):
		var font := float((payload as Dictionary).get("font_size", 14.0))
		var requested: Variant = TextBoxLayout.optional_size(payload, "box_size", font,
			float((payload as Dictionary).get("scale", 1.0)))
		return (requested as Vector2) if requested is Vector2 else TextBoxLayout.default_size(font)
	for primitive: Variant in annotation.get("primitives", []):
		if primitive is Dictionary and str((primitive as Dictionary).get("kind", "")) == "text":
			var font := float((primitive as Dictionary).get("size", 14.0))
			var requested: Variant = TextBoxLayout.optional_size(primitive, "box_size", font,
				float((primitive as Dictionary).get("scale", 1.0)))
			return (requested as Vector2) if requested is Vector2 else TextBoxLayout.default_size(font)
	return TextBoxLayout.default_size(14.0)


func with_text_box(annotation: Dictionary, text: String, requested: Vector2) -> Dictionary:
	var out := annotation.duplicate(true)
	var payload_v: Variant = out.get("kind_payload", {})
	if payload_v is Dictionary and (payload_v as Dictionary).has("text"):
		var payload: Dictionary = (payload_v as Dictionary).duplicate(true)
		payload["text"] = text
		var measured: Dictionary = TextBoxLayout.layout(text, float(payload.get("font_size", 14.0)),
			float(payload.get("scale", 1.0)), requested)
		var size: Vector2 = measured["size"]
		payload["box_size"] = [size.x, size.y]
		out["kind_payload"] = payload
		return out
	var primitives: Array = out.get("primitives", []).duplicate(true)
	for index in primitives.size():
		if primitives[index] is Dictionary and str(primitives[index].get("kind", "")) == "text":
			var primitive: Dictionary = primitives[index].duplicate(true)
			primitive["content"] = text
			var measured: Dictionary = TextBoxLayout.layout(text, float(primitive.get("size", 14.0)),
				float(primitive.get("scale", 1.0)), requested)
			var size: Vector2 = measured["size"]
			primitive["box_size"] = [size.x, size.y]
			primitives[index] = primitive
			break
	out["primitives"] = primitives
	return out


# ── Required overrides ────────────────────────────────────────────────────────

## Text's canonical anchor is the placement point of the label.
func primary_anchor_point(annotation: Dictionary) -> Vector2:
	var prims: Array = annotation.get("primitives", [])
	for prim in prims:
		if prim is Dictionary and prim.get("kind", "") == "text":
			return AnnotationKind._to_vec2(prim.get("at", [0, 0]))
	return super(annotation)


func render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
	var color := _annotation_color(annotation)

	# Anchor-aware payload path (Round 2: overlay-canvas DCR). When
	# kind_payload.text is set, render at the anchor-resolved position.
	# kind_payload.font_size + .scale + .rotation_rad are honored if present.
	var payload_pos: Variant = _resolve_payload_position(ctx, annotation)
	if payload_pos is Vector2:
		var payload: Dictionary = annotation.get("kind_payload", {})
		_render_payload_text(ctx, payload_pos, payload, color)
		return

	var prims: Array = annotation.get("primitives", [])
	for prim in prims:
		if prim is Dictionary and prim.get("kind", "") == "text":
			_render_text(ctx, prim, color)


func hit_test(annotation: Dictionary, point: Vector2, threshold: float) -> bool:
	var payload_pos: Variant = _resolve_payload_position(null, annotation)
	if payload_pos is Vector2:
		var rect := _payload_text_aabb(payload_pos, annotation.get("kind_payload", {})).grow(threshold)
		return rect.has_point(point)

	var prims: Array = annotation.get("primitives", [])
	for prim in prims:
		if not (prim is Dictionary and prim.get("kind", "") == "text"):
			continue
		var r := _text_aabb(prim).grow(threshold)
		if r.has_point(point):
			return true
	return false


func bounds(annotation: Dictionary) -> Rect2:
	var payload_pos: Variant = _resolve_payload_position(null, annotation)
	if payload_pos is Vector2:
		return _payload_text_aabb(payload_pos, annotation.get("kind_payload", {}))

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


func transform_annotation(annotation: Dictionary, transform: Transform2D, operation: String = "") -> Dictionary:
	var out: Dictionary = super(annotation, transform, operation)
	var payload_v: Variant = out.get("kind_payload", {})
	if not (payload_v is Dictionary and (payload_v as Dictionary).has("text")):
		if operation == "scale":
			var delta := AnnotationKind.transform_uniform_scale_delta(transform)
			var primitives: Array = out.get("primitives", []).duplicate(true)
			for index in primitives.size():
				if primitives[index] is Dictionary and primitives[index].get("kind", "") == "text" \
						and primitives[index].has("box_size"):
					var primitive: Dictionary = primitives[index].duplicate(true)
					var raw: Variant = primitive.get("box_size")
					if raw is Array and (raw as Array).size() >= 2:
						primitive["box_size"] = [float(raw[0]) * delta, float(raw[1]) * delta]
						primitives[index] = primitive
			out["primitives"] = primitives
		return out
	if not out.has("anchor"):
		return out

	out["anchor"] = AnnotationKind.transform_position_source(out.get("anchor", null), transform)
	var payload: Dictionary = (payload_v as Dictionary).duplicate(true)
	if operation == "rotate":
		var rotation_delta := AnnotationKind.transform_rotation_delta(transform)
		if absf(rotation_delta) > 0.0001:
			payload["rotation_rad"] = float(payload.get("rotation_rad", 0.0)) + rotation_delta
	elif operation == "scale":
		var scale_delta := AnnotationKind.transform_uniform_scale_delta(transform)
		if absf(scale_delta - 1.0) > 0.0001:
			payload["scale"] = float(payload.get("scale", 1.0)) * scale_delta
			if payload.has("box_size"):
				var stored: Variant = TextBoxLayout.optional_size(payload, "box_size",
					float(payload.get("font_size", 14.0)), float(payload.get("scale", 1.0)) / scale_delta)
				if stored is Vector2:
					payload["box_size"] = [(stored as Vector2).x * scale_delta,
						(stored as Vector2).y * scale_delta]
	out["kind_payload"] = payload
	return out


# ── Anchor-aware payload path (Round 2 overlay-canvas DCR) ───────────────────

## Resolve the rendering position from the annotation envelope. Returns null
## when this annotation is not in payload-anchor mode (legacy primitives path).
##
## ctx may be null for hit-test/bounds calls; in that case anchor resolution
## falls back to anchor.snapshot.position so static geometry queries still work.
func _resolve_payload_position(ctx: AnnotationRenderContext, annotation: Dictionary) -> Variant:
	var payload: Variant = annotation.get("kind_payload", {})
	if not (payload is Dictionary and (payload as Dictionary).has("text")):
		return null
	var anchor: Variant = annotation.get("anchor", null)
	if not anchor is Dictionary:
		return null
	if ctx != null and ctx.host != null and ctx.host.has_method("resolve_position_source"):
		var resolved: Variant = ctx.host.resolve_position_source(anchor)
		if resolved is Vector2:
			return resolved
	# Snapshot fallback (no host or host can't resolve).
	var snapshot: Variant = (anchor as Dictionary).get("snapshot", {})
	if snapshot is Dictionary and (snapshot as Dictionary).has("position"):
		return AnnotationKind._to_vec2((snapshot as Dictionary).get("position"))
	return null


func _render_payload_text(ctx: AnnotationRenderContext, pos: Vector2, payload: Dictionary, color: Color) -> void:
	var text := str(payload.get("text", ""))
	var base_size := float(payload.get("font_size", 14.0))
	var scale_factor := float(payload.get("scale", 1.0))
	var rotation_rad := float(payload.get("rotation_rad", 0.0))
	var box_size: Variant = TextBoxLayout.optional_size(payload, "box_size", base_size, scale_factor)
	if box_size is Vector2:
		_render_wrapped(ctx, pos, text, base_size, scale_factor, rotation_rad, box_size, color)
		return
	var px_size := int(clampf(base_size * scale_factor * ctx.zoom, 8.0, 64.0))
	ctx.draw_string_rotated(null, _baseline_position(pos, base_size, scale_factor, rotation_rad), text, color, px_size, rotation_rad)


func _payload_text_aabb(pos: Vector2, payload_v: Variant) -> Rect2:
	var payload: Dictionary = {}
	if payload_v is Dictionary:
		payload = payload_v as Dictionary
	var content := str(payload.get("text", ""))
	var base := float(payload.get("font_size", 14.0))
	var scale_factor := float(payload.get("scale", 1.0))
	var rotation_rad := float(payload.get("rotation_rad", 0.0))
	var box_size: Variant = TextBoxLayout.optional_size(payload, "box_size", base, scale_factor)
	if box_size is Vector2:
		var measured: Dictionary = TextBoxLayout.layout(content, base, scale_factor, box_size)
		return TextBoxLayout.rotated_aabb(pos, measured["size"], rotation_rad)
	var w := content.length() * base * scale_factor * 0.55
	var h := base * scale_factor * 1.2
	if absf(rotation_rad) < 0.0001:
		return Rect2(pos, Vector2(w, h))
	var t := Transform2D(rotation_rad, Vector2.ZERO)
	var c0 := t * Vector2(0.0, 0.0)
	var c1 := t * Vector2(w, 0.0)
	var c2 := t * Vector2(0.0, h)
	var c3 := t * Vector2(w, h)
	var min_x := minf(minf(c0.x, c1.x), minf(c2.x, c3.x))
	var min_y := minf(minf(c0.y, c1.y), minf(c2.y, c3.y))
	var max_x := maxf(maxf(c0.x, c1.x), maxf(c2.x, c3.x))
	var max_y := maxf(maxf(c0.y, c1.y), maxf(c2.y, c3.y))
	return Rect2(pos + Vector2(min_x, min_y), Vector2(max_x - min_x, max_y - min_y))


# ── Private helpers ───────────────────────────────────────────────────────────

func _render_text(ctx: AnnotationRenderContext, prim: Dictionary, color: Color) -> void:
	var at   := AnnotationKind._to_vec2(prim.get("at", [0, 0]))
	var text := str(prim.get("content", ""))
	# Clamp size so text stays legible: pixel size = primitive size * scale * zoom,
	# min 8, max 64. The optional `scale` field is multiplied in pre-clamp so a
	# scaled-down annotation can shrink to 8px (legibility floor) and a scaled-up
	# one can grow to 64px (no runaway growth).
	var base_size := float(prim.get("size", 14.0))
	var scale_factor := float(prim.get("scale", 1.0))
	var rotation_rad := float(prim.get("rotation_rad", 0.0))
	var box_size: Variant = TextBoxLayout.optional_size(prim, "box_size", base_size, scale_factor)
	if box_size is Vector2:
		_render_wrapped(ctx, at, text, base_size, scale_factor, rotation_rad, box_size, color)
		return
	var px_size := int(clampf(base_size * scale_factor * ctx.zoom, 8.0, 64.0))
	ctx.draw_string_rotated(null, _baseline_position(at, base_size, scale_factor, rotation_rad), text, color, px_size, rotation_rad)


static func _baseline_position(top_left: Vector2, base_size: float, scale_factor: float, rotation_rad: float) -> Vector2:
	var baseline_offset := Vector2(0.0, base_size * scale_factor)
	if absf(rotation_rad) < 0.0001:
		return top_left + baseline_offset
	return top_left + Transform2D(rotation_rad, Vector2.ZERO) * baseline_offset


static func _text_aabb(prim: Dictionary) -> Rect2:
	var at      := AnnotationKind._to_vec2(prim.get("at", [0, 0]))
	var content := str(prim.get("content", ""))
	# Approximate: 7px per character width, 14px height at default size.
	# Multiplied by `scale` (default 1.0) so a scale-tool drag grows the AABB.
	var base := float(prim.get("size", 14.0))
	var scale_factor := float(prim.get("scale", 1.0))
	var rotation_rad := float(prim.get("rotation_rad", 0.0))
	var box_size: Variant = TextBoxLayout.optional_size(prim, "box_size", base, scale_factor)
	if box_size is Vector2:
		var measured: Dictionary = TextBoxLayout.layout(content, base, scale_factor, box_size)
		return TextBoxLayout.rotated_aabb(at, measured["size"], rotation_rad)
	var w := content.length() * base * scale_factor * 0.55
	var h := base * scale_factor * 1.2
	if absf(rotation_rad) < 0.0001:
		return Rect2(at, Vector2(w, h))
	# Rotated AABB: the unrotated rect's four corners (relative to `at`) get
	# rotated by `rotation_rad`; we return the AABB enclosing them.
	var t := Transform2D(rotation_rad, Vector2.ZERO)
	var c0 := t * Vector2(0.0, 0.0)
	var c1 := t * Vector2(w, 0.0)
	var c2 := t * Vector2(0.0, h)
	var c3 := t * Vector2(w, h)
	var min_x := minf(minf(c0.x, c1.x), minf(c2.x, c3.x))
	var min_y := minf(minf(c0.y, c1.y), minf(c2.y, c3.y))
	var max_x := maxf(maxf(c0.x, c1.x), maxf(c2.x, c3.x))
	var max_y := maxf(maxf(c0.y, c1.y), maxf(c2.y, c3.y))
	return Rect2(at + Vector2(min_x, min_y), Vector2(max_x - min_x, max_y - min_y))


static func _render_wrapped(ctx: AnnotationRenderContext, top_left: Vector2, text: String,
		font_size: float, scale_factor: float, rotation_rad: float,
		box_size: Vector2, color: Color) -> void:
	var measured: Dictionary = TextBoxLayout.layout(text, font_size, scale_factor, box_size)
	var line_height: float = measured["line_height"]
	var px_size := maxi(1, int(round(font_size * scale_factor * ctx.zoom)))
	var baseline := float(measured["ascent"])
	for line: String in measured["lines"]:
		var local_baseline := Vector2(0.0, baseline)
		var position := top_left + Transform2D(rotation_rad, Vector2.ZERO) * local_baseline
		ctx.draw_string_rotated(null, position, line, color, px_size, rotation_rad)
		baseline += line_height


static func _annotation_color(annotation: Dictionary) -> Color:
	var payload: Dictionary = annotation.get("payload", {})
	if payload.has("color"):
		return Color(str(payload["color"]))
	return AnnotationRenderContext.author_color(annotation.get("author", ""))

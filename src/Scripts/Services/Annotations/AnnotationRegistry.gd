class_name AnnotationRegistry
extends RefCounted
## Registry and dispatcher for annotation kinds.
##
## Design §4.3. Plugins call register_annotation_kind() on start and
## deregister_annotation_kind() on stop. Core built-in kinds (2d_*) are
## registered at Minerva startup (separate task 019dc055beeb7e058247b579214a2f70).
##
## Collision policy: second registration of the same name fails (returns false,
## logs a warning). No silent overwrites.
##
## Namespace rules (design §4.4 / plan-decision):
##   - "2d_*" prefix is reserved for core. Plugin registrations using "2d_*"
##     are rejected regardless of owning_plugin.
##   - Plugin kinds must follow "<plugin>_<kind>" convention per policy.
##
## Signals fire on the Godot main thread. AnnotationToolbar listens to
## annotation_kind_registered to append a toolbar button dynamically.

signal annotation_kind_registered(kind_name: StringName)
signal annotation_kind_deregistered(kind_name: StringName)

# ── Internal storage ───────────────────────────────────────────────────────────

## kind.name (StringName) → AnnotationKind instance
var _kinds: Dictionary = {}

## Set of unknown kind names already warned about this session (design §10 rule 5).
## Cleared whenever the registry changes (kind registered or deregistered) so that
## a plugin installing mid-session resets the "already warned" state for its kinds.
var _warned_unknown_kinds: Dictionary = {}

# ── Placeholder rendering constants ───────────────────────────────────────────

## Default placeholder rect when primitives produce no bounds.
const _PLACEHOLDER_DEFAULT_W: float = 100.0
const _PLACEHOLDER_DEFAULT_H: float = 40.0

## Dashed-stroke segment length and gap length in document units.
const _DASH_LEN: float  = 8.0
const _GAP_LEN: float   = 4.0

## Placeholder style
const _PLACEHOLDER_COLOR: Color    = Color(0.55, 0.55, 0.55, 0.85)   # grey
const _PLACEHOLDER_TEXT_SIZE: int  = 11
const _PLACEHOLDER_INSET: float    = 4.0   # text inset from top-left corner
const _PLACEHOLDER_STROKE_W: float = 1.5

# ── Registration API ───────────────────────────────────────────────────────────

## Register a new kind. Returns true on success, false on collision or
## namespace violation (logs a warning in both failure cases).
func register_annotation_kind(kind: AnnotationKind) -> bool:
	if kind == null:
		push_warning("[AnnotationRegistry] register_annotation_kind() called with null kind")
		return false

	if kind.name == &"":
		push_warning("[AnnotationRegistry] Cannot register kind with empty name")
		return false

	# Namespace guard: only core may use 2d_* prefix
	if AnnotationSchema.is_core_kind(kind.name) and kind.owning_plugin != &"core":
		push_warning(
			"[AnnotationRegistry] Plugin '%s' attempted to register kind '%s' "
			% [str(kind.owning_plugin), str(kind.name)] +
			"with reserved '2d_*' prefix. Rejected."
		)
		return false

	# Collision guard
	if _kinds.has(kind.name):
		push_warning(
			"[AnnotationRegistry] Kind '%s' is already registered (owned by '%s'). "
			% [str(kind.name), str(_kinds[kind.name].owning_plugin)] +
			"Duplicate registration rejected."
		)
		return false

	_kinds[kind.name] = kind
	# A new registration may resolve previously-unknown kinds — reset the
	# warned-set so that any remaining unknowns get a fresh log entry.
	_warned_unknown_kinds.clear()
	annotation_kind_registered.emit(kind.name)
	return true


## Deregister a kind by name. Returns true if the kind was present and removed.
## The authoring toolbar task is responsible for deactivating any in-progress
## authoring tool before or after receiving the signal (design §11.3).
func deregister_annotation_kind(kind_name: StringName) -> bool:
	if not _kinds.has(kind_name):
		return false
	_kinds.erase(kind_name)
	# Deregistration may cause annotations to fall back to placeholder — reset
	# the warned-set so the "missing plugin" message fires once for the new state.
	_warned_unknown_kinds.clear()
	annotation_kind_deregistered.emit(kind_name)
	return true


## Returns the registered AnnotationKind for the given name, or null if unknown.
## Callers use null to trigger placeholder rendering (design §10).
func get_annotation_kind(kind_name: StringName) -> AnnotationKind:
	return _kinds.get(kind_name, null)


## Returns all registered kinds in registration order.
## Core kinds first (registered at startup); plugin kinds appended on start.
func list_annotation_kinds() -> Array[AnnotationKind]:
	var result: Array[AnnotationKind] = []
	for k in _kinds.values():
		result.append(k)
	return result


## Returns the count of registered kinds (convenience for tests).
func count() -> int:
	return _kinds.size()


## Returns true if the given kind name is currently registered.
func has_kind(kind_name: StringName) -> bool:
	return _kinds.has(kind_name)

# ── Dispatch helpers ───────────────────────────────────────────────────────────

## Dispatch render() to the appropriate kind.
## For unknown kinds renders a grey dashed-stroke placeholder rectangle with
## the kind name and a warning glyph (design §10). Never silently drops.
func dispatch_render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
	var kind_name: StringName = StringName(annotation.get("kind", ""))
	var kind := get_annotation_kind(kind_name)
	if kind == null:
		_render_unknown_placeholder(ctx, annotation, kind_name)
		return
	kind.render(ctx, annotation)


## Renders a grey dashed-rectangle placeholder for an annotation whose kind is
## not currently registered.  Called only by dispatch_render(); not part of the
## public API.
func _render_unknown_placeholder(
	ctx: AnnotationRenderContext,
	annotation: Dictionary,
	kind_name: StringName
) -> void:
	# ── 1. Warn once per unknown kind per registry state ──────────────────────
	var kind_str := str(kind_name)
	if not _warned_unknown_kinds.has(kind_str):
		_warned_unknown_kinds[kind_str] = true
		# Extract owning_plugin hint from the kind name prefix (design §10 §3).
		var plugin_hint := kind_str.split("_")[0] if "_" in kind_str else kind_str
		push_warning(
			("[AnnotationRegistry] Missing plugin: annotation kind '%s' is not registered. "
			% kind_str) +
			("Plugin hint: '%s'. Annotation is preserved and rendered as placeholder." % plugin_hint)
		)

	# ── 2. Compute bounds ─────────────────────────────────────────────────────
	var bounds := _placeholder_bounds(annotation)

	# ── 3. Draw dashed-stroke rectangle ──────────────────────────────────────
	_draw_dashed_rect(ctx, bounds, _PLACEHOLDER_COLOR, _PLACEHOLDER_STROKE_W)

	# ── 4. Warning glyph + kind name at top-left, slightly inset ─────────────
	var label := ("⚠ " + kind_str)
	var text_pos := bounds.position + Vector2(_PLACEHOLDER_INSET, _PLACEHOLDER_INSET)
	ctx.draw_string(null, text_pos, label, _PLACEHOLDER_COLOR, _PLACEHOLDER_TEXT_SIZE)


## Computes the document-space bounding rect for an unknown-kind placeholder.
## Falls back to a fixed default if primitives yield no bounds (design §10).
func _placeholder_bounds(annotation: Dictionary) -> Rect2:
	var prims = annotation.get("primitives", [])
	var bounds := Rect2()
	if prims is Array and (prims as Array).size() > 0:
		bounds = AnnotationKind.bounds_from_primitives(prims)

	# bounds_from_primitives returns Rect2() (zero) when no known primitive type
	# matched.  Fall back to a fixed-size placeholder at the centroid of any
	# point primitives, or at (0, 0) if none exist (design §10).
	if bounds.size == Vector2.ZERO:
		var centroid := _primitives_centroid(prims if prims is Array else [])
		bounds = Rect2(
			centroid.x - _PLACEHOLDER_DEFAULT_W * 0.5,
			centroid.y - _PLACEHOLDER_DEFAULT_H * 0.5,
			_PLACEHOLDER_DEFAULT_W,
			_PLACEHOLDER_DEFAULT_H
		)
	return bounds


## Returns the centroid of all point-like coordinates found in primitives[].
## Returns Vector2.ZERO when no points are found.
func _primitives_centroid(prims: Array) -> Vector2:
	var pts: PackedVector2Array = []
	for prim in prims:
		if not prim is Dictionary:
			continue
		# Collect any coordinate fields we recognise as single points.
		for field in ["at", "from", "to", "a", "b", "c", "center", "edge"]:
			var v = prim.get(field)
			if v is Array and (v as Array).size() >= 2:
				pts.append(Vector2(float(v[0]), float(v[1])))
		# Also collect individual vertices from points[] arrays.
		var points_arr = prim.get("points")
		if points_arr is Array:
			for pt in (points_arr as Array):
				if pt is Array and (pt as Array).size() >= 2:
					pts.append(Vector2(float(pt[0]), float(pt[1])))
	if pts.size() == 0:
		return Vector2.ZERO
	var sum := Vector2.ZERO
	for p in pts:
		sum += p
	return sum / float(pts.size())


## Draws a dashed stroke rectangle by decomposing each edge into alternating
## drawn/skipped segments.  Godot has no native dashed-line primitive.
func _draw_dashed_rect(
	ctx: AnnotationRenderContext,
	rect: Rect2,
	color: Color,
	width: float
) -> void:
	# Corner names use _corner suffix because plain `tr` shadows Object.tr()
	# (Godot's translation lookup method).
	var tl_corner := rect.position
	var tr_corner := Vector2(rect.position.x + rect.size.x, rect.position.y)
	var br_corner := rect.position + rect.size
	var bl_corner := Vector2(rect.position.x, rect.position.y + rect.size.y)

	_draw_dashed_segment(ctx, tl_corner, tr_corner, color, width)
	_draw_dashed_segment(ctx, tr_corner, br_corner, color, width)
	_draw_dashed_segment(ctx, br_corner, bl_corner, color, width)
	_draw_dashed_segment(ctx, bl_corner, tl_corner, color, width)


## Draws a single edge as a series of short drawn / skipped segments.
func _draw_dashed_segment(
	ctx: AnnotationRenderContext,
	a: Vector2,
	b: Vector2,
	color: Color,
	width: float
) -> void:
	var total_len := a.distance_to(b)
	if total_len < 0.001:
		return
	var dir := (b - a) / total_len
	var t := 0.0
	var drawing := true  # start with a drawn segment
	while t < total_len:
		var seg_len := _DASH_LEN if drawing else _GAP_LEN
		var t_end := minf(t + seg_len, total_len)
		if drawing:
			ctx.draw_line(a + dir * t, a + dir * t_end, color, width)
		t = t_end
		drawing = not drawing


## Dispatch hit_test() to the appropriate kind.
## For unknown kinds, uses the same AABB the placeholder renders at,
## so a click on the visible placeholder box actually selects it.
func dispatch_hit_test(
	annotation: Dictionary,
	point: Vector2,
	threshold: float
) -> bool:
	var kind_name: StringName = StringName(annotation.get("kind", ""))
	var kind := get_annotation_kind(kind_name)
	if kind == null:
		# Unknown kind: AABB hit against the SAME bounds used by the
		# placeholder renderer (design §10 rule 4). See dispatch_bounds.
		var b := dispatch_bounds(annotation)
		return b.grow(threshold).has_point(point)
	return kind.hit_test(annotation, point, threshold)


## Dispatch bounds() to the appropriate kind.
## For unknown kinds, returns the SAME bounds the placeholder renderer
## draws at (design §10) — so hit-test and visible placeholder agree
## even when primitives[] is empty or unrecognised.
func dispatch_bounds(annotation: Dictionary) -> Rect2:
	var kind_name: StringName = StringName(annotation.get("kind", ""))
	var kind := get_annotation_kind(kind_name)
	if kind == null:
		# Unknown kind: delegate to the placeholder-bounds helper so
		# render-bounds and hit-bounds stay in sync.  _placeholder_bounds
		# falls back to a fixed-size default when bounds_from_primitives
		# returns an empty rect.
		return _placeholder_bounds(annotation)
	return kind.bounds(annotation)


## Dispatch validate() to the appropriate kind (kind-specific extra validation).
## Returns an empty array on success; array of AnnotationSchema.ValidationError otherwise.
## Returns empty array for unknown kinds — they are preserved verbatim, not rejected.
func dispatch_validate(annotation: Dictionary) -> Array:
	var kind_name: StringName = StringName(annotation.get("kind", ""))
	var kind := get_annotation_kind(kind_name)
	if kind == null:
		return []
	return kind.validate(annotation)


## Dispatch rewrite_paths() to the appropriate kind during project pack/unpack.
## mode is "pack" or "unpack"; base is the package root (pack) or unpack destination (unpack).
## Returns the annotation with paths rewritten if the kind implements rewrite_paths().
## Returns the annotation unchanged for unknown kinds or kinds that don't override the method.
## Design §9.4: per-kind path rewrites are optional; the base class no-op default handles
## kinds with no path payloads.
func dispatch_rewrite_paths(annotation: Dictionary, mode: String, base: String) -> Dictionary:
	var kind_name: StringName = StringName(annotation.get("kind", ""))
	var kind := get_annotation_kind(kind_name)
	if kind == null:
		return annotation
	# All AnnotationKind subclasses inherit the base no-op rewrite_paths(), so has_method
	# is always true. We call it directly — kinds that need rewrites override the method.
	return kind.rewrite_paths(annotation, mode, base)

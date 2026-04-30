class_name AnnotationKind
extends RefCounted
## Abstract base for all annotation kinds — both built-in 2d_* and plugin-contributed.
##
## Design §4.1. One instance per registered kind. Core kinds are owned by &"core";
## plugin kinds are owned by their plugin id (e.g. &"cad", &"pcb").
##
## Subclass requirements:
##   - Override render(), hit_test(), and bounds() — these are the required methods.
##   - Set name, display_name, schema_version, and owning_plugin in _init().
##   - Optionally override validate(), author_ui(), migrate(), rewrite_paths().
##
## Naming rules (design §4.4 / policy):
##   - Core kinds:   "2d_<kind>"        (e.g. &"2d_arrow")
##   - Plugin kinds: "<plugin>_<kind>"  (e.g. &"cad_3d_plane", &"pcb_route_hint")
##   - The "2d_*" prefix is reserved for core. Plugins that attempt to register
##     a "2d_*" name will be rejected by AnnotationRegistry.
##
## primitives_optional flag (design §2.3 / plan-decision §3):
##   Set to true for kinds whose anchor lives entirely in payload (e.g. text-editor
##   range annotations with payload.range). The sidecar I/O task will read this flag
##   when deciding whether to require primitives[].

const ContextBlockScript = preload("res://Scripts/Services/Annotations/ContextBlock.gd")

# ── Required properties ────────────────────────────────────────────────────────

## Globally unique kind identifier. Must match the "kind" discriminator in
## annotation JSON. Use StringName for interning / fast comparison.
var name: StringName = &""

## Human-readable label shown in the authoring toolbar and UI.
var display_name: String = ""

## Bump on any breaking change to payload schema so migrate() can be invoked.
var schema_version: int = 1

## &"core" for built-in kinds; plugin id string for plugin-contributed kinds.
var owning_plugin: StringName = &"core"

# ── Optional properties ────────────────────────────────────────────────────────

## Icon shown in the authoring toolbar. Null = no icon (text label only).
var toolbar_icon: Texture2D = null

## Skeleton dictionary used when creating a new annotation of this kind via UI.
## The authoring tool merges user input into a copy of this.
var default_payload: Dictionary = {}

## When true, primitives[] may be absent or empty for annotations of this kind.
## The substrate and sidecar I/O respect this flag (design §2.3).
var primitives_optional: bool = false

# ── Required methods ───────────────────────────────────────────────────────────

## Render the annotation onto ctx.
## annotation is the full annotation envelope dict (id, kind, primitives, payload, …).
## Must not mutate annotation.
func render(_ctx: AnnotationRenderContext, _annotation: Dictionary) -> void:
	push_error(
		"[AnnotationKind] render() not implemented for kind '%s'. "
		% str(name) +
		"Subclass must override render()."
	)


func render_broken(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
	if ctx != null:
		ctx.is_stale = true
		var snapshot: Dictionary = annotation.get("anchor", {}).get("snapshot", {})
		var pos := _to_vec2(snapshot.get("position", []))
		if ctx.has_method("draw_badge"):
			ctx.draw_badge(pos)
	render(ctx, annotation)


## Returns true if document-space point is within threshold pixels of this annotation.
## Used for selection / hover detection.
func hit_test(annotation: Dictionary, point: Vector2, threshold: float) -> bool:
	# Default: AABB of bounds() grown by threshold.
	var b := bounds(annotation)
	return b.grow(threshold).has_point(point)


## Returns the document-space bounding rectangle of this annotation.
## Used for unknown-kind placeholder rendering and viewport culling.
func bounds(_annotation: Dictionary) -> Rect2:
	push_error(
		"[AnnotationKind] bounds() not implemented for kind '%s'. "
		% str(name) +
		"Subclass must override bounds()."
	)
	return Rect2()

# ── Optional methods ───────────────────────────────────────────────────────────

## Additional kind-specific validation beyond the envelope schema.
## Called after AnnotationSchema.validate_annotation() passes.
## Return an empty array on success; array of AnnotationSchema.ValidationError on failure.
func validate(_annotation: Dictionary) -> Array:
	return []


func accepted_anchor_types() -> Array:
	if owning_plugin == &"core" and _is_builtin_generic_kind(str(name)):
		return ["core/*"]
	return []


## Return the authoring tool for this kind, or null to use the default
## primitive-level author UI (design §11.2).
# TODO(019dc055e8da710588ea283351710c01): narrow return type to AnnotationAuthorTool
# once that class exists (authoring-UI task).
func author_ui() -> Object:  # -> AnnotationAuthorTool (defined in separate task)
	return null


## Migrate annotation data from an older schema_version to the current one.
## Called by sidecar I/O when it finds schema_version < current.
## Return the migrated annotation dict (may be same object with mutations).
func migrate(annotation: Dictionary, from_version: int) -> Dictionary:
	push_warning(
		"[AnnotationKind] migrate() not overridden for kind '%s' "
		% str(name) +
		"(from_version=%d → %d). Annotation loaded as-is." % [from_version, schema_version]
	)
	return annotation


## Rewrite file paths embedded in the annotation payload during project pack/unpack.
## mode is "pack" or "unpack"; base is the sidecar directory path.
## Called by ProjectPackage per annotation (design §9.4).
## Default implementation does nothing (kinds with no path payloads don't need this).
func rewrite_paths(annotation: Dictionary, _mode: String, _base: String) -> Dictionary:
	return annotation


## The canonical document-space point that describe_point should be called against.
##
## Contract: arrow returns `to` (the head — what the arrow points AT); text returns
## `at`; polyline, region, highlight, measure_*, and ink_stroke default to the
## bounds center via this base implementation.
##
## Hosts call this to compute `anchored_to` via AnnotationHost._stamp_anchor().
func primary_anchor_point(annotation: Dictionary) -> Vector2:
	return bounds(annotation).get_center()


## Return the semantic target description for an annotation's anchor point.
##
## kinds with directional/extended target semantics override this.
## base_pos is the kind.primary_anchor_point. Default delegates to host.describe_point.
##
## Called by AnnotationHost._stamp_anchor instead of host.describe_point directly,
## so arrow (and future kinds) can apply directional projection or other geometry
## before the host lookup.
func describe_target_point(_annotation: Dictionary, base_pos: Vector2, host: AnnotationHost) -> String:
	if host == null:
		return ""
	return host.describe_point(base_pos)


## Return a one-line natural-language description of this annotation.
##
## Used by minerva_annotations_list (LLM ergonomics).  Default implementation
## uses display_name + primitive count + anchored_to suffix if present.
## Override in each kind for richer kind-specific output.
func summary(annotation: Dictionary) -> String:
	var prim_count: int = annotation.get("primitives", []).size()
	var anchor: String = AnnotationSchema.get_anchored_to(annotation)
	var base: String = "%s (%d primitive%s)" % [
		display_name,
		prim_count,
		"s" if prim_count != 1 else "",
	]
	if not anchor.is_empty():
		return "%s → %s" % [base, anchor]
	return base


func to_chat_context(annotation: Dictionary, capabilities: Dictionary) -> Array:
	var blocks: Array = []
	var supported: Array = capabilities.get("supported_block_types", ["text", "structured_json"])
	var stale := str(annotation.get("lifecycle", "")) == "stale" or bool(annotation.get("stale", false))
	var content := {
		"id": str(annotation.get("id", "")),
		"kind": str(annotation.get("kind", "")),
		"anchor": annotation.get("anchor", {}),
		"lifecycle": "stale" if stale else str(annotation.get("lifecycle", "")),
		"stale": stale,
		"summary": str(annotation.get("summary", "")),
		"view_context": str(annotation.get("view_context", "")),
		"author": annotation.get("author", {}),
		"kind_payload": annotation.get("kind_payload", {}),
	}
	if "structured_json" in supported:
		blocks.append(ContextBlockScript.make(ContextBlockScript.Type.STRUCTURED_JSON, content))
	elif "text" in supported:
		blocks.append(ContextBlockScript.make(ContextBlockScript.Type.UNSUPPORTED_PLACEHOLDER, "structured_json unsupported"))

	if "text" in supported:
		var text := str(annotation.get("summary", ""))
		if stale:
			text = "[BROKEN] %s" % text
		blocks.append(ContextBlockScript.make(ContextBlockScript.Type.TEXT, _truncate_text(text, 500)))

	return blocks


func has_visual_render() -> bool:
	return true


func _truncate_text(text: String, max_words: int) -> String:
	var words := text.split(" ", false)
	if words.size() <= max_words:
		return text
	return "%s [truncated]" % " ".join(words.slice(0, max_words))


# ── Convenience helpers ────────────────────────────────────────────────────────

## Compute the AABB of a primitives[] array using only substrate-known primitive
## types. Used for unknown-kind placeholder rendering (design §10).
static func bounds_from_primitives(primitives: Array) -> Rect2:
	# Uses an explicit `initialized` flag rather than a zero-Rect2 sentinel so that
	# primitives legitimately positioned at the origin (e.g. arrow from [0,0] to [0,0],
	# highlight with a zero-size rect at origin) are included in the AABB instead of
	# being silently skipped.  Fix for follow-up item 1 (review comment 217).
	var result := Rect2()
	var initialized := false

	for prim in primitives:
		if not prim is Dictionary:
			continue
		var prim_bounds := _primitive_bounds(prim)
		if not initialized:
			result = prim_bounds
			initialized = true
		else:
			result = result.merge(prim_bounds)

	return result


static func _primitive_bounds(p: Dictionary) -> Rect2:
	var kind: String = p.get("kind", "")
	match kind:
		"arrow":
			var a := _to_vec2(p.get("from", [0, 0]))
			var b := _to_vec2(p.get("to",   [0, 0]))
			return Rect2(a, Vector2.ZERO).expand(b)

		"text":
			var at := _to_vec2(p.get("at", [0, 0]))
			return Rect2(at, Vector2(50, 12))  # approximate; real bounds need font metrics

		"region", "polyline":
			return _points_aabb(p.get("points", []))

		"highlight":
			var r = p.get("rect", [0, 0, 0, 0])
			if r is Array and r.size() == 4:
				return Rect2(float(r[0]), float(r[1]), float(r[2]), float(r[3]))

		"measure_distance":
			var a := _to_vec2(p.get("from", [0, 0]))
			var b := _to_vec2(p.get("to",   [0, 0]))
			return Rect2(a, Vector2.ZERO).expand(b)

		"measure_angle":
			var a := _to_vec2(p.get("a", [0, 0]))
			var b := _to_vec2(p.get("b", [0, 0]))
			var c := _to_vec2(p.get("c", [0, 0]))
			return Rect2(a, Vector2.ZERO).expand(b).expand(c)

		"measure_radius":
			var center := _to_vec2(p.get("center", [0, 0]))
			var edge   := _to_vec2(p.get("edge",   [0, 0]))
			var radius := center.distance_to(edge)
			return Rect2(center - Vector2(radius, radius), Vector2(radius * 2, radius * 2))

		"ink_stroke":
			return _points_aabb_4col(p.get("points", []))

	return Rect2()


static func _to_vec2(arr: Variant) -> Vector2:
	if arr is Array and (arr as Array).size() >= 2:
		return Vector2(float(arr[0]), float(arr[1]))
	return Vector2.ZERO


static func _points_aabb(pts: Variant) -> Rect2:
	if not pts is Array or (pts as Array).size() == 0:
		return Rect2()
	var result := Rect2(_to_vec2(pts[0]), Vector2.ZERO)
	for i in range(1, (pts as Array).size()):
		result = result.expand(_to_vec2(pts[i]))
	return result


## AABB for ink_stroke points which are [x, y, p, t] 4-element arrays.
## _to_vec2 reads only indices 0 and 1, so the extra pressure/timestamp columns
## are ignored automatically — no separate implementation needed.
## Deduped per follow-up item 5 (review comment 217).
static func _points_aabb_4col(pts: Variant) -> Rect2:
	return _points_aabb(pts)


static func _is_builtin_generic_kind(kind_name: String) -> bool:
	return kind_name in [
		"text", "arrow", "region", "polyline", "highlight",
		"measure_distance", "measure_angle", "measure_radius", "callout",
		"2d_text", "2d_arrow", "2d_region", "2d_polyline", "2d_highlight",
		"2d_measure_distance", "2d_measure_angle", "2d_measure_radius",
	]


## Apply a Transform2D to all coord arrays in a primitives list.
## Recognizes scalar coord-array keys: "from", "to", "at", "p0", "p1", "p2".
## Coord values must be 2-element Arrays [x, y].
## Also handles the "points" key, which is an Array of 2-element Arrays.
## Returns a NEW primitives Array; does not mutate the input.
##
## Used by TranslateTool (pure translation), and will be shared by RotateTool
## and ScaleTool for their respective Transform2D arguments.
##
## Example (pure translation by delta):
##   var t := Transform2D(0.0, delta)
##   var new_prims := AnnotationKind.transform_primitives(old_prims, t)
static func transform_primitives(primitives: Array, transform: Transform2D) -> Array:
	var result: Array = []
	# TODO(019dc64be4967c3a9a45e5038273ee88): expand to recognize coord keys
	# used by the remaining built-in kinds — measure_angle uses a/b/c,
	# measure_radius uses center/edge, highlight uses rect. Today those
	# primitives silently pass through transform_primitives unchanged.
	# Arrow + text + polyline + region are correctly handled. Keep this list
	# in sync with _primitive_bounds.
	var coord_keys := ["from", "to", "at", "p0", "p1", "p2"]
	for prim in primitives:
		if not (prim is Dictionary):
			result.append(prim)
			continue
		var new_prim: Dictionary = (prim as Dictionary).duplicate(true)
		var prim_kind := str(new_prim.get("kind", ""))

		# Text primitives carry their orientation/size in `rotation_rad` and
		# `scale` fields rather than via multiple coord points. Rotating just
		# the `at` anchor would slide the glyph along a circle without ever
		# turning it; scaling `at` would move it without enlarging the font.
		# Decompose the incoming Transform2D so the rendered glyph actually
		# rotates and grows: translate `at` (this picks up the rotate-around-
		# center lever arm), accumulate rotation into `rotation_rad`, and
		# multiply the uniform scale into `scale`.
		if prim_kind == "text":
			if new_prim.has("at"):
				var av := _to_vec2(new_prim["at"])
				var atv := transform * av
				new_prim["at"] = [atv.x, atv.y]
			var dr: float = transform.get_rotation()
			if absf(dr) > 0.0001:
				var cur_rot: float = float(new_prim.get("rotation_rad", 0.0))
				new_prim["rotation_rad"] = cur_rot + dr
			var ds: Vector2 = transform.get_scale()
			# Scale tool emits uniform Transform2D; average sx/sy in case a
			# future caller passes a slightly non-uniform one.
			var s_uniform: float = (ds.x + ds.y) * 0.5
			if absf(s_uniform - 1.0) > 0.0001:
				var cur_scale: float = float(new_prim.get("scale", 1.0))
				new_prim["scale"] = cur_scale * s_uniform
			result.append(new_prim)
			continue

		for key in coord_keys:
			if new_prim.has(key):
				var v := _to_vec2(new_prim[key])
				var t := transform * v
				new_prim[key] = [t.x, t.y]
		# "points" is an Array of 2-element Arrays (polyline / region).
		if new_prim.has("points") and new_prim["points"] is Array:
			var new_points: Array = []
			for p in new_prim["points"]:
				var v := _to_vec2(p)
				var t := transform * v
				new_points.append([t.x, t.y])
			new_prim["points"] = new_points
		result.append(new_prim)
	return result

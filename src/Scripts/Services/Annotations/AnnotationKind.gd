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
func render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
	push_error(
		"[AnnotationKind] render() not implemented for kind '%s'. "
		% str(name) +
		"Subclass must override render()."
	)


## Returns true if document-space point is within threshold pixels of this annotation.
## Used for selection / hover detection.
func hit_test(annotation: Dictionary, point: Vector2, threshold: float) -> bool:
	# Default: AABB of bounds() grown by threshold.
	var b := bounds(annotation)
	return b.grow(threshold).has_point(point)


## Returns the document-space bounding rectangle of this annotation.
## Used for unknown-kind placeholder rendering and viewport culling.
func bounds(annotation: Dictionary) -> Rect2:
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
func validate(annotation: Dictionary) -> Array:
	return []


## Return the authoring tool for this kind, or null to use the default
## primitive-level author UI (design §11.2).
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
func rewrite_paths(annotation: Dictionary, mode: String, base: String) -> Dictionary:
	return annotation


# ── Convenience helpers ────────────────────────────────────────────────────────

## Compute the AABB of a primitives[] array using only substrate-known primitive
## types. Used for unknown-kind placeholder rendering (design §10).
static func bounds_from_primitives(primitives: Array) -> Rect2:
	var result := Rect2()
	var initialized := false

	for prim in primitives:
		if not prim is Dictionary:
			continue
		var prim_bounds := _primitive_bounds(prim)
		if prim_bounds.size == Vector2.ZERO and prim_bounds.position == Vector2.ZERO:
			continue
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
static func _points_aabb_4col(pts: Variant) -> Rect2:
	if not pts is Array or (pts as Array).size() == 0:
		return Rect2()
	var result := Rect2(_to_vec2(pts[0]), Vector2.ZERO)
	for i in range(1, (pts as Array).size()):
		result = result.expand(_to_vec2(pts[i]))
	return result

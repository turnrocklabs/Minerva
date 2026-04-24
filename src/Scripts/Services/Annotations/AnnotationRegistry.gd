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
	annotation_kind_registered.emit(kind.name)
	return true


## Deregister a kind by name. Returns true if the kind was present and removed.
## The authoring toolbar task is responsible for deactivating any in-progress
## authoring tool before or after receiving the signal (design §11.3).
func deregister_annotation_kind(kind_name: StringName) -> bool:
	if not _kinds.has(kind_name):
		return false
	_kinds.erase(kind_name)
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

## Dispatch render() to the appropriate kind, or perform placeholder rendering
## if the kind is unknown (design §10). Placeholder rendering is the
## responsibility of the unknown-kind-fallback task; this method logs and no-ops
## to keep the registry free of rendering policy.
func dispatch_render(ctx: AnnotationRenderContext, annotation: Dictionary) -> void:
	var kind_name: StringName = StringName(annotation.get("kind", ""))
	var kind := get_annotation_kind(kind_name)
	if kind == null:
		# Unknown kind — placeholder rendering is handled by a separate subsystem.
		# Log once per kind per session (logging deduplication is caller's responsibility).
		push_warning(
			"[AnnotationRegistry] Unknown annotation kind '%s' — "
			% str(kind_name) +
			"placeholder rendering not yet implemented (separate task)."
		)
		return
	kind.render(ctx, annotation)


## Dispatch hit_test() to the appropriate kind.
## Returns false for unknown kinds (AABB hit is available through bounds() dispatch).
func dispatch_hit_test(
	annotation: Dictionary,
	point: Vector2,
	threshold: float
) -> bool:
	var kind_name: StringName = StringName(annotation.get("kind", ""))
	var kind := get_annotation_kind(kind_name)
	if kind == null:
		# Unknown kind: fall back to AABB hit via bounds
		var b := dispatch_bounds(annotation)
		return b.grow(threshold).has_point(point)
	return kind.hit_test(annotation, point, threshold)


## Dispatch bounds() to the appropriate kind.
## For unknown kinds, computes bounds from primitives[] directly (design §10).
func dispatch_bounds(annotation: Dictionary) -> Rect2:
	var kind_name: StringName = StringName(annotation.get("kind", ""))
	var kind := get_annotation_kind(kind_name)
	if kind == null:
		# Unknown kind: substrate computes bounds from primitives (design §10)
		var prims = annotation.get("primitives", [])
		if prims is Array:
			return AnnotationKind.bounds_from_primitives(prims)
		return Rect2()
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

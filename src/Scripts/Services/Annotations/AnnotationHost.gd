class_name AnnotationHost
extends RefCounted
## Editor-side protocol for annotation authoring tools.
##
## Design §11.2. A thin interface that authoring tools (AnnotationAuthorTool
## subclasses) use to interact with their host editor. Each editor that hosts an
## AnnotationToolbar subclasses AnnotationHost and overrides these methods.
##
## Base-class implementations are no-ops / sensible defaults so that:
##   - Mock hosts in tests can subclass and override only what they need.
##   - Plugins that miss a method don't crash — they get a logged warning and a
##     safe fallback value.
##
## Ownership: the editor creates one AnnotationHost and passes it to
## AnnotationToolbar.set_host(). The toolbar forwards it to each tool on
## activation via AnnotationAuthorTool.on_activate(host).

const AnnotationResolveCacheScript = preload("res://Scripts/Services/Annotations/AnnotationResolveCache.gd")

# ── Selection ──────────────────────────────────────────────────────────────────

## Emitted when the selected annotation changes. Emits "" when selection is
## cleared. Subclasses MUST emit this when the selected id changes.
## Declared on the base class so all hosts share the contract; subclasses
## are the actual emitters, so the parser can't see usage from this file.
@warning_ignore("unused_signal")
signal selection_changed(annotation_id: String)

var _anchor_resolvers: Dictionary = {}
var resolve_cache: Object = null


func _init() -> void:
	resolve_cache = AnnotationResolveCacheScript.new()

# ── Registry ───────────────────────────────────────────────────────────────────

## Return the AnnotationRegistry used by this editor.
## The toolbar and tools use this to look up kinds.
## Subclasses MUST override; reaching the base implementation indicates a
## missing override (programmer error, not a runtime condition).
func get_registry() -> AnnotationRegistry:
	push_error("[AnnotationHost] get_registry() not overridden — returning null")
	return null


## Return the v2 anchor registry used by this editor, if one is available.
## Subclasses that accept v2 annotations should override this and call
## validate_annotation_anchor() before storing or updating an annotation.
func get_anchor_registry() -> Object:
	return null


func validate_annotation_anchor(annotation: Dictionary) -> Array:
	if not annotation.has("anchor"):
		return []
	var registry := get_anchor_registry()
	if registry == null:
		return ["AnnotationHost has no AnnotationAnchorRegistry"]
	return registry.validate_anchor(annotation["anchor"])


# ── V2 anchor resolution ──────────────────────────────────────────────────────

## Resolve an anchor to screen-space for rendering. Hosts with live semantic
## documents should override this or register per-anchor callables; the base
## fallback deliberately marks anchors stale and renders at snapshot.position.
func resolve_anchor(anchor: Dictionary) -> Dictionary:
	var resolver: Variant = _anchor_resolvers.get(_anchor_key(anchor), Callable())
	if resolver is Callable and (resolver as Callable).is_valid():
		return _normalise_resolve_result((resolver as Callable).call(anchor), anchor)

	var pos := _snapshot_position_2d(anchor.get("snapshot", {}))
	return {
		"position": pos,
		"bounds": Rect2(pos, Vector2.ZERO),
		"stale": true,
		"view_metadata": {},
	}


## Screen-space hit-test rectangle for an anchor in a view. Subclasses can
## override when hit bounds depend on view_context beyond resolve_anchor().bounds.
func anchor_screen_rect(anchor: Dictionary, _view_context: String) -> Rect2:
	var resolved := resolve_anchor(anchor)
	var bounds: Variant = resolved.get("bounds", Rect2(resolved.get("position", Vector2.ZERO), Vector2.ZERO))
	if bounds is Rect2:
		return bounds
	var pos: Vector2 = resolved.get("position", Vector2.ZERO)
	return Rect2(pos, Vector2.ZERO)


## Register a host-local resolver callable for a full anchor key like
## "core/text.range" or "cad/edge". This is useful for plugin hosts that want
## composition over subclassing.
func register_anchor_resolver(anchor_type: String, resolver: Callable) -> void:
	if anchor_type.strip_edges().is_empty():
		push_warning("[AnnotationHost] Cannot register empty anchor resolver key")
		return
	if not resolver.is_valid():
		push_warning("[AnnotationHost] Cannot register invalid anchor resolver for %s" % anchor_type)
		return
	_anchor_resolvers[anchor_type] = resolver


func has_anchor_resolver_for(anchor_type: String) -> bool:
	return _anchor_resolvers.has(anchor_type)


func _resolve_anchor_cached(anchor: Dictionary, view_context: String) -> Dictionary:
	if resolve_cache == null:
		return resolve_anchor(anchor)
	return resolve_cache.resolve(anchor, self, view_context)


func invalidate_resolve_cache(anchor_type: String = "") -> void:
	if resolve_cache != null and resolve_cache.has_method("invalidate"):
		resolve_cache.invalidate(anchor_type)


func bump_revision() -> void:
	if resolve_cache != null and resolve_cache.has_method("bump_revision"):
		resolve_cache.bump_revision()


func get_revision() -> int:
	if resolve_cache != null and resolve_cache.has_method("revision"):
		return int(resolve_cache.revision())
	return 0


func capture_state_snapshot() -> Variant:
	return null


func restore_state_snapshot(_snapshot: Variant) -> bool:
	return false


func _anchor_key(anchor: Dictionary) -> String:
	return "%s/%s" % [str(anchor.get("plugin", "")), str(anchor.get("type", ""))]


func _normalise_resolve_result(value: Variant, anchor: Dictionary) -> Dictionary:
	if not value is Dictionary:
		var pos := _snapshot_position_2d(anchor.get("snapshot", {}))
		return {"position": pos, "bounds": Rect2(pos, Vector2.ZERO), "stale": true, "view_metadata": {}}

	var result: Dictionary = (value as Dictionary).duplicate(true)
	var pos: Variant = result.get("position", _snapshot_position_2d(anchor.get("snapshot", {})))
	if not pos is Vector2:
		pos = _to_vec2(pos)
	result["position"] = pos

	var bounds: Variant = result.get("bounds", Rect2(pos, Vector2.ZERO))
	if not bounds is Rect2:
		bounds = Rect2(pos, Vector2.ZERO)
	result["bounds"] = bounds

	result["stale"] = bool(result.get("stale", false))
	var meta: Variant = result.get("view_metadata", {})
	result["view_metadata"] = meta if meta is Dictionary else {}
	return result


func _snapshot_position_2d(snapshot: Variant) -> Vector2:
	if not snapshot is Dictionary:
		return Vector2.ZERO
	return _to_vec2((snapshot as Dictionary).get("position", Vector2.ZERO))


func _to_vec2(value: Variant) -> Vector2:
	if value is Vector2:
		return value
	if value is Vector3:
		return Vector2(value.x, value.y)
	if value is Array and (value as Array).size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return Vector2.ZERO

# ── Document mutation ──────────────────────────────────────────────────────────

## Add a completed annotation dict to the editor's document.
## Returns the assigned annotation id (substrate-generated "ann_<hex>").
## Subclasses MUST override; reaching the base implementation indicates a
## missing override (programmer error, not a runtime condition).
func add_annotation(_annotation: Dictionary) -> String:
	push_error("[AnnotationHost] add_annotation() not overridden — annotation not stored")
	return ""


## Replace a stored annotation by id. The new_annotation dict is stamped with
## the original id before storing. Returns true on success, false if id unknown.
## Subclass MUST emit annotations_changed (or equivalent) on success.
## Subclasses MUST override; base implementation is a programmer-error trap.
func update_annotation(_annotation_id: String, _new_annotation: Dictionary) -> bool:
	push_error("[AnnotationHost] update_annotation() not overridden")
	return false


## Remove an annotation by id. Returns true if removed, false if id unknown.
## If the removed annotation is currently selected, the selection MUST be
## cleared. Subclasses MUST override; base implementation is a programmer-error trap.
func remove_annotation(_annotation_id: String) -> bool:
	push_error("[AnnotationHost] remove_annotation() not overridden")
	return false


## Track which annotation is currently selected. Empty string = no selection.
## Subclass MUST emit selection_changed when the value changes. Default no-ops.
func set_selected_annotation_id(_annotation_id: String) -> void:
	pass


## Return the current selection id, or "" if none. Default returns "".
func get_selected_annotation_id() -> String:
	return ""


## Return the current document's annotation list. Manipulation tools iterate
## this to hit-test, render halos, etc. Concrete subclasses store annotations
## internally; the base default returns []. Subclasses override.
func get_annotations() -> Array:
	return []

# ── Coordinate transforms ──────────────────────────────────────────────────────

## Convert a document-space point to screen-space pixels.
## Default: identity (document == screen, useful for tests with zoom=1).
func transform_doc_to_screen(p: Vector2) -> Vector2:
	return p


## Convert a screen-space point to document-space.
## Default: identity.
func transform_screen_to_doc(p: Vector2) -> Vector2:
	return p

# ── View context ───────────────────────────────────────────────────────────────

## Return the current view context string (e.g. "pcb", "cad:top", "graphics").
## Tools embed this in the annotation envelope they build.
## Default returns "" — override in each editor.
func get_view_context() -> String:
	return ""

# ── Semantic hit-testing ───────────────────────────────────────────────────────

## Return a semantic identifier for whatever is at document-space point doc_pos.
##
## Format conventions (all optional — hosts pick what makes sense):
##   "ui:Label"          — a UI label node named "Label"
##   "label.word:this"   — a specific word in a label
##   "component:R12"     — a PCB/CAD component reference
##   ""                  — nothing meaningful at this point
##
## The return value is written into annotation["anchored_to"] by _stamp_anchor().
## Returning "" is valid and means "no meaningful target here."
## Default returns "" — override in each editor that can identify content.
func describe_point(_doc_pos: Vector2) -> String:
	return ""

# ── Compositing ────────────────────────────────────────────────────────────────

## Render the host's underlying content (NOT annotations) into an Image that
## covers viewport_rect in document space.
##
## Used by render_overlay(include_document=true) to composite the host content
## beneath the annotation layer. Hosts that can produce a viewport image should
## override this; others return null and the overlay falls back to a transparent
## background.
##
## viewport_rect is expressed in document coordinates. The returned Image should
## have dimensions matching the pixel size of that rect (i.e. the caller handles
## coordinate mapping). Returning null is valid and safe.
func render_content_to_image(_viewport_rect: Rect2) -> Image:
	return null

# ── Anchor stamping helpers ────────────────────────────────────────────────────

## Write the semantic anchor for a single annotation in-place.
##
## Computes: kind.primary_anchor_point(annotation) → host.describe_point() →
## annotation["anchored_to"]. Always overwrites anchored_to (even with "") so
## the value always reflects current host state. No-ops silently when the host
## or its registry is null, or when the kind is not registered.
static func _stamp_anchor(annotation: Dictionary, host: AnnotationHost) -> void:
	if host == null:
		return
	var registry := host.get_registry()
	if registry == null:
		return
	var kind_name := StringName(annotation.get("kind", ""))
	var kind := registry.get_annotation_kind(kind_name)
	if kind == null:
		return
	var anchor_point: Vector2 = kind.primary_anchor_point(annotation)
	var target: String = kind.describe_target_point(annotation, anchor_point, host)
	annotation["anchored_to"] = target


## Stamp anchors for every annotation in the list in-place.
##
## Walks annotations and calls _stamp_anchor on each Dictionary entry.
## Intended for use by hosts on save to catch unobserved UI changes
## (e.g. components that moved since the annotation was authored).
static func refresh_all_anchors(annotations: Array, host: AnnotationHost) -> void:
	for ann in annotations:
		if ann is Dictionary:
			_stamp_anchor(ann, host)

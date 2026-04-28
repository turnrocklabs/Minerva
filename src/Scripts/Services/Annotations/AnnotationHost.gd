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

# ── Selection ──────────────────────────────────────────────────────────────────

## Emitted when the selected annotation changes. Emits "" when selection is
## cleared. Subclasses MUST emit this when the selected id changes.
## Declared on the base class so all hosts share the contract; subclasses
## are the actual emitters, so the parser can't see usage from this file.
@warning_ignore("unused_signal")
signal selection_changed(annotation_id: String)

# ── Registry ───────────────────────────────────────────────────────────────────

## Return the AnnotationRegistry used by this editor.
## The toolbar and tools use this to look up kinds.
## Subclasses MUST override; reaching the base implementation indicates a
## missing override (programmer error, not a runtime condition).
func get_registry() -> AnnotationRegistry:
	push_error("[AnnotationHost] get_registry() not overridden — returning null")
	return null

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

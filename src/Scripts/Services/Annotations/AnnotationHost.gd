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
signal selection_changed(annotation_id: String)

# ── Registry ───────────────────────────────────────────────────────────────────

## Return the AnnotationRegistry used by this editor.
## The toolbar and tools use this to look up kinds.
## Default returns null; override in each editor.
func get_registry() -> AnnotationRegistry:
	push_warning("[AnnotationHost] get_registry() not overridden — returning null")
	return null

# ── Document mutation ──────────────────────────────────────────────────────────

## Add a completed annotation dict to the editor's document.
## Returns the assigned annotation id (substrate-generated "ann_<hex>").
## Default implementation logs a warning and returns an empty string.
func add_annotation(annotation: Dictionary) -> String:
	push_warning("[AnnotationHost] add_annotation() not overridden — annotation not stored")
	return ""


## Replace a stored annotation by id. The new_annotation dict is stamped with
## the original id before storing. Returns true on success, false if id unknown.
## Subclass MUST emit annotations_changed (or equivalent) on success.
## Default returns false with a push_warning.
func update_annotation(annotation_id: String, new_annotation: Dictionary) -> bool:
	push_warning("[AnnotationHost] update_annotation() not overridden")
	return false


## Remove an annotation by id. Returns true if removed, false if id unknown.
## If the removed annotation is currently selected, the selection MUST be
## cleared. Default returns false with a push_warning.
func remove_annotation(annotation_id: String) -> bool:
	push_warning("[AnnotationHost] remove_annotation() not overridden")
	return false


## Track which annotation is currently selected. Empty string = no selection.
## Subclass MUST emit selection_changed when the value changes. Default no-ops.
func set_selected_annotation_id(annotation_id: String) -> void:
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

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

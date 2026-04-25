class_name Helloscene_AnnotationHost
extends AnnotationHost
## AnnotationHost for the hello_scene plugin panel.
##
## First real consumer of the annotation substrate (design §11.2). The
## hello panel uses an unscaled, unscrolled Control as its drawing surface,
## so document-space and screen-space are identical (identity transforms).
## CAD/PCB hosts will replace these transforms with their camera matrices
## later — the wiring pattern (registry + host + toolbar + canvas) is the
## same.
##
## Ownership:
##   - The panel creates one instance and one AnnotationRegistry.
##   - The toolbar is given the host via set_host() so authoring tools can
##     call into it on activation.
##   - The canvas is given the host via set_host() so it can read the
##     annotation list and queue redraws when annotations are added.
##
## class_name prefix "Helloscene" = canonical_prefix("hello_scene")
## per design §6.1: plugin_id.replace("_","").lower() → first-upper.

## Emitted whenever the annotation list mutates (add or bulk replace).
## The canvas listens and queues a redraw.
signal annotations_changed()

# ── Internal state ─────────────────────────────────────────────────────────────

## Registry shared with the toolbar. The panel populates this with
## BuiltinKinds.register_all(reg) at panel-load time.
var _registry: AnnotationRegistry = null

## The list of annotations currently on the panel. Each entry is a
## complete annotation envelope dict.
var _annotations: Array = []  # Array[Dictionary]

# ── AnnotationHost overrides ───────────────────────────────────────────────────

func get_registry() -> AnnotationRegistry:
	return _registry


## Append an annotation to the document. Assigns an id if none is present
## (the substrate convention is "ann_<hex>"), emits annotations_changed,
## and returns the assigned id so callers can track it.
func add_annotation(annotation: Dictionary) -> String:
	var id: String = str(annotation.get("id", ""))
	if id.is_empty():
		id = "ann_%x" % randi()
	# Avoid mutating the caller's dict.
	var stored: Dictionary = annotation.duplicate(true)
	stored["id"] = id
	_annotations.append(stored)
	annotations_changed.emit()
	return id


## Identity transform: the hello canvas is screen-space already at zoom 1,
## so document coordinates equal screen pixels. Overridden explicitly
## (despite matching the base default) to document the intent — CAD/PCB
## subclasses will have non-trivial transforms.
func transform_doc_to_screen(p: Vector2) -> Vector2:
	return p


## Identity inverse — see transform_doc_to_screen.
func transform_screen_to_doc(p: Vector2) -> Vector2:
	return p


## View context string embedded in every annotation authored on this panel.
func get_view_context() -> String:
	return "hello"


# ── Hello-panel-specific API (not part of AnnotationHost protocol) ────────────

## Returns the annotation list for the canvas to iterate during _draw.
## The returned array is the live list — callers must not mutate it.
func get_annotations() -> Array:
	return _annotations


## Replace the annotation list wholesale (used by panel save/load to restore
## from .__panel_state). Emits annotations_changed so the canvas redraws.
func set_annotations(list: Array) -> void:
	_annotations = []
	for ann in list:
		if ann is Dictionary:
			_annotations.append((ann as Dictionary).duplicate(true))
	annotations_changed.emit()

class_name AnnotationAuthorTool
extends RefCounted
## Abstract base class for annotation authoring AND manipulation tools.
##
## Design §11.2. One instance per annotation kind (returned by kind.author_ui())
## for authoring tools, or one instance per non-kind manipulation tool (Select,
## Translate, Rotate, Scale) instantiated directly by the toolbar's Tools section.
## Receives forwarded pointer/input events from the host editor in document-space
## coordinates.
##
## Dual-signal contract:
##   - Authoring tools (arrow, text, region, …) CREATE new annotations and emit
##     `annotation_ready(annotation)` when authoring completes. The toolbar/canvas
##     responds by calling host.add_annotation(annotation).
##   - Manipulation tools (Select, Translate, Rotate, Scale, …) modify EXISTING
##     annotations and emit `annotation_modified(annotation_id, new_annotation)`
##     when a change is committed. The toolbar/canvas responds by calling
##     host.update_annotation(annotation_id, new_annotation).
##   - Both authoring and manipulation tools share `cancelled()` for explicit
##     user abort (Escape, right-click).
##
## A given subclass should emit ONLY ONE of {annotation_ready, annotation_modified}
## — never both — depending on whether it creates or modifies. cancelled() is
## shared. Selection-only tools (e.g. Select) may emit no committal signal at
## all; they just call host.set_selected_annotation_id() and host.remove_annotation()
## directly through host APIs that already broadcast their own change signals.
##
## Subclass contract:
##   - Override on_activate(), on_deactivate() for setup/teardown.
##   - Override on_pointer_down(), on_pointer_move(), on_pointer_up() to handle input.
##     Return true from pointer_down/up to consume the event (prevent host default handling).
##   - Override draw_preview() to render an in-progress visual during authoring/manipulation.
##   - Emit annotation_ready(annotation) (authoring) OR annotation_modified(id, new)
##     (manipulation) with a fully-formed annotation Dictionary when done.
##   - Emit cancelled() to abort and clean up (no annotation added/changed).
##
## AnnotationHost provides document context (registry, add_annotation,
## update_annotation, remove_annotation, selection, transforms, view_context).
## Authoring tools should NOT call host.add_annotation() directly — emit
## annotation_ready and let AnnotationToolbar call it, so the toolbar can update
## UI state. Selection-only tools (Select) may call host.set_selected_annotation_id()
## and host.remove_annotation() directly because these mutate host state without
## producing a new annotation envelope.

## Emitted when the user has completed authoring an annotation.
## annotation is a full annotation envelope dict (design §2.1) without an id;
## the substrate assigns one on add.
signal annotation_ready(annotation: Dictionary)

## Emitted when a manipulation tool changes an existing annotation. Toolbar
## or canvas should call host.update_annotation(annotation_id, new_dict) on
## receipt. Author tools that CREATE annotations emit `annotation_ready`
## instead and never use this signal.
signal annotation_modified(annotation_id: String, new_annotation: Dictionary)

## Emitted when authoring/manipulation is aborted (Escape, tool switch, kind deregister).
signal cancelled()

# ── Lifecycle ──────────────────────────────────────────────────────────────────

## Called when this tool becomes the active tool in the toolbar.
## host provides access to the editor's registry, add_annotation, and transforms.
func on_activate(host: AnnotationHost) -> void:
	pass


## Called when this tool is deactivated (another tool selected, toolbar hidden,
## or the owning kind is deregistered).
## Implementations should clean up any in-progress state and emit cancelled()
## if an authoring operation is in progress.
func on_deactivate() -> void:
	pass

# ── Pointer / input forwarding ─────────────────────────────────────────────────
## Coordinates are in document-space (host has applied the editor's transform).

## Called when a pointer button is pressed.
## Returns true to consume the event (prevent host default handling).
func on_pointer_down(pos: Vector2, button: int, mods: int) -> bool:
	return false


## Called when the pointer moves (with or without a button held).
func on_pointer_move(pos: Vector2) -> void:
	pass


## Called when a pointer button is released.
## Returns true to consume the event.
func on_pointer_up(pos: Vector2, button: int, mods: int) -> bool:
	return false

# ── Optional preview ───────────────────────────────────────────────────────────

## Draw an in-progress preview of the annotation being authored.
## Called by the editor's draw callback while this tool is active.
## Default implementation is a no-op (no preview).
func draw_preview(ctx: AnnotationRenderContext) -> void:
	pass

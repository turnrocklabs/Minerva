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

## Emitted whenever the annotation list mutates (add, update, remove, or bulk
## replace). The canvas listens and queues a redraw.
signal annotations_changed()

# ── Internal state ─────────────────────────────────────────────────────────────

## Registry shared with the toolbar. The panel populates this with
## BuiltinKinds.register_all(reg) at panel-load time.
var _registry: AnnotationRegistry = null

## The list of annotations currently on the panel. Each entry is a
## complete annotation envelope dict.
var _annotations: Array = []  # Array[Dictionary]

## The id of the currently selected annotation, or "" if none.
var _selected_id: String = ""

## Tolerance margin (pixels) added to each control's rect during _find_leaf_at hit
## testing. Allows arrows and other annotations whose head is drawn a few pixels
## outside a widget's exact rect to still resolve to that widget.
const _TOLERANCE_MARGIN: float = 16.0

## Canvas Control node — needed to compute canvas-global coords for describe_point.
## Set via set_canvas_and_root() called from HelloPanel._ready().
var _canvas_node: Control = null

## Root Control of the panel (HelloPanel itself). Used to walk the UI tree in
## describe_point(). Set via set_canvas_and_root().
var _ui_root: Control = null

## Pre-cached panel image, refreshed via RenderingServer.frame_post_draw after
## each annotation mutation event so MCP callers get a synchronous (non-stalling)
## result from render_content_to_image. Null until the first post-draw capture
## completes or until the host is destroyed.
var _cached_panel_image: Image = null

## Re-entrancy guard: true while a frame_post_draw capture is already scheduled.
## Prevents multiple annotation_changed signals queued in the same frame from
## each registering their own one-shot listener.
var _cache_refresh_pending: bool = false

# ── AnnotationHost overrides ───────────────────────────────────────────────────

func get_registry() -> AnnotationRegistry:
	return _registry


## Append an annotation to the document. Assigns an id if none is present
## (the substrate convention is "ann_<hex>"), stamps anchored_to via
## _stamp_anchor, emits annotations_changed, and returns the assigned id
## so callers can track it.
func add_annotation(annotation: Dictionary) -> String:
	var id: String = str(annotation.get("id", ""))
	if id.is_empty():
		id = "ann_%x" % randi()
	# Avoid mutating the caller's dict.
	var stored: Dictionary = annotation.duplicate(true)
	stored["id"] = id
	# Stamp the anchor BEFORE appending so listeners see the final state.
	AnnotationHost._stamp_anchor(stored, self)
	_annotations.append(stored)
	_schedule_cache_refresh()
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


## Replace the annotation at annotation_id with new_annotation, re-stamping the
## original id and anchor onto the new dict. Returns false if id not found.
func update_annotation(annotation_id: String, new_annotation: Dictionary) -> bool:
	for i in range(_annotations.size()):
		var entry: Dictionary = _annotations[i] as Dictionary
		if str(entry.get("id", "")) == annotation_id:
			var stored: Dictionary = new_annotation.duplicate(true)
			stored["id"] = annotation_id
			# Re-stamp the anchor BEFORE storing so listeners see the final state.
			AnnotationHost._stamp_anchor(stored, self)
			_annotations[i] = stored
			_schedule_cache_refresh()
			annotations_changed.emit()
			return true
	return false


## Remove the annotation at annotation_id. If it is currently selected,
## the selection is cleared and selection_changed("") is emitted.
## Returns false if id not found.
func remove_annotation(annotation_id: String) -> bool:
	for i in range(_annotations.size()):
		var entry: Dictionary = _annotations[i] as Dictionary
		if str(entry.get("id", "")) == annotation_id:
			_annotations.remove_at(i)
			if _selected_id == annotation_id:
				_selected_id = ""
				selection_changed.emit("")
			_schedule_cache_refresh()
			annotations_changed.emit()
			return true
	return false


## Set the selected annotation id. Emits selection_changed only when the
## value actually changes to avoid signal spam.
func set_selected_annotation_id(annotation_id: String) -> void:
	if _selected_id == annotation_id:
		return
	_selected_id = annotation_id
	selection_changed.emit(_selected_id)


## Return the currently selected annotation id, or "" if none.
func get_selected_annotation_id() -> String:
	return _selected_id


# ── Hello-panel-specific API (not part of AnnotationHost protocol) ────────────

## Returns a SHALLOW DUPLICATE of the annotation list so consumers can iterate
## safely without coordinating with subsequent add/remove/update calls. The
## annotation Dicts inside are still the same instances; callers must not
## mutate those — use update_annotation(id, new_dict) instead.
func get_annotations() -> Array:
	return _annotations.duplicate()


## Replace the annotation list wholesale (used by panel save/load to restore
## from .__panel_state). Re-stamps anchors on every loaded entry so the
## anchored_to values reflect the current UI state. Emits annotations_changed
## so the canvas redraws.
func set_annotations(list: Array) -> void:
	_annotations = []
	for ann in list:
		if ann is Dictionary:
			_annotations.append((ann as Dictionary).duplicate(true))
	AnnotationHost.refresh_all_anchors(_annotations, self)
	_schedule_cache_refresh()
	annotations_changed.emit()


# ── Hello-panel-specific describe_point ───────────────────────────────────────

## Set the canvas node and UI root that describe_point uses to resolve coords.
## Called from HelloPanel._ready() after the canvas and host are wired up.
func set_canvas_and_root(canvas: Control, root: Control) -> void:
	_canvas_node = canvas
	_ui_root = root
	_schedule_cache_refresh()


## Map a canvas-local document-space point to a semantic UI identifier.
##
## Format outcomes:
##   "label.word:<word>"  — point lands on a word inside a Label's text
##   "ui:<NodeName>"      — point lands on a named leaf control (Button, LineEdit, etc.)
##   ""                   — nothing meaningful at this point
##
## Coordinate model: the canvas uses identity transforms, so doc_pos is in
## canvas-local (== document) coordinates. We convert to global screen coords
## by adding the canvas node's global_position, then walk the panel tree to
## find the topmost leaf Control under that point.
func describe_point(doc_pos: Vector2) -> String:
	if _ui_root == null or _canvas_node == null:
		return ""

	# Convert canvas-local doc coords to global screen coords.
	var canvas_global: Vector2 = _canvas_node.global_position + doc_pos

	# Walk the UI tree and find the deepest leaf Control that contains the point,
	# excluding the canvas itself and its descendants (AnnotationToolbar, AnnotationCanvas).
	var hit := _find_leaf_at(_ui_root, canvas_global)
	if hit == null:
		return ""

	# Special case: Label — try word-level resolution first.
	if hit is Label:
		var label: Label = hit as Label
		var word := _resolve_word(label, canvas_global)
		if not word.is_empty():
			return "label.word:" + word

	return "ui:" + hit.name


## Recursively walk ctrl's children to find the deepest leaf Control under
## global_pos. Skips the canvas node and its descendants (they are the
## annotation drawing surface, not UI content we want to annotate "onto").
## Also skips pure layout containers (VBoxContainer, HBoxContainer).
## Applies _TOLERANCE_MARGIN to all rect checks so annotations drawn a few pixels
## outside a widget's exact boundary still resolve to that widget.
func _find_leaf_at(ctrl: Control, global_pos: Vector2) -> Control:
	# Check all children first (depth-first, last-child = top-most in draw order).
	# Grow by _TOLERANCE_MARGIN so children of containers that slightly overhang
	# their parent's rect are still visited (handles negative-margin layouts).
	var best: Control = null
	for i in range(ctrl.get_child_count()):
		var child := ctrl.get_child(i)
		if not (child is Control):
			continue
		var child_ctrl := child as Control
		# Skip the canvas and annotation toolbar subtrees entirely — those are
		# the annotation drawing surface, not labelled UI content.
		var child_name: String = child_ctrl.name
		if child_name == "AnnotationCanvas" or child_name == "AnnotationToolbar":
			continue
		# Only recurse into children whose grown rect contains the point.
		if not child_ctrl.get_global_rect().grow(_TOLERANCE_MARGIN).has_point(global_pos):
			continue
		var result := _find_leaf_at(child_ctrl, global_pos)
		if result != null:
			best = result

	if best != null:
		return best

	# Check this node itself. Skip layout containers (VBoxContainer, HBoxContainer,
	# Control without a meaningful class name) — we want leaf-level widgets.
	if not ctrl.get_global_rect().grow(_TOLERANCE_MARGIN).has_point(global_pos):
		return null

	# Skip pure layout containers by class name.
	var cls: String = ctrl.get_class()
	if cls == "VBoxContainer" or cls == "HBoxContainer" or cls == "Control":
		return null

	return ctrl


## Return the pre-cached panel image.
##
## The image is captured asynchronously via RenderingServer.frame_post_draw so
## that MCP tool handlers never block on a GPU→CPU sync. The first call after
## the host is created (or after the panel is opened) will return null while the
## initial capture is pending; subsequent calls return the last good image.
##
## viewport_rect ignored in v1; full panel always rendered. The parameter is
## reserved for future partial-region rendering.
func render_content_to_image(_viewport_rect: Rect2) -> Image:
	if _cached_panel_image == null:
		# Cache is cold — schedule a refresh so the next MCP call gets a result,
		# but return null immediately rather than blocking on GPU→CPU sync.
		_schedule_cache_refresh()
	return _cached_panel_image


## Schedule a one-shot frame_post_draw capture if not already pending.
##
## Pattern follows PluginScenePanelHost.gd CONNECT_ONE_SHOT usage: connect a
## lambda to the signal with CONNECT_ONE_SHOT so it fires exactly once on the
## next rendered frame then auto-disconnects.
func _schedule_cache_refresh() -> void:
	if _cache_refresh_pending:
		return  # already queued, de-dup
	if _ui_root == null:
		return  # can't capture without a UI root — try again after set_canvas_and_root
	_cache_refresh_pending = true
	RenderingServer.frame_post_draw.connect(
		func() -> void: _do_capture_now(),
		CONNECT_ONE_SHOT)


## Perform the actual viewport capture and store the result in _cached_panel_image.
## Called from a frame_post_draw one-shot lambda so the GPU pipeline has flushed
## and get_image() is safe to call without a multi-minute stall.
func _do_capture_now() -> void:
	# Clear the pending flag first so any annotation event arriving DURING this
	# capture can re-schedule immediately (1-frame staleness is acceptable).
	_cache_refresh_pending = false

	if not is_instance_valid(_ui_root):
		return  # host or panel torn down between scheduling and firing

	var vp := _ui_root.get_viewport()
	if vp == null:
		return
	var vp_tex := vp.get_texture()
	if vp_tex == null:
		return
	var full_image := vp_tex.get_image()
	if full_image == null:
		return
	var root_rect := _ui_root.get_global_rect()
	var crop_rect := Rect2i(root_rect.position, root_rect.size)
	# Clamp to image bounds so get_region() never goes out of range.
	crop_rect = crop_rect.intersection(Rect2i(Vector2i.ZERO, full_image.get_size()))
	if crop_rect.size.x <= 0 or crop_rect.size.y <= 0:
		# Degenerate rect — leave _cached_panel_image unchanged so we don't clobber
		# a previous good capture with a transient failure (e.g. panel mid-resize).
		return
	_cached_panel_image = full_image.get_region(crop_rect)


## Resolve which word in label's text is under the given global screen position.
## Uses a character-width approximation consistent with AnnotationText._text_aabb
## (base * 0.55 per character at default size 14) since headless tests have no
## real font metrics available.
func _resolve_word(label: Label, global_pos: Vector2) -> String:
	var text: String = label.text
	if text.is_empty():
		return ""

	# Try to get the real font size from the theme; fall back to 14.
	var font_size: float = 14.0
	if label.get_theme_font_size("font_size") > 0:
		font_size = float(label.get_theme_font_size("font_size"))

	# Compute x offset of the test point relative to the label's left edge.
	var local_x: float = global_pos.x - label.global_position.x

	# Walk through words, accumulating their widths (with a space between each).
	var words: PackedStringArray = text.split(" ")
	var char_w: float = font_size * 0.55
	var space_w: float = char_w  # approximate space width as one char-width
	var cursor: float = 0.0

	for word in words:
		if word.is_empty():
			cursor += space_w
			continue
		var word_w: float = word.length() * char_w
		if local_x >= cursor and local_x < cursor + word_w:
			return word
		cursor += word_w + space_w

	return ""

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

## Canvas Control node — needed to compute canvas-global coords for describe_point.
## Set via set_canvas_and_root() called from HelloPanel._ready().
var _canvas_node: Control = null

## Root Control of the panel (HelloPanel itself). Used to walk the UI tree in
## describe_point(). Set via set_canvas_and_root().
var _ui_root: Control = null

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
	annotations_changed.emit()


# ── Hello-panel-specific describe_point ───────────────────────────────────────

## Set the canvas node and UI root that describe_point uses to resolve coords.
## Called from HelloPanel._ready() after the canvas and host are wired up.
func set_canvas_and_root(canvas: Control, root: Control) -> void:
	_canvas_node = canvas
	_ui_root = root


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
func _find_leaf_at(ctrl: Control, global_pos: Vector2) -> Control:
	# Check all children first (depth-first, last-child = top-most in draw order).
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
		var result := _find_leaf_at(child_ctrl, global_pos)
		if result != null:
			best = result

	if best != null:
		return best

	# Check this node itself. Skip layout containers (VBoxContainer, HBoxContainer,
	# Control without a meaningful class name) — we want leaf-level widgets.
	if not ctrl.get_global_rect().has_point(global_pos):
		return null

	# Skip pure layout containers by class name.
	var cls: String = ctrl.get_class()
	if cls == "VBoxContainer" or cls == "HBoxContainer" or cls == "Control":
		return null

	return ctrl


## Render the panel's current UI into an Image by capturing the viewport
## texture and cropping to _ui_root's global rect.
##
## viewport_rect ignored in v1; full panel always rendered.
## Returns null if _ui_root is not set, the viewport texture is unavailable
## (headless GPU-less mode), or the resulting crop rect is degenerate.
## The viewport_rect parameter is reserved for future partial-region rendering.
func render_content_to_image(_viewport_rect: Rect2) -> Image:
	# Defensive check: _ui_root is wired by set_canvas_and_root() (Unit B).
	# Using "in self" lets this method return null gracefully if called before
	# Unit B lands, so test ordering does not matter.
	if not ("_ui_root" in self) or _ui_root == null:
		return null
	var vp := _ui_root.get_viewport()
	if vp == null:
		return null
	var vp_tex := vp.get_texture()
	if vp_tex == null:
		return null
	var full_image := vp_tex.get_image()
	if full_image == null:
		return null
	var root_rect := _ui_root.get_global_rect()
	var crop_rect := Rect2i(root_rect.position, root_rect.size)
	# Clamp to image bounds so get_region() never goes out of range.
	crop_rect = crop_rect.intersection(Rect2i(Vector2i.ZERO, full_image.get_size()))
	if crop_rect.size.x <= 0 or crop_rect.size.y <= 0:
		return null
	return full_image.get_region(crop_rect)


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

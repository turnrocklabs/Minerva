class_name Helloscene_AnnotationCanvas
extends Control
## Drawing surface for hello_scene annotations.
##
## Owns no annotation state itself — reads from a Helloscene_AnnotationHost
## via host.get_annotations() each _draw, and forwards pointer/key events
## to the active AnnotationAuthorTool (provided by the toolbar through
## set_active_tool()).
##
## Coordinate model:
##   The hello canvas uses identity transforms (zoom 1, no pan), so local
##   widget coordinates ARE document coordinates. AnnotationRenderContext
##   is built with Transform2D.IDENTITY and zoom=1.0.
##
##   ⚠️ NOT for cargo-cult by CAD/PCB: those editors have a camera with pan
##   and zoom; their canvas must build the AnnotationRenderContext using the
##   real viewport transform and live zoom factor, not IDENTITY. Their
##   _gui_input may also need to consume MOUSE_MOTION mid-drag so parent
##   pan/zoom doesn't fight an in-progress author tool — hello does not.
##
## Preview-redraw contract (matches AnnotationArrowAuthorTool top-of-file
## comment): we redraw on pointer-move and on annotations_changed. We do
## NOT do per-frame _process redraw — pointer-move covers the only state
## the in-progress preview can change.
##
## class_name prefix "Helloscene" = canonical_prefix("hello_scene")
## per design §6.1.

# ── State ──────────────────────────────────────────────────────────────────────

var _host: Helloscene_AnnotationHost = null
var _active_tool: AnnotationAuthorTool = null

const _BADGE_RADIUS := 10.0
const _BADGE_OFFSET := Vector2(10.0, -10.0)
const _BADGE_FILL := Color(0.08, 0.10, 0.12, 0.92)
const _BADGE_STROKE := Color(1.0, 0.72, 0.22, 1.0)
const _BADGE_TEXT := Color.WHITE

# ── Public API ─────────────────────────────────────────────────────────────────

## Bind this canvas to the panel's annotation host.
## Connects to host.annotations_changed so the canvas redraws when an
## annotation is added (or the list is bulk-replaced via set_annotations).
## Also connects to host.selection_changed so the selection halo refreshes
## whenever the user selects/deselects an annotation.
func set_host(host: Helloscene_AnnotationHost) -> void:
	if _host != null:
		if _host.annotations_changed.is_connected(_on_annotations_changed):
			_host.annotations_changed.disconnect(_on_annotations_changed)
		if _host.selection_changed.is_connected(queue_redraw):
			_host.selection_changed.disconnect(queue_redraw)
	_host = host
	if _host != null:
		_host.annotations_changed.connect(_on_annotations_changed)
		_host.selection_changed.connect(queue_redraw)
	queue_redraw()


## Set or clear the active authoring tool. The toolbar pushes this on tool
## activation/deactivation via its active_tool_changed signal.
## Disconnects annotation_modified from the previous tool (if any) and
## connects it to the new one (if it has that signal) so manipulation-tool
## changes are forwarded to the host via _on_tool_annotation_modified.
func set_active_tool(tool: AnnotationAuthorTool) -> void:
	# Disconnect from the outgoing tool's annotation_modified.
	if _active_tool != null:
		if _active_tool.annotation_modified.is_connected(_on_tool_annotation_modified):
			_active_tool.annotation_modified.disconnect(_on_tool_annotation_modified)
	_active_tool = tool
	# Connect to the incoming tool's annotation_modified (manipulation tools emit
	# this; authoring tools never do). The toolbar also connects annotation_modified
	# on its side for host.update_annotation; having both connected is safe because
	# the host's update_annotation is idempotent for equal-content calls.
	if _active_tool != null:
		if not _active_tool.annotation_modified.is_connected(_on_tool_annotation_modified):
			_active_tool.annotation_modified.connect(_on_tool_annotation_modified)
	queue_redraw()


# ── Drawing ────────────────────────────────────────────────────────────────────

func _draw() -> void:
	if _host == null:
		return
	var registry: AnnotationRegistry = _host.get_registry()
	var ctx := AnnotationRenderContext.create(
		get_canvas_item(),
		Transform2D.IDENTITY,
		Rect2(Vector2.ZERO, size),
		theme,
		1.0,
		_host.get_view_context()
	)
	ctx.host = _host

	# Render each annotation. dispatch_render handles unknown-kind placeholders
	# (grey dashed rect with kind name) per design §10.
	for ann in _host.get_annotations():
		if registry != null:
			registry.dispatch_render(ctx, ann)
		if ann is Dictionary:
			_draw_annotation_number_badge(ann as Dictionary)

	# In-progress preview from the active tool, if any.
	if _active_tool != null:
		_active_tool.draw_preview(ctx)


# ── Input ──────────────────────────────────────────────────────────────────────

func _gui_input(event: InputEvent) -> void:
	if _active_tool == null:
		return

	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		var mods := _mods_from_event(mb)
		if mb.pressed:
			var consumed := _active_tool.on_pointer_down(mb.position, mb.button_index, mods)
			if consumed:
				accept_event()
		else:
			var consumed_up := _active_tool.on_pointer_up(mb.position, mb.button_index, mods)
			if consumed_up:
				accept_event()
		queue_redraw()
		return

	if event is InputEventMouseMotion:
		var mm: InputEventMouseMotion = event
		_active_tool.on_pointer_move(mm.position)
		queue_redraw()
		return

	if event is InputEventKey:
		var ek: InputEventKey = event
		if ek.pressed and not ek.is_echo():
			if ek.keycode == KEY_ESCAPE:
				# Surface Escape to the tool via the mods channel (per
				# AnnotationArrowAuthorTool.on_pointer_down's Escape contract: when
				# mods == KEY_ESCAPE the tool treats it as a cancel). pos/button
				# are unused on the cancel path.
				var consumed := _active_tool.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, KEY_ESCAPE)
				if consumed:
					accept_event()
				queue_redraw()
			elif ek.keycode == KEY_DELETE:
				# Surface Delete to the tool via the mods channel.
				# AnnotationSelectTool interprets mods == KEY_DELETE as a remove
				# command on the currently-selected annotation.
				var consumed := _active_tool.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, KEY_DELETE)
				if consumed:
					accept_event()
				queue_redraw()


# ── Helpers ────────────────────────────────────────────────────────────────────

## Pack Godot modifier-key state into a bitmask. The exact bit values are
## not part of the AnnotationAuthorTool contract — tools that care about
## Shift/Ctrl/Alt should agree on the encoding with their host. We use the
## Godot KEY_MASK_* values for portability.
func _mods_from_event(event: InputEventWithModifiers) -> int:
	var mods := 0
	if event.shift_pressed:
		mods |= KEY_MASK_SHIFT
	if event.ctrl_pressed:
		mods |= KEY_MASK_CTRL
	if event.alt_pressed:
		mods |= KEY_MASK_ALT
	if event.meta_pressed:
		mods |= KEY_MASK_META
	return mods


func get_annotation_badge_position(annotation: Dictionary) -> Vector2:
	var base_pos: Variant = _annotation_badge_anchor_position(annotation)
	if base_pos == null:
		base_pos = Vector2.ZERO
	return _clamp_badge_position((base_pos as Vector2) + _BADGE_OFFSET)


func _draw_annotation_number_badge(annotation: Dictionary) -> void:
	if _host == null:
		return
	var index := int(annotation.get("display_index", 0))
	if index <= 0 and _host.has_method("get_annotation_display_index"):
		index = int(_host.get_annotation_display_index(annotation))
	if index <= 0:
		return

	var text := str(index)
	var center := get_annotation_badge_position(annotation)
	var radius := maxf(_BADGE_RADIUS, 7.0 + float(text.length()) * 3.0)
	draw_circle(center, radius, _BADGE_FILL)
	draw_arc(center, radius, 0.0, TAU, 32, _BADGE_STROKE, 2.0, true)

	var font := get_theme_font(&"font")
	if font == null:
		font = ThemeDB.fallback_font
	if font == null:
		return
	var font_size := 12
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var baseline := center + Vector2(-text_size.x * 0.5, font_size * 0.36)
	draw_string(font, baseline, text, HORIZONTAL_ALIGNMENT_LEFT, -1.0, font_size, _BADGE_TEXT)


func _annotation_badge_anchor_position(annotation: Dictionary) -> Variant:
	var kind := str(annotation.get("kind", ""))
	match kind:
		"callout":
			return _resolve_position_source(annotation.get("anchor", null))
		"2d_arrow":
			return _arrow_badge_anchor_position(annotation)
		"2d_text":
			var text_pos: Variant = _text_badge_anchor_position(annotation)
			if text_pos != null:
				return text_pos
	return _resolve_position_source(annotation.get("anchor", null))


func _arrow_badge_anchor_position(annotation: Dictionary) -> Variant:
	var payload: Variant = annotation.get("kind_payload", {})
	if payload is Dictionary and (payload as Dictionary).has("endpoint_b"):
		var endpoint_pos: Variant = _resolve_position_source((payload as Dictionary).get("endpoint_b", null))
		if endpoint_pos != null:
			return endpoint_pos
	var prims: Variant = annotation.get("primitives", [])
	if prims is Array:
		for prim in prims:
			if prim is Dictionary and str((prim as Dictionary).get("kind", "")) == "arrow":
				return _resolve_position_source((prim as Dictionary).get("to", null))
	return null


func _text_badge_anchor_position(annotation: Dictionary) -> Variant:
	var anchor_pos: Variant = _resolve_position_source(annotation.get("anchor", null))
	if anchor_pos != null:
		return anchor_pos
	var prims: Variant = annotation.get("primitives", [])
	if prims is Array:
		for prim in prims:
			if prim is Dictionary and str((prim as Dictionary).get("kind", "")) == "text":
				return _resolve_position_source((prim as Dictionary).get("at", null))
	return null


func _resolve_position_source(source: Variant) -> Variant:
	if _host != null and _host.has_method("resolve_position_source"):
		var resolved: Variant = _host.resolve_position_source(source)
		if resolved is Vector2:
			return resolved
	if source is Vector2:
		return source
	if source is Vector3:
		return Vector2((source as Vector3).x, (source as Vector3).y)
	if source is Array and (source as Array).size() >= 2:
		return Vector2(float((source as Array)[0]), float((source as Array)[1]))
	if source is Dictionary:
		var d: Dictionary = source
		if d.has("x") and d.has("y") and not d.has("plugin"):
			return Vector2(float(d.get("x", 0.0)), float(d.get("y", 0.0)))
		var snapshot: Variant = d.get("snapshot", {})
		if snapshot is Dictionary and (snapshot as Dictionary).has("position"):
			return _array_or_vector_to_vec2((snapshot as Dictionary).get("position"))
	return null


func _array_or_vector_to_vec2(value: Variant) -> Vector2:
	if value is Vector2:
		return value
	if value is Vector3:
		return Vector2((value as Vector3).x, (value as Vector3).y)
	if value is Array and (value as Array).size() >= 2:
		return Vector2(float((value as Array)[0]), float((value as Array)[1]))
	return Vector2.ZERO


func _clamp_badge_position(pos: Vector2) -> Vector2:
	if size.x <= 0.0 or size.y <= 0.0:
		return pos
	var margin := _BADGE_RADIUS + 2.0
	return Vector2(
		clampf(pos.x, margin, maxf(margin, size.x - margin)),
		clampf(pos.y, margin, maxf(margin, size.y - margin))
	)


# ── Signal handlers ────────────────────────────────────────────────────────────

func _on_annotations_changed() -> void:
	queue_redraw()


## Called when the active manipulation tool emits annotation_modified.
## Forwards the change to the host so the host's annotations_changed signal
## fires and the canvas redraws with the updated annotation.
func _on_tool_annotation_modified(annotation_id: String, new_annotation: Dictionary) -> void:
	if _host == null:
		return
	_host.update_annotation(annotation_id, new_annotation)
	queue_redraw()

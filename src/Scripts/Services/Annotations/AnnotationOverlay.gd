class_name AnnotationOverlay
extends Control
## Shared base for editor annotation overlays.
##
## The important contract is input discipline: overlays are transparent while
## idle and only claim pointer/key events while an authoring or manipulation tool
## is active. Control.MOUSE_FILTER_PASS is deliberately avoided because it does
## not forward events to siblings behind the overlay.

signal active_tool_changed(tool: Object)

const _BADGE_RADIUS := 10.0
const _BADGE_OFFSET := Vector2(10.0, -10.0)
const _BADGE_FILL := Color(0.08, 0.10, 0.12, 0.92)
const _BADGE_STROKE := Color(1.0, 0.72, 0.22, 1.0)
const _BADGE_TEXT := Color.WHITE
const _HALO_COLOR := Color(1.0, 0.78, 0.30, 0.85)
const _HALO_GROW := 4.0

var _host: RefCounted = null
var _active_tool: AnnotationAuthorTool = null


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	focus_mode = Control.FOCUS_ALL
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func set_host(host: RefCounted) -> void:
	if _host != null:
		if _host.annotations_changed.is_connected(_on_annotations_changed):
			_host.annotations_changed.disconnect(_on_annotations_changed)
		if _host.selection_changed.is_connected(_on_selection_changed):
			_host.selection_changed.disconnect(_on_selection_changed)
	_host = host
	if _host != null:
		_host.annotations_changed.connect(_on_annotations_changed)
		_host.selection_changed.connect(_on_selection_changed)
	queue_redraw()


func _on_annotations_changed() -> void:
	queue_redraw()


func _on_selection_changed(_annotation_id: String) -> void:
	queue_redraw()


func set_active_tool(tool: AnnotationAuthorTool) -> void:
	if _active_tool != null:
		if _active_tool.annotation_modified.is_connected(_on_tool_annotation_modified):
			_active_tool.annotation_modified.disconnect(_on_tool_annotation_modified)
		if _active_tool.has_method("on_deactivate"):
			_active_tool.on_deactivate()
	_active_tool = tool
	if _active_tool != null:
		if not _active_tool.annotation_modified.is_connected(_on_tool_annotation_modified):
			_active_tool.annotation_modified.connect(_on_tool_annotation_modified)
	mouse_filter = Control.MOUSE_FILTER_STOP if _active_tool != null else Control.MOUSE_FILTER_IGNORE
	active_tool_changed.emit(_active_tool)
	queue_redraw()


func clear_active_tool() -> void:
	set_active_tool(null)


func has_active_tool() -> bool:
	return _active_tool != null


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

	for ann in _host.get_annotations():
		if registry != null:
			registry.dispatch_render(ctx, ann)
		if ann is Dictionary:
			_draw_annotation_number_badge(ann as Dictionary)

	if _active_tool != null:
		_active_tool.draw_preview(ctx)

	var tool_owns_selection_visual := _active_tool is AnnotationSelectTool or _active_tool is AnnotationTransformTool
	if _host != null and not tool_owns_selection_visual:
		var sel_id: String = _host.get_selected_annotation_id()
		if not sel_id.is_empty():
			for ann in _host.get_annotations():
				if not ann is Dictionary:
					continue
				if str((ann as Dictionary).get("id", "")) != sel_id:
					continue
				var ann_dict: Dictionary = ann as Dictionary
				var kind_name := StringName(ann_dict.get("kind", ""))
				var kind: AnnotationKind = registry.get_annotation_kind(kind_name) if registry != null else null
				if kind == null:
					break
				var halo_rect: Rect2 = kind.bounds(ann_dict)
				if halo_rect.size.length() < 0.5:
					break
				draw_rect(halo_rect.grow(_HALO_GROW), _HALO_COLOR, false, 2.0)
				break


func _gui_input(event: InputEvent) -> void:
	if _active_tool == null:
		return

	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		var mods := _mods_from_event(mb)
		if mb.pressed:
			if mb.button_index == MOUSE_BUTTON_LEFT:
				grab_focus()
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
				var consumed := _active_tool.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, KEY_ESCAPE)
				if consumed:
					accept_event()
				queue_redraw()
			elif ek.keycode == KEY_DELETE:
				var consumed := _active_tool.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, KEY_DELETE)
				if consumed:
					accept_event()
				queue_redraw()


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


func _on_tool_annotation_modified(annotation_id: String, new_annotation: Dictionary) -> void:
	if _host == null:
		return
	_host.update_annotation(annotation_id, new_annotation)
	queue_redraw()

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
	# Re-render when our own rect changes (pane resize / layout change) so a
	# host whose transform derives from the live rect stays aligned.
	if not resized.is_connected(_on_view_changed):
		resized.connect(_on_view_changed)


func set_host(host: RefCounted) -> void:
	if _host != null:
		if _host.annotations_changed.is_connected(_on_annotations_changed):
			_host.annotations_changed.disconnect(_on_annotations_changed)
		if _host.selection_changed.is_connected(_on_selection_changed):
			_host.selection_changed.disconnect(_on_selection_changed)
		if _host.has_signal("view_changed") and _host.view_changed.is_connected(_on_view_changed):
			_host.view_changed.disconnect(_on_view_changed)
	_host = host
	if _host != null:
		_host.annotations_changed.connect(_on_annotations_changed)
		_host.selection_changed.connect(_on_selection_changed)
		# Hosts with a movable/scaled surface emit view_changed on pan/zoom/resize.
		if _host.has_signal("view_changed") and not _host.view_changed.is_connected(_on_view_changed):
			_host.view_changed.connect(_on_view_changed)
	queue_redraw()


func _on_view_changed() -> void:
	queue_redraw()


## Document → on-screen (overlay-local) transform from the host; identity for
## hosts that don't override it, so legacy behavior is unchanged.
func _view_transform() -> Transform2D:
	if _host != null and _host.has_method("get_annotation_view_transform"):
		return _host.get_annotation_view_transform()
	return Transform2D.IDENTITY


func _view_zoom() -> float:
	if _host != null and _host.has_method("get_annotation_zoom"):
		return float(_host.get_annotation_zoom())
	return 1.0


func _on_annotations_changed() -> void:
	queue_redraw()


func _on_selection_changed(_annotation_id: String) -> void:
	queue_redraw()


func set_active_tool(tool: AnnotationAuthorTool) -> void:
	if _active_tool != null:
		if _active_tool.annotation_modified.is_connected(_on_tool_annotation_modified):
			_active_tool.annotation_modified.disconnect(_on_tool_annotation_modified)
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
	var view_xform := _view_transform()
	var ctx := AnnotationRenderContext.create(
		get_canvas_item(),
		view_xform,
		Rect2(Vector2.ZERO, size),
		theme,
		_view_zoom(),
		_host.get_view_context()
	)
	ctx.host = _host

	for ann in _host.get_annotations():
		# Host visibility veto (e.g. pcb layer filter hiding B.Cu route hints,
		# WC-2 C3 fix): a hidden annotation is neither rendered nor badged.
		if ann is Dictionary and not _host_annotation_visible(ann as Dictionary):
			continue
		if registry != null:
			# Host-owned canvas; the host overlay subclass draws this kind.
			var ann_kind_name := StringName((ann as Dictionary).get("kind", "")) if ann is Dictionary else StringName("")
			var ann_kind: AnnotationKind = registry.get_annotation_kind(ann_kind_name)
			if ann_kind != null and not ann_kind.has_visual_render():
				continue
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
				if not _host_annotation_visible(ann_dict):
					break
				var kind_name := StringName(ann_dict.get("kind", ""))
				var kind: AnnotationKind = registry.get_annotation_kind(kind_name) if registry != null else null
				if kind == null:
					break
				# Host-owned canvas; the host overlay subclass draws this kind.
				if not kind.has_visual_render():
					break
				var halo_rect: Rect2 = view_xform * kind.bounds(ann_dict)
				if halo_rect.size.length() < 0.5:
					break
				draw_rect(halo_rect.grow(_HALO_GROW), _HALO_COLOR, false, 2.0)
				break


func _gui_input(event: InputEvent) -> void:
	if _active_tool == null:
		return

	# Navigation pass-through (pcb-ui-native-cluster §1a): tools only own
	# LEFT/RIGHT pointer input. MIDDLE-button events, wheel events, pan
	# gestures, and middle-drag motion are canvas navigation — forwarded to a
	# duck-typed host method forward_navigation_input(event) (the PCB host
	# relays to the board canvas's pan/zoom handling) and NEVER given to the
	# tool. Hosts without the hook simply keep today's behavior (the overlay
	# consumes the event; tools still never see it).
	if _is_navigation_event(event):
		if _host != null and _host.has_method("forward_navigation_input"):
			_host.forward_navigation_input(event)
		accept_event()
		queue_redraw()
		return

	# Pass RAW overlay-local pixels. Every tool owns the screen→doc mapping via
	# _host.transform_screen_to_doc(pos) — that is the documented per-tool
	# contract (see AnnotationTranslateTool/AnnotationScaleTool headers and every
	# author tool). The overlay must NOT pre-convert to doc space: on hosts with
	# a real view transform (e.g. the PCB panel, board-mm ↔ canvas px) that
	# double-inverts the position — annotations land near the origin instead of
	# under the cursor. (On identity-transform hosts the two conventions
	# coincide, which is how the pre-conversion went unnoticed.) This requires
	# the overlay to be mounted so its local space IS the host transform's
	# target space — see Editor.gd's get_annotation_overlay_parent duck-typing.

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
			elif ek.keycode == KEY_DELETE or ek.keycode == KEY_BACKSPACE:
				# macOS keyboards label Backspace as "Delete" and emit KEY_BACKSPACE;
				# forward-delete (Fn+Delete) emits KEY_DELETE. Accept both, surface
				# as KEY_DELETE to the tool so its mods contract is unchanged.
				var consumed := _active_tool.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, KEY_DELETE)
				if consumed:
					accept_event()
				queue_redraw()
			elif ek.keycode == KEY_ENTER or ek.keycode == KEY_KP_ENTER:
				# Enter forwarding (pcb-ui-native-cluster §1b): same pseudo-pointer
				# convention as Esc/Del above. Numpad Enter surfaces as KEY_ENTER so
				# tools handle one keycode (mirrors the BACKSPACE→DELETE normalize).
				var consumed := _active_tool.on_pointer_down(Vector2.ZERO, MOUSE_BUTTON_LEFT, KEY_ENTER)
				if consumed:
					accept_event()
				queue_redraw()


## True when the event is canvas navigation (pan/zoom), not tool input:
## middle button press/release, any wheel button, a trackpad pan gesture, or
## mouse motion while the middle button is held (a middle-drag pan in
## progress). Left/right buttons and plain motion remain tool input.
func _is_navigation_event(event: InputEvent) -> bool:
	if event is InputEventPanGesture:
		return true
	if event is InputEventMouseButton:
		return (event as InputEventMouseButton).button_index in [
			MOUSE_BUTTON_MIDDLE,
			MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN,
			MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT,
		]
	if event is InputEventMouseMotion:
		return ((event as InputEventMouseMotion).button_mask & MOUSE_BUTTON_MASK_MIDDLE) != 0
	return false


## Host visibility veto for one annotation (duck-typed; hosts without the
## hook show everything). See AnnotationHost.is_annotation_visible.
func _host_annotation_visible(annotation: Dictionary) -> bool:
	if _host == null or not _host.has_method("is_annotation_visible"):
		return true
	return bool(_host.is_annotation_visible(annotation))


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
	# Badge anchor resolves in document space; map to screen, then add the
	# pixel offset so the badge gap is constant regardless of view scale.
	var screen_pos: Vector2 = _view_transform() * (base_pos as Vector2)
	return _clamp_badge_position(screen_pos + _BADGE_OFFSET)


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

class_name DrawingTool
extends BaseTool

# Minimum pressure for feather-light touches
const MIN_PRESSURE := 0.01

@export var _color_picker_button: ColorPickerButton
@export var _brush_size_slider: Slider

var brush_color: Color:
	set(value):
		brush_color = value
		if not _color_picker_button.is_node_ready():
			await _color_picker_button.ready
		_color_picker_button.color = value
	get:
		return _color_picker_button.color

var brush_size: int:
	set(value):
		brush_size = value
		if not _brush_size_slider.is_node_ready():
			await _brush_size_slider.ready
		_brush_size_slider.value = value
	get:
		return int(_brush_size_slider.value)

var auto_expand: = true

var drawing: = false
var _last_drawing_position: Vector2
var _last_pressure: float = 1.0
var _smoothed_pressure: float = 1.0
var _pressure_smoothing_factor: float = 0.3
var _single_click: bool = false
var _waiting_for_motion: bool = false
var _saw_motion: bool = false
var _use_pressure: bool = true  # false = treat as mouse/no-pressure this stroke

# Performance optimizations
var _circle_cache = {}
var _max_cached_radius = 100

var current_stroke_command: GraphicsEditorUndo.DrawStrokeCommand

func _ready() -> void:
	editor.active_tool_changed.connect(
		func(tool_: BaseTool):
			if tool_ == self:
				var cursor_radius = roundi(brush_size / 2.0)
				var cursor_image = create_contrast_circle_cursor(cursor_radius)
				var hotspot = Vector2(cursor_image.get_width(), cursor_image.get_height()) / 2
				editor.set_custom_cursor(cursor_image, Input.CursorShape.CURSOR_ARROW, hotspot)
	)

	_brush_size_slider.value_changed.connect(
		func(value: float):
			var cursor_radius = roundi(value / 2.0)
			var cursor_image = create_contrast_circle_cursor(cursor_radius)
			var hotspot = Vector2(cursor_image.get_width(), cursor_image.get_height()) / 2
			editor.set_custom_cursor(cursor_image, Input.CursorShape.CURSOR_ARROW, hotspot)
	)
	
	# Pre-cache common brush sizes
	for r in range(1, min(30, _max_cached_radius)):
		_get_cached_circle_pixels(r)

func handle_input_event(event: InputEvent) -> bool:
	if not editor.active_layer: return false

	event = editor.active_layer.localize_input(event)

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if editor.selected_layers.size() > 1:
				display_tool_error(ToolError.MULTIPLE_LAYERS_SELECTED)
				return false
			
			if event.is_pressed():
				_start_stroke(event)
			else:
				_end_stroke(event)

			return true

	elif event is InputEventMouseMotion and drawing:
		_single_click = false
		_add_stroke_point(event)
		return true
	

	return false

func get_bounds_point_for_expansion(center: Vector2, radius: int) -> Vector2:
	var layer_size = editor.active_layer.image.get_size()
	var bounds_point = center
	
	if center.x > layer_size.x * 0.5:
		bounds_point.x += radius
	else:
		bounds_point.x -= radius
	
	if center.y > layer_size.y * 0.5:
		bounds_point.y += radius
	else:
		bounds_point.y -= radius
	
	return bounds_point

func get_actual_brush_radius(pressure: float) -> int:
	var visual_zoom = editor.layers_container.scale.x
	var actual_diameter = (brush_size * pressure) / visual_zoom
	var radius = int(ceil(actual_diameter * 0.5))
	return max(radius, 1)

func _pressure_from_event(ev: InputEvent) -> float:
	if ev is InputEventScreenDrag:
		return clamp(ev.pressure, MIN_PRESSURE, 1.0)
	elif ev is InputEventMouseMotion:
		return clamp(ev.pressure, MIN_PRESSURE, 1.0)
	elif ev is InputEventScreenTouch:
		# Some devices provide pressure on press/release
		return clamp(ev.pressure, MIN_PRESSURE, 1.0)
	return 1.0  # Default to full pressure for unknown event types (mouse)

func _start_stroke(event: InputEvent) -> void:
	drawing = true
	_single_click = true
	_last_drawing_position = event.position
	
	# Seed with a safe low default, or real pressure if this event has it (e.g., touch).
	var start_pressure := 0.1
	if event is InputEventScreenTouch: # touch has pressure on press
		start_pressure = clamp(event.pressure, MIN_PRESSURE, 1.0)
	
	_smoothed_pressure = start_pressure
	_last_pressure = start_pressure
	_waiting_for_motion = true
	_saw_motion = false
	_use_pressure = true
	
	# Handle layer expansion first (if needed)
	var max_radius = get_actual_brush_radius(1.0)
	var bounds_point = get_bounds_point_for_expansion(event.position, max_radius)
	var offset = editor.active_layer.expand_to_point(bounds_point)
	
	if offset != Vector2.ZERO:
		# Create resize command for layer expansion
		var resize_command = GraphicsEditorUndo.ResizeCommand.new(
			editor.active_layer, 
			editor.active_layer.position - offset
		)
		resize_command.set_new_image(editor.active_layer.image)  # After expansion
		editor.execute_command(resize_command)
		editor.active_layer.position -= offset
	
	# Update event after potential layer changes
	event = editor.active_layer.localize_input(event)
	_last_drawing_position = event.position
	
	# this needs to be calculated after the stroke has been finished
	# Create drawing command - captures "before" state
	# var stroke_bounds = _calculate_stroke_bounds(event.position)

	current_stroke_command = GraphicsEditorUndo.DrawStrokeCommand.new(editor.active_layer)


func _add_stroke_point(event: InputEvent) -> void:
	var pos: Vector2 = event.position
	var p := _pressure_from_event(event)
	
	if _waiting_for_motion:
		_waiting_for_motion = false
		_saw_motion = true
		
		# Heuristic: a mouse "looks" like constant full pressure with zero tilt.
		var looks_like_mouse: bool = (event is InputEventMouseMotion 
									   and is_equal_approx(p, 1.0) 
									   and (event.tilt == Vector2.ZERO))
		_use_pressure = not looks_like_mouse
		
		# Use the first real sample as-is (no ramp from 0.1)
		_smoothed_pressure = p
		_last_pressure = p
		
		# Expand & localize before optional "touchdown" stamp
		var radius := get_actual_brush_radius(_smoothed_pressure)
		var bounds_point := get_bounds_point_for_expansion(pos, radius)
		var offset := editor.active_layer.expand_to_point(bounds_point)
		editor.active_layer.position -= offset
		event = editor.active_layer.localize_input(event)
		pos = event.position
		
		# Optional: stamp once at touchdown using the true first pressure
		_draw_brush_stamp(
			editor.active_layer.image,
			pos,
			brush_color,
			brush_size * (p if _use_pressure else 1.0)
		)
		editor.queue_redraw()
		
		_last_drawing_position = pos
		_single_click = false   # Important: clear this flag to prevent double stamping
		return
	
	# Subsequent motion: smooth only if we're actually using pressure
	if _use_pressure:
		_smoothed_pressure = lerp(_smoothed_pressure, p, _pressure_smoothing_factor)
	else:
		_smoothed_pressure = 1.0
	
	# Expand layer if needed
	var radius = get_actual_brush_radius(_smoothed_pressure)
	var bounds_point = get_bounds_point_for_expansion(pos, radius)
	var offset = editor.active_layer.expand_to_point(bounds_point)
	editor.active_layer.position -= offset
	event = editor.active_layer.localize_input(event)
	pos = event.position
	
	# Draw continuous line between last and current position
	_draw_continuous_line(
		_last_drawing_position, 
		pos, 
		_last_pressure if _use_pressure else 1.0,
		_smoothed_pressure if _use_pressure else 1.0
	)
	
	_last_drawing_position = pos
	_last_pressure = _smoothed_pressure
	editor.queue_redraw()

func _end_stroke(event: InputEvent) -> void:
	# Handle single click - draw one dot
	if _single_click:
		# Clicks/taps with no motion: use full pressure for mouse, touch pressure if available
		var p := 1.0
		if event is InputEventScreenTouch:
			p = clamp(event.pressure, MIN_PRESSURE, 1.0)  # touch reports pressure on press/release
		_draw_brush_stamp(
			editor.active_layer.image,
			_last_drawing_position,
			brush_color,
			brush_size * p
		)
		editor.queue_redraw()
	
	# Finalize and execute the drawing command
	if current_stroke_command:
		current_stroke_command.finalize_stroke()  # Captures "after" state
		editor.execute_command(current_stroke_command)
		current_stroke_command = null
	
	drawing = false
	_single_click = false
	_waiting_for_motion = false
	_saw_motion = false

## Helper function to calculate the bounds of the stroke
func _calculate_stroke_bounds(center_pos: Vector2) -> Rect2i:
	var max_radius = get_actual_brush_radius(1.0)
	var top_left = Vector2i(
		int(center_pos.x - max_radius),
		int(center_pos.y - max_radius)
	)
	var size = Vector2i(max_radius * 2, max_radius * 2)
	
	# Clamp to layer bounds
	var layer_size = editor.active_layer.image.get_size()
	top_left.x = max(0, top_left.x)
	top_left.y = max(0, top_left.y)
	size.x = min(size.x, layer_size.x - top_left.x)
	size.y = min(size.y, layer_size.y - top_left.y)
	
	return Rect2i(top_left, size)

func _draw_continuous_line(start_pos: Vector2, end_pos: Vector2, start_pressure: float, end_pressure: float) -> void:
	var distance = start_pos.distance_to(end_pos)
	var effective_brush_size = brush_size * max(start_pressure, end_pressure)
	
	# Calculate step size based on brush size for smooth lines
	var step_size = max(1.0, effective_brush_size * 0.15)
	var steps = max(1, int(ceil(distance / step_size)))
	
	for i in range(steps + 1):
		var t = float(i) / steps if steps > 0 else 0.0
		var lerp_pos = start_pos.lerp(end_pos, t)
		var lerp_pressure = lerp(start_pressure, end_pressure, t)
		
		_draw_brush_stamp(
			editor.active_layer.image,
			lerp_pos,
			brush_color,
			brush_size * lerp_pressure
		)

func _draw_brush_stamp(target_image: Image, center: Vector2, color: Color, diameter: float) -> void:
	var visual_zoom = editor.layers_container.scale.x
	var actual_diameter = diameter / visual_zoom
	var radius = max(1, int(ceil(actual_diameter * 0.5)))
	
	var pixels = _get_cached_circle_pixels(radius)
	var center_x = int(center.x)
	var center_y = int(center.y)
	var img_width = target_image.get_width()
	var img_height = target_image.get_height()
	
	for offset in pixels:
		var x = center_x + offset.x
		var y = center_y + offset.y
		
		if x >= 0 and x < img_width and y >= 0 and y < img_height:
			var alpha_factor = offset.z
			
			if alpha_factor >= 0.99:
				target_image.set_pixel(x, y, color)
			else:
				var new_color = color
				new_color.a *= alpha_factor
				
				if new_color.a > 0.01:
					var existing_color = target_image.get_pixel(x, y)
					var blended_color = _blend_colors(existing_color, new_color)
					target_image.set_pixel(x, y, blended_color)

func _get_cached_circle_pixels(radius: int) -> Array:
	radius = min(radius, _max_cached_radius)
	
	if _circle_cache.has(radius):
		return _circle_cache[radius]
	
	var pixels = []
	var r_squared = radius * radius
	
	for x in range(-radius, radius + 1):
		for y in range(-radius, radius + 1):
			var dist_squared = x*x + y*y
			if dist_squared <= r_squared:
				var alpha_factor = 1.0
				
				if dist_squared > (radius-1) * (radius-1):
					var dist = sqrt(dist_squared)
					alpha_factor = max(0.0, 1.0 - (dist - (radius-1)))
				
				pixels.append(Vector3(x, y, alpha_factor))
	
	_circle_cache[radius] = pixels
	return pixels

func _blend_colors(bottom: Color, top: Color) -> Color:
	if top.a >= 0.99:
		return top
	if top.a <= 0.01:
		return bottom
		
	var one_minus_top_a = 1.0 - top.a
	var bottom_factor = bottom.a * one_minus_top_a
	var a = 1.0 - one_minus_top_a * (1.0 - bottom.a)
	
	if a < 0.01:
		return Color(0, 0, 0, 0)
	
	var inv_a = 1.0 / a
	var r = (top.r * top.a + bottom.r * bottom_factor) * inv_a
	var g = (top.g * top.a + bottom.g * bottom_factor) * inv_a
	var b = (top.b * top.a + bottom.b * bottom_factor) * inv_a
	
	return Color(r, g, b, a)

func create_contrast_circle_cursor(radius: int) -> Image:
	var size = radius * 2 + 3
	var image = Image.create(size, size, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	
	var center = size / 2
	draw_circle_outline(image, center, radius + 1, Color.BLACK)
	draw_circle_outline(image, center, radius, Color.WHITE)
	
	return image

func draw_circle_outline(image: Image, center: int, radius: int, color: Color):
	var x = radius
	var y = 0
	var decision = 1 - radius
	
	while x >= y:
		plot_circle_points(image, center, x, y, color)
		plot_circle_points(image, center, y, x, color)
		
		y += 1
		if decision <= 0:
			decision += 2 * y + 1
		else:
			x -= 1
			decision += 2 * (y - x) + 1

func plot_circle_points(image: Image, center: int, x: int, y: int, color: Color):
	var points = [
		Vector2i(center + x, center + y),
		Vector2i(center - x, center + y),
		Vector2i(center + x, center - y),
		Vector2i(center - x, center - y),
		Vector2i(center + y, center + x),
		Vector2i(center - y, center + x),
		Vector2i(center + y, center - x),
		Vector2i(center - y, center - x)
	]
	
	for point in points:
		if point.x >= 0 and point.x < image.get_width() and point.y >= 0 and point.y < image.get_height():
			image.set_pixel(point.x, point.y, color)

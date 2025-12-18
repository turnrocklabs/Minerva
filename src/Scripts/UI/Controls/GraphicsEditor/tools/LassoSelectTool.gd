class_name LassoSelectTool
extends BaseTool

enum SelectionMode { REPLACE, ADD, SUBTRACT, INTERSECT }

var selection_mode: SelectionMode = SelectionMode.REPLACE
var _is_dragging: bool = false
var _points: PackedVector2Array = PackedVector2Array()

func _ready() -> void:
	super()
	editor.active_tool_changed.connect(_on_tool_changed)

func _on_tool_changed(tool_: BaseTool) -> void:
	if tool_ == self:
		# Use crosshair cursor for precision
		editor.set_custom_cursor(null, Input.CURSOR_CROSS)
	else:
		# Cancel any in-progress selection when switching away
		_is_dragging = false
		_points.clear()

func handle_input_event(event: InputEvent) -> bool:
	if not editor.active_layer:
		return false

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		event = editor.active_layer.localize_input(event)

		if event.is_pressed():
			# Determine selection mode from modifier keys
			if Input.is_key_pressed(KEY_SHIFT) and Input.is_key_pressed(KEY_ALT):
				selection_mode = SelectionMode.INTERSECT
			elif Input.is_key_pressed(KEY_SHIFT):
				selection_mode = SelectionMode.ADD
			elif Input.is_key_pressed(KEY_ALT):
				selection_mode = SelectionMode.SUBTRACT
			else:
				selection_mode = SelectionMode.REPLACE

			_is_dragging = true
			_points.clear()
			_points.append(event.position)
			editor.selection_overlay.queue_redraw()
			return true
		else:
			# Mouse released - finalize selection
			if _is_dragging:
				_is_dragging = false
				# Close the path by adding start point if we have enough points
				if _points.size() >= 3:
					_create_lasso_selection()
				_points.clear()
				editor.selection_overlay.queue_redraw()
				return true

	elif event is InputEventMouseMotion and _is_dragging:
		event = editor.active_layer.localize_input(event)
		# Add point if it's far enough from the last point (avoid too many points)
		if _points.is_empty() or event.position.distance_to(_points[-1]) >= 2.0:
			_points.append(event.position)
		editor.selection_overlay.queue_redraw()
		return true

	return false

func _create_lasso_selection() -> void:
	var image := editor.active_layer.image
	var size := image.get_size()

	if _points.size() < 3:
		return  # Need at least 3 points for a polygon

	# Create temporary mask for this selection operation
	var new_selection = Image.create(size.x, size.y, false, Image.FORMAT_L8)
	new_selection.fill(Color.BLACK)

	# Get bounding box to optimize fill
	var min_x := int(size.x)
	var max_x := 0
	var min_y := int(size.y)
	var max_y := 0

	for point in _points:
		min_x = mini(min_x, int(point.x))
		max_x = maxi(max_x, int(point.x))
		min_y = mini(min_y, int(point.y))
		max_y = maxi(max_y, int(point.y))

	# Clamp to image bounds
	min_x = clampi(min_x, 0, size.x - 1)
	max_x = clampi(max_x, 0, size.x - 1)
	min_y = clampi(min_y, 0, size.y - 1)
	max_y = clampi(max_y, 0, size.y - 1)

	# Fill polygon using scanline algorithm
	for y in range(min_y, max_y + 1):
		var intersections: Array[float] = []

		# Find intersections with polygon edges
		var j = _points.size() - 1
		for i in range(_points.size()):
			var p1 = _points[i]
			var p2 = _points[j]

			if (p1.y <= y and p2.y > y) or (p2.y <= y and p1.y > y):
				# Calculate x intersection
				var x_intersect = p1.x + (y - p1.y) / (p2.y - p1.y) * (p2.x - p1.x)
				intersections.append(x_intersect)

			j = i

		# Sort intersections
		intersections.sort()

		# Fill between pairs of intersections
		for i in range(0, intersections.size() - 1, 2):
			var x1 = clampi(int(intersections[i]), min_x, max_x)
			var x2 = clampi(int(intersections[i + 1]), min_x, max_x)
			for x in range(x1, x2 + 1):
				if x >= 0 and x < size.x:
					new_selection.set_pixel(x, y, Color.WHITE)

	# Apply selection mode with bounding box for optimization
	_apply_selection(new_selection, Vector2i(min_x, min_y), Vector2i(max_x, max_y))

func _apply_selection(new_mask: Image, bbox_min: Vector2i = Vector2i.ZERO, bbox_max: Vector2i = Vector2i.ZERO) -> void:
	var size = new_mask.get_size()

	# Ensure editor has a selection mask
	if not editor.selection_mask or editor.selection_mask.get_size() != size:
		editor.create_selection_mask(size)

	# Use bounding box to limit iteration (much faster for small selections)
	var x_start = bbox_min.x if bbox_min != Vector2i.ZERO else 0
	var y_start = bbox_min.y if bbox_min != Vector2i.ZERO else 0
	var x_end = bbox_max.x + 1 if bbox_max != Vector2i.ZERO else size.x
	var y_end = bbox_max.y + 1 if bbox_max != Vector2i.ZERO else size.y

	# Clamp to valid range
	x_start = clampi(x_start, 0, size.x)
	y_start = clampi(y_start, 0, size.y)
	x_end = clampi(x_end, 0, size.x)
	y_end = clampi(y_end, 0, size.y)

	match selection_mode:
		SelectionMode.REPLACE:
			# For replace, just copy the new mask directly
			editor.selection_mask = new_mask.duplicate()
		SelectionMode.ADD:
			for y in range(y_start, y_end):
				for x in range(x_start, x_end):
					if new_mask.get_pixel(x, y).r > 0.5:
						editor.selection_mask.set_pixel(x, y, Color.WHITE)
		SelectionMode.SUBTRACT:
			for y in range(y_start, y_end):
				for x in range(x_start, x_end):
					if new_mask.get_pixel(x, y).r > 0.5:
						editor.selection_mask.set_pixel(x, y, Color.BLACK)
		SelectionMode.INTERSECT:
			for y in range(y_start, y_end):
				for x in range(x_start, x_end):
					if new_mask.get_pixel(x, y).r < 0.5:
						editor.selection_mask.set_pixel(x, y, Color.BLACK)

	# Update the selection cache after modifying the mask
	editor._update_selection_cache()
	editor.selection_changed.emit()
	editor.selection_overlay.queue_redraw()

## Returns true if currently dragging a lasso selection
func is_selecting() -> bool:
	return _is_dragging

## Get the current lasso points for drawing preview
func get_preview_points() -> PackedVector2Array:
	return _points

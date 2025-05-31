class_name BucketTool
extends BaseTool

@export var _color_picker_button: ColorPickerButton


var fill_color: Color:
	set(value):
		fill_color = value
		if not _color_picker_button.is_node_ready():
			await _color_picker_button.ready
		_color_picker_button.color = value
	get:
		return _color_picker_button.color


func _ready() -> void:
	super()


func handle_input_event(event: InputEvent) -> void:
	event = editor.active_layer.localize_input(event)

	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.is_pressed():
				fill(event.position)



func _tool_selected():
	pass


func fill(position: Vector2) -> void:
	var point := Vector2i(position.round())
	var image := editor.active_layer.image
	var size := image.get_size()
	
	if point.x < 0 or point.x >= size.x or point.y < 0 or point.y >= size.y:
		return
		
	var target_color := image.get_pixelv(point)
	if target_color == fill_color:
		return
	
	var stack := [point]
	
	while stack.size() > 0:
		var p = stack.pop_back()
		var x = p.x
		var y = p.y
		
		# Find leftmost pixel of this color on this row
		while x >= 0 and image.get_pixel(x, y) == target_color:
			x -= 1
		x += 1
		
		var span_above := false
		var span_below := false
		
		# Fill the scanline
		while x < size.x and image.get_pixel(x, y) == target_color:
			image.set_pixel(x, y, fill_color)
			
			# Check pixel above
			if not span_above and y > 0 and image.get_pixel(x, y - 1) == target_color:
				stack.push_back(Vector2i(x, y - 1))
				span_above = true
			elif span_above and y > 0 and image.get_pixel(x, y - 1) != target_color:
				span_above = false
				
			# Check pixel below  
			if not span_below and y < size.y - 1 and image.get_pixel(x, y + 1) == target_color:
				stack.push_back(Vector2i(x, y + 1))
				span_below = true
			elif span_below and y < size.y - 1 and image.get_pixel(x, y + 1) != target_color:
				span_below = false
				
			x += 1
	
	editor.queue_redraw()

class_name GraphicsEditorV2
extends PanelContainer

signal active_tool_changed(tool_: BaseTool)
signal active_layer_changed(layer: LayerV2)

@onready var layers_container: LayersContainer = %LayersContainer
@onready var layer_cards_container: Control = %LayerCardsContainer
@onready var tool_options_container: Control = %ToolOptionsContainer


# tool options containers
@onready var _brush_options_container: Control = %BrushOptions
@onready var _eraser_options_container: Control = %EraserOptions
@onready var _speech_bubble_options: Control = %SpeechBubbleOptions

@onready var drawing_tool: DrawingTool = %DrawingTool
@onready var pane_tool: PaneTool = %PaneTool
@onready var eraser_tool: EraserTool = %EraserTool
@onready var transform_tool: TransformTool = %TransformTool
@onready var speech_bubble_tool: SpeechBubbleTool = %SpeechBubbleTool


@onready var tool_options_mapping: = {
	drawing_tool: _brush_options_container,
	eraser_tool: _eraser_options_container,
	speech_bubble_tool: _speech_bubble_options,
}

var canvas_size: = Vector2i(1000, 1000)

var _custom_cursor: Resource
var _custom_cursor_shape: int
var _custom_cursor_hotspot: Vector2

var layers: Array[LayerV2]
	# get:
	# 	return layers_container.get_children().filter(func(n): return n is LayerV2) as Array[LayerV2]

var active_layer: LayerV2:
	set(value):
		active_layer = value
		for l in layers_container.get_children().filter(func(n): return n is LayerV2):
			l.get_meta("layer_card").selected = false
			l.transform_rect_visible = false
			l.queue_redraw() # editor queue_redraw will not redraw layers that are not active, so call it here to remove the controls points
		
		active_layer.get_meta("layer_card").selected = true
		queue_redraw()

		active_layer_changed.emit(active_layer)


var active_tool: BaseTool:
	set(value):
		active_tool = value
		# reset the cursor here,
		# so it happends before the signal is consumed by selected tool which may change it
		set_custom_cursor(null)
		_set_drag_forward_to_layer(active_tool)
		active_tool_changed.emit(value)


func _ready() -> void:
	
	active_tool_changed.connect(_on_active_tool_changed)
	
	setup()


func setup(canvas_size_: Vector2i = Vector2i(1000, 1000)) -> void:

	create_new_layer("Layer", canvas_size_)

	# layers_container.center_view()


func create_new_layer(layer_name: String, dimensions: Vector2i) -> LayerV2:
	# var img = Image.create(dimensions.x, dimensions.y, true, Image.FORMAT_RGBA8)
	# img.fill(Color.TRANSPARENT)

	var layer: = LayerV2.create_drawing_layer(layer_name, dimensions, Color.WHITE)
	var layer_card: = LayerCard.create(layer)
	
	# don't change the active_layer untill layer_card updates the layer metadata
	active_layer = layer

	layer_card.layer_clicked.connect(func(): active_layer = layer)
	layer_card.reorder.connect(
		func(to: int):
			reorder_layer(
				layer_card.layer,
				to
			)
	)

	layer_cards_container.add_child(layer_card)
	layer_cards_container.move_child(layer_card, 0)

	layers_container.add_child(layer, true)
	
	# place the layer at the center of the screen
	get_tree().process_frame.connect(
		func(): layer.position = layers_container.size/2 - layer.size/2,
		ConnectFlags.CONNECT_ONE_SHOT
	)

	layers.append(layer)

	return layer


func add_layer(layer: LayerV2):
	var layer_card: = LayerCard.create(layer)
	
	# don't change the active_layer untill layer_card updates the layer metadata
	active_layer = layer

	layer_card.layer_clicked.connect(func(): active_layer = layer)

	layer_cards_container.add_child(layer_card)
	layer_cards_container.move_child(layer_card, 0)

	layers_container.add_child(layer, true)

	layers.append(layer)
	
	return layer


func export_image(path: String) -> Error:
	# Get all layers
	var layer_nodes = layers_container.get_children().filter(func(n): return n is LayerV2)
	
	# If no layers, return error
	if layer_nodes.is_empty():
		return ERR_INVALID_DATA
	
	# Determine the bounding rectangle for all layers
	var bounds := Rect2()
	var first_layer := true
	
	for layer in layer_nodes:
		if layer is LayerV2:
			# For rotated layers, we need to calculate a more complex bounding rectangle
			var corners = _get_rotated_corners(layer)
			for corner in corners:
				if first_layer:
					bounds = Rect2(corner, Vector2.ZERO)
					first_layer = false
				else:
					bounds = bounds.expand(corner)
	
	# Create a new image with the determined size
	var width = int(bounds.size.x)
	var height = int(bounds.size.y)
	var output_image := Image.create(width, height, false, Image.FORMAT_RGBA8)
	
	# Make sure the image is transparent to start
	output_image.fill(Color(0, 0, 0, 0))
	
	# Blend all layers onto the output image
	for layer in layer_nodes:
		if layer is LayerV2 and layer.visible:
			# Get the layer's image
			var layer_image = layer.image
			
			# Skip empty layers
			if not layer_image or layer_image.is_empty():
				continue
			
			# Handle rotation using a transform
			var rotation_rad = layer.rotation
			var pivot = layer.pivot_offset
			var layer_pos = layer.position
			
			# Process each pixel in the output image space
			for out_y in range(height):
				for out_x in range(width):
					# Get position in global space
					var global_pos = Vector2(out_x, out_y) + bounds.position
					
					# Convert to layer local space (accounting for rotation)
					var local_pos = _global_to_layer_space(global_pos, layer_pos, rotation_rad, pivot)
					
					# Check if the point is within the layer's image
					var img_x = int(local_pos.x)
					var img_y = int(local_pos.y)
					
					if img_x >= 0 and img_x < layer_image.get_width() and img_y >= 0 and img_y < layer_image.get_height():
						var src_color = layer_image.get_pixel(img_x, img_y)
						
						# Skip fully transparent pixels
						if src_color.a <= 0.01:
							continue
							
						var dst_color = output_image.get_pixel(out_x, out_y)
						var blended = drawing_tool._blend_colors(dst_color, src_color)
						output_image.set_pixel(out_x, out_y, blended)
	
	# Save the image to the specified path
	var error := output_image.save_png(path)
	return error

# Helper function to get corners of a rotated layer
func _get_rotated_corners(layer: LayerV2) -> Array[Vector2]:
	var corners: Array[Vector2] = []
	var pivot = layer.pivot_offset
	var pos = layer.position
	var size = layer.size
	var rotation_rad = layer.rotation
	
	# Calculate the four corners in local space
	var local_corners = [
		Vector2(0, 0) - pivot,           # Top-left
		Vector2(size.x, 0) - pivot,      # Top-right
		Vector2(size.x, size.y) - pivot, # Bottom-right
		Vector2(0, size.y) - pivot       # Bottom-left
	]
	
	# Transform to global space
	for corner in local_corners:
		# Rotate
		var rotated = corner.rotated(rotation_rad)
		# Translate to global position
		var global_corner = rotated + pivot + pos
		corners.append(global_corner)
	
	return corners

# Convert from global space to layer's local space (accounting for rotation)
func _global_to_layer_space(global_pos: Vector2, layer_pos: Vector2, rotation_rad: float, pivot: Vector2) -> Vector2:
	# Translate to layer's origin
	var relative_pos = global_pos - layer_pos
	# Adjust for pivot point
	relative_pos -= pivot
	# Apply inverse rotation
	relative_pos = relative_pos.rotated(-rotation_rad)
	# Re-adjust for pivot
	relative_pos += pivot
	
	return relative_pos

func set_custom_cursor(image: Resource = null, shape: int = 0, hotspot: Vector2 = Vector2.ZERO):
	_custom_cursor = image
	_custom_cursor_shape = shape
	_custom_cursor_hotspot = hotspot

	if layers_container.get_rect().has_point(layers_container.get_local_mouse_position()):
		Input.set_custom_mouse_cursor(image, shape, hotspot)

func reorder_layer(layer: LayerV2, index: int) -> void:
	if not layer.has_meta("layer_card") or not layer.get_meta("layer_card") is LayerCard:
		push_error("Can't reorder layer %s to index %s, because of the invalid metadata on it" % [layer, index])
		return

	var layer_card: LayerCard = layer.get_meta("layer_card")

	if index - layer_card.get_index() == 1:
		# same final order if we drop it on next index
		return

	if layer_card.get_index() < index:
		index -= 1

	if index == layer_cards_container.get_child_count():
		index -= 1

	layers_container.move_child(layer, -(index+1))
	layer_cards_container.move_child(layer_card, index)
	

func _gui_input(event: InputEvent) -> void:
	if active_layer.is_visible_in_tree() and active_tool:
		active_tool.handle_input_event(event)
		accept_event()


func _draw() -> void:
	active_layer.queue_redraw()
	for c: LayerCard in layer_cards_container.get_children():
		c.queue_redraw()

## Delegates drag handling functions to given layer.[br]
## See [method Control.set_drag_forwarding].
func _set_drag_forward_to_layer(tool_: BaseTool) -> void:
	return
	if not tool_: return

	var gdd = tool_.get("_get_drag_data")
	print(gdd)
	gdd = gdd if gdd else Callable()

	var cdd = tool_.get("_can_drop_data")
	cdd = cdd if cdd else Callable()

	var dd = tool_.get("_drop_data")
	dd = dd if dd else Callable()
	
	prints(gdd, cdd, dd)

	set_drag_forwarding(gdd, cdd, dd)

func _on_active_tool_changed(tool_: BaseTool) -> void:
	for child in tool_options_container.get_children():
		child.visible = false
	
	var options: Control = tool_options_mapping.get(tool_)

	if options: options.visible = true


func _on_new_layer_button_pressed() -> void:
	active_layer = create_new_layer("Layer", canvas_size)


func _on_brush_tool_button_toggled(toggled_on: bool) -> void:
	active_tool = drawing_tool if toggled_on else null

func _on_pane_tool_button_toggled(toggled_on:bool) -> void:
	active_tool = pane_tool if toggled_on else null

func _on_eraser_tool_button_toggled(toggled_on: bool) -> void:
	active_tool = eraser_tool if toggled_on else null

func _on_transform_tool_button_toggled(toggled_on: bool) -> void:
	active_tool = transform_tool if toggled_on else null

func _on_speech_bubble_tool_button_toggled(toggled_on:bool) -> void:
	active_tool = speech_bubble_tool if toggled_on else null

func _on_layers_container_mouse_entered() -> void:
	Input.set_custom_mouse_cursor(_custom_cursor, _custom_cursor_shape, _custom_cursor_hotspot)

func _on_center_view_button_pressed() -> void:
	layers_container.center_view()

func _on_add_image_button_pressed() -> void:
	var fd: = FileDialog.new()
	
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	# fd.filters = []

	fd.file_selected.connect(_on_file_selected)

	add_child(fd)

	fd.popup_centered()

func _on_file_selected(fp: String) -> void:
	var image: = Image.load_from_file(fp)

	# TODO: validate
	var l: = LayerV2.create_image_layer(fp.get_file(), image)

	add_layer(l)


func _on_layers_container_mouse_exited() -> void:
	Input.set_custom_mouse_cursor(null)



func _on_save_button_pressed() -> void:
	export_image(r"D:\Programs\Godot_v4.4-stable_win64.exe\test.png")

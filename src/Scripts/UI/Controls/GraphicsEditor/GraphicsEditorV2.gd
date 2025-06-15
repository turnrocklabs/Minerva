class_name GraphicsEditorV2
extends PanelContainer

signal active_tool_changed(tool_: BaseTool)
signal active_layer_changed(layer: LayerV2)

@onready var layers_container: LayersContainer = %LayersContainer
@onready var layer_cards_container: Control = %LayerCardsContainer
@onready var tool_options_container: Control = %ToolOptionsContainer

@onready var message_window: PersistentWindow = %MessageWindow
@onready var message_title: Label = %MessageTitle
@onready var message_content: Label = %MessageContent


# tool options containers
@onready var _brush_options_container: Control = %BrushOptions
@onready var _bucket_options_container: Control = %BucketOptions
@onready var _eraser_options_container: Control = %EraserOptions
@onready var _speech_bubble_options: Control = %SpeechBubbleOptions

@onready var drawing_tool: DrawingTool = %DrawingTool
@onready var bucket_tool: BucketTool = %BucketTool
@onready var pane_tool: PaneTool = %PaneTool
@onready var eraser_tool: EraserTool = %EraserTool
@onready var transform_tool: TransformTool = %TransformTool
@onready var speech_bubble_tool: SpeechBubbleTool = %SpeechBubbleTool


@onready var tool_options_mapping: = {
	drawing_tool: _brush_options_container,
	bucket_tool: _bucket_options_container,
	eraser_tool: _eraser_options_container,
	speech_bubble_tool: _speech_bubble_options,
}

var canvas_size: = Vector2i(1000, 1000)

var _custom_cursor: Resource
var _custom_cursor_shape: int
var _custom_cursor_hotspot: Vector2

var layers: Array[LayerV2]

## Array of selected layers, in order in which they were selected
var selected_layers: Array[LayerV2] = []

var active_layer: LayerV2:
	get: return selected_layers.get(0) if not selected_layers.is_empty() else null

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
	
	# setup(Vector2i(500, 500))
	setup()

func setup(canvas_size_: Vector2i = Vector2i(1000, 1000)) -> void:

	create_new_layer("Layer", canvas_size_, Color.WHITE)

	# layers_container.center_view()


func create_new_layer(layer_name: String, dimensions: Vector2i, color: Color = Color.TRANSPARENT, select: = true) -> LayerV2:
	# var img = Image.create(dimensions.x, dimensions.y, true, Image.FORMAT_RGBA8)
	# img.fill(Color.TRANSPARENT)

	var layer: = LayerV2.create_drawing_layer(layer_name, dimensions, color)
	layer.tree_exiting.connect(_on_layer_tree_exiting.bind(layer))
	
	var layer_card: = LayerCard.create(self, layer)
	layer_card.layer_selected.connect(_on_layer_card_selected.bind(layer, layer_card))
	layer_card.layer_deselected.connect(_on_layer_card_deselected.bind(layer, layer_card))
	layer_card.reorder.connect(_on_layer_card_reorder.bind(layer_card))
	layer_card.layer_clicked.connect(_on_layer_card_clicked.bind(layer_card))

	layer_card.selected = select

	layer_cards_container.add_child(layer_card)
	layer_cards_container.move_child(layer_card, 0)

	layers_container.add_child(layer, true)

	# breakpoint
	
	# place the layer at the center of the screen
	# get_tree().process_frame.connect(
	# 	func(): layer.position = layers_container.size/2 - layer.size/2; print("PROCESS FRAME HERE"),
	# 	ConnectFlags.CONNECT_ONE_SHOT
	# )

	layers.append(layer)

	return layer


func add_layer(layer: LayerV2):
	layer.tree_exiting.connect(_on_layer_tree_exiting.bind(layer))

	var layer_card: = LayerCard.create(self, layer)

	layer_card.layer_selected.connect(_on_layer_card_selected.bind(layer, layer_card))
	layer_card.layer_deselected.connect(_on_layer_card_deselected.bind(layer, layer_card))
	layer_card.reorder.connect(_on_layer_card_reorder.bind(layer_card))
	layer_card.layer_clicked.connect(_on_layer_card_clicked.bind(layer_card))

	layer_cards_container.add_child(layer_card)
	layer_cards_container.move_child(layer_card, 0)

	layers_container.add_child(layer, true)

	layers.append(layer)
	
	return layer

# when layer is deleted remove it from selected layers if it's there
func _on_layer_tree_exiting(layer: LayerV2):
	if selected_layers.has(layer):
		selected_layers.erase(layer)


func _on_layer_card_selected(layer: LayerV2, _layer_card: LayerCard):
	selected_layers.append(layer)

func _on_layer_card_deselected(layer: LayerV2, _layer_card: LayerCard):
	selected_layers.erase(layer)

func _on_layer_card_clicked(button_index: int, layer_card: LayerCard):
	if button_index == MOUSE_BUTTON_LEFT:
		if Input.is_key_pressed(KEY_CTRL):
			layer_card.selected = not layer_card.selected
		
		else:
			for c: LayerCard in layer_cards_container.get_children():
				c.selected = false
			layer_card.selected = true

func _on_layer_card_reorder(to: int, layer_card: LayerCard):
	reorder_layer(layer_card.layer, to)


func display_message(title: String, content: String):
	message_window.popup_centered()
	message_title.text = title
	message_content.text = content

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
	# if we have a active tool and at least one of selected layers is visible
	if active_tool and selected_layers.any(func(l: LayerV2): return l.is_visible_in_tree()):

		# if active_tool.multi_select or selected_layers.size() < 2:
		
		# elif selected_layers.size() > 1:
		# 	# multiple layers selected for tool that only allows one
		# 	display_message(
		# 		"Multiple layers selected",
		# 		"%s tool only allows operation on one layers. Select only one or merge selected layers." % [active_tool.name]
		# 	)

		active_tool.handle_input_event(event)
		accept_event()


func _draw() -> void:
	for layer in selected_layers: layer.queue_redraw()
	
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
	# clear layers and create a new one
	for c: LayerCard in layer_cards_container.get_children():
		c.selected = false
	
	create_new_layer("Layer", canvas_size)


func _on_brush_tool_button_toggled(toggled_on: bool) -> void:
	active_tool = drawing_tool if toggled_on else null

func _on_bucket_tool_button_toggled(toggled_on:bool) -> void:
	active_tool = bucket_tool if toggled_on else null

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
	fd.access = FileDialog.ACCESS_FILESYSTEM
	# fd.filters = []

	fd.file_selected.connect(_on_file_selected)

	add_child(fd)

	fd.popup_centered()

func _on_file_selected(fp: String) -> void:
	var image: = Image.load_from_file(fp)

	var l: = LayerV2.create_image_layer(fp.get_file(), image)

	add_layer(l)


func _on_layers_container_mouse_exited() -> void:
	Input.set_custom_mouse_cursor(null)



func _on_save_button_pressed() -> void:

	var fd: = FileDialog.new()
	
	fd.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.filters = ["*.png"]


	add_child(fd)

	fd.popup_centered()

	var path = await fd.file_selected

	export_image(path)


func merge_layers(to_merge: Array[LayerV2]) -> LayerV2:
	if to_merge.is_empty():
		push_error("Cannot merge empty array of layers")
		return null
	
	if to_merge.size() == 1:
		return to_merge[0]  # Nothing to merge
	
	# Calculate the bounding rectangle for all layers
	var bounds := Rect2()
	var first_layer := true
	
	for layer in to_merge:
		if not layer.visible:
			continue  # Skip invisible layers
			
		# Get the layer's bounding rect in global space
		var layer_rect = Rect2(layer.position, layer.size)
		
		# Handle rotation by getting rotated corners
		if layer.rotation != 0:
			var corners = _get_rotated_corners(layer)
			for corner in corners:
				if first_layer:
					bounds = Rect2(corner, Vector2.ZERO)
					first_layer = false
				else:
					bounds = bounds.expand(corner)
		else:
			if first_layer:
				bounds = layer_rect
				first_layer = false
			else:
				bounds = bounds.merge(layer_rect)
	
	if bounds.size.x <= 0 or bounds.size.y <= 0:
		push_error("Invalid bounds calculated for merged layers")
		return null
	
	# Create a new image with the calculated bounds size
	var merged_image := Image.create(int(bounds.size.x), int(bounds.size.y), false, Image.FORMAT_RGBA8)
	merged_image.fill(Color(0, 0, 0, 0))  # Transparent background
	
	# Sort layers by their z-index (drawing order) - top layers first (higher index = on top)
	var sorted_layers = to_merge.duplicate()
	sorted_layers.sort_custom(func(a: LayerV2, b: LayerV2): 
		return layers_container.get_children().find(a) < layers_container.get_children().find(b)
	)
	
	# Blend each layer onto the merged image
	for layer in sorted_layers:
		if not layer.visible or not layer.image or layer.image.is_empty():
			continue
			
		var layer_image = layer.image
		var layer_pos = layer.position
		var rotation_rad = layer.rotation
		var pivot = layer.pivot_offset
		
		# For each pixel in the merged image
		for y in range(int(bounds.size.y)):
			for x in range(int(bounds.size.x)):
				# Convert merged image coordinates to global coordinates
				var global_pos = Vector2(x, y) + bounds.position
				
				# Convert global position to layer's local space
				var local_pos: Vector2
				if rotation_rad != 0:
					local_pos = _global_to_layer_space(global_pos, layer_pos, rotation_rad, pivot)
				else:
					local_pos = global_pos - layer_pos
				
				# Check if the point is within the layer's image bounds
				var img_x = int(local_pos.x)
				var img_y = int(local_pos.y)
				
				if img_x >= 0 and img_x < layer_image.get_width() and img_y >= 0 and img_y < layer_image.get_height():
					var src_color = layer_image.get_pixel(img_x, img_y)
					
					# Skip fully transparent pixels
					if src_color.a <= 0.01:
						continue
					
					# Blend with existing pixel
					var dst_color = merged_image.get_pixel(x, y)
					var blended: Color
					
					# Use the drawing tool's blend function if available, otherwise use our own
					if drawing_tool and drawing_tool.has_method("_blend_colors"):
						blended = drawing_tool._blend_colors(dst_color, src_color)
					else:
						blended = _blend_colors(dst_color, src_color)
					
					merged_image.set_pixel(x, y, blended)
	
	var merged_layer = LayerV2.create_image_layer("Layer", merged_image)
	merged_layer.position = bounds.position
	
	# Add the merged layer to the editor
	add_layer(merged_layer)
	
	# Remove original layers and their cards
	for layer in to_merge:
		# Find and remove the layer card
		for card in layer_cards_container.get_children():
			if card is LayerCard and card.layer == layer:
				card.queue_free()
				break
		
		# Remove from layers array
		layers.erase(layer)
		
		# Remove from scene
		layer.queue_free()
	
	# Select the merged layer
	if merged_layer.has_meta("layer_card"):
		var merged_card = merged_layer.get_meta("layer_card")
		merged_card.selected = true
	
	return merged_layer

# Helper function for color blending (alpha compositing)
func _blend_colors(dst: Color, src: Color) -> Color:
	if src.a == 0:
		return dst
	if dst.a == 0:
		return src
	
	var alpha = src.a + dst.a * (1.0 - src.a)
	if alpha == 0:
		return Color.TRANSPARENT
	
	var r = (src.r * src.a + dst.r * dst.a * (1.0 - src.a)) / alpha
	var g = (src.g * src.a + dst.g * dst.a * (1.0 - src.a)) / alpha
	var b = (src.b * src.a + dst.b * dst.a * (1.0 - src.a)) / alpha
	
	return Color(r, g, b, alpha)

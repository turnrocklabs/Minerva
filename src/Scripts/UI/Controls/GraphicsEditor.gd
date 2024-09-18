### Title: GraphicsEditor
class_name GraphicsEditor
extends PanelContainer

signal masking_ended()

var Buble = preload("res://Scenes/CloudControl.tscn")
@onready var _layers_container: Control = %LayersContainer
@onready var _brush_slider: HSlider = %BrushHSlider

@export var _color_picker: ColorPickerButton
@export var _mask_check_button: CheckButton
@export var _apply_mask_button: Button
@export var masking_color: Color

var selectedLayer: String
var selectedIndex: int
var loaded_layers: Array[Layer]
static var layer_Number = 0

var _transparency_texture: CompressedTexture2D = preload("res://assets/generated/transparency.bmp")

var image: Image:
	get: return _draw_layer.image if _draw_layer else null

var drawing:bool = false
var drawing_brush_active: bool = true
var erasing:bool = false
var clouding:bool = false
var zoomIn:bool = false
var zoomOut:bool = false

var view_tool_active: bool = false
var prev_mouse_position: Vector2
var transfering:bool = false
var layer_being_transfered: Layer = null  # Store the layer being transferred
var active_transfer_button: Button = null  # Store the active butto

var _rotating: bool = false
var _rotation_pivot: Vector2 = Vector2.ZERO
var _can_resize:bool = false

var brush_size: int = 5:
	set(value):
		brush_size = value
		_brush_slider.value = value

var brush_color: Color:
	get:
		if _masking:
			return Color.TRANSPARENT 
		elif erasing:
			return Color.TRANSPARENT  
		else:
			return _color_picker.color

var _last_pos: Vector2
var _draw_begin: bool = false
var bubble: CloudControl = Buble.instantiate()
var _draw_layer: Layer
var _mask_layer: Layer
var _background_images = {}  # Store the background images for each layer
var fill_tool

## Is masking active. Active masking prevents any color, except for transparency to be active
var _masking: bool:
	set(value):
		_masking = value
		if not value: 
			masking_ended.emit()

var layer_undo_histories = {} # Dictionary to store undo histories for each layer
# Called when the node enters the scene tree for the first time.
func _ready():
	layers_buttons()
	
	_color_picker = %ColorPickerButton
	
	_draw_layer = _layers_container.get_child(0)
	if SingletonObject.is_graph == true:
		toggle_controls(SingletonObject.is_graph)
	elif SingletonObject.is_masking == true:
		#editing and drawing
		toggle_masking(SingletonObject.is_masking)
		
	layer_Number += 1
	setup(Vector2i(2000, 2000), Color.WHITE)
	SingletonObject.is_graph = false
	SingletonObject.is_masking = false
	
	for layer in loaded_layers:
		_layers_container.add_child(layer)
		layer_undo_histories[layer.name] = [] # Initialize undo history for each layer
		layer_undo_histories[layer.name].append(layer.image.duplicate()) # Add the initial state to the undo history
		#%PickLayers.add_item(layer.name)#get_item_text(index)
	
	if loaded_layers.size() > 0:
		layer_Number = loaded_layers.size()
		SingletonObject.is_graph = true
		toggle_controls(true)

	# Initialize undo history
	#undo_history.append(_draw_layer.image.duplicate())
	SingletonObject.is_Brush = false
	SingletonObject.is_square = false
	SingletonObject.is_cryon = false
	
	_can_resize = true

func toggle_controls(toggle: bool):
	#only drawing
	%ColorPickerButton.visible = toggle
	%BrushHSlider.visible = toggle


func toggle_masking(toggle: bool):
	#editing and drawing
	%BrushHSlider.visible = toggle


func _calculate_resized_dimensions(original_size: Vector2, max_size: Vector2) -> Vector2:
	var aspect_ratio = original_size.x / original_size.y
	var target_width = original_size.x
	var target_height = original_size.y
	
	if original_size.x > max_size.x:
		target_width = max_size.x
		target_height = target_width / aspect_ratio
		
		if target_height > max_size.y:
			target_height = max_size.y
			target_width = target_height * aspect_ratio

	elif original_size.y > max_size.y:
		target_height = max_size.y
		target_width = target_height * aspect_ratio
		
		if target_width > max_size.x:
			target_width = max_size.x
			target_height = target_width / aspect_ratio
	
	return Vector2(target_width, target_height)
	
func setup_from_image(image_: Image):
	var new_size = _calculate_resized_dimensions(image_.get_size(), Vector2(800, 800))
	image_.resize(new_size.x, new_size.y)
	for ch in _layers_container.get_children(true): 
		ch.queue_free()
	_draw_layer = _create_layer(image_)
	_background_images[_draw_layer.name] = image_.duplicate()  # Store the initial background

	var transparency_node = TextureRect.new()
	transparency_node.stretch_mode = TextureRect.STRETCH_TILE
	transparency_node.texture = _transparency_texture
	transparency_node.custom_minimum_size = _draw_layer.image.get_size()
	_layers_container.add_child(transparency_node, false, INTERNAL_MODE_FRONT)

	image = image_

	# Ensure the undo history contains the initial state
	layer_undo_histories[_draw_layer.name] = []
	layer_undo_histories[_draw_layer.name].append(_draw_layer.image.duplicate())

# Similar updates to the function setup_from_created_image
func setup_from_created_image(image_: Image):
	# Create a new image with the same properties as in create_image
	var img = image_

	# Resize the image to fit within the canvas boundaries
	var new_size = _calculate_resized_dimensions(img.get_size(), Vector2(800, 800))
	img.resize(new_size.x, new_size.y)

	# Create a new layer from the scratch image
	_draw_layer = _create_layer(img)

	# Store the initial background image for the layer
	_background_images[_draw_layer.name] = img.duplicate()
	
	# Assign the created image to the editor's image property
	image = img

	# Ensure the undo history contains the initial state
	layer_undo_histories[_draw_layer.name] = []
	layer_undo_histories[_draw_layer.name].append(_draw_layer.image.duplicate())
	# Create a new image with the same properties as in create_image
	img = image_

	# Resize the image to fit within the canvas boundaries
	new_size = _calculate_resized_dimensions(img.get_size(), Vector2(800, 800))
	img.resize(new_size.x, new_size.y)

	# Create a new layer from the scratch image
	_draw_layer = _create_layer(img)

	# Store the initial background image for the layer
	_background_images[_draw_layer.name] = img.duplicate()
	
	# Assign the created image to the editor's image property
	image = img

func setup(canvas_size: Vector2i, background_color: Color):
	var img = Image.create(canvas_size.x, canvas_size.y, false, Image.FORMAT_RGBA8)
	img.fill(background_color)
	setup_from_image(img)

func create_image(vec:Vector2):
	var img = Image.create(int(vec.x), int(vec.y), false, Image.FORMAT_RGBA8)
	img.fill(Color(255, 255, 255, 0)) 
	
	# Create new layer and assign the new image
	_draw_layer = _create_layer(img)
	  
	# Store the initial background image for the layer
	_background_images[_draw_layer.name] = img.duplicate() 

	   # This line is unnecessary and might be causing issues - remove it:
	   # setup_from_created_image(img) 
	
func _create_layer(from: Image, internal: InternalMode = INTERNAL_MODE_DISABLED) -> Layer:
	var layer = Layer.create(from, "Layer " + str(layer_Number)) 
	_layers_container.add_child(layer, false, internal)
	return layer

func get_circle_pixels(center: Vector2, radius: int) -> PackedVector2Array:
	var pixels = PackedVector2Array()
	for x in range(center.x - radius, center.x + radius + 1):
		for y in range(center.y - radius, center.y + radius + 1):
			if (x - center.x) * (x - center.x) + (y - center.y) * (y - center.y) <= radius * radius:
				pixels.append(Vector2(x, y))
	return pixels

func bresenham_line(start: Vector2, end: Vector2) -> PackedVector2Array:
	var pixels = PackedVector2Array()

	var x1 = int(start.x)
	var y1 = int(start.y)
	var x2 = int(end.x)
	var y2 = int(end.y)

	var dx = abs(x2 - x1)
	var dy = abs(y2 - y1)
	var sx = 1 if x1 < x2 else -1
	var sy = 1 if y1 < y2 else -1
	var err = dx - dy

	while true and drawing_brush_active:
		pixels.append(Vector2(x1, y1))
		if x1 == x2 and y1 == y2:
			break
		var e2 = 2 * err
		if e2 > -dy:
			err -= dy
			x1 += sx
		if e2 < dx:
			err += dx
			y1 += sy

	return pixels

## Checks if given pixel is within the image and draws it using `set_pixelv`
func image_draw(target_image: Image, pos: Vector2, color: Color, point_size: int):
	if SingletonObject.is_Brush:
		Brush_draw(target_image, pos, color, point_size)
		
	elif SingletonObject.is_square:
		draw_square(target_image, pos, color, point_size)
		
	elif SingletonObject.is_cryon:
		Crayon_draw(target_image, pos, color, point_size)
		
	else:
		for pixel in get_circle_pixels(pos, point_size):
			if pixel.x >= 0 and pixel.x < target_image.get_width() and pixel.y >= 0 and pixel.y < target_image.get_height():
				if erasing and target_image.get_pixelv(pixel).a > 0.1: 
					target_image.set_pixelv(pixel, _background_images[_draw_layer.name].get_pixelv(pixel))  
				elif not erasing:
					target_image.set_pixelv(pixel, color) 
				
func _gui_input(event: InputEvent):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT and event.pressed:
		var active_layer = _mask_layer if _masking else _draw_layer
		var layer_local_pos = active_layer.get_local_mouse_position()
		# Get color at clicked position
		var picked_color = active_layer.image.get_pixelv(layer_local_pos)
		
		# Update the ColorPickerButton
		_color_picker.color = picked_color
		
		
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed and fill_tool:
		var active_layer = _mask_layer if _masking else _draw_layer
		var layer_local_pos = active_layer.get_local_mouse_position()
		flood_fill(active_layer.image, layer_local_pos, brush_color) 
		active_layer.update()
		fill_tool = false
		%Brushes.select(0)
		%PenAdditionalTools.visible = true
	# Early exit if view tool is active
	if view_tool_active:
		if event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_LEFT:
			var current_mouse_position = event.position
			var delta = current_mouse_position - prev_mouse_position
			_layers_container.position += delta
			prev_mouse_position = current_mouse_position
			return
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				prev_mouse_position = event.position
			return
		
	if _rotating and not null:
		var hbox_index = %LayersList.get_children().find(active_transfer_button.get_parent())
		var layer = _layers_container.get_child(hbox_index)

		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:  
				_rotation_pivot = _layers_container.get_local_mouse_position()
				layer.pivot_offset = _rotation_pivot - layer.position

		elif event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_LEFT: 
			var angle = (_layers_container.get_local_mouse_position() - _rotation_pivot).angle()
			layer.rotation = angle

		elif event is InputEventKey and event.pressed and event.keycode == KEY_ENTER:
			_rotating = false
			active_transfer_button.modulate = Color.WHITE
			active_transfer_button = null
			layer.pivot_offset = Vector2.ZERO
		return

	if layer_being_transfered: 
		if event is InputEventMouseMotion and event.button_mask & MOUSE_BUTTON_LEFT:
			var current_mouse_position = _layers_container.get_local_mouse_position()
			layer_being_transfered.position = current_mouse_position - prev_mouse_position
			return
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				prev_mouse_position = _layers_container.get_local_mouse_position() - layer_being_transfered.position 
			else: 
				layer_being_transfered = null 
			return

	if zoomIn or zoomOut:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			var zoom_factor = 1.1 if zoomIn else 0.9 
			var zoom_center = _layers_container.get_local_mouse_position() 

			var zoom_offset = zoom_center * (1 - zoom_factor)

			_layers_container.scale *= Vector2.ONE * zoom_factor
			_layers_container.position += zoom_offset
			
		if event is InputEventMouseMotion and %MgIcon.visible == true:
			# Correctly calculate the position relative to the zoom level and container position
			var local_position = _layers_container.get_local_mouse_position()
			var global_position = _layers_container.position + local_position * _layers_container.scale
			%MgIcon.offset = Vector2(-20,20)
			%MgIcon.position = global_position
			drawing = false
			
			
			
	if clouding and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		# 1. Create a new layer
		var new_layer_image = Image.create(_draw_layer.image.get_width(), _draw_layer.image.get_height(), false, Image.FORMAT_RGBA8) 
		new_layer_image.fill(Color(0, 0, 0, 0)) # Fill with transparent
		var new_layer = _create_layer(new_layer_image)
		layer_Number += 1
		_background_images[new_layer.name] = new_layer_image.duplicate()

		# 2. Add layer button to UI 
		layers_buttons()

		# 3. Instantiate and add the bubble to the NEW layer
		var new_bubble = Buble.instantiate()
		new_layer.add_child(new_bubble)
		new_bubble.position = new_layer.get_local_mouse_position() # Position bubble

		clouding = false

	# Handle drawing actions
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				drawing = true
				_draw_begin = true
			else:
				drawing = false
				
			#layer_undo_histories[_draw_layer.name].append(_draw_layer.image.duplicate())

	if event is InputEventMouseMotion and drawing and drawing_brush_active:
		# Get mouse position relative to the active layer
		var active_layer = _mask_layer if _masking else _draw_layer
		var layer_local_pos = active_layer.get_global_transform().affine_inverse() * get_global_transform_with_canvas() * event.position

		# --- No manual offset calculation needed here ---
		if %LayersList.get_child_count() > 0:
			if _draw_begin:  
				_last_pos = layer_local_pos 
				image_draw(active_layer.image, layer_local_pos, brush_color, brush_size * event.pressure)
				_draw_begin = false

			if _last_pos.x != layer_local_pos.x or _last_pos.y != layer_local_pos.y:
				for line_pixel in bresenham_line(_last_pos, layer_local_pos):
					image_draw(active_layer.image, line_pixel, brush_color, brush_size * event.pressure)

		_last_pos = layer_local_pos 
		active_layer.update() 
		
func _on_h_slider_value_changed(value):
	brush_size = value

func _on_mask(toggled_on: bool):
	_masking = toggled_on
	_draw_layer.visible = not _masking

	if toggled_on:
		# Create a temporary mask for background and foreground
		var bgd_img = Image.new()
		Image.create(_draw_layer.image.get_width(), _draw_layer.image.get_height(), false, Image.FORMAT_RGBA8)
		bgd_img.fill(masking_color)
		var background_mask_layer = _create_layer(bgd_img, INTERNAL_MODE_BACK)
		background_mask_layer.name = "BackgroundMaskLayer"

		var img = Image.new()
		img.copy_from(_draw_layer.image)
		img.convert(Image.FORMAT_RGBA8)
		_mask_layer = _create_layer(img, INTERNAL_MODE_FRONT)
		_mask_layer.name = "MaskLayer"

		await masking_ended
		background_mask_layer.queue_free()
		_mask_layer.queue_free()
	else:
		_mask_layer = null
		_draw_layer.visible = true
		
#make it like signal,probably through SingeltonObject
func _on_apply_mask_button_pressed():
	if _mask_layer and _draw_layer:
		# Use the mask layer image to mask the draw layer image
		for x in range(_draw_layer.image.get_width()):
			for y in range(_draw_layer.image.get_height()):
				var mask_pixel = _mask_layer.image.get_pixel(x, y)
				if mask_pixel.a > 0:  # If the mask pixel has some opacity
					_draw_layer.image.set_pixel(x, y, mask_pixel)  # Apply mask color

		_draw_layer.update()  # Update the draw layer to reflect the applied mask

		image.set_meta("mask", _mask_layer.image)
		
	%MgIcon.visible = false
	zoomIn = false
	zoomOut = false
	
	%ZoomIn.modulate = Color.WHITE
	%ZoomOut.modulate = Color.WHITE 

	# if the image has the signal defined call it
	if image.has_user_signal("mask_changed"):
		image.emit_signal("mask_changed")
	
	_masking = false
	_draw_layer.visible = true  # Ensure the layer is visible after applying the mask
	
func _on_layers_pressed():
	%PopupPanel.visible = not %PopupPanel.visible
	var bPos = %Layers.position
	%LayersMenu.position = Vector2(bPos.x - 60, bPos.y + 105)
	%LayerBG.position = Vector2(bPos.x - 60, bPos.y + 105)
	
	%MgIcon.visible = false
	zoomIn = false
	zoomOut = false
	
	%ZoomIn.modulate = Color.WHITE
	%ZoomOut.modulate = Color.WHITE 
	
func _on_add_layer_pressed():
	layers_buttons()
	
	create_image(Vector2(800,800))
	
	layer_Number += 1
	
	# Automatically select the newly created layer

func RemoveLayer(Hbox:HBoxContainer, _index:int):
	# Find the index of the HBoxContainer within LayersList
	var hbox_index = %LayersList.get_children().find(Hbox)
	
	# Remove the layer container (visual)
	Hbox.queue_free()
	
	# Get the layer to remove directly from the HBox's index 
	var layer_to_remove = _layers_container.get_child(hbox_index)
	layer_to_remove.queue_free()
	
	layer_Number -= 1
	
	# Synchronize undo history to ensure consistency
	layer_undo_histories.erase(layer_to_remove.name) 
	
	erasing = false
	view_tool_active = false
	_on_mask(false)
	clouding = false
	zoomIn =false
	zoomOut = false
	_rotating = false
	
	# If there are no layers left, reset the editor
	if layer_Number <= 0:
		layer_Number = 0
		create_image(Vector2(800,800))
		return # Nothing to select
		
	# Select the previous layer 
	var new_index = max(0, hbox_index - 1) # Clamp to 0 
	if new_index < %LayersList.get_child_count():
		var new_hbox = %LayersList.get_child(new_index)
		var new_button = new_hbox.get_child(0) # Assuming button is the first child
		selectButton(new_button, new_hbox)

func selectButton(btn: Button, Hbox: HBoxContainer):
	# Set the selected button to green
	btn.modulate = Color.LIME_GREEN
	
	# Find the index of the HBoxContainer within LayersList
	var hbox_index = %LayersList.get_children().find(Hbox)
	
	# Ensure a valid index was found
	if hbox_index != -1:
		# Assuming layers in _layers_container directly correspond to 
		# the order in LayersList, use the hbox_index
		
		_draw_layer = _layers_container.get_child(hbox_index)
		
		# Update undo history for the previously selected layer
	if _draw_layer != null:
		# Initialize the undo history if it doesn't exist for this layer
		if not layer_undo_histories.find_key(_draw_layer.name):
			layer_undo_histories[_draw_layer.name] = []

		# Append the current state to the undo history
		layer_undo_histories[_draw_layer.name].append(_draw_layer.image.duplicate())
	# Reset other buttons' color
	for child in %LayersList.get_children():
		if child is HBoxContainer and child != Hbox:
			for button in child.get_children():
				button.modulate = Color.WHITE

func LayerVisible(Hbox: HBoxContainer):
	var hbox_index = %LayersList.get_children().find(Hbox)
	var VisibleOfBox = _layers_container.get_child(hbox_index)
	VisibleOfBox.visible = !VisibleOfBox.visible

	# Get the VisibleButton from the HBoxContainer
	var VisibleButton = Hbox.get_child(1)  # Assuming it's the second child

	# Toggle the icon based on visibility
	if VisibleOfBox.visible:
		VisibleButton.icon = preload("res://assets/icons/eye_icons/visibility_visible.svg")  # Replace with your visible icon path
	else:
		VisibleButton.icon = preload("res://assets/icons/eye_icons/visibility_not_visible.png")   # Replace with your hidden icon path


func _on_brushes_item_selected(index):
	if index != 0:
		drawing_brush_active = false
	else:
		drawing_brush_active = true
	#off other tools not drawing
	%MgIcon.visible = false
	erasing = false
	view_tool_active = false
	_on_mask(false)
	clouding = false
	zoomIn = false
	zoomOut = false
	%ZoomIn.modulate = Color.WHITE
	%ZoomOut.modulate = Color.WHITE
	
	%DialogClouds.visible = false
	%PenAdditionalTools.visible = false
	%ApplyMaskButton.visible = false
	
	match index:
		0:
			%PenAdditionalTools.visible = true
		1:
			erasing = true
			%PenAdditionalTools.visible = true
		2:
			_on_mask(true)
			%ApplyMaskButton.visible = true
		3:
			%DialogClouds.visible = true
		4:
			fill_tool = true

func _on_option_button_item_selected(index):
	drawing = false
	erasing = false
	view_tool_active = false
	_on_mask(false)
	clouding = true
	
	%MgIcon.visible = false
	zoomIn = false
	zoomOut = false
	
	%ZoomIn.modulate = Color.WHITE
	%ZoomOut.modulate = Color.WHITE 
	
	match index:
		0:
			SingletonObject.CloudType = CloudControl.Type.ELLIPSE
		1:
			SingletonObject.CloudType = CloudControl.Type.CLOUD
		2:
			SingletonObject.CloudType = CloudControl.Type.RECTANGLE


func _on_hand_pressed() -> void:
	# Toggle other tools off
	erasing = false
	_on_mask(false)
	clouding = false
	zoomIn = false
	zoomOut = false
	%DialogClouds.visible = false
	%MgIcon.visible = false

	# Toggle hand tool and its visual indicator
	view_tool_active = !view_tool_active 
	if view_tool_active:
		%Hand.modulate = Color.LIME_GREEN
		%MgIcon.visible = true 
	else:
		%Hand.modulate = Color.WHITE  # Reset color when deactivated
		%MgIcon.visible = false

func _on_zoom_in_pressed() -> void:
	# Toggle other tools off
	erasing = false
	_on_mask(false)
	view_tool_active = false
	clouding = false
	zoomOut = false 
	%DialogClouds.visible = false

	# Toggle zoom in and its visual indicator
	zoomIn = !zoomIn
	if zoomIn:
		%ZoomIn.modulate = Color.LIME_GREEN
		%ZoomOut.modulate = Color.WHITE
		%MgIcon.visible = true
	else:
		%ZoomIn.modulate = Color.WHITE 
		%MgIcon.visible = false
	
func _on_zoom_out_pressed() -> void:
	# Toggle other tools off
	erasing = false
	_on_mask(false)
	view_tool_active = false
	clouding = false
	zoomIn = false 
	%DialogClouds.visible = false

	# Toggle zoom out and its visual indicator
	zoomOut = !zoomOut
	if zoomOut:
		%ZoomOut.modulate = Color.LIME_GREEN 
		%ZoomIn.modulate = Color.WHITE
		%MgIcon.visible = true
	else:
		%ZoomOut.modulate = Color.WHITE 
		%MgIcon.visible = false

func _on_mg_pressed() -> void:
	# Define your default size here 
	var default_size := Vector2(800, 800) 

	# Iterate through each layer in the container
	for layer in _layers_container.get_children():
		if layer is Layer:
			# Resize the layer's image 
			layer.image.resize(default_size.x, default_size.y, Image.INTERPOLATE_BILINEAR)

			# Update the layer to reflect the changes
			layer.update()
			
	%MgIcon.visible = false
	zoomIn = false
	zoomOut = false
	
	%ZoomIn.modulate = Color.WHITE
	%ZoomOut.modulate = Color.WHITE 

	# Optionally, reset the zoom and position of the LayersContainer 
	_layers_container.scale = Vector2.ONE
	_layers_container.position = Vector2.ZERO
	
	
func _transfer(Hbox: HBoxContainer) -> void:
	var hbox_index = %LayersList.get_children().find(Hbox)
	var transfer_button = Hbox.get_child(2)

	# Toggle Logic
	if transfer_button == active_transfer_button: 
		# Deactivate if the same button is pressed again
		active_transfer_button.modulate = Color.WHITE
		active_transfer_button = null
		layer_being_transfered = null 
	else:
		# Deactivate the previous button
		if active_transfer_button:
			# Check if active_transfer_button is still a valid node
			if is_instance_valid(active_transfer_button): 
				active_transfer_button.modulate = Color.WHITE
			active_transfer_button = null
			
			
		# Activate the new button
		active_transfer_button = transfer_button
		active_transfer_button.modulate = Color.LIME_GREEN
		layer_being_transfered = _layers_container.get_child(hbox_index)
		prev_mouse_position = _layers_container.get_local_mouse_position()
		
		
func _rotate(Hbox: HBoxContainer) -> void:
	#this is declaring a new variable hbox_index, should the 'var' be removed
	var hbox_index = %LayersList.get_children().find(Hbox)
	var rotate_button = Hbox.get_child(3)  # Assuming the Rotate button is the 4th child

	# Toggle Logic
	if rotate_button == active_transfer_button:
		# Deactivate if the same button is pressed again
		active_transfer_button.modulate = Color.WHITE
		active_transfer_button = null
		_rotating = false
	else:
		# Deactivate the previous button
		if active_transfer_button:
			# Check if active_transfer_button is still a valid node
			if is_instance_valid(active_transfer_button): 
				active_transfer_button.modulate = Color.WHITE
			active_transfer_button = null

		# Activate the new button
		active_transfer_button = rotate_button
		active_transfer_button.modulate = Color.LIME_GREEN
		_rotating = true
		_rotation_pivot = _layers_container.get_local_mouse_position()

func _scale(Hbox: HBoxContainer) -> void:
	var hbox_index = %LayersList.get_children().find(Hbox)
	var scale_button = Hbox.get_child(4) 

	# Toggle visibility of child nodes in the layer FIRST
	var layer = _layers_container.get_child(hbox_index)
	for child in layer.get_children():
		child.visible = !child.visible 

	# --- Toggle Logic (Fixed) ---
	if scale_button == active_transfer_button:
		# Deactivate if the same button is pressed again
		active_transfer_button.modulate = Color.WHITE
		active_transfer_button = null 
	else:
		# Deactivate the previous button
		if active_transfer_button:
			if is_instance_valid(active_transfer_button):
				active_transfer_button.modulate = Color.WHITE
			active_transfer_button = null

		# Activate the new button
		active_transfer_button = scale_button
		active_transfer_button.modulate = Color.LIME_GREEN 
		
func _on_arrowleft_pressed() -> void:
	_resize_layers(1.1, 1.0)  # Increase width by 10%, center horizontallyc
	
	# --- Move layers after resizing ---
	for layer in _layers_container.get_children():
		if layer is Layer:
			layer.position.x -= layer.size.x * 0.09 # Move right by 5% of the new width 
			
func _on_arrow_right_pressed() -> void:
	_resize_layers(1.1, 1.0)  # Increase width by 10%, center horizontally

func _on_arrow_top_pressed() -> void:
	_resize_layers(1.1,false) # Increase height by 10%, center vertically 
	# --- Move layers after resizing ---
	for layer in _layers_container.get_children():
		if layer is Layer:
			layer.position.y -= layer.size.y * 0.09 # Move right by 5% of the new width 

func _on_arrow_bottom_pressed() -> void:
	_resize_layers(1.1,false) # Increase height by 10%, center vertically 

func _resize_layers(size_factor: float, resize_width: bool = true) -> void:
	
	%MgIcon.visible = false
	zoomIn = false
	zoomOut = false
	
	%ZoomIn.modulate = Color.WHITE
	%ZoomOut.modulate = Color.WHITE 
	
	for layer in _layers_container.get_children():
		if layer is Layer:
			var old_size = layer.image.get_size()
			var new_size: Vector2

			if resize_width:
				new_size = Vector2i(old_size.x * size_factor, old_size.y)
			else:
				new_size = Vector2i(old_size.x, old_size.y * size_factor)

			# Store the original content of the layer
			var temp_image := Image.new()
			temp_image.copy_from(layer.image)
			# Resize the layer's image
			layer.image.resize(new_size.x, new_size.y, Image.INTERPOLATE_BILINEAR)
			layer.size = new_size

			# Redraw the original content onto the resized image
			layer.image.blit_rect(temp_image, Rect2(Vector2.ZERO, old_size), Vector2.ZERO)
			layer.update()

func layers_buttons():
	var Hbox = HBoxContainer.new()
	Hbox.name = str("Layer" + str(layer_Number))
	
	Hbox.set("theme_override_constants/separation", 12)
	
	var LayerButton = Button.new()
	LayerButton.text = "Layer"+str(layer_Number)
	LayerButton.connect("pressed", self.selectButton.bind(LayerButton,Hbox))
	
	var VisibleButton = Button.new()
	VisibleButton.icon = preload("res://assets/icons/eye_icons/visibility_visible.svg")
	VisibleButton.connect("pressed", self.LayerVisible.bind(Hbox))
	
	var RemoveButton = Button.new()
	RemoveButton.connect("pressed", self.RemoveLayer.bind(Hbox, layer_Number))
	RemoveButton.icon = preload("res://assets/icons/remove.svg")
	
	%LayersList.add_child(Hbox)
	
	var Translate = Button.new()
	Translate.text = "T"
	Translate.connect("pressed", self._transfer.bind(Hbox))
	
	var Rotate = Button.new()
	Rotate.text = "R"
	Rotate.connect("pressed", self._rotate.bind(Hbox))
	
	var Scale = Button.new()
	Scale.text = "S"
	Scale.connect("pressed", self._scale.bind(Hbox))
	
	Hbox.add_child(LayerButton)
	Hbox.add_child(VisibleButton)
	Hbox.add_child(Translate)
	Hbox.add_child(Rotate) 
	Hbox.add_child(Scale)
	
	if %LayersList.get_child_count() != 1:
		Hbox.add_child(RemoveButton)
	
	selectButton(LayerButton, Hbox) 


func _on_add_new_pic_file_selected(path: String) -> void:
	# Check if the file extension is a supported image type
	var extension = path.get_extension().to_lower()
	if extension in ["png", "jpg", "jpeg"]:
		# Load the image
		var image = Image.new()
		var err = image.load(path)
		if err != OK:
			print("Error loading image:", err)
			return

		# Create a new layer from the loaded image
		var new_layer = _create_layer(image)

		# Store the loaded image as the background for this layer
		_background_images[new_layer.name] = image.duplicate()

		# Increment the layer counter
		layer_Number += 1

		# Add layer button to the UI
		layers_buttons()
 
		# Optionally select the newly added layer
		# selectButton(new_layer_button, new_layer_hbox) 
	else:
		print("Unsupported file type:", extension)
	%AddNewPic.visible = false  # Close the file dialog


func _on_add_imagelayer_pressed() -> void:
	%AddNewPic.visible = true


func _on_additional_tools_item_selected(index: int) -> void:
	SingletonObject.is_cryon = false
	SingletonObject.is_Brush = false
	SingletonObject.is_square = false
	match index:
		1:
			SingletonObject.is_Brush = true
		2:
			SingletonObject.is_square = true
		3:
			SingletonObject.is_cryon = true

func Brush_draw(target_image: Image, pos: Vector2, color: Color, radius: int):
	var rand = RandomNumberGenerator.new()
	rand.seed = Time.get_ticks_msec()  # Use a time-based seed for more randomness

	var scatter_amount = radius * 0.7  # Adjust for desired scatter effect
	var density = 15  # Number of dots to spray (adjust for intensity)

	for _i in range(density):
		var offset_x = rand.randf_range(-scatter_amount, scatter_amount)
		var offset_y = rand.randf_range(-scatter_amount, scatter_amount)
		var spray_pos = pos + Vector2(offset_x, offset_y)

		# Draw a single pixel for the spray dot
		if spray_pos.x >= 0 and spray_pos.x < target_image.get_width() and spray_pos.y >= 0 and spray_pos.y < target_image.get_height():
			if erasing:
				target_image.set_pixelv(spray_pos, _background_images[_draw_layer.name].get_pixelv(spray_pos))
			else:
				target_image.set_pixelv(spray_pos, color)

func draw_square(target_image: Image, pos: Vector2, color: Color, size: int):
	var half_size = size / 2
	for x in range(int(pos.x - half_size), int(pos.x + half_size + 1)):
		for y in range(int(pos.y - half_size), int(pos.y + half_size + 1)):
			var pixel = Vector2(x, y)
			if pixel.x >= 0 and pixel.x < target_image.get_width() and pixel.y >= 0 and pixel.y < target_image.get_height():
				if erasing:
					target_image.set_pixelv(pixel, _background_images[_draw_layer.name].get_pixelv(pixel))
				else:
					target_image.set_pixelv(pixel, color)


func flood_fill(target_image: Image, start_pos: Vector2, fill_color: Color):
	var target_color = target_image.get_pixelv(start_pos)
	
	# If the starting pixel is already the fill color, do nothing
	if target_color == fill_color:
		return

	var width = target_image.get_width()
	var height = target_image.get_height()
	var stack = [start_pos] 
	
	while stack.size() > 0:
		var current_pos = stack.pop_back()
		var x = int(current_pos.x)
		var y = int(current_pos.y)

		if x < 0 or x >= width or y < 0 or y >= height:
			continue

		if target_image.get_pixelv(current_pos) == target_color:
			target_image.set_pixelv(current_pos, fill_color)          

			# Add neighboring pixels to the stack
			stack.append(Vector2(x + 1, y))
			stack.append(Vector2(x - 1, y))
			stack.append(Vector2(x, y + 1))
			stack.append(Vector2(x, y - 1))

func Crayon_draw(target_image: Image, pos: Vector2, color: Color, radius: int):
	var rand = RandomNumberGenerator.new()
	rand.seed = Time.get_ticks_msec()

	var jitter_amount = radius * 0.5
	var opacity_falloff = 0.7

	for _i in range(radius * 2):
		var offset_x = rand.randf_range(-jitter_amount, jitter_amount)
		var offset_y = rand.randf_range(-jitter_amount, jitter_amount)
		var draw_pos = pos + Vector2(offset_x, offset_y)

		var distance_from_center = pos.distance_to(draw_pos)
		var opacity = 1.0 - (distance_from_center / radius) * opacity_falloff
		opacity = clamp(opacity, 0.0, 1.0)

		if draw_pos.x >= 0 and draw_pos.x < target_image.get_width() and draw_pos.y >= 0 and draw_pos.y < target_image.get_height():
			if erasing:
				# Erase by blending with the background image
				target_image.set_pixelv(draw_pos, _background_images[_draw_layer.name].get_pixelv(draw_pos))
			else:
				var bg_color = target_image.get_pixelv(draw_pos)

				# Calculate the premultiplied crayon color 
				var crayon_color_premultiplied = Color(color.r * color.a, color.g * color.a, color.b * color.a, color.a)

				# Apply the 40% transparency reduction to the opacity
				opacity *= 0.6 

				# Blend with the adjusted opacity
				var final_color = crayon_color_premultiplied * opacity + bg_color * (1.0 - opacity)

				target_image.set_pixelv(draw_pos, final_color) 

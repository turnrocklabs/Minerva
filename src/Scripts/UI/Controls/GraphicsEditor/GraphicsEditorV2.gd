class_name GraphicsEditorV2
extends PanelContainer

signal active_tool_changed(tool_: BaseTool)
@warning_ignore("unused_signal")
signal active_layer_changed(layer: LayerV2)
signal active_layer_is_mask_layer(is_mask_layer: bool)

signal compose_progress_updated(progress: float)
signal compose_finished(image: Image)
signal delete_layer(layer: LayerV2)
#signal lock_unlock_media_gen_ui(lock: bool)

@onready var layers_container: LayersContainer = %LayersContainer
@onready var layer_cards_container: Control = %LayerCardsContainer
@onready var tool_options_container: Control = %ToolOptionsContainer
@onready var layer_cards_popup_panel: Window = %LayerCardsPopupPanel
@onready var layer_cards_toggle_button: Button = %LayerCardsButton

@onready var message_window: PersistentWindow = %MessageWindow
@onready var message_title: Label = %MessageTitle
@onready var message_content: Label = %MessageContent

@onready var progress_window: PersistentWindow = %ProgressWindow
@onready var progress_window_bar: ProgressBar = %ProgressBar
@onready var progress_window_label: Label = %ProgressLabel

@onready var _tools_option_button: OptionButton = %ToolsOptionButton

#region tool options containers
@onready var _brush_options_container: Control = %BrushOptions
@onready var _smudge_options_container: Control = %SmudgeOptions
@onready var _bucket_options_container: Control = %BucketOptions
@onready var _eraser_options_container: Control = %EraserOptions
@onready var _speech_bubble_options: Control = %SpeechBubbleOptions

@onready var drawing_tool: DrawingTool = %DrawingTool
@onready var smudge_tool: SmudgeTool = %SmudgeTool
@onready var bucket_tool: BucketTool = %BucketTool
@onready var pan_tool: PanTool = %PanTool
@onready var eraser_tool: EraserTool = %EraserTool
@onready var transform_tool: TransformTool = %TransformTool
@onready var speech_bubble_tool: SpeechBubbleTool = %SpeechBubbleTool


@onready var tool_options_mapping: = {
	drawing_tool: _brush_options_container,
	smudge_tool: _smudge_options_container,
	bucket_tool: _bucket_options_container,
	eraser_tool: _eraser_options_container,
	speech_bubble_tool: _speech_bubble_options,
}

@onready var image_gen_window: Window = %ImageGenWindow
@onready var prompt_text_edit: TextEdit = %PromptTextEdit
@onready var send_prompt_button: Button = %SendPromptButton
@onready var negative_text_edit: TextEdit = %NegativeTextEdit
@onready var image_width_line_edit: LineEdit = %ImageWidthLineEdit
@onready var image_height_line_edit: LineEdit = %ImageHeightLineEdit
@onready var image_width_option_button: OptionButton = %ImageWidthOptionButton
@onready var image_height_option_button: OptionButton = %ImageHeightOptionButton
@onready var advanced_settings_check_button: CheckButton = %AdvancedSettingsCheckButton
@onready var advanced_settings_container: VBoxContainer = %AdvancedSettingsContainer
@onready var prompt_button: Button = %PromptButton
@onready var steps_spin_box: SpinBox = %StepsSpinBox
@onready var cfg_spin_box: SpinBox = %CFGSpinBox
@onready var denoise_spin_box: SpinBox = %DenoiseSpinBox
@onready var seed_line_edit: LineEdit = %SeedLineEdit

@onready var mask_color_option_button: OptionButton = %MaskColorOptionButton
@onready var color_picker_button: ColorPickerButton = %ColorPickerButton
@onready var mask_layer_cards_container: VBoxContainer = %MaskLayerCardsContainer
@onready var image_gen_panel_container: PanelContainer = %ImageGenPanelContainer
@onready var mask_edit_button: Button = %MaskEditPanelButton
@onready var tool_size_v_slider: VSlider = %ToolSizeVSlider
@onready var copy_layer_button: Button = %CopyLayerButton
@onready var merge_layers_button: Button = %MergeLayersButton
@onready var delete_layer_button: Button = %DeleteLayerButton
@onready var positive_prompt_mic_button: Button = %PositivePromptMicButton
@onready var negative_prompt_mic_button: Button = %NegativePromptMicButton
@onready var mask_container: HBoxContainer = %MaskContainer

#endregion

const DEFAULT_IMAGE_GEN_RES: int = 1024 # The total numgber of pixels must be divisible by 64
const MAX_IMAGE_GEN_RES: int = 2500
const MIN_IMAGE_RES: int = 512
var canvas_size: = Vector2i(1000, 1000)

var _custom_cursor: Resource
var _custom_cursor_shape: int
var _custom_cursor_hotspot: Vector2


const COMMANDS_SIZE: = 15
var _command_idx: = -1
var _commands: Array[GraphicsEditorUndo.Command] = []

var layers: Array[LayerV2]

## Array of selected layers, in order in which they were selected
var selected_layers: Array[LayerV2] = []
var selected_mask_layers: Array[LayerV2] = []
var is_active_layer_mask: = false
var active_layer: LayerV2:
	get:
		if selected_layers.is_empty() and selected_mask_layers.is_empty():
			return layers[0] if not layers.is_empty() else null 
		if is_active_layer_mask:
			return selected_mask_layers.get(0) if not selected_mask_layers.is_empty() else null
		else:
			return selected_layers.get(0) if not selected_layers.is_empty() else null

var last_selected_color: Color = Color.BLACK
var active_tool: BaseTool:
	set(value):
		active_tool = value
		# reset the cursor here,
		# so it happends before the signal is consumed by selected tool which may change it
		set_custom_cursor(null)
		_set_drag_forward_to_layer(active_tool)
		active_tool_changed.emit(value)

var saved: = true
var _previous_tool_before_eraser: BaseTool = null  # Store tool to return to after eraser mode

var _current_image_gen_request_id: String = ""

func _ready() -> void:
	
	active_tool_changed.connect(_on_active_tool_changed)
	_tools_option_button.select(0)
	_tools_option_button.item_selected.emit(0)
	compose_progress_updated.connect(_on_compose_progress)
	compose_finished.connect(_on_compose_complete)
	active_layer_is_mask_layer.connect(_on_active_layer_mask_layer)
	# Connect pen inverted signals
	drawing_tool.pen_inverted_changed.connect(_on_pen_inverted_changed)
	eraser_tool.pen_normal_detected.connect(_on_pen_normal_detected)
	
	# Connect media generation signal to receive generated images
	MediaGen.pass_image_to_editor.connect(_on_image_received)
	
	var temp_res: = MIN_IMAGE_RES
	while temp_res + 64 <= MAX_IMAGE_GEN_RES:
		var res: = str(temp_res)
		image_width_option_button.add_item(res)
		image_height_option_button.add_item(res)
		temp_res += 128
	
	delete_layer.connect(_on_delete_layer)


func setup(canvas_size_: Vector2i = Vector2i(1000, 1000)) -> void:
	# Create layers in order (first created appears at bottom in visual stack)
	create_new_layer("Background", canvas_size_, Color.WHITE, false)
	create_new_layer("Canvas", canvas_size_, Color.TRANSPARENT, false, true)
	create_new_layer("Drawing", canvas_size_, Color.TRANSPARENT, true)  # Selected by default


func create_new_layer(layer_name: String, dimensions: Vector2i, color: Color = Color.TRANSPARENT, select: = true, locked: = false) -> LayerV2:
	var layer: = LayerV2.create_drawing_layer(layer_name, dimensions, color)
	
	layer.locked = locked

	add_layer(layer, select)

	return layer

func create_new_image_layer(layer_name: String, image: Image, select: = true) -> LayerV2:
	var layer: = LayerV2.create_image_layer(layer_name, image)
	
	add_layer(layer, select)

	return layer


func create_new_mask_layer(layer_name: String, dimensions: Vector2i, color: Color = Color.TRANSPARENT, select: = true, locked: = false) -> LayerV2:
	var layer: = LayerV2.create_mask_layer(layer_name, dimensions, color)
	
	layer.locked = locked

	add_mask_layer(layer, select)

	return layer


func add_mask_layer(layer: LayerV2, select: = true) -> LayerV2:
	layer.tree_exiting.connect(_on_mask_layer_tree_exiting.bind(layer))

	var layer_card: = LayerCard.create(self, layer)

	layer_card.layer_selected.connect(_on_layer_card_selected.bind(layer, layer_card))
	layer_card.layer_deselected.connect(_on_layer_card_deselected.bind(layer, layer_card))
	layer_card.reorder.connect(_on_layer_card_reorder.bind(layer_card))
	layer_card.layer_clicked.connect(_on_layer_card_clicked.bind(layer_card))

	mask_layer_cards_container.add_child(layer_card)
	mask_layer_cards_container.move_child(layer_card, 0)
	layer_card.selected = select

	layers_container.add_child(layer, true)

	layers.append(layer)
	
	return layer


func add_layer(layer: LayerV2, select: = true) -> LayerV2:
	layer.tree_exiting.connect(_on_layer_tree_exiting.bind(layer))

	var layer_card: = LayerCard.create(self, layer)

	layer_card.layer_selected.connect(_on_layer_card_selected.bind(layer, layer_card))
	layer_card.layer_deselected.connect(_on_layer_card_deselected.bind(layer, layer_card))
	layer_card.reorder.connect(_on_layer_card_reorder.bind(layer_card))
	layer_card.layer_clicked.connect(_on_layer_card_clicked.bind(layer_card))

	layer_cards_container.add_child(layer_card)
	layer_cards_container.move_child(layer_card, 0)
	layer_card.selected = select

	layers_container.add_child(layer, true)

	layers.append(layer)
	
	return layer

# when layer is deleted remove it from selected layers if it's there
func _on_layer_tree_exiting(layer: LayerV2) -> void:
	selected_layers.erase(layer)
	layers.erase(layer)


func _on_mask_layer_tree_exiting(layer: LayerV2) -> void:
	selected_mask_layers.erase(layer)
	layers.erase(layer)


func _on_layer_card_selected(layer: LayerV2, _layer_card: LayerCard):
	if not selected_layers.has(layer) and (LayerV2.Type.DRAWING == layer.type or LayerV2.Type.IMAGE == layer.type):
		selected_layers.append(layer)
	if not selected_mask_layers.has(layer) and LayerV2.Type.MASK == layer.type:
		selected_mask_layers.append(layer)
	if selected_layers.size() > 0 and selected_layers.get(0).type != LayerV2.Type.MASK:
		active_layer_is_mask_layer.emit(false)
	elif selected_mask_layers.size() > 0 and selected_mask_layers[0].type == LayerV2.Type.MASK:
		active_layer_is_mask_layer.emit(true)


func _on_layer_card_deselected(layer: LayerV2, _layer_card: LayerCard):
	selected_layers.erase(layer)
	selected_mask_layers.erase(layer)
	if selected_layers.size() > 0 and selected_layers.get(0).type != LayerV2.Type.MASK:
		active_layer_is_mask_layer.emit(false)
	elif selected_mask_layers.size() > 0 and selected_mask_layers[0].type == LayerV2.Type.MASK:
		active_layer_is_mask_layer.emit(true)


func _on_layer_card_clicked(button_index: int, layer_card: LayerCard):
	if button_index == MOUSE_BUTTON_LEFT:

		if layer_card.layer.locked: return # ignore locked layers
		
		if Input.is_key_pressed(KEY_CTRL):
			layer_card.selected = not layer_card.selected
		
		else:
			for c: LayerCard in layer_cards_container.get_children():
				c.selected = false
			for c: LayerCard in mask_layer_cards_container.get_children():
				c.selected = false
			layer_card.selected = true


func _on_layer_card_reorder(to: int, layer_card: LayerCard):
	reorder_layer(layer_card.layer, to)


func display_message(title: String, content: String):
	message_window.popup_centered()
	message_title.text = title
	message_content.text = content

# FIXME: change this
func export_image(path: String) -> Error:
	
	var image: = await compose_final_image()

	if image.is_empty():
		return ERR_INVALID_DATA

	var error: = image.save_png(path)

	return error

# Helper function to get corners of a rotated layer
func _get_rotated_corners(layer: LayerV2) -> Array[Vector2]:
	var corners: Array[Vector2] = []
	var pivot = layer.pivot_offset
	var pos = layer.position
	var _size = layer.size
	var rotation_rad = layer.rotation
	
	# Calculate the four corners in local space
	var local_corners = [
		Vector2(0, 0) - pivot,           # Top-left
		Vector2(_size.x, 0) - pivot,      # Top-right
		Vector2(_size.x, _size.y) - pivot, # Bottom-right
		Vector2(0, _size.y) - pivot       # Bottom-left
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
	
	if layer.type == LayerV2.Type.MASK:
		if index - layer_card.get_index() == 1:
			# same final order if we drop it on next index
			return
		if layer_card.get_index() < index:
			index -= 1
		if index == mask_layer_cards_container.get_child_count():
			index -= 1
		layers_container.move_child(layer, -(index+1))
		mask_layer_cards_container.move_child(layer_card, index)
	else:
		if index - layer_card.get_index() == 1:
			# same final order if we drop it on next index
			return
		if layer_card.get_index() < index:
			index -= 1
		if index == layer_cards_container.get_child_count():
			index -= 1
		layers_container.move_child(layer, -(index+1))
		layer_cards_container.move_child(layer_card, index)

# Why graphics editor instead of just layers container?
# When using layers container, pan tool acts wierd and i don't know why exactly.
# Control with tools is set to stop the mouse events to accommodate for the below input hadnling
var dragging: = false
var last_mouse_position: Vector2 = Vector2.ZERO
func _gui_input(event: InputEvent) -> void:
	
	#region Move Canvas
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_MIDDLE:
			if event.is_pressed():
				dragging = true
				last_mouse_position = event.position
			else:
				dragging = false

		elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom(event.position, 1.1)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom(event.position, 0.9)
	if event is InputEventMouseMotion:
		if dragging:
			# Pan all layers together
			var relative = event.position - last_mouse_position
			_pan_canvas(relative)
			last_mouse_position = event.position
			return
	#endregion Move Canvas
	
	# if we have a active tool and at least one of selected layers is visible
	if active_tool and (selected_layers.any(func(l: LayerV2): return l.is_visible_in_tree()) or selected_mask_layers.any(func(l: LayerV2): return l.is_visible_in_tree()) ):
		if active_tool.handle_input_event(event):
			_compose_result_expired = true
			saved = false
			graphics_editor_changed.emit()
		accept_event()


func _pan_canvas(relative: Vector2) -> void:
	layers_container.position += relative


func _zoom(mouse_position: Vector2, factor: float) -> void:
	var container = layers_container
	
	if container.scale.x * factor < 0.1 or container.scale.x * factor > 2.5:
		return 
	
	# Get mouse position relative to the container
	var mouse_relative = mouse_position - container.position
	
	# Apply scale to the entire container
	container.scale *= factor
	
	# Adjust container position to keep the mouse point stationary
	var offset = mouse_relative * (factor - 1.0)
	container.position -= offset


signal graphics_editor_changed
func _unhandled_key_input(event: InputEvent) -> void:
	
	if event.is_action_pressed("ui_undo"):
		undo_command()

	elif event.is_action_pressed("ui_redo"):
		redo_command()


func _draw() -> void:
	for layer in selected_layers: layer.queue_redraw()
	for layer in selected_mask_layers: layer.queue_redraw()
	for c: LayerCard in layer_cards_container.get_children():
		c.queue_redraw()
	for c: LayerCard in mask_layer_cards_container.get_children():
		c.queue_redraw()

## Delegates drag handling functions to given layer.[br]
## See [method Control.set_drag_forwarding].
func _set_drag_forward_to_layer(tool_: BaseTool) -> void:
	#return
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

func _on_pen_inverted_changed(is_inverted: bool) -> void:
	if is_inverted:
		# Switch to eraser tool when pen is inverted
		if active_tool != eraser_tool:
			_previous_tool_before_eraser = active_tool
			eraser_tool.set_activated_by_pen(true)  # Mark that eraser was activated by pen
			active_tool = eraser_tool
			# Update the UI to show eraser is selected
			_tools_option_button.select(1)  # Index 1 is eraser
	else:
		# Switch back to previous tool when pen is normal
		if active_tool == eraser_tool and _previous_tool_before_eraser:
			active_tool = _previous_tool_before_eraser
			# Update UI to show the previous tool
			if _previous_tool_before_eraser == drawing_tool:
				_tools_option_button.select(0)  # Brush
			elif _previous_tool_before_eraser == bucket_tool:
				_tools_option_button.select(2)  # Bucket
			elif _previous_tool_before_eraser == smudge_tool:
				_tools_option_button.select(3)  # Smudge
			_previous_tool_before_eraser = null


func _on_pen_normal_detected() -> void:
	# Called when eraser tool detects pen is no longer inverted
	if active_tool == eraser_tool and _previous_tool_before_eraser:
		active_tool = _previous_tool_before_eraser
		# Update UI to show the previous tool
		if _previous_tool_before_eraser == drawing_tool:
			_tools_option_button.select(0)  # Brush
		elif _previous_tool_before_eraser == bucket_tool:
			_tools_option_button.select(2)  # Bucket
		elif _previous_tool_before_eraser == smudge_tool:
			_tools_option_button.select(3)  # Smudge
		_previous_tool_before_eraser = null

#region LayersCards PopUp panel
func _on_new_layer_button_pressed() -> void:
	# clear layers and create a new one
	for c: LayerCard in layer_cards_container.get_children():
		c.selected = false
	for c: LayerCard in mask_layer_cards_container.get_children():
		c.selected = false
	
	create_new_layer("Layer", canvas_size)


func _on_copy_layer_button_pressed() -> void:
	for i: LayerV2 in selected_layers:
		var j: LayerV2 = i.duplicate()
		j.image = i.image.duplicate()
		add_layer(j, false)


func _on_merge_layers_button_pressed() -> void:
	merge_layers(selected_layers.duplicate())


func _on_delete_layer_button_pressed() -> void:
	for i: LayerCard in layer_cards_container.get_children():
		if i.selected:
			i.delete_layer()

#endregion LayersCards PopUp panel

func _on_brush_tool_button_toggled(toggled_on: bool) -> void:
	active_tool = drawing_tool if toggled_on else null

func _on_bucket_tool_button_toggled(toggled_on:bool) -> void:
	active_tool = bucket_tool if toggled_on else null

func _on_pane_tool_button_toggled(toggled_on:bool) -> void:
	if not toggled_on:
		_tools_option_button.select(0)
		_tools_option_button.item_selected.emit(0)
		_tools_option_button.grab_focus()
		return
	
	active_tool = pan_tool if toggled_on else null


func _on_eraser_tool_button_toggled(toggled_on: bool) -> void:
	if toggled_on:
		eraser_tool.set_activated_by_pen(false)  # Mark that eraser was activated manually
		active_tool = eraser_tool
	else:
		active_tool = null


func _on_transform_tool_button_toggled(toggled_on: bool) -> void:
	if not toggled_on:
		_tools_option_button.select(0)
		_tools_option_button.item_selected.emit(0)
		_tools_option_button.grab_focus()
		return
	
	active_tool = transform_tool if toggled_on else null


func _on_speech_bubble_tool_button_toggled(toggled_on:bool) -> void:
	active_tool = speech_bubble_tool if toggled_on else null

func _on_smudge_tool_button_toggled(toggled_on: bool) -> void:
	active_tool = smudge_tool if toggled_on else null

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

	# reselect the first tool
	_tools_option_button.select(0)
	_tools_option_button.item_selected.emit(0)

func _on_layers_container_mouse_exited() -> void:
	Input.set_custom_mouse_cursor(null)


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

	var _processed: = 0 
	
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
				# var global_pos = Vector2(x, y) + bounds.position
				var global_pos = bounds.position + Vector2(x, y)
				
				# Convert global position to layer's local space
				var local_pos: = _global_to_layer_space(global_pos, layer_pos, rotation_rad, pivot)
				
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
				
				_processed += 1

				if _processed > 5000:
					await get_tree().process_frame # let the UI update
					_processed = 0
	
	if to_merge[0].type == LayerV2.Type.MASK:
		var merged_layer: = LayerV2.create_image_layer("Merged Mask Layer", merged_image)
		merged_layer.type = LayerV2.Type.MASK
		add_mask_layer(merged_layer)
		merged_layer.position = bounds.position
		# Remove original layers and their cards
		for layer in to_merge:
			# Find and remove the layer card
			for card in mask_layer_cards_container.get_children():
				if card is LayerCard and card.layer == layer:
					card.queue_free()
					#break
			# Remove from layers array
			layers.erase(layer)
			selected_mask_layers.erase(layer)
			# Remove from scene
			layer.queue_free()
		return merged_layer
	else:
		var merged_layer = LayerV2.create_image_layer("Merged Layer", merged_image)
		# Add the merged layer to the editor
		add_layer(merged_layer)
		# We need to set the position here, after the add_layer
		# because that function resets this property, not sure where exactly
		merged_layer.position = bounds.position
		# Remove original layers and their cards
		for layer in to_merge:
			# Find and remove the layer card
			for card in layer_cards_container.get_children():
				if card is LayerCard and card.layer == layer:
					card.queue_free()
					#break
			# Remove from layers array
			layers.erase(layer)
			selected_layers.erase(layer)
			# Remove from scene
			layer.queue_free()
		return merged_layer

# Helper function for color blending (alpha compositing)
func _blend_colors(dst: Color, src: Color) -> Color:
	if src.a == 0.0:
		return dst
	if dst.a == 0.0:
		return src
	
	var alpha: float = src.a + dst.a * (1.0 - src.a)
	if alpha == 0.0:
		return Color.TRANSPARENT
	
	var r: float = (src.r * src.a + dst.r * dst.a * (1.0 - src.a)) / alpha
	var g: float = (src.g * src.a + dst.g * dst.a * (1.0 - src.a)) / alpha
	var b: float = (src.b * src.a + dst.b * dst.a * (1.0 - src.a)) / alpha
	
	return Color(r, g, b, alpha)

func _on_layer_cards_button_pressed() -> void:
	if !layer_cards_popup_panel.visible:
		layer_cards_popup_panel.position = Vector2(
			(
				layer_cards_toggle_button.global_position.x 
				-layer_cards_popup_panel.size.x/2.0
				+layer_cards_toggle_button.size.x/2.0
			),
			layer_cards_toggle_button.global_position.y + layer_cards_toggle_button.size.y + 30
		)
		layer_cards_popup_panel.show()
		layer_cards_popup_panel.borderless = true
		%TopOfLayersContainer.hide()
		%SendActionButton.disabled = true
		%SendActionButton.hide()
	else:
		layer_cards_popup_panel.hide()



func _on_layer_cards_popup_panel_popup_hide() -> void:
	layer_cards_toggle_button.release_focus()
	layer_cards_toggle_button.set_pressed_no_signal(false)

#region Undo
## Stores the executed command in the commands stack.
## The command is treated as completed and ready for undo.
func execute_command(cmd: GraphicsEditorUndo.Command) -> void:
	# if we did execute a undo for some command and now there's a new one
	# delete all the commands after the current index and store the new one
	if _command_idx != _commands.size()-1:
		_commands.resize(_command_idx+1)
	# since this check occurs every time,
	# there must be no more than one command over the limit
	# account for element that will be added
	if _commands.size()+1 > COMMANDS_SIZE:
		_commands.remove_at(0)

	_commands.append(cmd)
	_command_idx = _commands.size()-1


func undo_command() -> void:
	if _command_idx < 0:
		return
	var cmd: = _commands[_command_idx]

	cmd.undo()

	_command_idx = clampi(_command_idx-1, 0, _commands.size()-1)


func redo_command() -> void:

	if _command_idx == _commands.size()-1:
		return # nothing to redo

	var cmd: = _commands[_command_idx+1]

	cmd.redo()

	_command_idx = clampi(_command_idx+1, 0, _commands.size()-1)
#endregion


func _on_tools_option_button_item_selected(index: int) -> void:
	match index:
		0: _on_brush_tool_button_toggled(true)
		1: _on_eraser_tool_button_toggled(true)
		2: _on_bucket_tool_button_toggled(true)
		3: _on_smudge_tool_button_toggled(true)
		4: active_tool = null; _on_add_image_button_pressed()
		_: pass
	

#region Image compose

var _compose_result_image: Image
var _compose_result_expired: = false
var _current_compose_thread: Thread = null

func _on_compose_progress(progress: float):
	progress_window_bar.value = progress * 100

func _on_compose_complete(_image: Image):
	progress_window.hide()
	_compose_result_expired = false


func compose_final_image(show_dialog: = true) -> Image:
	# _compose_result_expired is set to true every time a tool is used
	if _compose_result_image and not _compose_result_expired:
		return _compose_result_image


	# Don't start if already running
	if _current_compose_thread != null and _current_compose_thread.is_alive():
		print("Compose already running, ignoring request")
		return Image.new()
	
	# Clean up previous thread if it exists
	if _current_compose_thread != null:
		if _current_compose_thread.is_alive():
			_current_compose_thread.wait_to_finish()
		_current_compose_thread = null
	
	if show_dialog:
		# Show progress window
		progress_window.popup()
		progress_window_label.text = "Composing image..."
		progress_window_bar.value = 0
	
	# Extract all needed data from nodes in main thread
	var layer_data: Array[Dictionary] = []
	var layer_nodes = layers_container.get_children().filter(func(n): return n is LayerV2)
	
	for layer in layer_nodes:
		if layer is LayerV2 and layer.visible:
			layer_data.append({
				"image": layer.image,
				"position": layer.position,
				"rotation": layer.rotation,
				"pivot_offset": layer.pivot_offset,
				"size": layer.size
			})
	
	# Create and start new thread
	_current_compose_thread = Thread.new()
	_current_compose_thread.start(_compose_image_thread_worker.bind(layer_data))
	
	return await compose_finished

# Replace your thread worker with this simpler version:
func _compose_image_thread_worker(layer_data: Array[Dictionary]):
	print("Starting compose worker thread")
	
	var result_image = _compose_final_image_worker(layer_data)
	
	# Signal completion back to main thread
	call_deferred("_on_compose_finished", result_image)

# Keep your existing _compose_final_image_worker function as is, but update progress reporting:
func _compose_final_image_worker(layer_data: Array) -> Image:
	# If no layers, return empty image
	if layer_data.is_empty():
		return Image.new()
	
	# Determine the bounding rectangle for all layers
	var bounds := Rect2()
	var first_layer := true
	
	for data in layer_data:
		var corners = _get_rotated_corners_static(data.position, data.size, data.rotation, data.pivot_offset)
		for corner in corners:
			if first_layer:
				bounds = Rect2(corner, Vector2.ZERO)
				first_layer = false
			else:
				bounds = bounds.expand(corner)
	
	# Create output image
	var width = int(bounds.size.x)
	var height = int(bounds.size.y)
	var output_image := Image.create(width, height, false, Image.FORMAT_RGBA8)
	output_image.fill(Color(0, 0, 0, 0))
	
	# Calculate total pixels for progress reporting
	var total_pixels = width * height * layer_data.size()
	var processed_pixels = 0
	var progress_update_interval: int = max(1000, int(total_pixels / 100.0))  # Update progress every 1% or 1000 pixels
	
	# Blend all layers onto the output image
	for layer_idx in range(layer_data.size()):
		var data = layer_data[layer_idx]
		var layer_image = data.image
		
		# Skip empty layers
		if not layer_image or layer_image.is_empty():
			processed_pixels += width * height  # Skip this layer's pixels
			continue
		
		var rotation_rad = data.rotation
		var pivot = data.pivot_offset
		var layer_pos = data.position
		
		# Process each pixel in the output image space
		for out_y in range(height):
			for out_x in range(width):
				# Get position in global space
				var global_pos = Vector2(out_x, out_y) + bounds.position
				
				# Convert to layer local space (accounting for rotation)
				var local_pos = _global_to_layer_space_static(global_pos, layer_pos, rotation_rad, pivot)
				
				# Check if the point is within the layer's image
				var img_x = int(local_pos.x)
				var img_y = int(local_pos.y)
				
				if img_x >= 0 and img_x < layer_image.get_width() and img_y >= 0 and img_y < layer_image.get_height():
					var src_color = layer_image.get_pixel(img_x, img_y)
					
					# Skip fully transparent pixels
					if src_color.a > 0.01:
						var dst_color = output_image.get_pixel(out_x, out_y)
						var blended = _blend_colors(dst_color, src_color)
						output_image.set_pixel(out_x, out_y, blended)
				
				processed_pixels += 1
				
				# Update progress periodically
				if processed_pixels % progress_update_interval == 0:
					var progress = float(processed_pixels) / float(total_pixels)
					call_deferred("_emit_progress", progress)
	
	return output_image

# Keep your existing helper functions:
func _emit_progress(progress: float):
	compose_progress_updated.emit(progress)

func _on_compose_finished(image: Image):
	_compose_result_image = image
	compose_finished.emit(image)
	
	# Clean up the thread
	if _current_compose_thread != null and _current_compose_thread.is_alive():
		_current_compose_thread.wait_to_finish()
		_current_compose_thread = null
	else:
		_current_compose_thread.wait_to_finish()
		_current_compose_thread = null

# Add this to handle cleanup when the node is being destroyed:
func _exit_tree():
	if _current_compose_thread != null and _current_compose_thread.is_alive():
		_current_compose_thread.wait_to_finish()
	_current_compose_thread = null
# Static helper functions that don't access node properties
static func _get_rotated_corners_static(position_: Vector2, size_: Vector2, rotation_: float, pivot_offset_: Vector2) -> Array[Vector2]:
	var corners: Array[Vector2] = []
	var pivot = pivot_offset_
	var pos = position_
	var rotation_rad = rotation_
	
	# Calculate the four corners in local space
	var local_corners = [
		Vector2(0, 0) - pivot,           # Top-left
		Vector2(size_.x, 0) - pivot,      # Top-right
		Vector2(size_.x, size_.y) - pivot, # Bottom-right
		Vector2(0, size_.y) - pivot       # Bottom-left
	]
	
	# Transform to global space
	for corner in local_corners:
		# Rotate
		var rotated = corner.rotated(rotation_rad)
		# Translate to global position
		var global_corner = rotated + pivot + pos
		corners.append(global_corner)
	
	return corners

static func _global_to_layer_space_static(global_pos: Vector2, layer_pos: Vector2, rotation_rad: float, pivot: Vector2) -> Vector2:
	# Translate to layer's origin
	var relative_pos = global_pos - layer_pos
	# Adjust for pivot point
	relative_pos -= pivot
	# Apply inverse rotation
	relative_pos = relative_pos.rotated(-rotation_rad)
	# Re-adjust for pivot
	relative_pos += pivot
	
	return relative_pos


func _on_prompt_button_pressed() -> void:
	if !image_gen_window.visible:
		image_gen_window.position = Vector2(
			(
				prompt_button.global_position.x 
				-image_gen_window.size.x
				+prompt_button.size.x
			),
			prompt_button.global_position.y + 50
		)
		image_gen_window.show()
	else:
		image_gen_window.hide()


func _on_send_prompt_button_pressed() -> void:
	image_gen_window.hide()
	var params : Dictionary = get_params_image_gen()
	var toast: ToastNotification
	if params.is_empty():
		toast =ToastNotification.create(ToastNotification.Type.WARNING, "Please enter a valid prompt for image generation")
	
	else:
		toast =ToastNotification.create(ToastNotification.Type.INFO, "Sending Image Gen request...")
		_current_image_gen_request_id = MediaGen.send_media_gen_request(params)
		image_gen_window.hide()
		layer_cards_popup_panel.hide()
	SingletonObject.main_scene.add_child(toast)


func _on_image_received(filename:String, request_id: String, buffer: PackedByteArray) -> void:
	# Always hide progress window when receiving response (success or failure)
	if request_id != _current_image_gen_request_id:
		return
	if progress_window.visible:
		progress_window.hide()

	if buffer.is_empty():
		display_message("Error", "Received empty image data from media generation service")
		return

	var image: = Image.new()
	var err = image.load_png_from_buffer(buffer)

	if err != OK:
		display_message("Error", "Failed to load generated image (error: %s)" % err)
		return

	var l: = LayerV2.create_image_layer(filename, image)

	add_layer(l)
	_current_image_gen_request_id = ""


enum AI_REQUEST {
	IMAGE_GEN,
	EDIT_IMAGE,
	MASK_EDIT
}
var ai_request_type: AI_REQUEST = AI_REQUEST.EDIT_IMAGE
func _on_edit_button_pressed() -> void:
	if !layer_cards_popup_panel.visible:
		layer_cards_popup_panel.position = Vector2(
			(
				%ImageGenWindow.position.x 
				-layer_cards_popup_panel.size.x/2.0
				+ %ImageGenWindow.size.x/2.0
			),
			%ImageGenWindow.position.y + %ImageGenWindow.size.y + 30
		)
		layer_cards_popup_panel.show()
		layer_cards_popup_panel.borderless = false
		%AIActionLabel.text = "Pick an Layer to Send to Edit"
		%TopOfLayersContainer.show()
		%SendActionButton.disabled = false
		%SendActionButton.show()
		ai_request_type = AI_REQUEST.EDIT_IMAGE
	else:
		layer_cards_popup_panel.hide()
		layer_cards_popup_panel.borderless = true
		%TopOfLayersContainer.hide()
		%SendActionButton.disabled = true
		%SendActionButton.hide()


func _on_edit_img_button_pressed() -> void:
	if ai_request_type == AI_REQUEST.EDIT_IMAGE:
		if selected_layers.size() < 1:
			return
		
		var layer_to_send: LayerV2 = selected_layers[0]
		# Get the image from the active layer
		if layer_to_send == null:
			return
		var image_to_edit: Image = layer_to_send.layer.image
		var image_filename: String = layer_to_send.layer.name + ".png" # Use layer name as filename
		# Convert Image to PackedByteArray (PNG format)
		# The image must be converted to RGBA8 for PNG export if it's not already.
		# Duplicate to avoid modifying the original layer image directly during conversion.
		var image_for_export: Image = image_to_edit.duplicate()
		if image_for_export.get_format() != Image.FORMAT_RGBA8:
			image_for_export.convert(Image.FORMAT_RGBA8)
		
		var image_buffer: PackedByteArray = image_for_export.save_png_to_buffer()
		
		if image_buffer.is_empty():
			display_message("Error", "Failed to convert active layer image to PNG buffer.")
			return
		
		var toast : =ToastNotification.create(ToastNotification.Type.INFO, "Sending image edit request...")
		SingletonObject.main_scene.add_child(toast)
		
		var params: Dictionary = get_params_image_gen()
		
		if params.is_empty():
			return
		
		if !seed_line_edit.text.is_empty():
			params["seed"] = seed_line_edit.text
		
		_current_image_gen_request_id = MediaGen.send_media_edit_request(params, image_buffer, image_filename)
		
		image_gen_window.hide()
		layer_cards_popup_panel.hide()
	elif  ai_request_type == AI_REQUEST.MASK_EDIT:
		if selected_layers.size() < 1 or selected_mask_layers.size() < 1:
			return
			
		var image_layer_to_edit: LayerV2 = null
		for i: LayerV2 in selected_layers:
			if i.selected:
				image_layer_to_edit = i
				break
		if prompt_text_edit.text.is_empty():
			display_message("Input Required", "Please enter a positive prompt for masked image editing.")
			return
		
		var images_dir: Array = []
		
		if image_layer_to_edit == null:
			return
		var base_image_to_edit: Image = image_layer_to_edit.image
		var base_image_filename: String = image_layer_to_edit.name + ".png" 
		
		
		var base_image_for_export: Image = base_image_to_edit.duplicate()
		if base_image_for_export.get_format() != Image.FORMAT_RGBA8:
			base_image_for_export.convert(Image.FORMAT_RGBA8)
		
		var base_image_buffer: PackedByteArray = base_image_for_export.save_png_to_buffer()
		
		if base_image_buffer.is_empty():
			display_message("Error", "Failed to convert active layer image to PNG buffer for mask editing.")
			return
		var base64_base_image_data: String = Marshalls.raw_to_base64(base_image_buffer)
		
		var image_file: = {
				"filename": base_image_filename,
				"role": "image",
				"data": base64_base_image_data,
				"content_type": "image/png"
			}
		images_dir.append(image_file)
		
		#var mask_dir: = {}
		var mask_color_channel: = ""
		for i: LayerV2 in selected_mask_layers:
			if i.type == LayerV2.Type.MASK and i.selected:
				var base_mask_image: = i.image
				var mask_layer_name: = i.name + ".png"
				mask_color_channel = i.layer.mask_color_name
				var base_mask_image_for_export: Image = base_mask_image.duplicate()
				if base_mask_image_for_export.get_format() != Image.FORMAT_RGBA8:
					base_mask_image_for_export.convert(Image.FORMAT_RGBA8)
				
				var base_mask_buffer: PackedByteArray = MediaGen.generate_mask_bytes(base_mask_image_for_export, i.layer.mask_color, mask_color_channel)
				#var base_mask_buffer: PackedByteArray = base_mask_image_for_export.save_png_to_buffer()
				if base_mask_buffer.is_empty():
					display_message("Error", "Error generating the mask image")
					return
				var base64_mask_image_data: String = (Marshalls.raw_to_base64(base_mask_buffer))
				
				var mask_file: = {
				"filename": mask_layer_name,
				"role": "mask",
				"data": base64_mask_image_data,
				"content_type": "image/png"
				}
				images_dir.append(mask_file)
		
		var toast : =ToastNotification.create(ToastNotification.Type.INFO, "Sending image and mask for selective editing...")
		SingletonObject.main_scene.add_child(toast)
		
		var selective_editing_params: Dictionary = get_params_image_gen()
		selective_editing_params["mask_channel"] = mask_color_channel
		_current_image_gen_request_id = MediaGen.send_media_selective_edit_request(selective_editing_params, images_dir)
		image_gen_window.hide()
		layer_cards_popup_panel.hide()

func _on_advanced_settings_check_button_toggled(toggled_on: bool) -> void:
	advanced_settings_container.visible = toggled_on


func get_params_image_gen() -> Dictionary:
	if prompt_text_edit.text.is_empty():
		return {}
		
	var image_res: int = image_width_line_edit.text.to_int() if !image_width_line_edit.text.is_empty() and image_width_line_edit.text.is_valid_int() else DEFAULT_IMAGE_GEN_RES
	return {
		"positive_prompt" = prompt_text_edit.text,
		"negative_prompt" = negative_text_edit.text,
		"width" = image_res,
		"height" = image_res,
		"steps" = steps_spin_box.value,
		"cfg" = cfg_spin_box.value,
		"denoise" = denoise_spin_box.value
	}


func selected_layers_has_mask() -> bool:
	for i in selected_layers:
		if i.type == LayerV2.Type.MASK:
			return true
	return false


func selected_layers_has_image() -> bool:
	for i in selected_layers:
		if i.type == LayerV2.Type.IMAGE:
			return true
	return false


func get_first_image_layer() -> LayerV2:
	for i in selected_layers:
		if i.type == LayerV2.Type.IMAGE:
			return i
	return null


func _on_mask_edit_button_pressed() -> void: 
	if !layer_cards_popup_panel.visible:
		layer_cards_popup_panel.position = Vector2(
			(
				%ImageGenWindow.position.x 
				-layer_cards_popup_panel.size.x/2.0
				+ %ImageGenWindow.size.x/2.0
			),
			%ImageGenWindow.position.y + %ImageGenWindow.size.y + 30
		)
		layer_cards_popup_panel.show()
		layer_cards_popup_panel.borderless = false
		%AIActionLabel.text = "Pick an Image Layer and a Mask Layer to Send to Edit"
		%TopOfLayersContainer.show()
		%SendActionButton.disabled = false
		%SendActionButton.show()
		ai_request_type = AI_REQUEST.MASK_EDIT
	else:
		layer_cards_popup_panel.hide()
		layer_cards_popup_panel.borderless = true
		%TopOfLayersContainer.hide()
		%SendActionButton.disabled = true
		%SendActionButton.hide()

#region LayersCards Masks PopUp panel
func _on_new_mask_layer_button_pressed() -> void:
	# clear layers and create a new one
	for c: LayerCard in layer_cards_container.get_children():
		c.selected = false
	
	for c: LayerCard in mask_layer_cards_container.get_children():
		c.selected = false
	
	create_new_mask_layer("Mask Layer", canvas_size)
	_on_mask_color_option_button_item_selected(mask_color_option_button.selected)


func _on_delete_mask_layer_button_pressed() -> void:
	for i: LayerCard in mask_layer_cards_container.get_children():
		if i.selected:
			i.delete_layer()


func _on_copy_mask_layer_button_pressed() -> void:
	for i: LayerV2 in selected_mask_layers:
		var j: LayerV2 = i.duplicate()
		j.image = i.image.duplicate()
		add_mask_layer(j, false)


func _on_merge_mask_layers_button_pressed() -> void:
	merge_layers(selected_mask_layers.duplicate())

#endregion LayersCards Masks PopUp panel

func _on_mask_color_option_button_item_selected(index: int) -> void:
	if active_layer and active_layer.type == active_layer.Type.MASK :
		var mask_color: Color = mask_color_option_button.get_item_icon(index).get_image().get_pixel(0,0)
		color_picker_button.color = mask_color
		active_layer.mask_color = mask_color
		active_layer.mask_color_name = mask_color_option_button.get_item_text(index).to_lower()
		active_layer.lock_color = true


func _on_mask_edit_panel_button_pressed() -> void:
	if !%SelectiveEditingPopupPanel.visible:
		%SelectiveEditingPopupPanel.position = Vector2(
			(
				mask_edit_button.global_position.x 
				+ mask_edit_button.size.x
			),
			mask_edit_button.global_position.y - (%SelectiveEditingPopupPanel.size.y * 0.8)
		)

		for child in %MediaGenLayersContainer.get_children():
			child.queue_free()

		for child in %MaskMediaGenLayersContainer.get_children():
			child.queue_free()

		for i: LayerCard in layer_cards_container.get_children():
			var j: LayerCard = i.duplicate()
			j.layer = i.layer
			j.selected = false
			j.layer_clicked.connect(_on_layer_card_clicked.bind(j))
			await get_tree().process_frame
			%MediaGenLayersContainer.add_child(j)
	
		for i: LayerCard in mask_layer_cards_container.get_children():
			var j: LayerCard = i.duplicate()
			j.layer = i.layer
			j.selected = false
			j.layer_clicked.connect(_on_layer_card_clicked.bind(j))
			await get_tree().process_frame
			%MaskMediaGenLayersContainer.add_child(j)
		%SelectiveEditingPopupPanel.show()
	else:
		%SelectiveEditingPopupPanel.hide()


func _on_delete_layer(layer: LayerV2) -> void:
	if layer.tree_exited.is_connected(_on_layer_tree_exiting):
		layer.tree_exited.disconnect(_on_layer_tree_exiting)
	layers.erase(layer)
	selected_layers.erase(layer)
	selected_mask_layers.erase(layer)
	layer.queue_free()


func _on_positive_prompt_mic_button_pressed() -> void:
	if SingletonObject.AtT._StartConverting() != OK: return
	SingletonObject.AtT.FieldForFilling = prompt_text_edit
	SingletonObject.AtT.btn = positive_prompt_mic_button
	positive_prompt_mic_button.modulate = Color(Color.LIME_GREEN)
	SingletonObject.AtT.btnStop = positive_prompt_mic_button


func _on_negative_prompt_mic_button_pressed() -> void:
	if SingletonObject.AtT._StartConverting() != OK: return
	SingletonObject.AtT.FieldForFilling = negative_text_edit
	SingletonObject.AtT.btn = negative_prompt_mic_button
	negative_prompt_mic_button.modulate = Color(Color.LIME_GREEN)
	SingletonObject.AtT.btnStop = negative_prompt_mic_button


func _on_active_layer_mask_layer(is_mask: bool) -> void:
	is_active_layer_mask = is_mask
	color_picker_button.visible = not is_mask
	mask_container.visible = is_mask
	if is_mask:
		_tools_option_button.select(0)
		_tools_option_button.set_item_disabled(2, true)
		_tools_option_button.set_item_disabled(3, true)
		_tools_option_button.set_item_disabled(4, true)
		color_picker_button.color = active_layer.mask_color
	else:
		_tools_option_button.set_item_disabled(2, false)
		_tools_option_button.set_item_disabled(3, false)
		_tools_option_button.set_item_disabled(4, false)
		color_picker_button.color = last_selected_color


func _on_image_gen_window_close_requested() -> void:
	image_gen_window.hide()


func _on_color_picker_button_color_changed(color: Color) -> void:
	last_selected_color = color


func _on_layer_cards_popup_panel_close_requested() -> void:
	layer_cards_popup_panel.hide()


func _on_back_button_pressed() -> void:
	image_gen_window.show()
	layer_cards_popup_panel.hide()

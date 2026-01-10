class_name LayerV2
extends Control

enum Type {
	IMAGE,
	DRAWING,
	SPEECH_BUBBLE,
	MASK,
	CONTROL,
	TEXT,
}

enum ControlType {
	POSE,
	CANNY,
	DEPTH,
	SEGMENTATION
}

@onready var texture_rect: TextureRect = %TextureRect
@onready var center_container: Control = %CenterContainer

const _scene = preload("res://Scenes/LayerV2.tscn")

enum TransformPoint {
	TOP_LEFT,
	TOP,
	TOP_RIGHT,
	RIGHT,
	BOTTOM_RIGHT,
	BOTTOM,
	BOTTOM_LEFT,
	LEFT,
	MOVE,
	ROTATE,
	NONE,
}

var _transform_rect_size: = Vector2(50, 50)
var transform_rect_visible: = false

var outline_color: = Color.ORANGE_RED
var outline_visible: = true
var locked: = false

var image_zoom_factor: float:
	get: return (Vector2(image.get_size()).length() / size.length()) if image else .0


var type: Type

# Unscaled image that will be used to create scaled versions of the image
var base_image: Image = null

var image: Image:
	set(value):
		image = value
		if not image or image.is_empty(): return

		if not is_node_ready():
			await ready

		if not base_image:
			base_image = image.duplicate()

		# Reuse existing ImageTexture if possible to avoid leaks
		var img: ImageTexture
		if texture_rect.texture is ImageTexture:
			img = texture_rect.texture as ImageTexture
			img.set_image(image)
		else:
			img = ImageTexture.create_from_image(image)
			texture_rect.texture = img

		await get_tree().process_frame

		# Set the layer's minimum size to match the image
		size = img.get_size()

		# Set the actual size if it's currently zero
		if size == Vector2.ZERO:
			size = img.get_size()

		# Set pivot to center for proper rotation
		pivot_offset = size / 2

		# Set texture size to match image
		texture_rect.size = img.get_size()

		queue_redraw()

var speech_bubble: CloudControl:
	set(value):
		speech_bubble = value

		if not is_node_ready():
			await ready

		center_container.add_child(speech_bubble)

var lock_color: bool = false
var mask_color: Color = Color.WHITE
var mask_color_name: String = "blue"

# Control layer properties
var control_type: ControlType = ControlType.POSE
var control_strength: float = 1.0

# Text layer properties
var text_content: String = ""
var text_font: Font = null
var text_font_size: int = 48
var text_fill_color: Color = Color.WHITE
var text_stroke_color: Color = Color.BLACK
var text_stroke_width: int = 2



func _ready() -> void:
	# Prevent automatic positioning while allowing manual size control
	set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	# Or use size flags to control behavior
	size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	size_flags_vertical = Control.SIZE_SHRINK_CENTER


func _exit_tree() -> void:
	# Release texture to prevent leaks during shutdown
	if texture_rect and texture_rect.texture:
		texture_rect.texture = null


static func create_image_layer(name_: String, image_: Image) -> LayerV2:
	var layer: LayerV2 = _scene.instantiate()

	layer.image = image_
	layer.name = name_
	layer.type = Type.IMAGE

	return layer

static func create_drawing_layer(name_: String, size_: Vector2i, background_color: = Color.TRANSPARENT) -> LayerV2:
	var layer: LayerV2 = _scene.instantiate()

	var img = Image.create(size_.x, size_.y, false, Image.Format.FORMAT_RGBA8)
	img.fill(background_color)
	
	layer.image = img
	layer.name = name_
	layer.type = Type.DRAWING

	return layer


static func create_speech_bubble_layer(name_: String, type_: CloudControl.Type = CloudControl.Type.ELLIPSE) -> LayerV2:
	var layer: LayerV2 = _scene.instantiate()
	
	layer.speech_bubble = CloudControl.create(type_)

	layer.name = name_
	layer.type = Type.SPEECH_BUBBLE

	return layer


static func create_mask_layer(name_: String, size_: Vector2i, background_color: = Color.TRANSPARENT) -> LayerV2:
	var layer: = _scene.instantiate()

	var img = Image.create(size_.x, size_.y, false, Image.Format.FORMAT_RGBA8)
	img.fill(background_color)

	layer.image = img
	layer.name = name_
	layer.type = Type.MASK

	return layer


static func create_control_layer(name_: String, size_: Vector2i, control_type_: ControlType = ControlType.POSE) -> LayerV2:
	var layer: = _scene.instantiate()

	# Create transparent image for the control layer
	var img = Image.create(size_.x, size_.y, false, Image.Format.FORMAT_RGBA8)
	img.fill(Color.TRANSPARENT)

	layer.image = img
	layer.name = name_
	layer.type = Type.CONTROL
	layer.control_type = control_type_

	return layer


static func create_text_layer(name_: String, text: String, font: Font,
							  font_size: int, fill_color: Color,
							  stroke_color: Color, stroke_width: int) -> LayerV2:
	var layer: LayerV2 = _scene.instantiate()

	layer.name = name_
	layer.type = Type.TEXT
	layer.text_content = text
	layer.text_font = font
	layer.text_font_size = font_size
	layer.text_fill_color = fill_color
	layer.text_stroke_color = stroke_color
	layer.text_stroke_width = stroke_width

	# Calculate and set size immediately so hit detection works
	var padding = stroke_width + 4
	var text_size = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	layer.size = text_size + Vector2(padding * 2, padding * 2)

	return layer


## Return the [enum TransformPoint] type of the rect thats under the given [parameter mouse_position]
func get_rect_by_mouse_position(mouse_position: Vector2) -> TransformPoint:
	var _transform_rect_positions: = _get_transform_rect_positions()
	
	for key: TransformPoint in _transform_rect_positions:
		var drag_square: = Rect2(_transform_rect_positions[key] - _transform_rect_size/2, _transform_rect_size)    
		if drag_square.has_point(mouse_position):
			return key
	
	return TransformPoint.NONE

func _draw() -> void:
	match type:
		Type.IMAGE, Type.DRAWING, Type.MASK:
			_update_texture_from_image()
		Type.SPEECH_BUBBLE:
			speech_bubble.queue_redraw()
		Type.CONTROL:
			_update_texture_from_image()
		Type.TEXT:
			_draw_text_layer()


## Update texture from image, reusing existing ImageTexture if possible
func _update_texture_from_image() -> void:
	if not image: return
	# Reuse existing ImageTexture to avoid creating new texture on every draw
	if texture_rect.texture is ImageTexture:
		(texture_rect.texture as ImageTexture).set_image(image)
	else:
		texture_rect.texture = ImageTexture.create_from_image(image)

	# Draw the outline if visible
	if outline_visible:
		draw_rect(Rect2(Vector2.ZERO, get_rect().size), outline_color, false)

	# Draw transform handles if visible
	if transform_rect_visible:
		_draw_transform_handles()


## Draw text layer content using draw_string
func _draw_text_layer() -> void:
	if text_content.is_empty() or text_font == null:
		return

	var padding = text_stroke_width + 4
	var pos = Vector2(padding, padding + text_font.get_ascent(text_font_size))

	# Draw stroke (outline) first
	if text_stroke_width > 0:
		draw_string_outline(text_font, pos, text_content, HORIZONTAL_ALIGNMENT_LEFT,
						   -1, text_font_size, text_stroke_width, text_stroke_color)

	# Draw fill on top
	draw_string(text_font, pos, text_content, HORIZONTAL_ALIGNMENT_LEFT,
				-1, text_font_size, text_fill_color)

	# Draw the outline if visible (like other layer types)
	if outline_visible:
		draw_rect(Rect2(Vector2.ZERO, size), outline_color, false)

	# Draw transform handles if visible
	if transform_rect_visible:
		_draw_transform_handles()


## Calculate and set the size based on text content
func update_text_size() -> void:
	if type != Type.TEXT or text_font == null:
		return

	var padding = text_stroke_width + 4
	var text_size = text_font.get_string_size(text_content, HORIZONTAL_ALIGNMENT_LEFT, -1, text_font_size)
	size = text_size + Vector2(padding * 2, padding * 2)
	pivot_offset = size / 2


## Update text properties and re-render
func set_text_properties(text: String, font: Font = null, font_size: int = -1,
						 fill_color: Color = Color(-1, -1, -1),
						 stroke_color: Color = Color(-1, -1, -1),
						 stroke_width: int = -1) -> void:
	if type != Type.TEXT:
		return

	text_content = text
	if font != null:
		text_font = font
	if font_size > 0:
		text_font_size = font_size
	if fill_color.r >= 0:
		text_fill_color = fill_color
	if stroke_color.r >= 0:
		text_stroke_color = stroke_color
	if stroke_width >= 0:
		text_stroke_width = stroke_width

	update_text_size()
	queue_redraw()


## Draw the transform handles (shared by image and text layers)
func _draw_transform_handles() -> void:
	
	# Draw 8 control squares plus rotation handle
	var drag_square_positions: = PackedVector2Array([
		Vector2.ZERO,
		Vector2(size.x/2, 0),
		Vector2(size.x, 0),
		Vector2(size.x, size.y/2),
		Vector2(size.x, size.y),
		Vector2(size.x/2, size.y),
		Vector2(0, size.y),
		Vector2(0, size.y/2),
	])

	# Add rotation handle (above the top center handle)
	# var rotation_handle_pos = Vector2(size.x/2, -30)
	
	# Draw border lines
	draw_line(Vector2.ZERO, Vector2(size.x, 0), Color.BLACK)
	draw_line(Vector2(size.x, 0), Vector2(size.x, size.y), Color.BLACK)
	draw_line(Vector2(size.x, size.y), Vector2(0, size.y), Color.BLACK)
	draw_line(Vector2(0, size.y), Vector2.ZERO, Color.BLACK)
	
	# Draw diagonals (optional)
	draw_line(Vector2.ZERO, size, Color.BLACK)
	draw_line(Vector2(size.x, 0), Vector2(0, size.y), Color.BLACK)

	# Draw transform handles
	for pos in drag_square_positions:
		var drag_square: = Rect2(pos - _transform_rect_size/2, _transform_rect_size)
		
		draw_rect(drag_square.grow(2), Color.BLACK)
		draw_rect(drag_square, Color.WHITE)

	# # Draw rotation handle
	# var rotation_square: = Rect2(rotation_handle_pos - _transform_rect_size/2, _transform_rect_size)
	# draw_rect(rotation_square.grow(2), Color.BLACK)
	# draw_rect(rotation_square, Color.YELLOW)  # Different color to distinguish it
	
	# # Draw line from top center to rotation handle
	# draw_line(Vector2(size.x/2, 0), rotation_handle_pos, Color.BLACK)

func _get_transform_rect_positions() -> Dictionary:
	var positions = {
		TransformPoint.TOP_LEFT: Vector2.ZERO,
		TransformPoint.TOP: Vector2(size.x/2, 0),
		TransformPoint.TOP_RIGHT: Vector2(size.x, 0),
		TransformPoint.RIGHT: Vector2(size.x, size.y/2),
		TransformPoint.BOTTOM_RIGHT: Vector2(size.x, size.y),
		TransformPoint.BOTTOM: Vector2(size.x/2, size.y),
		TransformPoint.BOTTOM_LEFT: Vector2(0, size.y),
		TransformPoint.LEFT: Vector2(0, size.y/2),
		# Add rotation handle position
		TransformPoint.ROTATE: Vector2(size.x/2, -30)
	}
	return positions

func localize_input(event: InputEvent):
	if not event is InputEventMouse:
		return event

	var local_event = event.duplicate()

	match type:
		Type.IMAGE, Type.DRAWING, Type.MASK, Type.CONTROL, Type.TEXT:
			# Transform global mouse position to layer's local coordinate space
			# Using affine_inverse() properly handles rotation, scale, and translation
			# This ensures hit detection works correctly even when layer is rotated
			local_event.position = get_global_transform().affine_inverse() * get_global_mouse_position()
		Type.SPEECH_BUBBLE:
			pass

	return local_event

func expand_to_point(point: Vector2) -> Vector2:
	# If point is already within bounds, no expansion needed
	if (
		point.x >= 0 and point.x < image.get_size().x and
		point.y >= 0 and point.y < image.get_size().y
	):
		return Vector2.ZERO
	
	var current_size = image.get_size()
	
	# Convert point to integer coordinates (floor for proper pixel alignment)
	var point_x = int(floor(point.x))
	var point_y = int(floor(point.y))
	
	# Calculate new dimensions and offsets
	var min_x = min(0, point_x)
	var min_y = min(0, point_y)
	var max_x = max(current_size.x, point_x + 1)  # +1 to include the target pixel
	var max_y = max(current_size.y, point_y + 1)  # +1 to include the target pixel
	
	var required_width = max_x - min_x
	var required_height = max_y - min_y
	
	# Round up to next multiple of 64 (required for generative AI models)
	var new_width = int(ceil(required_width / 64.0) * 64)
	var new_height = int(ceil(required_height / 64.0) * 64)
	
	# Calculate extra space added by rounding
	var extra_width = new_width - required_width
	var extra_height = new_height - required_height
	
	# Calculate where to place the old image in the new expanded image
	# Add extra space from rounding to the side that needed expansion:
	# - If expanding left/top (min_x/min_y < 0), add extra space on left/top
	# - If expanding right/bottom (min_x/min_y == 0), extra space stays on right/bottom (offset stays 0)
	var offset_x = -min_x + (extra_width if min_x < 0 else 0)
	var offset_y = -min_y + (extra_height if min_y < 0 else 0)
	
	# Create new expanded image with transparent background
	var expanded_image = Image.create(new_width, new_height, false, image.get_format())
	expanded_image.fill(Color(0, 0, 0, 0))  # Fill with transparent
	
	# Debug info
	print("Expanding from ", current_size, " to ", Vector2(new_width, new_height))
	print("Target point: ", point, " -> ", Vector2(point_x, point_y))
	print("Offset: ", Vector2(offset_x, offset_y))
	
	# Copy the original image to the correct position in the expanded image
	expanded_image.blit_rect(image, Rect2i(0, 0, current_size.x, current_size.y), Vector2i(offset_x, offset_y))
	
	# Replace the original image with the expanded one
	image = expanded_image
	
	# Return the visual offset (amount to adjust layer position) - this is the actual expansion amount,
	# not including the padding from rounding, so content stays in the same visual position
	return Vector2(-min_x, -min_y)

func _on_resized() -> void:
	pass
	# _adjust_control_size()
	
func _on_minimum_size_changed() -> void:
	pass
	# _adjust_control_size()

func _adjust_control_size() -> void:

	if not is_node_ready(): return
	
	# Set pivot to center for proper rotation
	# custom_minimum_size = size
	pivot_offset = size / 2

	match type:
		Type.IMAGE:
			texture_rect.size = size
			# Only resize the image if the size has changed significantly
			if abs(image.get_width() - size.x) > 1 or abs(image.get_height() - size.y) > 1:

				var scaled_image = base_image.duplicate()

				scaled_image.resize(int(size.x), int(size.y), Image.INTERPOLATE_LANCZOS)

				image.copy_from(scaled_image)

		Type.DRAWING, Type.MASK:
			texture_rect.size = size
			if abs(image.get_width() - size.x) > 1 or abs(image.get_height() - size.y) > 1:

				image.resize(int(size.x), int(size.y), Image.INTERPOLATE_LANCZOS)

		Type.SPEECH_BUBBLE:
			speech_bubble.size = size

		Type.CONTROL:
			texture_rect.size = size

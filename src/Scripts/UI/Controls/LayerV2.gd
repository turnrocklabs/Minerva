class_name LayerV2
extends Control

enum Type {
	IMAGE,
	DRAWING,
	SPEECH_BUBBLE,
	MASK,
	CONTROL,
	TEXT,
	DIAGRAM_SHAPE,
	DIAGRAM_CONNECTOR,
}

enum DiagramShapeType {
	RECTANGLE,
	ELLIPSE,
	DIAMOND,
}

enum AnchorPoint {
	TOP,
	RIGHT,
	BOTTOM,
	LEFT,
}

enum ArrowHeadType {
	NONE,
	SINGLE,
	DOUBLE,
}

enum ConnectorRouting {
	STRAIGHT,
	ORTHOGONAL,
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

## UUID of the Note this layer has been pushed to, for update-in-place re-pushes.
## Session-scoped (not serialized into the project): empty until the layer is
## first sent to a note. Cleared implicitly when the linked note no longer exists.
var linked_note_uuid: String = ""

# Control layer properties
var control_type: ControlType = ControlType.POSE
var control_strength: float = 1.0

# Text layer properties
var text_content: String = ""
var text_font: Font = null
var text_font_size: int = 48
var text_fill_color: Color = Color.BLACK
var text_stroke_color: Color = Color.BLACK
var text_stroke_width: int = 2
var _text_underline_rect: Rect2 = Rect2()  # Stored for hit detection

# Diagram shape properties
var diagram_shape_type: DiagramShapeType = DiagramShapeType.RECTANGLE
var diagram_stroke_color: Color = Color.BLACK
var diagram_fill_color: Color = Color.TRANSPARENT
var diagram_stroke_width: int = 2
var diagram_text_content: String = ""
var diagram_text_font: Font = null
var diagram_text_font_size: int = 14
var diagram_text_color: Color = Color.BLACK
var diagram_text_bold: bool = false
var diagram_text_italic: bool = false
var diagram_text_underline: bool = false
var diagram_text_strikethrough: bool = false

# Diagram connector properties
var connector_source_layer_id: int = 0
var connector_source_anchor: AnchorPoint = AnchorPoint.RIGHT
var connector_target_layer_id: int = 0
var connector_target_anchor: AnchorPoint = AnchorPoint.LEFT
var connector_line_color: Color = Color(0.53, 0.81, 0.92)  # Light blue
var connector_line_width: int = 2
var connector_arrow_head: ArrowHeadType = ArrowHeadType.SINGLE
var connector_routing: ConnectorRouting = ConnectorRouting.ORTHOGONAL  # Default to orthogonal
var connector_manual_waypoints: PackedVector2Array = []  # User-adjusted waypoints (empty = auto)
var _source_layer_ref: WeakRef = null
var _target_layer_ref: WeakRef = null
# Connector text properties
var connector_text_content: String = ""
var connector_text_font: Font = null
var connector_text_font_size: int = 12
var connector_text_color: Color = Color.BLACK

signal shape_moved(layer: LayerV2)



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
	var handle_space = 14.0  # Space for underline handle
	var text_size = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	layer.size = text_size + Vector2(padding * 2, padding * 2 + handle_space)

	return layer


static func create_diagram_shape(name_: String, shape_type: DiagramShapeType,
								  size_: Vector2, stroke_color: Color = Color.BLACK,
								  fill_color: Color = Color.TRANSPARENT,
								  stroke_width: int = 2) -> LayerV2:
	var layer: LayerV2 = _scene.instantiate()

	layer.name = name_
	layer.type = Type.DIAGRAM_SHAPE
	layer.diagram_shape_type = shape_type
	layer.diagram_stroke_color = stroke_color
	layer.diagram_fill_color = fill_color
	layer.diagram_stroke_width = stroke_width
	layer.size = size_
	layer.custom_minimum_size = size_
	layer.pivot_offset = size_ / 2

	# Set default font for text rendering
	layer.diagram_text_font = ThemeDB.get_fallback_font()

	# Enable transform change notification for connector updates
	layer.set_notify_transform(true)

	return layer


static func create_diagram_connector(name_: String, source_layer: LayerV2,
									  source_anchor: AnchorPoint,
									  target_layer: LayerV2,
									  target_anchor: AnchorPoint,
									  line_color: Color = Color(0.53, 0.81, 0.92),
									  line_width: int = 2,
									  arrow_head: ArrowHeadType = ArrowHeadType.SINGLE) -> LayerV2:
	var layer: LayerV2 = _scene.instantiate()

	layer.name = name_
	layer.type = Type.DIAGRAM_CONNECTOR
	layer.connector_source_layer_id = source_layer.get_instance_id()
	layer.connector_target_layer_id = target_layer.get_instance_id()
	layer.connector_source_anchor = source_anchor
	layer.connector_target_anchor = target_anchor
	layer.connector_line_color = line_color
	layer.connector_line_width = line_width
	layer.connector_arrow_head = arrow_head
	layer._source_layer_ref = weakref(source_layer)
	layer._target_layer_ref = weakref(target_layer)
	layer.connector_text_font = ThemeDB.get_fallback_font()

	# Subscribe to shape movements so connector updates when shapes move
	source_layer.shape_moved.connect(layer._on_connected_shape_moved)
	target_layer.shape_moved.connect(layer._on_connected_shape_moved)

	# Note: _update_connector_bounds() should be called after the layer is added to the tree

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
		Type.DIAGRAM_SHAPE:
			_draw_diagram_shape()
		Type.DIAGRAM_CONNECTOR:
			_draw_diagram_connector()


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

	# Always draw underline handle for TEXT layers (used for dragging)
	_draw_text_underline_handle()

	# Draw transform handles if visible
	if transform_rect_visible:
		_draw_transform_handles()


## Draw an underline handle beneath text (used for dragging)
func _draw_text_underline_handle() -> void:
	var padding = text_stroke_width + 4
	var handle_height = 4.0
	var handle_margin = 4.0  # Space below text
	var handle_y = size.y - handle_height - handle_margin

	# Draw a line/bar beneath the text - use outline color for consistency with bounding boxes
	var handle_rect = Rect2(padding, handle_y, size.x - padding * 2, handle_height)
	draw_rect(handle_rect, outline_color, true)  # Filled bar

	# Store the handle rect for hit detection (in local coordinates)
	# Expand the hit area slightly for easier clicking
	_text_underline_rect = handle_rect.grow(4)


## Check if a local position is on the text underline handle
func is_point_on_text_handle(local_pos: Vector2) -> bool:
	if type != Type.TEXT:
		return false

	# Calculate the handle rect on-demand (don't rely on cached value from _draw)
	var padding = text_stroke_width + 4
	var handle_height = 4.0
	var handle_margin = 4.0
	var handle_y = size.y - handle_height - handle_margin
	var handle_rect = Rect2(padding, handle_y, size.x - padding * 2, handle_height)
	var hit_rect = handle_rect.grow(4)  # Expand for easier clicking

	return hit_rect.has_point(local_pos)


## Calculate and set the size based on text content
func update_text_size() -> void:
	if type != Type.TEXT or text_font == null:
		return

	var padding = text_stroke_width + 4
	var handle_space = 14.0  # Space for underline handle (6px handle + 4px margin + 4px buffer)
	var text_size = text_font.get_string_size(text_content, HORIZONTAL_ALIGNMENT_LEFT, -1, text_font_size)
	size = text_size + Vector2(padding * 2, padding * 2 + handle_space)
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


## Draw diagram shape layer
func _draw_diagram_shape() -> void:
	var rect = Rect2(Vector2.ZERO, size)

	match diagram_shape_type:
		DiagramShapeType.RECTANGLE:
			_draw_diagram_rectangle(rect)
		DiagramShapeType.ELLIPSE:
			_draw_diagram_ellipse(rect)
		DiagramShapeType.DIAMOND:
			_draw_diagram_diamond(rect)

	# Draw centered text if present
	if not diagram_text_content.is_empty() and diagram_text_font:
		_draw_diagram_centered_text(rect)

	# Always draw anchor points on diagram shapes for connector tool
	_draw_anchor_points()

	# Draw transform handles when selected
	if transform_rect_visible:
		_draw_transform_handles()
	elif outline_visible:
		# Draw outline when not in transform mode
		draw_rect(rect, outline_color, false)


func _draw_diagram_rectangle(rect: Rect2) -> void:
	# Inset by half stroke width so stroke stays inside bounds
	var inset = diagram_stroke_width / 2.0
	var draw_rect_ = rect.grow(-inset)

	if diagram_fill_color.a > 0:
		draw_rect(draw_rect_, diagram_fill_color, true)
	if diagram_stroke_width > 0 and diagram_stroke_color.a > 0:
		draw_rect(draw_rect_, diagram_stroke_color, false, diagram_stroke_width)


func _draw_diagram_ellipse(rect: Rect2) -> void:
	var center = rect.size / 2
	var radius = rect.size / 2 - Vector2(diagram_stroke_width / 2.0, diagram_stroke_width / 2.0)

	# Draw ellipse using polygon approximation
	var points = PackedVector2Array()
	var segments = 64  # More segments = smoother ellipse

	for i in range(segments + 1):
		var angle = i * TAU / segments
		var point = center + Vector2(cos(angle) * radius.x, sin(angle) * radius.y)
		points.append(point)

	if diagram_fill_color.a > 0:
		draw_colored_polygon(points, diagram_fill_color)
	if diagram_stroke_width > 0 and diagram_stroke_color.a > 0:
		draw_polyline(points, diagram_stroke_color, diagram_stroke_width)


func _draw_diagram_diamond(rect: Rect2) -> void:
	var inset = diagram_stroke_width / 2.0
	var points = PackedVector2Array([
		Vector2(rect.size.x / 2, inset),                    # Top
		Vector2(rect.size.x - inset, rect.size.y / 2),      # Right
		Vector2(rect.size.x / 2, rect.size.y - inset),      # Bottom
		Vector2(inset, rect.size.y / 2),                    # Left
	])

	if diagram_fill_color.a > 0:
		draw_colored_polygon(points, diagram_fill_color)
	if diagram_stroke_width > 0 and diagram_stroke_color.a > 0:
		# Close the polyline by adding the first point again
		var closed_points = points.duplicate()
		closed_points.append(points[0])
		draw_polyline(closed_points, diagram_stroke_color, diagram_stroke_width)


func _draw_diagram_centered_text(rect: Rect2) -> void:
	if not diagram_text_font:
		return

	# Create a font variation for bold/italic if needed
	var draw_font: Font = diagram_text_font
	if diagram_text_bold or diagram_text_italic:
		var font_var = FontVariation.new()
		font_var.base_font = diagram_text_font
		if diagram_text_bold:
			font_var.variation_embolden = 0.5
		if diagram_text_italic:
			font_var.variation_transform = Transform2D(Vector2(1, 0.2), Vector2(0, 1), Vector2.ZERO)
		draw_font = font_var

	var text_size = draw_font.get_string_size(diagram_text_content, HORIZONTAL_ALIGNMENT_CENTER, -1, diagram_text_font_size)
	var text_pos = Vector2(
		(rect.size.x - text_size.x) / 2,
		(rect.size.y + draw_font.get_ascent(diagram_text_font_size)) / 2
	)

	draw_string(draw_font, text_pos, diagram_text_content, HORIZONTAL_ALIGNMENT_LEFT,
				-1, diagram_text_font_size, diagram_text_color)

	# Draw underline
	if diagram_text_underline:
		var underline_y = text_pos.y + draw_font.get_descent(diagram_text_font_size) * 0.5
		draw_line(Vector2(text_pos.x, underline_y), Vector2(text_pos.x + text_size.x, underline_y),
				  diagram_text_color, 1.0)

	# Draw strikethrough
	if diagram_text_strikethrough:
		var strike_y = text_pos.y - draw_font.get_ascent(diagram_text_font_size) * 0.3
		draw_line(Vector2(text_pos.x, strike_y), Vector2(text_pos.x + text_size.x, strike_y),
				  diagram_text_color, 1.0)


## Get the local position of an anchor point
func get_anchor_position(anchor: AnchorPoint) -> Vector2:
	match anchor:
		AnchorPoint.TOP:
			return Vector2(size.x / 2, 0)
		AnchorPoint.RIGHT:
			return Vector2(size.x, size.y / 2)
		AnchorPoint.BOTTOM:
			return Vector2(size.x / 2, size.y)
		AnchorPoint.LEFT:
			return Vector2(0, size.y / 2)
	return size / 2


## Get the global position of an anchor point
func get_anchor_global_position(anchor: AnchorPoint) -> Vector2:
	return get_global_transform() * get_anchor_position(anchor)


## Get the outward-facing direction of an anchor point
static func get_anchor_direction(anchor: AnchorPoint) -> Vector2:
	match anchor:
		AnchorPoint.TOP:
			return Vector2(0, -1)
		AnchorPoint.RIGHT:
			return Vector2(1, 0)
		AnchorPoint.BOTTOM:
			return Vector2(0, 1)
		AnchorPoint.LEFT:
			return Vector2(-1, 0)
	return Vector2.ZERO


## Calculate orthogonal path waypoints between source and target anchors
func _calculate_orthogonal_path(source_pos: Vector2, source_anchor: AnchorPoint,
								target_pos: Vector2, target_anchor: AnchorPoint) -> PackedVector2Array:
	var path: PackedVector2Array = []

	# Round positions to avoid floating point precision issues
	var src = Vector2(round(source_pos.x), round(source_pos.y))
	var tgt = Vector2(round(target_pos.x), round(target_pos.y))

	path.append(src)

	var source_dir = get_anchor_direction(source_anchor)
	var target_dir = get_anchor_direction(target_anchor)

	# Minimum offset from anchor before turning
	var offset = 20.0

	# Extend from source in its facing direction
	var source_ext = Vector2(round(src.x + source_dir.x * offset), round(src.y + source_dir.y * offset))
	# Extend from target in its facing direction (we approach from opposite)
	var target_ext = Vector2(round(tgt.x + target_dir.x * offset), round(tgt.y + target_dir.y * offset))

	# Determine routing based on anchor directions
	var source_horizontal = source_anchor in [AnchorPoint.LEFT, AnchorPoint.RIGHT]
	var target_horizontal = target_anchor in [AnchorPoint.LEFT, AnchorPoint.RIGHT]

	if source_horizontal and target_horizontal:
		# Both horizontal: route via vertical middle segment
		var mid_x = round((source_ext.x + target_ext.x) / 2)
		path.append(Vector2(source_ext.x, src.y))
		path.append(Vector2(mid_x, src.y))
		path.append(Vector2(mid_x, tgt.y))
		path.append(Vector2(target_ext.x, tgt.y))
	elif not source_horizontal and not target_horizontal:
		# Both vertical: route via horizontal middle segment
		var mid_y = round((source_ext.y + target_ext.y) / 2)
		path.append(Vector2(src.x, source_ext.y))
		path.append(Vector2(src.x, mid_y))
		path.append(Vector2(tgt.x, mid_y))
		path.append(Vector2(tgt.x, target_ext.y))
	elif source_horizontal:
		# Source horizontal, target vertical: L-shape or Z-shape
		# Go horizontal from source, then vertical to target
		path.append(source_ext)
		if _needs_extra_segment(source_ext, target_ext, source_dir, target_dir):
			# Z-shape: need intermediate point
			path.append(Vector2(source_ext.x, target_ext.y))
		else:
			# L-shape: direct corner
			path.append(Vector2(source_ext.x, tgt.y))
		path.append(target_ext)
	else:
		# Source vertical, target horizontal: L-shape or Z-shape
		# Go vertical from source, then horizontal to target
		path.append(source_ext)
		if _needs_extra_segment(source_ext, target_ext, source_dir, target_dir):
			# Z-shape: need intermediate point
			path.append(Vector2(target_ext.x, source_ext.y))
		else:
			# L-shape: direct corner
			path.append(Vector2(tgt.x, source_ext.y))
		path.append(target_ext)

	path.append(tgt)

	# Simplify path by removing collinear and duplicate points
	return _simplify_path(path)


## Check if we need an extra segment to avoid backtracking
func _needs_extra_segment(source_ext: Vector2, target_ext: Vector2,
						   source_dir: Vector2, target_dir: Vector2) -> bool:
	# Check if direct L-shape would require backtracking
	var delta = target_ext - source_ext
	var source_progress = delta.dot(source_dir)
	var target_progress = -delta.dot(target_dir)
	return source_progress < 0 or target_progress < 0


## Remove collinear and duplicate points from path
func _simplify_path(path: PackedVector2Array) -> PackedVector2Array:
	if path.size() <= 2:
		return path

	var simplified: PackedVector2Array = []
	simplified.append(path[0])

	for i in range(1, path.size() - 1):
		var prev = simplified[simplified.size() - 1]  # Use last simplified point
		var curr = path[i]
		var next = path[i + 1]

		# Skip if current point is too close to previous (duplicate/near-duplicate)
		if curr.distance_to(prev) < 1.0:
			continue

		# Skip if current point is too close to next
		if curr.distance_to(next) < 1.0:
			continue

		# Calculate directions (avoid NaN from zero-length vectors)
		var vec1 = curr - prev
		var vec2 = next - curr

		if vec1.length() < 0.001 or vec2.length() < 0.001:
			continue  # Skip degenerate segments

		var dir1 = vec1.normalized()
		var dir2 = vec2.normalized()

		# If directions differ significantly, keep the point (it's a corner)
		if dir1.distance_to(dir2) > 0.01:
			simplified.append(curr)

	# Add last point if it's not a duplicate
	var last_point = path[path.size() - 1]
	if simplified.size() == 0 or last_point.distance_to(simplified[simplified.size() - 1]) >= 1.0:
		simplified.append(last_point)

	return simplified


## Draw anchor points (for connector attachment)
func _draw_anchor_points() -> void:
	var anchor_radius = 6.0
	var anchors = [AnchorPoint.TOP, AnchorPoint.RIGHT, AnchorPoint.BOTTOM, AnchorPoint.LEFT]

	for anchor in anchors:
		var pos = get_anchor_position(anchor)
		# Blue filled circle with white outline
		draw_circle(pos, anchor_radius, Color.DODGER_BLUE)
		draw_arc(pos, anchor_radius, 0, TAU, 32, Color.WHITE, 2.0)


## Draw diagram connector layer
func _draw_diagram_connector() -> void:
	var source = _source_layer_ref.get_ref() if _source_layer_ref else null
	var target = _target_layer_ref.get_ref() if _target_layer_ref else null

	if not source or not target:
		return

	# Get anchor positions in layers_container local space
	var source_pos = source.position + source.get_anchor_position(connector_source_anchor)
	var target_pos = target.position + target.get_anchor_position(connector_target_anchor)

	# Convert to this layer's local space (subtract our position)
	var source_local = source_pos - position
	var target_local = target_pos - position

	# Get the path to draw (manual waypoints or auto-calculated)
	var path = get_connector_path()

	# Convert path to local space
	var local_path: PackedVector2Array = []
	for point in path:
		local_path.append(point - position)

	if local_path.size() >= 2:
		# Draw polyline
		draw_polyline(local_path, connector_line_color, connector_line_width)

		# Draw arrow head at target (using last segment direction)
		if connector_arrow_head == ArrowHeadType.SINGLE or connector_arrow_head == ArrowHeadType.DOUBLE:
			var last_idx = local_path.size() - 1
			_draw_arrow_head(local_path[last_idx], local_path[last_idx - 1])
		if connector_arrow_head == ArrowHeadType.DOUBLE:
			_draw_arrow_head(local_path[0], local_path[1])

		# Draw text at path midpoint
		if not connector_text_content.is_empty() and connector_text_font:
			var mid_point = _get_path_midpoint(local_path)
			_draw_connector_text_at(mid_point)

		# Draw waypoint handles when selected
		if transform_rect_visible:
			_draw_waypoint_handles(local_path)
	elif connector_routing == ConnectorRouting.STRAIGHT or local_path.size() < 2:
		# Fallback to straight line
		draw_line(source_local, target_local, connector_line_color, connector_line_width)

		if connector_arrow_head == ArrowHeadType.SINGLE or connector_arrow_head == ArrowHeadType.DOUBLE:
			_draw_arrow_head(target_local, source_local)
		if connector_arrow_head == ArrowHeadType.DOUBLE:
			_draw_arrow_head(source_local, target_local)

		if not connector_text_content.is_empty() and connector_text_font:
			_draw_connector_text(source_local, target_local)


## Get the connector path (always auto-calculated based on anchors)
func get_connector_path() -> PackedVector2Array:
	var source = _source_layer_ref.get_ref() if _source_layer_ref else null
	var target = _target_layer_ref.get_ref() if _target_layer_ref else null

	if not source or not target:
		return PackedVector2Array()

	var source_pos = source.position + source.get_anchor_position(connector_source_anchor)
	var target_pos = target.position + target.get_anchor_position(connector_target_anchor)

	# If manual waypoints exist, use them (source + waypoints + target)
	if connector_manual_waypoints.size() > 0:
		var path: PackedVector2Array = []
		path.append(source_pos)
		for wp in connector_manual_waypoints:
			path.append(wp)
		path.append(target_pos)
		return path

	# Auto-calculate path based on routing mode
	if connector_routing == ConnectorRouting.ORTHOGONAL:
		return _calculate_orthogonal_path(source_pos, connector_source_anchor,
										   target_pos, connector_target_anchor)
	else:
		var path: PackedVector2Array = []
		path.append(source_pos)
		path.append(target_pos)
		return path


## Draw handles for connector: blue endpoints and orange segment midpoints
func _draw_waypoint_handles(local_path: PackedVector2Array) -> void:
	var handle_radius = 6.0
	var handle_outline = Color.WHITE
	var endpoint_color = Color.DODGER_BLUE
	var segment_color = Color.ORANGE

	if local_path.size() < 2:
		return

	# Draw orange handles at segment midpoints (visual feedback for bends)
	for i in range(local_path.size() - 1):
		var start = local_path[i]
		var end = local_path[i + 1]
		var midpoint = (start + end) / 2
		draw_circle(midpoint, handle_radius + 1, handle_outline)
		draw_circle(midpoint, handle_radius, segment_color)

	# Draw blue endpoint handles (source and target) for reconnection
	draw_circle(local_path[0], handle_radius + 1, handle_outline)
	draw_circle(local_path[0], handle_radius, endpoint_color)
	draw_circle(local_path[local_path.size() - 1], handle_radius + 1, handle_outline)
	draw_circle(local_path[local_path.size() - 1], handle_radius, endpoint_color)


## Get the midpoint along a path (by total length)
func _get_path_midpoint(path: PackedVector2Array) -> Vector2:
	if path.size() < 2:
		return path[0] if path.size() > 0 else Vector2.ZERO

	# Calculate total path length
	var total_length = 0.0
	for i in range(1, path.size()):
		total_length += path[i].distance_to(path[i - 1])

	# Find point at half the total length
	var target_length = total_length / 2
	var current_length = 0.0

	for i in range(1, path.size()):
		var segment_length = path[i].distance_to(path[i - 1])
		if current_length + segment_length >= target_length:
			# Midpoint is on this segment
			var t = (target_length - current_length) / segment_length
			return path[i - 1].lerp(path[i], t)
		current_length += segment_length

	return path[path.size() - 1]


## Draw connector text at a specific position
func _draw_connector_text_at(midpoint: Vector2) -> void:
	var text_size = connector_text_font.get_string_size(
		connector_text_content, HORIZONTAL_ALIGNMENT_CENTER, -1, connector_text_font_size
	)

	# Draw background for readability
	var padding = Vector2(4, 2)
	var bg_rect = Rect2(
		midpoint - text_size / 2 - padding,
		text_size + padding * 2
	)
	draw_rect(bg_rect, Color(1, 1, 1, 0.85))

	# Position text centered at midpoint
	var text_pos = Vector2(
		midpoint.x - text_size.x / 2,
		midpoint.y + connector_text_font.get_ascent(connector_text_font_size) / 2
	)

	draw_string(connector_text_font, text_pos, connector_text_content,
				HORIZONTAL_ALIGNMENT_LEFT, -1, connector_text_font_size, connector_text_color)


func _draw_arrow_head(tip: Vector2, from: Vector2) -> void:
	var direction = (tip - from).normalized()
	if direction.length_squared() < 0.001:
		return

	var arrow_size = 12.0
	var arrow_angle = 0.5  # radians (~28 degrees)

	var left = tip - direction.rotated(arrow_angle) * arrow_size
	var right = tip - direction.rotated(-arrow_angle) * arrow_size

	draw_colored_polygon(PackedVector2Array([tip, left, right]), connector_line_color)


func _draw_connector_text(source_local: Vector2, target_local: Vector2) -> void:
	# Calculate midpoint
	var midpoint = (source_local + target_local) / 2

	# Get text size
	var text_size = connector_text_font.get_string_size(
		connector_text_content, HORIZONTAL_ALIGNMENT_CENTER, -1, connector_text_font_size
	)

	# Draw background for readability
	var padding = Vector2(4, 2)
	var bg_rect = Rect2(
		midpoint - text_size / 2 - padding,
		text_size + padding * 2
	)
	draw_rect(bg_rect, Color(1, 1, 1, 0.85))

	# Position text centered at midpoint
	var text_pos = Vector2(
		midpoint.x - text_size.x / 2,
		midpoint.y + connector_text_font.get_ascent(connector_text_font_size) / 2
	)

	draw_string(connector_text_font, text_pos, connector_text_content,
				HORIZONTAL_ALIGNMENT_LEFT, -1, connector_text_font_size, connector_text_color)


## Called when a connected shape moves - update connector
func _on_connected_shape_moved(_layer: LayerV2) -> void:
	_update_connector_bounds()
	queue_redraw()


## Update connector layer bounds to cover the line between shapes
func _update_connector_bounds() -> void:
	var path = get_connector_path()

	if path.size() == 0:
		return

	var min_pos: Vector2 = path[0]
	var max_pos: Vector2 = path[0]
	var padding = 20.0

	# Calculate bounds from full path (works for manual waypoints, orthogonal, or straight)
	for point in path:
		min_pos.x = min(min_pos.x, point.x)
		min_pos.y = min(min_pos.y, point.y)
		max_pos.x = max(max_pos.x, point.x)
		max_pos.y = max(max_pos.y, point.y)

	# Apply padding for arrow heads and handles
	min_pos -= Vector2(padding, padding)
	max_pos += Vector2(padding, padding)

	# Set position and size to cover the connector
	position = min_pos
	size = max_pos - min_pos
	custom_minimum_size = size
	pivot_offset = size / 2

	# Force redraw with new bounds
	queue_redraw()


## Handle transform notifications (for shape_moved signal)
func _notification(what: int) -> void:
	if what == NOTIFICATION_TRANSFORM_CHANGED and type == Type.DIAGRAM_SHAPE:
		shape_moved.emit(self)


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
		Type.IMAGE, Type.DRAWING, Type.MASK, Type.CONTROL, Type.TEXT, Type.DIAGRAM_SHAPE, Type.DIAGRAM_CONNECTOR:
			# Map the pointer into this layer's local space from the EVENT, not from
			# get_global_mouse_position() (the OS cursor, which a pen never moves — that
			# was why pens drew nowhere while mouse/touch worked).
			#
			# gui_input fires on LayersContainer and this layer is a direct child, so
			# event.position is already in LayersContainer-local space (Godot's GUI
			# routing has resolved the SubViewport + InputAreaCamera transform for us).
			# The layer's own parent-relative transform is therefore the only step left.
			# Do NOT re-apply the camera's canvas_transform here: that double-counts the
			# camera and offsets the stroke. Confirmed empirically in DrawingApp4, which
			# reproduces this exact SubViewport/camera/gui_input paradigm.
			local_event.position = get_transform().affine_inverse() * event.position
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

class_name LayerV2
extends Control

enum Type {
    IMAGE,
    DRAWING,
    SPEECH_BUBBLE,
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

var image_zoom_factor: float:
    get: return (Vector2(image.get_size()).length() / size.length()) if image else .0


var type: Type

var image: Image:
    set(value):
        image = value
        if not image or image.is_empty(): return
        
        if not is_node_ready():
            await ready
        
        var img = ImageTexture.create_from_image(image)
        texture_rect.texture = img
        size = img.get_size()
        print("SIZE SET TO: ", size)

var speech_bubble: CloudControl:
    set(value):
        speech_bubble = value

        if not is_node_ready():
            await ready

        center_container.add_child(speech_bubble)

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

    print("Img: ", img.get_size())

    return layer

static func create_speech_bubble_layer(name_: String, type_: CloudControl.Type = CloudControl.Type.ELLIPSE) -> LayerV2:
    var layer: LayerV2 = _scene.instantiate()
    
    layer.speech_bubble = CloudControl.create(type_)

    layer.name = name_
    layer.type = Type.SPEECH_BUBBLE

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
        Type.IMAGE, Type.DRAWING:
            var img = ImageTexture.create_from_image(image)
            texture_rect.texture = img
        Type.SPEECH_BUBBLE:
            speech_bubble.queue_redraw()

    if not transform_rect_visible: return
    
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
    var rotation_handle_pos = Vector2(size.x/2, -30)
    
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
    
    # Draw rotation handle
    var rotation_square: = Rect2(rotation_handle_pos - _transform_rect_size/2, _transform_rect_size)
    draw_rect(rotation_square.grow(2), Color.BLACK)
    draw_rect(rotation_square, Color.YELLOW)  # Different color to distinguish it
    
    # Draw line from top center to rotation handle
    draw_line(Vector2(size.x/2, 0), rotation_handle_pos, Color.BLACK)

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
    match type:
        Type.IMAGE, Type.DRAWING:
            return texture_rect.make_input_local(event)
        Type.SPEECH_BUBBLE:
            return speech_bubble.make_input_local(event)

func _on_resized() -> void:
    _adjust_control_size()
    
func _on_minimum_size_changed() -> void:
    _adjust_control_size()

func _adjust_control_size() -> void:
    if not is_node_ready(): return

    # Set pivot to center for proper rotation
    pivot_offset = size / 2

    prints("pivot offset", pivot_offset, size)

    match type:
        Type.IMAGE, Type.DRAWING:
            texture_rect.size = size
            # Only resize the image if the size has changed significantly
            if abs(image.get_width() - size.x) > 1 or abs(image.get_height() - size.y) > 1:
                image.resize(int(size.x), int(size.y), Image.INTERPOLATE_LANCZOS)
        Type.SPEECH_BUBBLE:
            speech_bubble.size = size
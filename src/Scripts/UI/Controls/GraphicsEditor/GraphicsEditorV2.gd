class_name GraphicsEditorV2
extends PanelContainer

signal active_tool_changed(tool_: BaseTool)

@onready var layers_container: Control = %LayersContainer
@onready var layer_cards_container: Control = %LayerCardsContainer
@onready var tool_options_container: Control = %ToolOptionsContainer


# tool options containers
@onready var _brush_options_container: Control = %BrushOptions
@onready var _eraser_options_container: Control = %EraserOptions

@onready var drawing_tool: DrawingTool = %DrawingTool
@onready var pane_tool: PaneTool = %PaneTool
@onready var eraser_tool: EraserTool = %EraserTool


@onready var tool_options_mapping: = {
	drawing_tool: _brush_options_container,
	eraser_tool: _eraser_options_container,
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
		
		active_layer.get_meta("layer_card").selected = true


var active_tool: BaseTool:
	set(value):
		active_tool = value
		# reset the cursor here,
		# so it happends before the signal is consumed by selected tool which may change it
		set_custom_cursor(null)
		active_tool_changed.emit(value)


func _ready() -> void:
	
	active_tool_changed.connect(_on_active_tool_changed)
	
	setup()


func setup(canvas_size_: Vector2i = Vector2i(1000, 1000)) -> void:

	var img = Image.create(canvas_size_.x, canvas_size_.y, true, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)

	active_layer = create_new_layer("Layer", canvas_size_)


func create_new_layer(layer_name: String, dimensions: Vector2i) -> LayerV2:
	var img = Image.create(dimensions.x, dimensions.y, true, Image.FORMAT_RGBA8)
	img.fill(Color.TRANSPARENT)

	var layer: = LayerV2.create_image_layer(layer_name, img)
	var layer_card: = LayerCard.create(layer)
	
	# don't change the active_layer untill layer_card updates the layer metadata
	active_layer = layer

	layer_card.layer_clicked.connect(func(): active_layer = layer)

	layer_cards_container.add_child(layer_card)

	layers_container.add_child(layer, true)

	return layer

func set_custom_cursor(image: Resource = null, shape: int = 0, hotspot: Vector2 = Vector2.ZERO):
	_custom_cursor = image
	_custom_cursor_shape = shape
	_custom_cursor_hotspot = hotspot

	if layers_container.get_rect().has_point(layers_container.get_local_mouse_position()):
		Input.set_custom_mouse_cursor(image, shape, hotspot)
	

func _gui_input(event: InputEvent) -> void:

	if active_layer.is_visible_in_tree() and active_tool:
		active_tool.handle_input_event(event)


func _draw() -> void:
	active_layer.queue_redraw()
	for c: LayerCard in layer_cards_container.get_children():
		c.queue_redraw()
	
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


func _on_layers_container_mouse_entered() -> void:
	Input.set_custom_mouse_cursor(_custom_cursor, _custom_cursor_shape, _custom_cursor_hotspot)


func _on_layers_container_mouse_exited() -> void:
	Input.set_custom_mouse_cursor(null)

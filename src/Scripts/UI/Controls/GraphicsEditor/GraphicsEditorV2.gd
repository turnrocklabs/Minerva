class_name GraphicsEditorV2
extends PanelContainer

signal active_tool_changed(tool_: BaseTool)

@onready var layers_container: Control = %LayersContainer
@onready var layer_cards_container: Control = %LayerCardsContainer
@onready var tool_options_container: Control = %ToolOptionsContainer


# tool options containers
@onready var _brush_options_container: Control = %BrushOptions

@onready var drawing_tool: DrawingTool = %DrawingTool
@onready var pane_tool: PaneTool = %PaneTool


@onready var tool_options_mapping: = {
	drawing_tool: _brush_options_container
}


var layers: Array[LayerV2] = []

var active_layer: LayerV2
var active_tool: BaseTool:
	set(value):
		active_tool = value
		active_tool_changed.emit(value)


func _ready() -> void:
	
	active_tool_changed.connect(_on_active_tool_changed)
	
	setup()


func setup(canvas_size: Vector2i = Vector2i(1000, 1000)) -> void:

	var img = Image.create(canvas_size.x, canvas_size.y, true, Image.FORMAT_RGBA8)
	img.fill(Color.WHITE)

	active_layer = LayerV2.create_image_layer("Layer", img)

	var layer_card: = LayerCard.create(active_layer)
	
	layer_cards_container.add_child(layer_card)

	layers_container.add_child(active_layer)

func create_new_layer(layer_name: String) -> LayerV2:
	var img = Image.create(1000, 1000, true, Image.FORMAT_RGBA8)
	img.fill(Color.TRANSPARENT)

	var layer: = LayerV2.create_image_layer(layer_name, img)
	active_layer = layer
	var layer_card: = LayerCard.create(layer)

	layer_cards_container.add_child(layer_card)

	layers_container.add_child(layer, true)

	return layer

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
	active_layer = create_new_layer("Layer")


func _on_brush_tool_button_toggled(toggled_on: bool) -> void:
	active_tool = drawing_tool if toggled_on else null

func _onpane_tool_button_toggled(toggled_on:bool) -> void:
	active_tool = pane_tool if toggled_on else null

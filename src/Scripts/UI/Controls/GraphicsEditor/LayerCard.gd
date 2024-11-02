class_name LayerCard
extends PanelContainer

signal layer_clicked()

const _scene: = preload("res://Scenes/LayerCard.tscn")

var _active_color: Color = Color.from_string("2d3648", Color.BLACK)
var _color: Color = Color.from_string("2f2c2c", Color.BLACK)


var selected: = false:
	set(value):
		selected = value
		
		var styleBox: StyleBoxFlat = get_theme_stylebox("panel").duplicate()
		styleBox.set("bg_color", _active_color if selected else _color)
		add_theme_stylebox_override("panel", styleBox)

var layer: LayerV2:
	set(value):
		layer = value
		queue_redraw()


@onready var label: Label = %Label
@onready var texture_rect: TextureRect = %TextureRect


static func create(layer_: LayerV2) -> LayerCard:
	var lc: LayerCard = _scene.instantiate()

	lc.layer = layer_
	lc.layer.set_meta("layer_card", lc)

	return lc


func _draw() -> void:
	if not layer: return

	if not is_node_ready():
		await ready

	label.text = layer.name
	texture_rect.texture = ImageTexture.create_from_image(layer.image)


func _create_drag_preview(pos: Vector2) -> LayerCard:
	
	# create layer copy so it doesnt overwrite the layer metadata
	var layer_copy: = layer.duplicate()

	var preview: = Control.new()

	var lc_copy: = create(layer_copy)

	preview.add_child(lc_copy)

	lc_copy.position = -pos

	return preview


func _get_drag_data(at_position: Vector2) -> Variant:	

	var preview: = _create_drag_preview(at_position)

	set_drag_preview(preview)

	return self


func _on_visibility_check_button_toggled(toggled_on: bool) -> void:
	layer.visible = toggled_on


func _on_layer_card_pressed() -> void:
	layer_clicked.emit()

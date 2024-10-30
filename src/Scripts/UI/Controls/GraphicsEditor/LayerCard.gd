class_name LayerCard
extends PanelContainer

const _scene: = preload("res://Scenes/LayerCard.tscn")

var layer: LayerV2:
	set(value):
		layer = value
		queue_redraw()


@onready var label: Label = %Label
@onready var texture_rect: TextureRect = %TextureRect


static func create(layer_: LayerV2) -> LayerCard:
	var lc: LayerCard = _scene.instantiate()

	lc.layer = layer_

	return lc


func _draw() -> void:
	if not layer: return

	if not is_node_ready():
		await ready

	label.text = layer.name
	texture_rect.texture = ImageTexture.create_from_image(layer.image)


func _on_visibility_check_button_toggled(toggled_on: bool) -> void:
	layer.visible = toggled_on

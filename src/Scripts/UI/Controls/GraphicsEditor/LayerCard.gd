class_name LayerCard
extends PanelContainer

signal layer_clicked()
signal reorder(to: int)

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
@onready var drop_above_separator: Control = %DropAboveSeparator
@onready var drop_below_separator: Control = %DropBelowSeparator


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
	match layer.type:
		LayerV2.Type.IMAGE, LayerV2.Type.DRAWING:
			texture_rect.texture = ImageTexture.create_from_image(layer.image)
		LayerV2.Type.SPEECH_BUBBLE:
			texture_rect.texture = await get_texture(layer.speech_bubble)

static func get_texture(control: Control) -> ImageTexture:
	var viewport = SubViewport.new()
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	viewport.size = control.size
	
	Engine.get_main_loop().root.add_child(viewport)
	viewport.add_child(control.duplicate())
	
	await Engine.get_main_loop().process_frame
	await Engine.get_main_loop().process_frame
	
	var image = viewport.get_texture().get_image()
	# image.save_jpg("test.jpg")
	var texture = ImageTexture.create_from_image(image)
	
	viewport.queue_free()
	
	return texture


func _create_drag_preview(pos: Vector2) -> LayerCard:
	
	# create layer copy so it doesnt overwrite the layer metadata
	var layer_copy: = layer.duplicate()
	layer_copy.image = layer.image.duplicate()

	var preview: = Control.new()
	preview.modulate.a = 0.25
	modulate.a = 0.75

	var lc_copy: = create(layer_copy)

	preview.add_child(lc_copy)

	lc_copy.position = -pos

	preview.tree_exited.connect(
		func(): modulate.a = 1
	)

	return preview


func _get_drag_data(at_position: Vector2) -> Variant:	

	var preview: = _create_drag_preview(at_position)

	set_drag_preview(preview)

	return self

func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	if not data is LayerCard:
		return false
	
	# cant drop it on self
	if data == self: return false

	if (
		at_position.x < 0 and at_position.y < 0 and
		at_position.x > size.x and at_position.y > size.y
	):
		drop_above_separator.modulate.a = 0
		drop_below_separator.modulate.a = 0
		return false

	if at_position.y > size.y / 2:
		drop_below_separator.modulate.a = 1
		drop_above_separator.modulate.a = 0
	else:
		drop_below_separator.modulate.a = 0
		drop_above_separator.modulate.a = 1

	return true


func _drop_data(at_position: Vector2, data: Variant) -> void:
	if not data is LayerCard: return

	if at_position.y < size.y / 2:
		data.reorder.emit(get_index())
	else:
		data.reorder.emit(get_index()+1)

func _on_visibility_check_button_toggled(toggled_on: bool) -> void:
	layer.visible = toggled_on


func _on_layer_card_pressed() -> void:
	layer_clicked.emit()


func _on_mouse_exited() -> void:
	drop_below_separator.modulate.a = 0
	drop_above_separator.modulate.a = 0

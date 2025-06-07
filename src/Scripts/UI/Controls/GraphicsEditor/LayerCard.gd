class_name LayerCard
extends PanelContainer

signal layer_clicked(button_index: int)
signal layer_selected()
signal layer_deselected()
signal reorder(to: int)

enum ContextMenuItem {
	VISIBILITY = 0,
	REMOVE = 1,
	MERGE = 2,
}

const _scene: = preload("res://Scenes/LayerCard.tscn")

var _active_color: Color = Color.from_string("2d3648", Color.BLACK)
var _color: Color = Color.from_string("2f2c2c", Color.BLACK)


var selected: = false:
	set(value):
		selected = value
		
		var styleBox: StyleBoxFlat = get_theme_stylebox("panel").duplicate()
		styleBox.set("bg_color", _active_color if selected else _color)
		add_theme_stylebox_override("panel", styleBox)

		if selected:
			layer_selected.emit()
		else:
			layer.transform_rect_visible = false
			layer_deselected.emit()
			layer.queue_redraw()
		
var editor: GraphicsEditorV2

var layer: LayerV2:
	set(value):
		layer = value

		if layer:
			layer.visibility_changed.connect(_on_layer_visibility_changed)

		queue_redraw()


@onready var name_line_edit: LineEdit = %Name
@onready var texture_rect: TextureRect = %TextureRect
@onready var visibility_check_button: CheckButton = %VisibilityCheckButton

@onready var drop_above_separator: Control = %DropAboveSeparator
@onready var drop_below_separator: Control = %DropBelowSeparator
@onready var context_menu: PopupMenu = %ContextMenu

static func create(editor_: GraphicsEditorV2, layer_: LayerV2) -> LayerCard:
	var lc: LayerCard = _scene.instantiate()

	lc.layer = layer_
	lc.editor = editor_
	lc.layer.set_meta("layer_card", lc)

	return lc


func _ready():
	_setup_context_menu()


func _draw() -> void:
	if not layer: return

	if not is_node_ready():
		await ready

	name_line_edit.text = layer.name
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

	var lc_copy: = create(editor, layer_copy)

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


func _on_mouse_exited() -> void:
	drop_below_separator.modulate.a = 0
	drop_above_separator.modulate.a = 0


func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:

		if event.is_released():
			layer_clicked.emit(event.button_index)

			if event.button_index == MOUSE_BUTTON_RIGHT:
				context_menu.position = DisplayServer.mouse_get_position()
				context_menu.popup()


func _on_layer_visibility_changed():
	if layer.visible:
		context_menu.set_item_text(ContextMenuItem.VISIBILITY, "Hide")
	else:
		context_menu.set_item_text(ContextMenuItem.VISIBILITY, "Show")

	visibility_check_button.set_pressed_no_signal(layer.visible)

func _setup_context_menu():
	context_menu.add_item("Hide", ContextMenuItem.VISIBILITY)
	context_menu.add_item("Remove", ContextMenuItem.REMOVE)
	context_menu.add_item("Merge", ContextMenuItem.MERGE)


func _on_context_menu_id_pressed(id: int) -> void:
	match id:
		ContextMenuItem.VISIBILITY:
			layer.visible = not layer.visible
		ContextMenuItem.REMOVE:
			layer.queue_free()
			queue_free()
		ContextMenuItem.MERGE:
			editor.merge_layers(editor.selected_layers)


func _on_context_menu_about_to_popup() -> void:
	context_menu.set_item_disabled(ContextMenuItem.MERGE, editor.selected_layers.size() < 2)


func _on_name_text_submitted(_new_text: String) -> void:
	name_line_edit.release_focus()


func _on_name_focus_exited() -> void:
	if not is_instance_valid(layer): return
	
	layer.name = name_line_edit.text

	# godot will change the name is already taken and append a number to it, so update the line edit
	name_line_edit.text = layer.name

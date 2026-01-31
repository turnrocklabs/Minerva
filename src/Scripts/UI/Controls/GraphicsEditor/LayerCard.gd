class_name LayerCard
extends PanelContainer

signal layer_clicked(button_index: int)
signal layer_selected()
signal layer_deselected()
@warning_ignore("unused_signal")
signal reorder(to: int)

enum ContextMenuItem {
	VISIBILITY = 0,
	REMOVE = 1,
	MERGE = 2,
	SAVE_PNG = 3,
}

const _scene: = preload("res://Scenes/LayerCard.tscn")

@export var  _active_color: Color = Color.from_string("2d3648", Color.BLACK)
@export var _color: Color = Color.from_string("2f2c2c", Color.BLACK)


var selected: = false:
	set(value):
		value = value if layer and not layer.locked else false # don't allow selecting locked layers
		selected = value
		
		var styleBox: StyleBoxFlat = get_theme_stylebox("panel").duplicate()
		styleBox.set("bg_color", _active_color if selected else _color)
		add_theme_stylebox_override("panel", styleBox)

		if selected:
			layer_selected.emit()
			layer.outline_visible = true
		else:
			mouse_filter = Control.MOUSE_FILTER_PASS
			if layer:
				layer.outline_visible = false
				layer.transform_rect_visible = false
				layer_deselected.emit()
				if name_line_edit:
					name_line_edit.release_focus()
		if layer:
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
@onready var layer_card: Button = %LayerCard

@onready var drop_above_separator: Control = %DropAboveSeparator
@onready var drop_below_separator: Control = %DropBelowSeparator
@onready var context_menu: PopupMenu = %ContextMenu
@onready var save_button: Button = %SaveButton

static func create(editor_: GraphicsEditorV2, layer_: LayerV2) -> LayerCard:
	var lc: LayerCard = _scene.instantiate()

	lc.layer = layer_
	lc.editor = editor_
	lc.layer.set_meta("layer_card", lc)

	return lc


func _ready():
	_setup_context_menu()


func _exit_tree() -> void:
	# Release texture to prevent leaks during shutdown
	if texture_rect and texture_rect.texture:
		texture_rect.texture = null


func _draw() -> void:
	if not layer: return

	if not is_node_ready():
		await ready

	name_line_edit.text = layer.name
	_update_preview_texture()


## Update the preview texture from layer image. Reuses existing texture if possible.
func _update_preview_texture() -> void:
	if not layer: return

	match layer.type:
		LayerV2.Type.IMAGE, LayerV2.Type.DRAWING, LayerV2.Type.MASK:
			if layer.image:
				# Reuse existing ImageTexture if we have one, otherwise create new
				if texture_rect.texture is ImageTexture:
					(texture_rect.texture as ImageTexture).set_image(layer.image)
				else:
					texture_rect.texture = ImageTexture.create_from_image(layer.image)
		LayerV2.Type.SPEECH_BUBBLE:
			# Speech bubble needs async texture generation
			_update_speech_bubble_texture()


func _update_speech_bubble_texture() -> void:
	var tex = await get_texture(layer.speech_bubble)
	texture_rect.texture = tex


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
	data = data as LayerCard
	
	if layer.type == LayerV2.Type.IMAGE or layer.type == LayerV2.Type.DRAWING:
		if data.layer.type == LayerV2.Type.MASK:
			self.set_meta("linked_mask_layercard", data)
			layer.set_meta("linked_mask_layer", data.layer)
			layer_card.tooltip_text = "Linked Mask: " + data.layer.name
			return
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
	
		if event.is_pressed():
			layer_clicked.emit(event.button_index)
	
			if event.button_index == MOUSE_BUTTON_RIGHT:
				#context_menu.position = DisplayServer.mouse_get_position()
				#context_menu.popup()
				name_line_edit.grab_focus()
				name_line_edit.select_all()
			elif event.double_click and event.button_index == MOUSE_BUTTON_LEFT:
				name_line_edit.grab_focus()
				name_line_edit.select_all()
			elif event.button_index == MOUSE_BUTTON_LEFT:
				name_line_edit.release_focus()
			
			accept_event()


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
	context_menu.add_item("Save as PNG", ContextMenuItem.SAVE_PNG)


func _on_context_menu_id_pressed(id: int) -> void:
	match id:
		ContextMenuItem.VISIBILITY:
			layer.visible = not layer.visible
		ContextMenuItem.REMOVE:
			delete_layer()
		ContextMenuItem.MERGE:
			editor.merge_layers(editor.selected_layers.duplicate())
		ContextMenuItem.SAVE_PNG:
			_on_save_button_pressed()


func _on_context_menu_about_to_popup() -> void:
	context_menu.set_item_disabled(ContextMenuItem.MERGE, editor.selected_layers.size() < 2)
	context_menu.set_item_disabled(ContextMenuItem.REMOVE, layer.locked)


func _on_name_text_submitted(_new_text: String) -> void:
	name_line_edit.release_focus()


func _on_name_focus_exited() -> void:
	if not is_instance_valid(layer): return
	
	layer.name = name_line_edit.text

	# godot will change the name is already taken and append a number to it, so update the line edit
	name_line_edit.text = layer.name


func delete_layer() -> void:
	if editor != null:
		editor.delete_layer.emit(layer)
	layer_selected.disconnect(editor._on_layer_card_selected)
	layer_deselected.disconnect(editor._on_layer_card_deselected)
	reorder.disconnect(editor._on_layer_card_reorder)
	layer_clicked.disconnect(editor._on_layer_card_clicked)
	queue_free()


func _on_save_button_pressed() -> void:
	if not layer:
		return

	var image_to_save: Image

	match layer.type:
		LayerV2.Type.IMAGE, LayerV2.Type.DRAWING, LayerV2.Type.MASK:
			if not layer.image:
				return
			image_to_save = layer.image.duplicate()
		LayerV2.Type.SPEECH_BUBBLE:
			var texture = await get_texture(layer.speech_bubble)
			image_to_save = texture.get_image()

	if image_to_save == null:
		return

	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.add_filter("*.png", "PNG Image")
	fd.current_file = layer.name + ".png"

	editor.add_child(fd)
	fd.popup_centered(Vector2i(800, 600))

	var path = await fd.file_selected
	fd.queue_free()

	if path.is_empty():
		return

	# Ensure .png extension
	if not path.ends_with(".png"):
		path += ".png"

	# Convert to RGBA8 if needed
	if image_to_save.get_format() != Image.FORMAT_RGBA8:
		image_to_save.convert(Image.FORMAT_RGBA8)

	var error = image_to_save.save_png(path)
	if error != OK:
		push_error("Failed to save layer: " + str(error))

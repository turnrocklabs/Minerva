class_name EditorContainer
extends VBoxContainer

@export var editor_pane: EditorPane
@export var editor_scene: PackedScene

func _ready() -> void:
	editor_pane.enable_editor_action_buttons.connect(_toggle_enable_action_buttons)


func _toggle_enable_action_buttons(enable: bool) -> void:
	if is_inside_tree():
		var editor_action_buttons = get_tree().get_nodes_in_group("editor_action_button")
		if editor_action_buttons:
			for button: Button in editor_action_buttons:
				button.disabled = !enable


func serialize() -> Dictionary:
	var editors_serialized: Array[Dictionary] = []
	
	for editor in editor_pane.open_editors():
		var content
		match editor.type:
			editor.TYPE.Text:
				content = editor.code_edit.text
			editor.TYPE.NOTE_EDITOR:
				content = editor.code_edit.text
			editor.TYPE.Graphics:
				var layers: Array[Dictionary] = []
				for layer in editor.graphics_editor._layers_container.get_children():
					if layer:
						var layer_dic = {
							"layer_img": Marshalls.raw_to_base64(layer.texture.get_image().save_png_to_buffer())
						}
						layers.append(layer_dic)
				content = layers
		
		var editor_string = {
			"name": editor.name,
			"file": editor.file,
			"type": editor.type,
			"content": content
		}
		editors_serialized.append(editor_string)
	
	var dic: Dictionary = {
		"editors_array": editors_serialized
	}
	
	return dic

static func deserialize(editors_array_dic: Dictionary) -> Array[Editor]:
	# first clear all open editors
	var data: Array = editors_array_dic.get("editors_array")
	var editor_insts: Array[Editor] = []
	for editor_ser in data:
		var editor_inst = await Editor.create(editor_ser.get("type"), editor_ser.get("file"))
		editor_inst.name = editor_ser.get("name")
		
		if editor_inst.type == Editor.TYPE.Text:
			editor_inst.get_node("%CodeEdit").text = editor_ser.get("content")
		elif editor_inst.type == Editor.TYPE.Graphics:
			var graphics_editor: GraphicsEditor = editor_inst.get_node("%GraphicsEditor")
			var counter = 1
			for layer_img in editor_ser.get("content"):
				
				var buffer = Marshalls.base64_to_raw(layer_img.get("layer_img"))
				var image = Image.new()
				image.load_png_from_buffer(buffer)
				var texture = ImageTexture.create_from_image(image)
				var layer = Layer.create(image, "layer " + str(counter))
				#layer.texture = texture
				graphics_editor.loaded_layers.append(layer)
				counter +=1
		
		editor_insts.append(editor_inst)
	
	return editor_insts



func clear_editor_tabs():
	for editor in editor_pane.open_editors():
		editor.queue_free()


func _is_graphics_file(filename: String) -> bool:
	# Convert the filename to lower case to make the check case-insensitive
	var lower_case_filename = filename.to_lower()
	
	# Check if the filename ends with either ".jpeg", ".jpg", or ".png"
	if lower_case_filename.ends_with(".jpeg") or lower_case_filename.ends_with(".jpg") or lower_case_filename.ends_with(".png"):
		return true
	# If it doesn't match the above, it's not considered a graphics file
	return false

func _on_open_file(filename:String):
	open_file(filename)
	SingletonObject.save_state(false)


# func create_editor(node_type: node, name: String):
# 	var new_control = node_type.new()
# 	new_control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
# 	new_control.size_flags_vertical = Control.SIZE_EXPAND_FILL

# 	editor_pane.add(new_control, name)


func open_file(filename: String):
	## Determine the file type, create a control for that type (CodeEdit/TextureRect)
	## Then add the new control to the active_container

	# var new_control: Control

	## Determine file type
	if _is_graphics_file(filename):
		SingletonObject.is_graph = true
		editor_pane.add(Editor.TYPE.Graphics, filename)
		# new_control = TextureRect.new()
		# new_control.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED # keep the image at center

		# var image = Image.load_from_file(filename)
		# var texture_item = ImageTexture.create_from_image(image)
		# new_control.texture = texture_item

	else:
		editor_pane.add(Editor.TYPE.Text, filename)
		# new_control = CodeEdit.new()
		# ## Open the file and read the content into one giant string
		# var fa_object = FileAccess.open(filename, FileAccess.READ)
		# new_control.text = fa_object.get_as_text()

	# new_control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# new_control.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# editor_pane.add(Editor.TYPE.Text, filename)


func _on_h_button_pressed():
	if not editor_pane: return

	editor_pane.toggle_horizontal_split()


func _on_v_button_pressed():
	if not editor_pane: return

	editor_pane.toggle_vertical_split()


func _on_new_line_button_pressed() -> void:
	var current_tab = %EditorPane.Tabs.get_current_tab_control()
	if current_tab:
		if current_tab.get_class() == "ScrollContainer":
			current_tab.get_node("NoteEditor").add_new_line()
		else:
			current_tab.add_new_line()


func _on_back_space_button_pressed() -> void:
	var current_tab = %EditorPane.Tabs.get_current_tab_control()
	if current_tab:
		if current_tab.get_class() == "ScrollContainer":
			current_tab.get_node("NoteEditor").delete_chars()
		else:
			current_tab.delete_chars()


func _on_clear_button_pressed():
	var current_tab = %EditorPane.Tabs.get_current_tab_control()
	if current_tab:
		if current_tab.get_class() == "ScrollContainer":
			current_tab.get_node("NoteEditor").clear_text()
		else:
			current_tab.clear_text()


func _on_undo_button_pressed():
	var current_tab = %EditorPane.Tabs.get_current_tab_control()
	if current_tab:
		if current_tab.get_class() == "ScrollContainer":
			current_tab.get_node("NoteEditor").undo_action()
		else:
			current_tab.undo_action()

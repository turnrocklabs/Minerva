class_name EditorContainer
extends VBoxContainer

@export var editor_pane: EditorPane

# get all open editors that have a file associated
var _opened_files: Array[String] = []:
	get:
		var files: Array[String] = []
		for editor in editor_pane.get_children():
			if not editor is Editor or not editor.file: continue
			files.append(editor.file)
		return files


func _ready() -> void:
	editor_pane.enable_editor_action_buttons.connect(_toggle_enable_action_buttons)


func _toggle_enable_action_buttons(enable: bool) -> void:
	if get_tree():
		var editor_action_buttons = get_tree().get_nodes_in_group("editor_action_button")
		if editor_action_buttons:
			for button: Button in editor_action_buttons:
				button.disabled = !enable


func serialize() -> Array[String]:
	return _opened_files

func deserialize(files: Array[String]):
	_opened_files = files

	for file in files:
		open_file(file)


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
	# _opened_files.append(filename)
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
	#if %EditorPane.Tabs.get_current_tab_control():
		#%EditorPane.Tabs.get_current_tab_control().delete_chars()
	#else:
		#_toggle_enable_action_buttons(false)


func _on_clear_button_pressed():
	var current_tab = %EditorPane.Tabs.get_current_tab_control()
	if current_tab:
		if current_tab.get_class() == "ScrollContainer":
			current_tab.get_node("NoteEditor").clear_text()
		else:
			current_tab.clear_text()
	#if %EditorPane.Tabs.get_current_tab_control():
		#%EditorPane.Tabs.get_current_tab_control().clear_text()


func _on_undo_button_pressed():
	var current_tab = %EditorPane.Tabs.get_current_tab_control()
	if current_tab:
		if current_tab.get_class() == "ScrollContainer":
			current_tab.get_node("NoteEditor").undo_action()
		else:
			current_tab.undo_action()
	#if %EditorPane.Tabs.get_current_tab_control():
		#%EditorPane.Tabs.get_current_tab_control().undo_action()

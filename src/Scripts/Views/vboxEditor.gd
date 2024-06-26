extends VBoxContainer

@export var editor_pane: EditorPane


func _is_graphics_file(filename: String) -> bool:
	# Convert the filename to lower case to make the check case-insensitive
	var lower_case_filename = filename.to_lower()
	
	# Check if the filename ends with either ".jpeg", ".jpg", or ".png"
	if lower_case_filename.ends_with(".jpeg") or lower_case_filename.ends_with(".jpg") or lower_case_filename.ends_with(".png"):
		return true
	# If it doesn't match the above, it's not considered a graphics file
	return false

func _on_open_file(filename:String):
	## Determine the file type, create a control for that type (CodeEdit/TextureRect)
	## Then add the new control to the active_container

	var new_control: Control

	## Determine file type
	if _is_graphics_file(filename):
		new_control = TextureRect.new()
		new_control.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED # keep the image at center

		var image = Image.load_from_file(filename)
		var texture_item = ImageTexture.create_from_image(image)
		new_control.texture = texture_item
	else:
		new_control = CodeEdit.new()
		## Open the file and read the content into one giant string
		var fa_object = FileAccess.open(filename, FileAccess.READ)
		new_control.text = fa_object.get_as_text()

	new_control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	new_control.size_flags_vertical = Control.SIZE_EXPAND_FILL
	editor_pane.add(new_control, filename.get_file())


func _on_h_button_pressed():
	if not editor_pane: return

	editor_pane.toggle_horizontal_split()


func _on_v_button_pressed():
	if not editor_pane: return

	editor_pane.toggle_vertical_split()

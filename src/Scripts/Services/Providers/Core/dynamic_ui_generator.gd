class_name DynamicUIGenerator
extends Node

signal parameter_changed(param_name, value)

# if we have file fields in input data, this will be true
var binary_data: = false

var _field_scenes: = {
	"string": String_Field,
	"image": ImageField,
	"file": FileField,
	"list": ListField,
	"bool": BoolField,
	"number": NumberField,
}


func process_parameters(parameters: Dictionary, input: = true) -> Array[Control]:
	var controls: Array[Control]

	for key in parameters.keys():
		print("Processing: ", key)
		var fields_params: Dictionary = parameters[key]

		var field_type: String = fields_params.get("type", "")

		var field_scene: GDScript = _field_scenes.get(field_type)

		binary_data = binary_data or (input and [ImageField, FileField].has(field_scene))

		if not field_scene:
			push_error("No field scene for given type: %s" % field_type)
		
		var ctrl = field_scene.create(fields_params, input)
		ctrl.set_meta("field_name", key)

		controls.append(ctrl)

	
	return controls




# func generate_ui(requirements, is_input, parent_param = ""):
# 	var ui_elements = []
# 	for param_name in requirements.keys():
# 		var param_info = requirements[param_name]
# 		var control = null
		
# 		# Calculate full parameter path for nested elements
# 		var full_param_name = parent_param + "/" + param_name if parent_param else param_name

# 		if param_info.get("type") == "list":
# 			# Create a list container with proper styling
# 			var list_container = PanelContainer.new()
# 			var margin_container = MarginContainer.new()
# 			margin_container.add_theme_constant_override("margin_left", 10)
# 			margin_container.add_theme_constant_override("margin_right", 10)
# 			margin_container.add_theme_constant_override("margin_top", 10)
# 			margin_container.add_theme_constant_override("margin_bottom", 10)
# 			list_container.add_child(margin_container)
			
# 			var main_vbox = VBoxContainer.new()
# 			main_vbox.add_theme_constant_override("separation", 10)
# 			margin_container.add_child(main_vbox)
			
# 			# Add header section
# 			var header_container = HBoxContainer.new()
# 			header_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
# 			main_vbox.add_child(header_container)
			
# 			var label = Label.new()
# 			label.text = param_info.get("display_name", param_name).capitalize()
# 			label.add_theme_font_size_override("font_size", 16)
# 			header_container.add_child(label)
			
# 			if is_input:
# 				var add_button = Button.new()
# 				add_button.text = "Add " + param_info.get("display_name", "Item")
# 				add_button.custom_minimum_size.x = 120
# 				add_button.size_flags_horizontal = Control.SIZE_SHRINK_END
# 				header_container.add_child(add_button)
				
# 				# Description label if available
# 				if param_info.has("description"):
# 					var description = Label.new()
# 					description.text = param_info.get("description")
# 					description.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
# 					description.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
# 					main_vbox.add_child(description)
				
# 				# Container for list items with proper spacing
# 				var items_container = VBoxContainer.new()
# 				items_container.name = "ListItems"
# 				items_container.add_theme_constant_override("separation", 15)
# 				main_vbox.add_child(items_container)
				
# 				add_button.pressed.connect(func(): _add_list_item(items_container, param_info.get("values", {}), full_param_name))
				
# 				list_container.set_meta("param_name", full_param_name)
# 				list_container.set_meta("list_values_template", param_info.get("values", {}))
# 				list_container.set_meta("items_container", items_container)
# 				list_container.set_meta("is_list", true)
# 				list_container.set_meta("is_input", true)
# 			else:
# 				# Output version of the list
# 				var items_container = VBoxContainer.new()
# 				items_container.name = "ListItems"
# 				items_container.add_theme_constant_override("separation", 10)
# 				main_vbox.add_child(items_container)
				
# 				list_container.set_meta("param_name", full_param_name)
# 				list_container.set_meta("list_values_template", param_info.get("values", {}))
# 				list_container.set_meta("items_container", items_container)
# 				list_container.set_meta("is_list", true)
			
# 			ui_elements.append(list_container)
# 		else:
# 			if is_input:
# 				match param_info.get("type", ""):
# 					"string":
# 						control = create_string_input(full_param_name, param_info)
# 					"select":
# 						control = create_select_input(full_param_name, param_info)
# 					"image":
# 						control = create_image_input(full_param_name, param_info)
# 						print("Created image input control for ", full_param_name)  # Debug print
# 					"file":
# 					control = create_file_input(param_name, param_info)
# 		else:
# 				match param_info.get("type", ""):
# 					"string":
# 						control = create_string_output(full_param_name, param_info)
# 					"image":
# 						control = create_image_output(full_param_name, param_info)

# 			if control:
# 				print("Adding control to ui_elements: ", control)  # Debug print
# 				ui_elements.append(control)

# 	return ui_elements

# func _add_list_item(items_container, values_template, param_name):
# 	var item_container = PanelContainer.new()
# 	var style = StyleBoxFlat.new()
# 	style.bg_color = Color(0.15, 0.15, 0.15)
# 	style.corner_radius_top_left = 5
# 	style.corner_radius_top_right = 5
# 	style.corner_radius_bottom_left = 5
# 	style.corner_radius_bottom_right = 5
# 	item_container.add_theme_stylebox_override("panel", style)
	
# 	var margin = MarginContainer.new()
# 	margin.add_theme_constant_override("margin_left", 10)
# 	margin.add_theme_constant_override("margin_right", 10)
# 	margin.add_theme_constant_override("margin_top", 10)
# 	margin.add_theme_constant_override("margin_bottom", 10)
# 	item_container.add_child(margin)
	
# 	var vbox = VBoxContainer.new()
# 	vbox.add_theme_constant_override("separation", 10)
# 	margin.add_child(vbox)
	
# 	# Header with remove button
# 	var header = HBoxContainer.new()
# 	header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
# 	vbox.add_child(header)
	
# 	var item_number = Label.new()
# 	item_number.text = "Item " + str(items_container.get_child_count() + 1)
# 	header.add_child(item_number)
	
# 	var remove_button = Button.new()
# 	remove_button.text = "Remove"
# 	remove_button.custom_minimum_size.x = 80
# 	remove_button.size_flags_horizontal = Control.SIZE_SHRINK_END
# 	header.add_child(remove_button)
	
# 	remove_button.pressed.connect(func(): 
# 		items_container.remove_child(item_container)
# 		item_container.queue_free()
# 		# Update remaining item numbers
# 		_update_item_numbers(items_container)
# 	)
	
# 	# Generate and add form fields
# 	var elements = generate_ui(values_template, true, str(items_container.get_child_count()))
# 	for element in elements:
# 		vbox.add_child(element)
	
# 	items_container.add_child(item_container)
# 	return item_container

# func _update_item_numbers(items_container):
# 	var index = 1
# 	for item in items_container.get_children():
# 		var header = item.get_node("MarginContainer").get_node("VBoxContainer").get_node("HBoxContainer")
# 		var label = header.get_child(0)
# 		label.text = "Item " + str(index)
# 		index += 1

# # Rest of the existing functions remain the same
# func create_string_input(param_name, param_info):
# 	var container = VBoxContainer.new()
# 	container.add_theme_constant_override("separation", 5)

# 	var label = Label.new()
# 	label.text = param_info.get("display_name", param_name).capitalize()
# 	container.add_child(label)

# 	var line_edit = LineEdit.new()
# 	line_edit.placeholder_text = param_info.get("description", "Enter " + param_name.replace("_", " "))
# 	line_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
# 	line_edit.text_changed.connect(Callable(self, "_on_parameter_changed").bind(param_name))
# 	container.add_child(line_edit)

# 	if param_info.has("required") and param_info.get("required"):
# 		label.text += " *"
# 		label.add_theme_color_override("font_color", Color(1, 0.8, 0.8))

# 	container.set_meta("input_node", line_edit)
# 	container.set_meta("param_name", param_name)
# 	return container

# func create_select_input(param_name, param_info):
# 	var container = VBoxContainer.new()

# 	var label = Label.new()
# 	label.text = param_info.get("display_name", param_name).capitalize()
# 	container.add_child(label)

# 	var options = param_info.get("options", [])
# 	var option_button = OptionButton.new()
	
# 	for i in range(options.size()):
# 		var option = options[i]
# 		option_button.add_item(option.get("name", "Unknown"), i)
# 		option_button.set_item_metadata(i, {
# 			"id": option.get("id", "unknown"),
# 			"description": option.get("description", "")
# 		})

# 	option_button.item_selected.connect(Callable(self, "_on_select_option_changed").bind(option_button, param_name))
# 	container.add_child(option_button)

# 	var description_label = Label.new()
# 	description_label.name = "DescriptionLabel"
# 	description_label.text = options[0].get("description", "") if options.size() > 0 else ""
# 	description_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
# 	container.add_child(description_label)

# 	container.set_meta("input_node", option_button)
# 	container.set_meta("param_name", param_name)
# 	return container

# func create_image_input(param_name, param_info):
# 	var container = VBoxContainer.new()
# 	container.add_theme_constant_override("separation", 5)

# 	var label = Label.new()
# 	label.text = param_info.get("display_name", param_name).capitalize()
# 	if param_info.has("required") and param_info.get("required"):
# 		label.text += " *"
# 		label.add_theme_color_override("font_color", Color(1, 0.8, 0.8))
# 	container.add_child(label)

# 	var button = Button.new()
# 	button.text = "Select File"
# 	button.custom_minimum_size = Vector2(120, 0)
	
# 	# Connect to a signal that will be emitted when button is ready
# 	button.tree_entered.connect(func():
# 		button.pressed.connect(func(): _show_image_dialog_deferred(param_name, button))
# 	)
	
# 	container.add_child(button)

# 	button.set_meta("selected_path", "")

# 	container.set_meta("input_node", line_edit)
# 	container.set_meta("param_name", param_name)
# 	return container

# func create_file_input(param_name, param_info):
# 	var container = VBoxContainer.new()

# 	var label = Label.new()
# 	label.text = param_info.get("display_name", param_name).capitalize()
# 	container.add_child(label)

# 	var hbox = HBoxContainer.new()
# 	container.add_child(hbox)

# 	var line_edit = LineEdit.new()
# 	line_edit.editable = false
# 	line_edit.placeholder_text = "No file selected"
# 	hbox.add_child(line_edit)

# 	var button = Button.new()
# 	button.text = "Select File"
# 	button.pressed.connect(Callable(self, "_on_file_select_pressed").bind(param_name, line_edit, ["*.* ; All Files"]))
# 	hbox.add_child(button)

# 	container.set_meta("input_node", line_edit)
# 	container.set_meta("param_name", param_name)
	
# 	return container

# func _show_image_dialog_deferred(param_name, button):
# 	# Create dialog and add it to the root viewport
# 	var file_dialog = FileDialog.new()
# 	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
# 	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
# 	file_dialog.filters = PackedStringArray(["*.png ; PNG Images", "*.jpg ; JPEG Images"])
	
# 	file_dialog.file_selected.connect(func(path): 
# 		button.set_meta("selected_path", path)
# 		button.text = path.get_file()
# 		parameter_changed.emit(param_name, path)
# 	)
	
# 	# Add to root viewport
# 	var root = button.get_tree().root
# 	root.add_child(file_dialog)
	
# 	file_dialog.popup_centered(Vector2(800, 600))
# 	file_dialog.visibility_changed.connect(func(): 
# 		if not file_dialog.visible:
# 			file_dialog.queue_free()
# 	)


# func create_string_output(param_name, param_info):
# 	var container = VBoxContainer.new()

# 	var label = Label.new()
# 	label.text = param_info.get("display_name", param_name).capitalize()
# 	container.add_child(label)

# 	var output_label = Label.new()
# 	output_label.name = param_name
# 	output_label.text = "Waiting for output..."
# 	container.add_child(output_label)

# 	container.set_meta("output_node", output_label)
# 	container.set_meta("param_name", param_name)
# 	return container


# func create_image_output(param_name, param_info):
# 	var container = VBoxContainer.new()
# 	container.size_flags_vertical = Control.SIZE_SHRINK_CENTER

# 	var label = Label.new()
# 	label.text = param_info.get("display_name", param_name).capitalize()
# 	container.add_child(label)

# 	var texture_rect = TextureRect.new()
# 	texture_rect.name = param_name
# 	texture_rect.stretch_mode = TextureRect.STRETCH_SCALE
# 	texture_rect.custom_minimum_size = Vector2(350, 350)
# 	texture_rect.size = Vector2(350, 350)
# 	texture_rect.expand_mode = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
# 	container.add_child(texture_rect)

# 	container.set_meta("output_node", texture_rect)
# 	container.set_meta("param_name", param_name)
# 	return container

# func _on_file_select_pressed(param_name, line_edit, filters):
# 	var file_dialog = FileDialog.new()
# 	file_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
# 	file_dialog.access = FileDialog.ACCESS_FILESYSTEM
# 	file_dialog.filters = PackedStringArray(filters)
# 	file_dialog.file_selected.connect(Callable(self, "_on_file_selected").bind(file_dialog, line_edit, param_name))
# 	file_dialog.visibility_changed.connect(Callable(self, "_on_file_dialog_close").bind(file_dialog))
# 	file_dialog.min_size = Vector2(800, 600)
# 	add_child(file_dialog)
# 	file_dialog.popup_centered(Vector2(800, 600))

# func _on_file_selected(path, dialog, line_edit, param_name):
# 	line_edit.text = path
# 	dialog.queue_free()
# 	parameter_changed.emit(param_name, path)

# func _on_file_dialog_close(dialog):
# 	if not dialog.visible:
# 		dialog.queue_free()

# func _on_select_option_changed(index, option_button, param_name):
# 	var metadata = option_button.get_item_metadata(index)
# 	var container = option_button.get_parent()
# 	var description_label = container.get_node("DescriptionLabel")
# 	description_label.text = metadata.get("description", "")
# 	parameter_changed.emit(param_name, metadata.get("id"))

# func _on_parameter_changed(value, param_name):
# 	parameter_changed.emit(param_name, value)


# func get_user_input(ui_elements):
# 	var user_input = {}
	
# 	for element in ui_elements:
# 		if not element.has_meta("param_name"):
# 			continue
			
# 		var param_name = element.get_meta("param_name")
# 		var param_parts = param_name.split("/")
# 		var base_param = param_parts[-1]
		
# 		print("Processing element with param_name: ", param_name)
		
# 		# Handle lists
# 		if element.has_meta("is_list"):
# 			print("Found list element: ", base_param)
# 			var items_container = element.get_meta("items_container")
# 			var list_data = []
			
# 			if items_container and items_container.name == "ListItems":
# 				print("Number of items in container: ", items_container.get_child_count())
				
# 				for item in items_container.get_children():
# 					print("Processing list item...")
# 					var item_data = _collect_item_data(item)
# 					if not item_data.is_empty():
# 						list_data.append(item_data)
# 						print("Added item data: ", item_data)
			
# 			if not list_data.is_empty():
# 				print("Final list data: ", list_data)
# 				user_input[base_param] = list_data
# 			else:
# 				user_input[base_param] = []
			
# 		# Handle regular inputs
# 		elif element.has_meta("input_node"):
# 			var input_node = element.get_meta("input_node")
# 			var input_value = get_input_value(input_node)
			
# 			if input_value != null:
# 				user_input[base_param] = input_value
# 				print("Added regular input: ", base_param, " = ", input_value)
	
# 	print("Final user input: ", user_input)
# 	return user_input

# func _collect_item_data(item):
# 	var item_data = {}
	
# 	# First, try to find input elements directly in the item's children
# 	_collect_input_from_node(item, item_data)
	
# 	# Then recursively search through all children
# 	_recursive_collect_input(item, item_data)
	
# 	return item_data

# func _recursive_collect_input(node, item_data):
# 	for child in node.get_children():
# 		_collect_input_from_node(child, item_data)
# 		_recursive_collect_input(child, item_data)

# func _collect_input_from_node(node, item_data):
# 	if node.has_meta("param_name"):
# 		print("Found node with param_name: ", node.get_meta("param_name"))
# 		var param_name = node.get_meta("param_name")
# 		var base_param = param_name.split("/")[-1]
		
# 		if node.has_meta("input_node"):
# 			var input_node = node.get_meta("input_node")
# 			var value = get_input_value(input_node)
# 			if value != null:
# 				item_data[base_param] = value
# 				print("Collected value for ", base_param, ": ", value)

# func get_input_value(input_node):
# 	if input_node is Button:  # For image inputs
# 		var file_path = input_node.get_meta("selected_path", "")
# 		if file_path != "" and FileAccess.file_exists(file_path):
# 			var file = FileAccess.open(file_path, FileAccess.READ)
# 			if file:
# 				return file
# 		return null
# 	elif input_node is LineEdit:
# 		return input_node.text if input_node.text.length() > 0 else null
# 	elif input_node is OptionButton:
# 		var selected_index = input_node.get_selected_id()
# 		var metadata = input_node.get_item_metadata(selected_index)
# 		return metadata.get("id") if metadata else null
	
# 	return null

# # If you need to get a FileAccess object from a path
# func get_file_access(file_path: String) -> FileAccess:
# 	if file_path != "" and FileAccess.file_exists(file_path):
# 		return FileAccess.open(file_path, FileAccess.READ)
# 	return null

# func create_list_item(values_template, item_data, list_index):
# 	var item_container = VBoxContainer.new()
# 	item_container.add_theme_constant_override("separation", 10)
	
# 	# Add a separator
# 	var separator = HSeparator.new()
# 	item_container.add_child(separator)
	
# 	# Generate UI elements with the list index in the parameter path
# 	var elements = generate_ui(values_template, false, str(list_index))
# 	for element in elements:
# 		item_container.add_child(element)
	
# 	# Update the values if we have data
# 	if item_data:
# 		for key in item_data.keys():
# 			var nested_data = {key: item_data[key]}
# 			update_output(elements, nested_data)
	
# 	return item_container

# func update_output(ui_elements, result_data):
# 	for element in ui_elements:
# 		# Skip elements without metadata
# 		if not element.has_meta("param_name"):
# 			continue
			
# 		var param_name = element.get_meta("param_name")
# 		var base_param = param_name.split("/")[-1]  # Get the last part of the parameter path
		
# 		# Handle lists
# 		if element.has_meta("is_list") and element.has_meta("list_values_template"):
# 			var items_container = element.get_meta("items_container")
# 			var values_template = element.get_meta("list_values_template")
			
# 			# Clear existing items
# 			for child in items_container.get_children():
# 				items_container.remove_child(child)
# 				child.queue_free()
			
# 			# Create new items based on the result data
# 			if result_data.has(base_param):
# 				var list_data = result_data[base_param]
# 				if list_data is Array:
# 					for idx in range(list_data.size()):
# 						var list_item = create_list_item(values_template, list_data[idx], idx)
# 						items_container.add_child(list_item)
# 			continue
		
# 		# Handle regular outputs
# 		if not element.has_meta("output_node"):
# 			continue
			
# 		var output_node = element.get_meta("output_node")
# 		if output_node and result_data.has(base_param):
# 			var output_value = result_data[base_param]
			
# 			if output_node is Label:
# 				output_node.text = str(output_value)
# 			elif output_node is TextureRect:
# 				if output_value is FileAccess:
# 					var img: = Image.new()
# 					var err: = img.load_png_from_buffer(output_value.get_buffer(output_value.get_length()))
# 					output_value.close()

# 					if err == OK:
# 						var texture = ImageTexture.create_from_image(img)
# 						output_node.texture = texture
# 					else:
# 						print("Error loading image from buffer: ", err)
				
# 				elif output_value is PackedByteArray:
# 					var img = Image.new()
# 					var err = img.load_png_from_buffer(output_value)
# 					if err == OK:
# 						var texture = ImageTexture.create_from_image(img)
# 						output_node.texture = texture
# 					else:
# 						print("Error loading image from buffer: ", err)
# 				elif output_value is Dictionary and output_value.has("data") and output_value.has("format"):
# 					var img = Image.new()
# 					var img_data = Marshalls.base64_to_raw(output_value["data"])
# 					var err = OK
# 					if output_value["format"] == "jpg":
# 						err = img.load_jpg_from_buffer(img_data)
# 					elif output_value["format"] == "png":
# 						err = img.load_png_from_buffer(img_data)
# 					else:
# 						print("Unsupported image format: ", output_value["format"])
					
# 					if err == OK:
# 						var texture = ImageTexture.create_from_image(img)
# 						output_node.texture = texture
# 					else:
# 						print("Error loading image: ", err)
# 				else:
# 					print("Invalid image data format for ", param_name)

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


func serialize() -> Array:
	var editors_serialized: Array[Dictionary] = []
	var tab_idx := 0
	for editor in editor_pane.get_open_editors():
		var content
		match editor.type:
			Editor.Type.TEXT:
				content = editor.code_edit.text
			editor.Type.SPREADSHEET:
				if editor.spreadsheet_editor:
					content = editor.spreadsheet_editor.serialize()
				else:
					content = {}
			Editor.Type.KANBAN:
				# Serialize kanban board
				if editor.kanban_board and editor.kanban_board.task_store:
					content = editor.kanban_board.task_store.serialize()
				else:
					content = {"session_id": "", "version": 1, "next_id": 1, "tasks": []}
			Editor.Type.GRAPHICS:
				var layers: Array[Dictionary] = []
				# Get the GraphicsEditorV2 instance
				var graphics_editor = editor.graphics_editor
				if graphics_editor:
					# Serialize layers in the correct order (from layers array)
					for layer in graphics_editor.layers:
						if not layer:
							continue

						# Base layer data (common to all types)
						var layer_data = {
							"name": layer.name,
							"position_x": layer.position.x,
							"position_y": layer.position.y,
							"size_x": layer.size.x,
							"size_y": layer.size.y,
							"rotation": layer.rotation,
							"pivot_offset_x": layer.pivot_offset.x,
							"pivot_offset_y": layer.pivot_offset.y,
							"visible": layer.visible,
							"locked": layer.locked,
							"type": layer.type,
							"outline_visible": layer.outline_visible,
							"outline_color_r": layer.outline_color.r,
							"outline_color_g": layer.outline_color.g,
							"outline_color_b": layer.outline_color.b,
							"outline_color_a": layer.outline_color.a
						}

						# Save image data if layer has an image
						if layer.image:
							layer_data["layer_img"] = Marshalls.raw_to_base64(layer.image.save_png_to_buffer())

						# Save base_image if it exists (for image layers)
						if layer.base_image:
							layer_data["base_img"] = Marshalls.raw_to_base64(layer.base_image.save_png_to_buffer())

						# Save speech bubble data if it exists
						if layer.type == LayerV2.Type.SPEECH_BUBBLE and layer.speech_bubble:
							layer_data["speech_bubble_type"] = layer.speech_bubble.type

						# Save DIAGRAM_SHAPE specific data
						if layer.type == LayerV2.Type.DIAGRAM_SHAPE:
							layer_data["diagram_shape_type"] = layer.diagram_shape_type
							layer_data["diagram_stroke_color_r"] = layer.diagram_stroke_color.r
							layer_data["diagram_stroke_color_g"] = layer.diagram_stroke_color.g
							layer_data["diagram_stroke_color_b"] = layer.diagram_stroke_color.b
							layer_data["diagram_stroke_color_a"] = layer.diagram_stroke_color.a
							layer_data["diagram_fill_color_r"] = layer.diagram_fill_color.r
							layer_data["diagram_fill_color_g"] = layer.diagram_fill_color.g
							layer_data["diagram_fill_color_b"] = layer.diagram_fill_color.b
							layer_data["diagram_fill_color_a"] = layer.diagram_fill_color.a
							layer_data["diagram_stroke_width"] = layer.diagram_stroke_width
							layer_data["diagram_text_content"] = layer.diagram_text_content
							layer_data["diagram_text_font_size"] = layer.diagram_text_font_size
							layer_data["diagram_text_color_r"] = layer.diagram_text_color.r
							layer_data["diagram_text_color_g"] = layer.diagram_text_color.g
							layer_data["diagram_text_color_b"] = layer.diagram_text_color.b
							layer_data["diagram_text_color_a"] = layer.diagram_text_color.a
							layer_data["diagram_text_bold"] = layer.diagram_text_bold
							layer_data["diagram_text_italic"] = layer.diagram_text_italic
							layer_data["diagram_text_underline"] = layer.diagram_text_underline
							layer_data["diagram_text_strikethrough"] = layer.diagram_text_strikethrough

						# Save DIAGRAM_CONNECTOR specific data
						if layer.type == LayerV2.Type.DIAGRAM_CONNECTOR:
							# Save source/target by layer name (will resolve during load)
							var source = layer._source_layer_ref.get_ref() if layer._source_layer_ref else null
							var target = layer._target_layer_ref.get_ref() if layer._target_layer_ref else null
							layer_data["connector_source_layer_name"] = source.name if source else ""
							layer_data["connector_target_layer_name"] = target.name if target else ""
							layer_data["connector_source_anchor"] = layer.connector_source_anchor
							layer_data["connector_target_anchor"] = layer.connector_target_anchor
							layer_data["connector_line_color_r"] = layer.connector_line_color.r
							layer_data["connector_line_color_g"] = layer.connector_line_color.g
							layer_data["connector_line_color_b"] = layer.connector_line_color.b
							layer_data["connector_line_color_a"] = layer.connector_line_color.a
							layer_data["connector_line_width"] = layer.connector_line_width
							layer_data["connector_arrow_head"] = layer.connector_arrow_head
							layer_data["connector_routing"] = layer.connector_routing
							# Manual waypoints
							var waypoints_data = []
							for wp in layer.connector_manual_waypoints:
								waypoints_data.append({"x": wp.x, "y": wp.y})
							layer_data["connector_manual_waypoints"] = waypoints_data
							# Connector text properties
							layer_data["connector_text_content"] = layer.connector_text_content
							layer_data["connector_text_font_size"] = layer.connector_text_font_size
							layer_data["connector_text_color_r"] = layer.connector_text_color.r
							layer_data["connector_text_color_g"] = layer.connector_text_color.g
							layer_data["connector_text_color_b"] = layer.connector_text_color.b
							layer_data["connector_text_color_a"] = layer.connector_text_color.a

						layers.append(layer_data)
					
					# Also save canvas size and selected layers
					content = {
						"layers": layers,
						"canvas_size_x": graphics_editor.canvas_size.x,
						"canvas_size_y": graphics_editor.canvas_size.y,
						"selected_layer_names": graphics_editor.selected_layers.map(func(l): return l.name)
					}
				else:
					content = {"layers": [], "canvas_size_x": 1000, "canvas_size_y": 1000, "selected_layer_names": []}
			Editor.Type.PCB:
				if editor.pcb_editor:
					content = editor.pcb_editor.to_dict()
				else:
					content = {}

		var editor_data = {
			"name": editor_pane.Tabs.get_tab_title(tab_idx),
			"file": editor.file,
			"type": editor.type,
			"content": content,
			"associated_object": SingletonObject.registered_object_get_uuid(editor.associated_object),
		}
		editors_serialized.append(editor_data)
		tab_idx += 1
	
	return editors_serialized


static func deserialize(editors_array: Array) -> Array[Editor]:
	var editor_instances: Array[Editor] = []
	for editor_ser in editors_array:
		prints("Getting registered object:", editor_ser.get("associated_object"))
		var editor_inst = Editor.create(
			editor_ser.get("type"),
			editor_ser.get("file"),
			null,
			SingletonObject.get_registered_object(editor_ser.get("associated_object")),
			false
		)
		editor_inst.tab_title = editor_ser.get("name")
		
		await SingletonObject.editor_container.get_tree().process_frame

		if editor_inst.type == Editor.Type.TEXT:
			editor_inst.code_edit.text = editor_ser.get("content")
		
		elif editor_inst.type == Editor.Type.KANBAN:
			# Deserialize kanban board
			var content = editor_ser.get("content")
			if content and editor_inst.kanban_board:
				var AutocoderTaskStoreClass = load("res://Scripts/UI/Controls/Autocoder/AutocoderTaskStore.gd")
				var task_store = AutocoderTaskStoreClass.deserialize(content)
				editor_inst.kanban_board.set_task_store(task_store)

		elif editor_inst.type == Editor.Type.SPREADSHEET:
			if editor_inst.spreadsheet_editor:
				var content = editor_ser.get("content")
				if content and content is Dictionary:
					editor_inst.spreadsheet_editor.deserialize(content)

		elif editor_inst.type == Editor.Type.GRAPHICS:
			var graphics_editor: GraphicsEditorV2 = editor_inst.graphics_editor
			if graphics_editor:
				
				var content = editor_ser.get("content")
				
				# Restore canvas size
				var canvas_size = Vector2i(
					content.get("canvas_size_x", 1000),
					content.get("canvas_size_y", 1000)
				)
				graphics_editor.canvas_size = canvas_size
				
				# Clear existing layers first
				for existing_layer in graphics_editor.layers.duplicate():
					if existing_layer:
						# Remove layer card
						for card in graphics_editor.layer_cards_container.get_children():
							if card is LayerCard and card.layer == existing_layer:
								card.queue_free()
								break
						
						# Remove from arrays
						graphics_editor.layers.erase(existing_layer)
						graphics_editor.selected_layers.erase(existing_layer)
						
						# Remove from scene
						existing_layer.queue_free()
				
				# Wait for cleanup
				await SingletonObject.editor_container.get_tree().process_frame
				
				# Recreate layers from serialized data
				var selected_layer_names = content.get("selected_layer_names", [])
				var layers_data = content.get("layers", [])
				
				# First pass: create all layers
				var created_layers: Array[LayerV2] = []
				var connector_data_list: Array[Dictionary] = []

				for layer_data in layers_data:
					var layer: LayerV2

					# Restore the image if it exists (raster layers)
					var image: Image = null
					if layer_data.has("layer_img"):
						var buffer = Marshalls.base64_to_raw(layer_data.get("layer_img"))
						image = Image.new()
						image.load_png_from_buffer(buffer)

					# Create layer based on type
					var layer_type = layer_data.get("type", LayerV2.Type.DRAWING)
					match layer_type:
						LayerV2.Type.IMAGE:
							layer = LayerV2.create_image_layer(layer_data.get("name", "Layer"), image)
							# Restore base_image if it exists
							if layer_data.has("base_img"):
								var base_buffer = Marshalls.base64_to_raw(layer_data.get("base_img"))
								var base_image = Image.new()
								base_image.load_png_from_buffer(base_buffer)
								layer.base_image = base_image

						LayerV2.Type.SPEECH_BUBBLE:
							var bubble_type = layer_data.get("speech_bubble_type", CloudControl.Type.ELLIPSE)
							layer = LayerV2.create_speech_bubble_layer(layer_data.get("name", "Speech Bubble"), bubble_type)

						LayerV2.Type.DIAGRAM_SHAPE:
							var shape_type = layer_data.get("diagram_shape_type", LayerV2.DiagramShapeType.RECTANGLE)
							var stroke_color = Color(
								layer_data.get("diagram_stroke_color_r", 0.0),
								layer_data.get("diagram_stroke_color_g", 0.0),
								layer_data.get("diagram_stroke_color_b", 0.0),
								layer_data.get("diagram_stroke_color_a", 1.0)
							)
							var fill_color = Color(
								layer_data.get("diagram_fill_color_r", 0.0),
								layer_data.get("diagram_fill_color_g", 0.0),
								layer_data.get("diagram_fill_color_b", 0.0),
								layer_data.get("diagram_fill_color_a", 0.0)
							)
							var stroke_width = layer_data.get("diagram_stroke_width", 2)
							var layer_size = Vector2(
								layer_data.get("size_x", 100),
								layer_data.get("size_y", 100)
							)
							layer = LayerV2.create_diagram_shape(
								layer_data.get("name", "Diagram Shape"),
								shape_type,
								layer_size,
								stroke_color,
								fill_color,
								stroke_width
							)
							# Restore text properties
							layer.diagram_text_content = layer_data.get("diagram_text_content", "")
							layer.diagram_text_font_size = layer_data.get("diagram_text_font_size", 14)
							layer.diagram_text_color = Color(
								layer_data.get("diagram_text_color_r", 0.0),
								layer_data.get("diagram_text_color_g", 0.0),
								layer_data.get("diagram_text_color_b", 0.0),
								layer_data.get("diagram_text_color_a", 1.0)
							)
							layer.diagram_text_bold = layer_data.get("diagram_text_bold", false)
							layer.diagram_text_italic = layer_data.get("diagram_text_italic", false)
							layer.diagram_text_underline = layer_data.get("diagram_text_underline", false)
							layer.diagram_text_strikethrough = layer_data.get("diagram_text_strikethrough", false)

						LayerV2.Type.DIAGRAM_CONNECTOR:
							# Create connector with placeholder - will resolve references after all layers are created
							var line_color = Color(
								layer_data.get("connector_line_color_r", 0.53),
								layer_data.get("connector_line_color_g", 0.81),
								layer_data.get("connector_line_color_b", 0.92),
								layer_data.get("connector_line_color_a", 1.0)
							)
							var line_width = layer_data.get("connector_line_width", 2)
							var arrow_head = layer_data.get("connector_arrow_head", LayerV2.ArrowHeadType.SINGLE)

							# Create a placeholder connector layer (will set source/target after)
							layer = LayerV2.new()
							layer.name = layer_data.get("name", "Connector")
							layer.type = LayerV2.Type.DIAGRAM_CONNECTOR
							layer.connector_line_color = line_color
							layer.connector_line_width = line_width
							layer.connector_arrow_head = arrow_head
							layer.connector_source_anchor = layer_data.get("connector_source_anchor", LayerV2.AnchorPoint.RIGHT)
							layer.connector_target_anchor = layer_data.get("connector_target_anchor", LayerV2.AnchorPoint.LEFT)
							layer.connector_routing = layer_data.get("connector_routing", LayerV2.ConnectorRouting.ORTHOGONAL)
							# Restore manual waypoints
							var waypoints_data = layer_data.get("connector_manual_waypoints", [])
							var manual_waypoints: PackedVector2Array = []
							for wp_data in waypoints_data:
								manual_waypoints.append(Vector2(wp_data.get("x", 0), wp_data.get("y", 0)))
							layer.connector_manual_waypoints = manual_waypoints
							# Restore connector text properties
							layer.connector_text_content = layer_data.get("connector_text_content", "")
							layer.connector_text_font_size = layer_data.get("connector_text_font_size", 12)
							layer.connector_text_color = Color(
								layer_data.get("connector_text_color_r", 0.0),
								layer_data.get("connector_text_color_g", 0.0),
								layer_data.get("connector_text_color_b", 0.0),
								layer_data.get("connector_text_color_a", 1.0)
							)
							layer.connector_text_font = ThemeDB.get_fallback_font()

							# Store connector data for second pass
							connector_data_list.append({
								"layer": layer,
								"source_name": layer_data.get("connector_source_layer_name", ""),
								"target_name": layer_data.get("connector_target_layer_name", "")
							})

						_: # Default to DRAWING
							if image:
								layer = LayerV2.create_drawing_layer(
									layer_data.get("name", "Layer"),
									Vector2i(image.get_width(), image.get_height())
								)
								layer.image = image
							else:
								# Fallback for drawing layers without image
								layer = LayerV2.create_drawing_layer(
									layer_data.get("name", "Layer"),
									Vector2i(int(layer_data.get("size_x", 100)), int(layer_data.get("size_y", 100)))
								)

					# Restore all layer properties
					layer.position = Vector2(
						layer_data.get("position_x", 0),
						layer_data.get("position_y", 0)
					)
					# Size for vector layers was already set during creation; for raster layers use image size
					if image and not (layer_type in [LayerV2.Type.DIAGRAM_SHAPE, LayerV2.Type.DIAGRAM_CONNECTOR]):
						layer.size = Vector2(
							layer_data.get("size_x", image.get_width()),
							layer_data.get("size_y", image.get_height())
						)
					else:
						layer.size = Vector2(
							layer_data.get("size_x", layer.size.x),
							layer_data.get("size_y", layer.size.y)
						)
					layer.rotation = layer_data.get("rotation", 0.0)
					layer.pivot_offset = Vector2(
						layer_data.get("pivot_offset_x", layer.size.x / 2),
						layer_data.get("pivot_offset_y", layer.size.y / 2)
					)
					layer.visible = layer_data.get("visible", true)
					layer.locked = layer_data.get("locked", false)
					layer.outline_visible = layer_data.get("outline_visible", true)
					layer.outline_color = Color(
						layer_data.get("outline_color_r", 1.0),
						layer_data.get("outline_color_g", 0.5),
						layer_data.get("outline_color_b", 0.0),
						layer_data.get("outline_color_a", 1.0)
					)

					created_layers.append(layer)

					# Add layer to graphics editor (this will create the layer card automatically)
					var should_select = selected_layer_names.has(layer.name)
					graphics_editor.add_layer.call_deferred(layer, should_select)

				# Second pass: resolve connector references by layer name
				await SingletonObject.editor_container.get_tree().process_frame
				for conn_data in connector_data_list:
					var connector_layer: LayerV2 = conn_data["layer"]
					var source_name: String = conn_data["source_name"]
					var target_name: String = conn_data["target_name"]

					# Find source and target layers by name
					for created_layer in created_layers:
						if created_layer.name == source_name:
							connector_layer._source_layer_ref = weakref(created_layer)
							connector_layer.connector_source_layer_id = created_layer.get_instance_id()
							# Connect to shape_moved signal
							if not created_layer.shape_moved.is_connected(connector_layer._on_connected_shape_moved):
								created_layer.shape_moved.connect(connector_layer._on_connected_shape_moved)
						if created_layer.name == target_name:
							connector_layer._target_layer_ref = weakref(created_layer)
							connector_layer.connector_target_layer_id = created_layer.get_instance_id()
							# Connect to shape_moved signal
							if not created_layer.shape_moved.is_connected(connector_layer._on_connected_shape_moved):
								created_layer.shape_moved.connect(connector_layer._on_connected_shape_moved)

		elif editor_inst.type == Editor.Type.PCB:
			if editor_inst.pcb_editor:
				var content = editor_ser.get("content")
				if content and content is Dictionary:
					editor_inst.pcb_editor.load_from_dict(content)

		editor_instances.append(editor_inst)
	
	return editor_instances



func clear_editor_tabs():
	for editor in editor_pane.get_open_editors():
		editor.queue_free()


func _is_graphics_file(filename: String) -> bool:
	# Convert the filename to lower case to make the check case-insensitive
	var lower_case_filename = filename.to_lower()
	
	# Check if the filename ends with either ".jpeg", ".jpg", or ".png"
	if lower_case_filename.ends_with(".jpeg") or lower_case_filename.ends_with(".jpg") or lower_case_filename.ends_with(".png"):
		return true
	# If it doesn't match the above, it's not considered a graphics file
	return false

func _on_open_files(files: PackedStringArray):
	for filename in files:
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
	## Determine file type
	if _is_graphics_file(filename):
		SingletonObject.is_graph = true
		SingletonObject.is_picture = true
		editor_pane.add(Editor.Type.GRAPHICS, filename)
	elif filename.to_lower().ends_with(".minpcb"):
		editor_pane.add(Editor.Type.PCB, filename)
	elif filename.to_lower().ends_with(".minkb"):
		editor_pane.add(Editor.Type.KANBAN, filename)
	elif filename.to_lower().ends_with(".minsheet"):
		editor_pane.add(Editor.Type.SPREADSHEET, filename)
	else:
		editor_pane.add(Editor.Type.TEXT, filename)
		# new_control = CodeEdit.new()
		# ## Open the file and read the content into one giant string
		# var fa_object = FileAccess.open(filename, FileAccess.READ)
		# new_control.text = fa_object.get_as_text()

	# new_control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# new_control.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# editor_pane.add(Editor.Type.TEXT, filename)


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
	SingletonObject.UpdateUnsavedTabIcon.emit()


func _on_back_space_button_pressed() -> void:
	var current_tab = %EditorPane.Tabs.get_current_tab_control()
	if current_tab:
		if current_tab.get_class() == "ScrollContainer":
			current_tab.get_node("NoteEditor").delete_chars()
		else:
			current_tab.delete_chars()
	SingletonObject.UpdateUnsavedTabIcon.emit()


func _on_clear_button_pressed():
	var current_tab = %EditorPane.Tabs.get_current_tab_control()
	if current_tab:
		if current_tab.get_class() == "ScrollContainer":
			current_tab.get_node("NoteEditor").clear_text()
		else:
			current_tab.clear_text()
	SingletonObject.UpdateUnsavedTabIcon.emit()


func _on_undo_button_pressed():
	var current_tab = %EditorPane.Tabs.get_current_tab_control()
	if current_tab:
		if current_tab.get_class() == "ScrollContainer":
			current_tab.get_node("NoteEditor").undo_action()
		else:
			current_tab.undo_action()
	SingletonObject.UpdateUnsavedTabIcon.emit()


func _on_redo_button_pressed():
	var current_tab = %EditorPane.Tabs.get_current_tab_control()
	if current_tab:
		if current_tab.get_class() == "ScrollContainer":
			current_tab.get_node("NoteEditor").redo_action()
		else:
			current_tab.redo_action()
	SingletonObject.UpdateUnsavedTabIcon.emit()


func _on_add_file_editor_pressed() -> void:
	SingletonObject.editor_container.editor_pane.add(Editor.Type.TEXT)


func _on_add_graphics_editor_pressed() -> void:
	SingletonObject.editor_container.editor_pane.add(Editor.Type.GRAPHICS)

func _on_add_package_editor_pressed() -> void:
	SingletonObject.editor_container.editor_pane.add(Editor.Type.PACKAGE)


func _on_add_spreadsheet_editor_pressed() -> void:
	SingletonObject.editor_container.editor_pane.add(Editor.Type.SPREADSHEET)


func _on_add_pcb_editor_pressed() -> void:
	SingletonObject.editor_container.editor_pane.add(Editor.Type.PCB)


func _on_add_many_new_files_editor_pressed() -> void:
	%ManyNewFilesDialogWindow.popup()

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

		# PLUGIN_SCENE editors are serialised via async MCP dispatch below.
		# We handle them after the match block so we can use await cleanly.
		if editor.type == Editor.Type.PLUGIN_SCENE:
			var plugin_entry: Dictionary = await _serialize_plugin_scene_editor(
				editor,
				editor_pane.Tabs.get_tab_title(tab_idx)
			)
			editors_serialized.append(plugin_entry)
			tab_idx += 1
			continue

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

	# Pre-pass: any plugin referenced by a PLUGIN_SCENE tab must be RUNNING
	# before its tab deserializes, so the deserialize_channel dispatch finds
	# a live connection.  This wires plugin lifecycle to project state — a
	# project that was saved with plugin X running comes back with plugin X
	# running, regardless of the manifest's autostart flag.
	await _ensure_plugins_running_for_entries(editors_array)

	for editor_ser in editors_array:
		prints("Getting registered object:", editor_ser.get("associated_object"))
		var ser_type = editor_ser.get("type")
		var editor_inst: Editor
		if ser_type == Editor.Type.PLUGIN_SCENE:
			editor_inst = Editor.create_plugin_scene(
				editor_ser.get("plugin_id", ""),
				editor_ser.get("panel_name", ""),
				editor_ser.get("file"),
				null,
				SingletonObject.get_registered_object(editor_ser.get("associated_object")),
			)
		else:
			editor_inst = Editor.create(
				ser_type,
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

		elif editor_inst.type == Editor.Type.PLUGIN_SCENE:
			await _deserialize_plugin_scene_editor(editor_inst, editor_ser)

		editor_instances.append(editor_inst)
	
	return editor_instances



## Serialise a PLUGIN_SCENE editor into a project-file manifest entry (design §8.1).
##
## Dispatches the plugin's declared project_file.serialize_channel as an MCP tool call
## and returns the complete editor manifest entry Dictionary.
##
## Fallback cases (no IPC dispatch):
##   - No project_file.serialize_channel declared → skipped silently, entry omitted.
##   - Plugin not running / connection unavailable → entry with plugin_unavailable:true.
##
## tab_title is the display name of the tab (taken from Tabs.get_tab_title).
func _serialize_plugin_scene_editor(editor: Editor, tab_title: String) -> Dictionary:
	var plugin_id: String = editor.plugin_id
	var panel_name: String = editor.panel_name
	var raw_editor_id = SingletonObject.registered_object_get_uuid(editor.associated_object)
	var editor_id: String = str(raw_editor_id) if raw_editor_id != null else ""

	# Resolve PluginDefinition — need project_file_serialize_channel.
	var def: PluginDefinition = _get_plugin_def(plugin_id)

	if def == null or def.project_file_serialize_channel.is_empty():
		# No project_file hook declared for this plugin — skip serialisation.
		# Return a minimal entry that can be re-opened but carries no saved state.
		# The type is still PLUGIN_SCENE so open_file/deserialize can handle it.
		push_warning(
			("[EditorContainer] serialize: PLUGIN_SCENE editor for plugin '%s' panel '%s' " +
			"has no project_file.serialize_channel — tab state will not be restored.") %
			[plugin_id, panel_name]
		)
		return {
			"name": tab_title,
			"file": editor.file,
			"type": Editor.Type.PLUGIN_SCENE,
			"plugin_id": plugin_id,
			"panel_name": panel_name,
			"plugin_version": def.version if def != null else "",
			"plugin_state": {"version": 1, "plugin_id": plugin_id,
				"plugin_version": def.version if def != null else "",
				"panel_name": panel_name, "payload": {}},
			"sidecar_paths": [],
			"associated_object": editor_id,
		}

	# Attempt MCP dispatch.
	var conn: MCPServerConnection = _get_plugin_connection(plugin_id)
	if conn == null:
		push_warning(
			("[EditorContainer] serialize: PLUGIN_SCENE plugin '%s' is not running; " +
			"saving with plugin_unavailable flag.") % plugin_id
		)
		return {
			"name": tab_title,
			"file": editor.file,
			"type": Editor.Type.PLUGIN_SCENE,
			"plugin_id": plugin_id,
			"panel_name": panel_name,
			"plugin_version": def.version,
			"plugin_state": {"version": 1, "plugin_id": plugin_id,
				"plugin_version": def.version, "panel_name": panel_name, "payload": {}},
			"sidecar_paths": [],
			"plugin_unavailable": true,
			"associated_object": editor_id,
		}

	var call_result = await conn.call_tool(
		def.project_file_serialize_channel,
		{
			"file_path": editor.file,
			"panel_name": panel_name,
			"editor_id": editor_id,
		}
	)

	var tab_state: Dictionary = {}
	var sidecar_paths: Array = []

	if call_result is Dictionary:
		tab_state = call_result.get("tab_state", {})
		var raw_paths = call_result.get("sidecar_paths", [])
		if raw_paths is Array:
			for p in raw_paths:
				sidecar_paths.append(str(p))
	else:
		push_warning(
			("[EditorContainer] serialize: plugin '%s' serialize_channel returned " +
			"unexpected result; saving with empty payload.") % plugin_id
		)

	# Platform-managed panel-state capture (sibling to the plugin's tab_state).
	# Reuses the host_owned _on_panel_save_request hook so simple panels round-trip
	# through the project file without each plugin author wiring their own cache.
	var panel_root: Control = editor.plugin_scene_root
	if panel_root != null and panel_root.has_method("_on_panel_save_request"):
		var panel_state = panel_root._on_panel_save_request()
		if panel_state is Dictionary:
			tab_state["__panel_state"] = panel_state

	return {
		"name": tab_title,
		"file": editor.file,
		"type": Editor.Type.PLUGIN_SCENE,
		"plugin_id": plugin_id,
		"panel_name": panel_name,
		"plugin_version": def.version,
		"plugin_state": {
			"version": 1,
			"plugin_id": plugin_id,
			"plugin_version": def.version,
			"panel_name": panel_name,
			"payload": tab_state,
		},
		"sidecar_paths": sidecar_paths,
		"associated_object": editor_id,
	}


## Deserialise a PLUGIN_SCENE entry from a project-file manifest back into
## an already-created Editor node (design §8.1, §8.3).
##
## `editor_inst` was created by Editor.create_plugin_scene() (or with Type.PLUGIN_SCENE).
## `editor_ser` is the raw Dictionary entry from the Editors array in the .minproj.
##
## Handles:
##   - Plugin not installed → placeholder label in the editor's VBox.
##   - Plugin version mismatch → stored_version passed to deserialize_channel.
##   - Normal path → waits for panel_loaded then dispatches deserialize_channel.
static func _deserialize_plugin_scene_editor(
		editor_inst: Editor,
		editor_ser: Dictionary
) -> void:
	var plugin_id: String = editor_ser.get("plugin_id", editor_inst.plugin_id)
	var panel_name: String = editor_ser.get("panel_name", editor_inst.panel_name)
	var plugin_state: Dictionary = editor_ser.get("plugin_state", {})
	var stored_version: String = str(editor_ser.get("plugin_version", ""))
	var payload: Dictionary = plugin_state.get("payload", {})

	# Ensure the editor instance has the right plugin identity.
	editor_inst.plugin_id = plugin_id
	editor_inst.panel_name = panel_name

	# Check if plugin is installed.
	var def: PluginDefinition = _get_plugin_def_static(plugin_id)
	if def == null:
		# Plugin not installed — show a placeholder label.
		_show_placeholder(
			editor_inst,
			("Install '%s' to open this document.") % plugin_id
		)
		return

	# Wait one frame to allow the just-instantiated panel's _ready and
	# _on_panel_loaded hooks to run before we push state into it.
	await SingletonObject.editor_container.get_tree().process_frame

	# Platform-managed panel-state restore — runs UNCONDITIONALLY of plugin server
	# state.  __panel_state lives in the .minproj and only needs the panel to be
	# mounted (which it already is, courtesy of Editor.create_plugin_scene).
	# Doing this before the server-side dispatch means a closed/crashed plugin
	# server still gets a faithful UI restore — the user's text comes back even
	# if the plugin's backend isn't running yet.
	_restore_panel_state(editor_inst, payload)

	# Server-side deserialize is best-effort: only fires when the plugin is
	# running AND declares a deserialize_channel.  Both branches log a warning
	# and continue — the panel UI restore above is the load-bearing step.
	if def.project_file_deserialize_channel.is_empty():
		push_warning(
			("[EditorContainer] deserialize: plugin '%s' has no " +
			"project_file.deserialize_channel — server-side state not restored.") %
			plugin_id
		)
		return

	var conn: MCPServerConnection = _get_plugin_connection_static(plugin_id)
	if conn == null:
		push_warning(
			("[EditorContainer] deserialize: plugin '%s' is not running; " +
			"server-side state not restored (UI was restored from __panel_state).") %
			plugin_id
		)
		return

	var call_result = await conn.call_tool(
		def.project_file_deserialize_channel,
		{
			"tab_state": payload,
			"stored_version": stored_version,
		}
	)

	if call_result is Dictionary and call_result.get("isError", false):
		push_warning(
			("[EditorContainer] deserialize: plugin '%s' deserialize_channel returned " +
			"an error: %s") % [plugin_id, str(call_result)]
		)


## Ensure that every plugin referenced by a PLUGIN_SCENE entry in `entries`
## is RUNNING.  Plugins not yet running are started; the function awaits each
## one's handshake (with a per-plugin timeout) so subsequent deserialize_channel
## dispatches find a live connection.
##
## Plugins not installed are skipped with a warning — the per-tab deserialize
## will surface its own placeholder for missing plugins.  Plugins in CRASH_LOOP
## are also skipped (start_plugin would refuse anyway).
static func _ensure_plugins_running_for_entries(entries: Array) -> void:
	var pm = SingletonObject.get("plugin_manager") if "plugin_manager" in SingletonObject else null
	if pm == null:
		return
	var db = pm.get_db()
	if db == null:
		return

	var plugins_needed: Dictionary = {}
	for entry in entries:
		if not (entry is Dictionary):
			continue
		if entry.get("type") != Editor.Type.PLUGIN_SCENE:
			continue
		var pid: String = entry.get("plugin_id", "")
		if not pid.is_empty():
			plugins_needed[pid] = true

	for pid in plugins_needed:
		var def: PluginDefinition = db.get_by_id(pid)
		if def == null:
			push_warning(
				("[EditorContainer] deserialize: plugin '%s' referenced by a tab " +
				"is not installed; tab will show install placeholder.") % pid
			)
			continue
		if def.state == PluginDefinition.State.RUNNING:
			continue
		if def.state == PluginDefinition.State.STARTING:
			await _wait_for_plugin_ready(pid, 5000)
			continue
		var result: Dictionary = await pm.start_plugin(pid)
		if result.has("error"):
			push_warning(
				("[EditorContainer] deserialize: failed to start plugin '%s': %s") %
				[pid, str(result.get("error", ""))]
			)
			continue
		await _wait_for_plugin_ready(pid, 5000)


## Poll the plugin's state until it is RUNNING (return true) or transitions
## to ERROR / CRASH_LOOP (return false), with `timeout_ms` overall budget.
## Returns false on timeout.
static func _wait_for_plugin_ready(plugin_id: String, timeout_ms: int) -> bool:
	var pm = SingletonObject.get("plugin_manager") if "plugin_manager" in SingletonObject else null
	if pm == null:
		return false
	var db = pm.get_db()
	if db == null:
		return false
	var start_ms: int = Time.get_ticks_msec()
	while Time.get_ticks_msec() - start_ms < timeout_ms:
		var def: PluginDefinition = db.get_by_id(plugin_id)
		if def == null:
			return false
		if def.state == PluginDefinition.State.RUNNING:
			return true
		if def.state == PluginDefinition.State.ERROR or def.state == PluginDefinition.State.CRASH_LOOP:
			return false
		await SingletonObject.editor_container.get_tree().create_timer(0.1).timeout
	return false


## Restore the panel's __panel_state via the host_owned _on_panel_load_request
## hook.  Server-independent — runs whether or not the plugin process is alive.
##
## During project deserialize the editor isn't yet in the live tree
## (ProjectMenuActions adds it AFTER EditorContainer.deserialize() returns),
## which means the panel root's _ready hasn't fired and its child node
## refs are still null.  Calling _on_panel_load_request now would no-op
## because plugin scenes typically guard against null fields.  Defer via
## the ready signal — _on_panel_loaded was wired via the same pattern in
## PluginScenePanelHost.instantiate_into and was connected EARLIER, so it
## fires first when the signal emits.  Restore lands after the panel
## paints its initial state.
static func _restore_panel_state(editor_inst: Editor, payload: Dictionary) -> void:
	var panel_state = payload.get("__panel_state", null)
	if not (panel_state is Dictionary):
		return
	if editor_inst.plugin_scene_root == null:
		return
	var panel_root: Control = editor_inst.plugin_scene_root
	if not panel_root.has_method("_on_panel_load_request"):
		return
	if panel_root.is_node_ready():
		panel_root._on_panel_load_request(panel_state)
	else:
		panel_root.ready.connect(func() -> void:
			if is_instance_valid(panel_root):
				panel_root._on_panel_load_request(panel_state)
		, CONNECT_ONE_SHOT)


## Return a PluginDefinition for the given plugin_id, or null.
## Delegates to the static variant so it can be called from the instance context too.
func _get_plugin_def(plugin_id: String) -> PluginDefinition:
	return _get_plugin_def_static(plugin_id)


## Return a PluginDefinition for the given plugin_id via the singleton's plugin_manager.
## Null-safe at every step — returns null when the plugin system is not initialised.
static func _get_plugin_def_static(plugin_id: String) -> PluginDefinition:
	var pm = SingletonObject.get("plugin_manager") if "plugin_manager" in SingletonObject else null
	if pm == null:
		return null
	var db = pm.get_db()
	if db == null:
		return null
	return db.get_by_id(plugin_id)


## Return the live MCPServerConnection for a plugin, or null.
func _get_plugin_connection(plugin_id: String) -> MCPServerConnection:
	return _get_plugin_connection_static(plugin_id)


## Return the live MCPServerConnection for a plugin, or null.
## Only returns non-null when the plugin is in RUNNING state.
static func _get_plugin_connection_static(plugin_id: String) -> MCPServerConnection:
	var pm = SingletonObject.get("plugin_manager") if "plugin_manager" in SingletonObject else null
	if pm == null:
		return null
	var db = pm.get_db()
	if db == null:
		return null
	var def: PluginDefinition = db.get_by_id(plugin_id)
	if def == null or def.state != PluginDefinition.State.RUNNING:
		return null
	return pm.get_connection(plugin_id)


## Show a placeholder label inside the editor's VBox (used when a plugin is
## unavailable during deserialize — design §8.3, §12).
static func _show_placeholder(editor_inst: Editor, message: String) -> void:
	var vbox = editor_inst.get_node_or_null("VBoxContainer")
	if vbox == null:
		push_warning("[EditorContainer] _show_placeholder: VBoxContainer not found")
		return
	var lbl := Label.new()
	lbl.text = message
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(lbl)


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
	## Determine file type.
	##
	## Resolution order (design §7.3):
	##   1. Core extension table (graphics, minpcb, minkb, minsheet, text)
	##   2. PluginEditorRegistry (plugin-contributed extensions)
	##   3. Fallback to TEXT
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
		# Check plugin registry before falling back to TEXT (design §7.3).
		var ext: String = "." + filename.get_extension().to_lower()
		var reg = SingletonObject.get("plugin_editor_registry") if "plugin_editor_registry" in SingletonObject else null
		var panel_info: Dictionary = reg.resolve_extension(ext) if reg != null else {}
		if not panel_info.is_empty():
			var p_id: String = panel_info.get("plugin_id", "")
			var p_name: String = panel_info.get("panel_name", "")
			# Use add_plugin_scene_editor() which sets plugin_id/panel_name on the
			# Editor node BEFORE Editor.create() reads them.
			editor_pane.add_plugin_scene_editor(p_id, p_name, filename)
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
	## Show a popup menu of all registered creatable items near the mouse cursor.
	var items := SingletonObject.creatable_item_registry.get_all_items()
	if items.is_empty():
		return

	var popup := PopupMenu.new()
	add_child(popup)
	for item in items:
		if item.icon:
			popup.add_icon_item(item.icon, item.display_name)
		else:
			popup.add_item(item.display_name)

	popup.index_pressed.connect(func(index: int) -> void:
		var current_items := SingletonObject.creatable_item_registry.get_all_items()
		if index >= 0 and index < current_items.size():
			current_items[index].create_callback.call()
	)
	popup.popup_hide.connect(popup.queue_free)

	var mouse_pos := get_viewport().get_mouse_position()
	popup.popup(Rect2i(int(mouse_pos.x), int(mouse_pos.y), 0, 0))


func _on_add_package_editor_pressed() -> void:
	SingletonObject.editor_container.editor_pane.add(Editor.Type.PACKAGE)


func _on_add_many_new_files_editor_pressed() -> void:
	%ManyNewFilesDialogWindow.popup()

class_name MCPEditorTools
extends MCPToolModule
## MCP tool module for Editor and Graphics domain tools.
## Handles text/graphics editor creation, content management, and AI image generation.


func get_tool_names() -> Array[String]:
	return [
		"minerva_create_text_editor",
		"minerva_create_graphics_editor",
		"minerva_get_editor_content",
		"minerva_update_editor",
		"minerva_save_editor",
		"minerva_close_editor",
		"minerva_list_editors",
		"minerva_rename_editor",
		"minerva_graphics_get_capabilities",
		"minerva_graphics_generate",
		"minerva_graphics_generate_iterative",
		"minerva_graphics_export_png",
	]


func register_tools() -> void:
	server._register_tool("minerva_create_text_editor",
		"Create a new text/code editor tab. For path-backed editing prefer passing file_path here, then drive content via minerva_doc_read / minerva_doc_write / minerva_doc_edit / minerva_doc_save (path-canonical buffer). For unbacked scratchpads (no file_path), use minerva_update_editor / minerva_get_editor_content / minerva_save_editor — the editor_*-keyed scratchpad API.",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Name for the editor tab"
				},
				"content": {
					"type": "string",
					"description": "Optional initial content"
				},
				"file_path": {
					"type": "string",
					"description": "Optional file path to associate with the editor"
				}
			},
			"required": ["name"]
		}
	, "editor")

	server._register_tool("minerva_create_graphics_editor",
		"Create a new graphics editor tab for image editing. Next steps: use minerva_graphics_generate or minerva_graphics_generate_iterative to create images.",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Name for the editor tab"
				},
				"file_path": {
					"type": "string",
					"description": "Optional file path to load an image from"
				}
			},
			"required": ["name"]
		}
	, "editor")

	server._register_tool("minerva_get_editor_content",
		"Read the in-memory text of an unbacked / scratchpad editor (no file_path). For path-backed editors prefer minerva_doc_read keyed on file_path. Returns the buffer's text when a file_path is associated; falls back to the editor's in-memory text otherwise.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the editor tab"
				}
			},
			"required": ["editor_name"]
		}
	, "editor")

	server._register_tool("minerva_update_editor",
		"Set the in-memory text of an unbacked / scratchpad editor (no file_path). For path-backed editors prefer minerva_doc_write or minerva_doc_edit keyed on file_path. Disk is NOT modified — pair with minerva_save_editor (or for path-backed editors, minerva_doc_save) to flush.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the editor tab"
				},
				"content": {
					"type": "string",
					"description": "New content for the editor"
				}
			},
			"required": ["editor_name", "content"]
		}
	, "editor")

	server._register_tool("minerva_save_editor",
		"Save an unbacked / scratchpad editor to disk — pass file_path to bind the tab to a location (\"save as\"). For path-backed editors prefer minerva_doc_save keyed on file_path. When the editor already has a file_path, this flushes the buffer to that path.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the editor tab"
				},
				"file_path": {
					"type": "string",
					"description": "Optional file path. If not specified, uses the associated file."
				}
			},
			"required": ["editor_name"]
		}
	, "editor")

	server._register_tool("minerva_close_editor",
		"Close an editor tab. Requires editor_name from minerva_list_editors.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the editor tab to close"
				},
				"force": {
					"type": "boolean",
					"description": "If true, close without prompting for unsaved changes"
				}
			},
			"required": ["editor_name"]
		}
	, "editor")

	server._register_tool("minerva_list_editors",
		"List all open editor tabs (text, graphics, and spreadsheet editors).",
		{
			"type": "object",
			"properties": {},
			"required": []
		}
	, "editor")

	server._register_tool("minerva_rename_editor",
		"Rename an editor tab (text, graphics, or spreadsheet).",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Current name/title of the editor tab"
				},
				"new_name": {
					"type": "string",
					"description": "New name for the editor tab"
				}
			},
			"required": ["editor_name", "new_name"]
		}
	, "editor")

	# Graphics editor AI tools
	server._register_tool("minerva_graphics_get_capabilities",
		"Get available AI models, actions, and parameters for a graphics editor. Call this before generating images to discover what's available.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the graphics editor tab"
				}
			},
			"required": ["editor_name"]
		}
	, "editor")

	server._register_tool("minerva_graphics_generate",
		"Generate or edit an image using AI (fire-and-forget, returns immediately). NOTE: If you need to SEE the result or ITERATE based on quality, use minerva_graphics_generate_iterative instead - it blocks until the image is visible. This tool is only for when you don't need to evaluate the output. Requires editor_name from minerva_list_editors.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the graphics editor tab"
				},
				"model": {
					"type": "string",
					"description": "Model ID from capabilities (e.g., 'z_turbo', 'qwen', 'qwen_2511_flex')"
				},
				"action": {
					"type": "string",
					"description": "Action ID: 'create', 'edit', 'mask_edit', 'compose_2', or 'compose_3'"
				},
				"prompt": {
					"type": "string",
					"description": "Positive prompt describing what to generate"
				},
				"negative_prompt": {
					"type": "string",
					"description": "Optional: what to avoid in generation"
				},
				"width": {
					"type": "integer",
					"description": "Image width (64-2048, divisible by 64). Default: 1024"
				},
				"height": {
					"type": "integer",
					"description": "Image height (64-2048, divisible by 64). Default: 1024"
				},
				"steps": {
					"type": "integer",
					"description": "Generation steps (more = higher quality). Default varies by model."
				},
				"source_layer": {
					"type": "string",
					"description": "Layer name for 'edit' and 'mask_edit' actions"
				},
				"mask_layer": {
					"type": "string",
					"description": "Mask layer name for 'mask_edit' action"
				},
				"image1_layer": {
					"type": "string",
					"description": "First image layer name for 'edit' (qwen_2511_flex) or 'compose_2'/'compose_3' actions"
				},
				"image2_layer": {
					"type": "string",
					"description": "Second image layer name for 'compose_2' or 'compose_3' actions"
				},
				"image3_layer": {
					"type": "string",
					"description": "Third image layer name for 'compose_3' action"
				}
			},
			"required": ["editor_name", "model", "action", "prompt"]
		}
	, "editor")

	server._register_tool("minerva_graphics_generate_iterative",
		"Generate an image with iterative refinement. This tool BLOCKS until the image is fully generated and visible, then returns. After it returns, the new image is visible and you can evaluate it immediately. Use for iterative refinement where you need to see each result before deciding to continue.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the graphics editor tab"
				},
				"model": {
					"type": "string",
					"description": "Model ID from capabilities (e.g., 'z_turbo', 'qwen', 'qwen_2511_flex')"
				},
				"action": {
					"type": "string",
					"description": "Action ID: 'create', 'edit', 'mask_edit', 'compose_2', or 'compose_3'"
				},
				"prompt": {
					"type": "string",
					"description": "Positive prompt describing what to generate"
				},
				"negative_prompt": {
					"type": "string",
					"description": "Optional: what to avoid in generation"
				},
				"width": {
					"type": "integer",
					"description": "Image width (64-2048, divisible by 64). Default: 1024"
				},
				"height": {
					"type": "integer",
					"description": "Image height (64-2048, divisible by 64). Default: 1024"
				},
				"steps": {
					"type": "integer",
					"description": "Generation steps (more = higher quality). Default varies by model."
				},
				"criteria": {
					"type": "string",
					"description": "Success criteria to evaluate against (e.g., 'full front view of star-fighter')"
				},
				"source_layer": {
					"type": "string",
					"description": "Layer name for 'edit' and 'mask_edit' actions"
				},
				"image1_layer": {
					"type": "string",
					"description": "First image layer name for 'edit' (qwen_2511_flex) or 'compose_2'/'compose_3' actions"
				},
				"image2_layer": {
					"type": "string",
					"description": "Second image layer name for 'compose_2' or 'compose_3' actions"
				},
				"image3_layer": {
					"type": "string",
					"description": "Third image layer name for 'compose_3' action"
				}
			},
			"required": ["editor_name", "model", "action", "prompt", "criteria"]
			# Note: iteration is tracked SERVER-SIDE. Do not pass iteration parameter.
		}
	, "editor")

	server._register_tool("minerva_graphics_export_png",
		"Flatten the graphics editor's layers and write the composite as a PNG file to disk. Use after minerva_graphics_generate_iterative when you need the bytes on disk (e.g. to feed another pipeline). file_path must be absolute; parent dir must exist.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the graphics editor tab"
				},
				"file_path": {
					"type": "string",
					"description": "Absolute output path ending in .png. Parent directory must exist; existing file is overwritten."
				}
			},
			"required": ["editor_name", "file_path"]
		}
	, "editor")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_create_text_editor":
			return _create_text_editor(arguments)
		"minerva_create_graphics_editor":
			return _create_graphics_editor(arguments)
		"minerva_get_editor_content":
			return _get_editor_content(arguments)
		"minerva_update_editor":
			return _update_editor(arguments)
		"minerva_save_editor":
			return _save_editor(arguments)
		"minerva_close_editor":
			return _close_editor(arguments)
		"minerva_list_editors":
			return _list_editors(arguments)
		"minerva_rename_editor":
			return _rename_editor(arguments)
		"minerva_graphics_get_capabilities":
			return _get_graphics_capabilities(arguments)
		"minerva_graphics_generate":
			return _generate_graphics(arguments)
		"minerva_graphics_generate_iterative":
			return await _generate_graphics_iterative(arguments)
		"minerva_graphics_export_png":
			return _export_graphics_png(arguments)
	return MCPToolUtils.error("Tool '%s' not implemented in MCPEditorTools" % tool_name)


#region Handler Functions

func _create_text_editor(args: Dictionary) -> Dictionary:
	var name_: String = args.get("name", "Untitled")
	var content: String = args.get("content", "")
	var file_path: String = args.get("file_path", "")

	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return MCPToolUtils.error("Editor pane not available")

	# Before creating, check if resource with same name exists
	# If it does, return it with already_existed: true
	if not name_.is_empty():
		var existing_editor = MCPToolUtils.find_editor_by_name(name_)
		if existing_editor:
			return {"success": true, "already_existed": true, "editor_name": existing_editor.tab_title}

	# Check if file exists when file_path is provided
	if not file_path.is_empty() and not FileAccess.file_exists(file_path):
		return MCPToolUtils.error("File not found: %s" % file_path)

	# Create the editor
	var EditorGDScript = load("res://Scripts/UI/Controls/Editor.gd")
	var file_arg: Variant = null
	if not file_path.is_empty():
		file_arg = file_path
	var editor = editor_pane.add(EditorGDScript.Type.TEXT, file_arg, name_, null)

	# Set content if provided
	if not content.is_empty() and editor.code_edit:
		editor.code_edit.text = content

	return {
		"success": true,
		"editor_name": editor.tab_title
	}


func _create_graphics_editor(args: Dictionary) -> Dictionary:
	var name_: String = args.get("name", "Graphics")
	var file_path: String = args.get("file_path", "")

	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return MCPToolUtils.error("Editor pane not available")

	# Before creating, check if resource with same name exists
	# If it does, return it with already_existed: true
	if not name_.is_empty():
		var existing_editor = MCPToolUtils.find_editor_by_name(name_)
		if existing_editor:
			return {"success": true, "already_existed": true, "editor_name": existing_editor.tab_title}

	# Check if file exists when file_path is provided
	if not file_path.is_empty() and not FileAccess.file_exists(file_path):
		return MCPToolUtils.error("File not found: %s" % file_path)

	# Create the graphics editor
	var EditorGDScript = load("res://Scripts/UI/Controls/Editor.gd")
	var file_arg: Variant = null
	if not file_path.is_empty():
		file_arg = file_path
	var editor = editor_pane.add(EditorGDScript.Type.GRAPHICS, file_arg, name_, null)

	return {
		"success": true,
		"editor_name": editor.tab_title
	}


func _get_editor_content(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")

	var editor = MCPToolUtils.find_editor_by_name(editor_name)
	if not editor:
		return MCPToolUtils.error("Editor not found: %s" % editor_name)

	var EditorGDScript = load("res://Scripts/UI/Controls/Editor.gd")
	if editor.type != EditorGDScript.Type.TEXT:
		return MCPToolUtils.error("Not a text editor")

	if not editor.code_edit:
		return MCPToolUtils.error("Editor has no code_edit")

	# Buffer-canonical: prefer the document registry's text when the editor has
	# a file_path. Fall back to the editor's in-memory text for untitled buffers
	# and for the migration window before Task 4 wires the editor to the registry.
	var file_path: String = editor.file if "file" in editor else ""
	if not file_path.is_empty():
		var registry := DocumentRegistry.get_instance()
		var br := registry.get_or_create_buffer(file_path)
		if br.ok:
			return {
				"success": true,
				"editor_name": editor_name,
				"content": (br.buffer as DocumentBuffer).text,
			}

	return {
		"success": true,
		"editor_name": editor_name,
		"content": editor.code_edit.text,
	}


func _update_editor(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var content: String = args.get("content", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")

	var editor = MCPToolUtils.find_editor_by_name(editor_name)
	if not editor:
		return MCPToolUtils.error("Editor not found: %s" % editor_name)

	var EditorGDScript = load("res://Scripts/UI/Controls/Editor.gd")
	if editor.type != EditorGDScript.Type.TEXT:
		return MCPToolUtils.error("Not a text editor")

	if not editor.code_edit:
		return MCPToolUtils.error("Editor has no code_edit")

	# Buffer-canonical: write through the document registry when a file_path is
	# associated. Mirror to editor.code_edit so the visible UI stays in sync
	# during the migration window (Task 4 wires the editor to the registry).
	var file_path: String = editor.file if "file" in editor else ""
	if not file_path.is_empty():
		var registry := DocumentRegistry.get_instance()
		var br := registry.get_or_create_buffer(file_path)
		if br.ok:
			(br.buffer as DocumentBuffer).apply_edit(content)

	editor.code_edit.text = content
	# Setting `text =` does not emit text_changed; emit explicitly so downstream
	# wiring (annotation revision bump, content_changed, etc.) sees the edit.
	editor.code_edit.text_changed.emit()

	return {
		"success": true,
		"message": "Editor content updated"
	}


func _save_editor(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var file_path: String = args.get("file_path", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")

	var editor = MCPToolUtils.find_editor_by_name(editor_name)
	if not editor:
		return MCPToolUtils.error("Editor not found: %s" % editor_name)

	# Set file path if provided
	if not file_path.is_empty():
		editor.file = file_path

	if editor.file.is_empty():
		return MCPToolUtils.error("No file path specified")

	# Buffer-canonical: mirror the editor's current visible text into the registry
	# (until Task 4 wires the editor to attach directly), then flush via doc_save.
	# This preserves "save what the user sees" while routing all writes through
	# the registry layer.
	var registry := DocumentRegistry.get_instance()
	var br := registry.get_or_create_buffer(editor.file)
	if br.ok and editor.code_edit:
		(br.buffer as DocumentBuffer).apply_edit(editor.code_edit.text)
		var save_r: Dictionary = (br.buffer as DocumentBuffer).save_to_disk()
		if not save_r.ok:
			return MCPToolUtils.error(save_r.error)
	else:
		# Fallback: editor.save() handles cases where registry can't allocate a buffer.
		editor.save()

	return {
		"success": true,
		"file_path": editor.file
	}


func _close_editor(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var force: bool = args.get("force", false)

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")

	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return MCPToolUtils.error("Editor pane not available")

	var editor = MCPToolUtils.find_editor_by_name(editor_name)
	if not editor:
		return MCPToolUtils.error("Editor not found: %s" % editor_name)

	var tab_idx = editor_pane.Tabs.get_tab_idx_from_control(editor)
	if tab_idx == -1:
		return MCPToolUtils.error("Editor not in tab container")

	# Check for unsaved content
	if not force and not editor.is_content_saved():
		return {
			"error": "Editor has unsaved content. Use force=true to close anyway.",
			"success": false,
			"has_unsaved_content": true
		}

	# Close the tab
	editor_pane.Tabs.remove_child(editor)

	return {"success": true, "message": "Editor closed"}


func _list_editors(_args: Dictionary) -> Dictionary:
	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return MCPToolUtils.error("Editor pane not available")

	var EditorGDScript = load("res://Scripts/UI/Controls/Editor.gd")
	var editors: Array[Dictionary] = []

	for i in range(editor_pane.Tabs.get_tab_count()):
		var editor = editor_pane.Tabs.get_tab_control(i)
		var tab_title = editor_pane.Tabs.get_tab_title(i)

		var editor_type: String = "unknown"
		if editor.has_method("get") and "type" in editor:
			match editor.type:
				EditorGDScript.Type.TEXT:
					editor_type = "text"
				EditorGDScript.Type.GRAPHICS:
					editor_type = "graphics"
				EditorGDScript.Type.SPREADSHEET:
					editor_type = "spreadsheet"
				EditorGDScript.Type.PCB:
					editor_type = "pcb"

		var editor_info: Dictionary = {
			"name": tab_title,
			"type": editor_type,
			"index": i
		}

		# Add file path if available
		if "file" in editor and editor.file:
			editor_info["file_path"] = editor.file

		# Add saved status if available
		if editor.has_method("is_content_saved"):
			editor_info["saved"] = editor.is_content_saved()

		editors.append(editor_info)

	return {
		"success": true,
		"count": editors.size(),
		"editors": editors
	}


func _rename_editor(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var new_name: String = args.get("new_name", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")

	if new_name.is_empty():
		return MCPToolUtils.error("new_name is required")

	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return MCPToolUtils.error("Editor pane not available")

	# Find the editor by name
	for i in range(editor_pane.Tabs.get_tab_count()):
		var tab_title = editor_pane.Tabs.get_tab_title(i)
		if tab_title == editor_name:
			editor_pane.Tabs.set_tab_title(i, new_name)
			# Also update the editor's tab_title property
			var editor_control = editor_pane.Tabs.get_tab_control(i)
			if editor_control and editor_control is Editor:
				editor_control.tab_title = new_name
			return {
				"success": true,
				"old_name": editor_name,
				"new_name": new_name,
				"message": "Editor renamed from '%s' to '%s'" % [editor_name, new_name]
			}

	return MCPToolUtils.error("Editor not found: %s" % editor_name)


func _get_graphics_capabilities(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")

	var editor = MCPToolUtils.find_editor_by_name(editor_name)
	if not editor:
		return MCPToolUtils.error("Editor not found: %s" % editor_name)

	var EditorGDScript = load("res://Scripts/UI/Controls/Editor.gd")
	if editor.type != EditorGDScript.Type.GRAPHICS:
		return MCPToolUtils.error("Not a graphics editor: %s" % editor_name)

	if not editor.graphics_editor:
		return MCPToolUtils.error("Graphics editor not initialized")

	return editor.graphics_editor.get_ai_capabilities()


func _generate_graphics(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")

	var editor = MCPToolUtils.find_editor_by_name(editor_name)
	if not editor:
		return MCPToolUtils.error("Editor not found: %s" % editor_name)

	var EditorGDScript = load("res://Scripts/UI/Controls/Editor.gd")
	if editor.type != EditorGDScript.Type.GRAPHICS:
		return MCPToolUtils.error("Not a graphics editor: %s" % editor_name)

	if not editor.graphics_editor:
		return MCPToolUtils.error("Graphics editor not initialized")

	var result = editor.graphics_editor.execute_ai_action(args)

	# Add warning that image won't be visible to LLM (non-iterative is fire-and-forget)
	if result.get("success", false):
		result["warning"] = "IMPORTANT: This is the non-iterative tool. The generated image will NOT be visible to you (the LLM). You cannot evaluate or describe this image. If you need to see and evaluate the result, use minerva_graphics_generate_iterative instead."
		result["image_visible"] = false

	return result


func _generate_graphics_iterative(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var max_iterations: int = SingletonObject.max_image_iterations
	var criteria: String = args.get("criteria", "")

	# SESSION-WIDE iteration tracking (prevents bypass via creating new editors)
	var reset_threshold := 5 * 60 * 1000  # Reset after 5 minutes of inactivity
	var iteration: int = server.consume_session_iterative_attempt(reset_threshold)

	print("[MCPEditorTools] Iterative generation: %d/%d (session-wide)" % [iteration, max_iterations])

	# Check iteration limit (session-enforced)
	if iteration > max_iterations:
		# Reset for next session
		server.reset_session_iterative_attempts()
		return {
			"error": "Maximum iterations (%d) reached for this session. Creating new editors will NOT bypass this limit. You must accept the current result or ask the user to increase the limit in settings." % max_iterations,
			"success": false,
			"iteration": iteration,
			"max_iterations": max_iterations
		}

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")

	var editor = MCPToolUtils.find_editor_by_name(editor_name)
	if not editor:
		return MCPToolUtils.error("Editor not found: %s" % editor_name)

	var EditorGDScript = load("res://Scripts/UI/Controls/Editor.gd")
	if editor.type != EditorGDScript.Type.GRAPHICS:
		return MCPToolUtils.error("Not a graphics editor: %s" % editor_name)

	if not editor.graphics_editor:
		return MCPToolUtils.error("Graphics editor not initialized")

	# Start generation
	var result = editor.graphics_editor.execute_ai_action(args)
	print("[MCPEditorTools] execute_ai_action result: %s" % str(result))
	if not result.get("success"):
		print("[MCPEditorTools] Generation failed: %s" % result.get("error", "unknown"))
		return result

	var request_id: String = result.get("request_id", "")
	print("[MCPEditorTools] Waiting for image generation to complete (blocking): %s" % request_id)

	# === BLOCKING: Wait for image generation to complete ===
	var image_state := {"completed": false, "received_id": ""}
	var image_handler := func(_fname: String, rid: String, _buffer: PackedByteArray):
		if rid == request_id:
			image_state.completed = true
			image_state.received_id = rid
			print("[MCPEditorTools] Image generation signal received for: %s" % rid)

	MediaGen.pass_image_to_editor.connect(image_handler)

	# Wait for image with timeout (4 minutes for slow generation backends)
	var image_timeout := 240.0
	var image_elapsed := 0.0
	while not image_state.completed and image_elapsed < image_timeout:
		await Engine.get_main_loop().create_timer(0.2).timeout
		image_elapsed += 0.2

	# Disconnect the handler
	if MediaGen.pass_image_to_editor.is_connected(image_handler):
		MediaGen.pass_image_to_editor.disconnect(image_handler)

	if not image_state.completed:
		push_error("[MCPEditorTools] Timeout waiting for image generation")
		return MCPToolUtils.error("Image generation timed out after %.0f seconds" % image_timeout)

	print("[MCPEditorTools] Image generated after %.1f seconds, now preparing for display..." % image_elapsed)

	# Wait for graphics editor to process the image buffer
	await Engine.get_main_loop().create_timer(0.5).timeout

	# === BLOCKING: Wait for note to be ready ===
	if not editor or not is_instance_valid(editor):
		return MCPToolUtils.error("Editor no longer valid")

	# Capture the user's pre-call toggle state so we can restore it on every
	# return path below. Without this, the trailing `editor.toggle(true)` at
	# the end of this function leaks "inject into next chat" state into
	# subsequent unrelated turns when the user had it OFF (RCA: persistent UI
	# toggle was being reused as a transient visibility hook).
	var prior_inject_state: bool = editor._note_check_button.button_pressed if editor._note_check_button != null else false

	# Toggle OFF first to clean up any existing state
	print("[MCPEditorTools] Toggling OFF to clean up existing state...")
	editor.toggle(false)

	# Wait for proxy to be fully cleaned up (event-driven, not arbitrary timeout)
	var cleanup_start := Time.get_ticks_msec()
	while editor._proxy_note != null:
		await Engine.get_main_loop().process_frame
		if Time.get_ticks_msec() - cleanup_start > 5000:  # 5s safety timeout
			push_warning("[MCPEditorTools] Proxy cleanup taking too long, proceeding anyway")
			break

	print("[MCPEditorTools] Cleanup complete, setting up signal handler...")

	# === BLOCKING: Wait for note to be ready (using same pattern as image wait) ===
	# Connect handler BEFORE toggle to ensure we don't miss the signal
	var note_state := {"received": false, "note": null}
	var note_handler := func(note: Note):
		print("[MCPEditorTools] note_ready_for_chat handler fired! note=%s" % note)
		note_state["received"] = true
		note_state["note"] = note

	editor.note_ready_for_chat.connect(note_handler, CONNECT_ONE_SHOT)

	# Toggle ON - this triggers _on_check_button_toggled which creates the proxy and note
	editor.toggle(true)
	print("[MCPEditorTools] Toggled ON, waiting for note_ready_for_chat signal...")

	# Poll until note is ready or timeout (same pattern that works for image generation)
	var note_timeout := 120.0
	var note_elapsed := 0.0
	while not note_state["received"] and note_elapsed < note_timeout:
		await Engine.get_main_loop().create_timer(0.2).timeout
		note_elapsed += 0.2
		if int(note_elapsed) % 5 == 0 and note_elapsed > 0.3:
			print("[MCPEditorTools] Still waiting for note... %.1fs elapsed, state=%s" % [note_elapsed, note_state])

	# Clean up handler if we timed out
	if not note_state["received"]:
		if editor.note_ready_for_chat.is_connected(note_handler):
			editor.note_ready_for_chat.disconnect(note_handler)
		editor.toggle(prior_inject_state)
		push_error("[MCPEditorTools] Timeout waiting for note_ready_for_chat after %.0f seconds" % note_timeout)
		return MCPToolUtils.error("Note composition timed out after %.0f seconds" % note_timeout)

	var received_note = note_state["note"]
	print("[MCPEditorTools] Note ready! Received: %s" % received_note)

	if received_note == null:
		editor.toggle(prior_inject_state)
		push_error("[MCPEditorTools] note_ready_for_chat returned null")
		return MCPToolUtils.error("Note composition failed - received null note")

	print("[MCPEditorTools] Note ready after %.1f seconds. Total time: %.1f seconds" % [note_elapsed, image_elapsed + note_elapsed])

	# Restore the user's pre-call inject toggle state. The toggle ON above was
	# used as a one-shot visibility mechanism to feed the generated image into
	# the current LLM evaluation turn (via the proxy_note + note_ready_for_chat
	# plumbing). Leaving it ON would leak the image into every subsequent chat
	# turn, which is not what the tool advertises ("blocking until visible",
	# not "permanent injection"). Callers that DO want persistent injection
	# should explicitly toggle the editor's checkbox in the UI.
	editor.toggle(prior_inject_state)

	# === SUCCESS: Image is now visible to the LLM ===
	var response_msg: String
	if iteration < max_iterations:
		response_msg = "Image generation complete (iteration %d/%d). The image is now visible. Evaluate it against the criteria: '%s'. If it meets the criteria, inform the user. If not, call this tool again with an adjusted prompt (iteration is tracked automatically)." % [iteration, max_iterations, criteria]
	else:
		response_msg = "Image generation complete (FINAL iteration %d/%d). The image is now visible. This was the LAST allowed iteration for this session. Creating new editors or using other tools will NOT give you more attempts. Evaluate it against the criteria: '%s' and inform the user of the final result." % [iteration, max_iterations, criteria]

	return {
		"success": true,
		"message": response_msg,
		"iteration": iteration,
		"max_iterations": max_iterations,
		"image_visible": true
	}


func _export_graphics_png(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var file_path: String = args.get("file_path", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")
	if file_path.is_empty():
		return MCPToolUtils.error("file_path is required")
	if not file_path.is_absolute_path():
		return MCPToolUtils.error("file_path must be absolute: %s" % file_path)

	var editor = MCPToolUtils.find_editor_by_name(editor_name)
	if not editor:
		return MCPToolUtils.error("Editor not found: %s" % editor_name)

	var EditorGDScript = load("res://Scripts/UI/Controls/Editor.gd")
	if editor.type != EditorGDScript.Type.GRAPHICS:
		return MCPToolUtils.error("Not a graphics editor: %s" % editor_name)
	if not editor.graphics_editor:
		return MCPToolUtils.error("Graphics editor not initialized")

	# Pick the layer to export. Prefer active_layer if it's an IMAGE; otherwise
	# the first IMAGE layer in the editor's layers list. compose_final_image()
	# is intentionally avoided here — it goes through a worker thread + cache +
	# a popup-progress dialog that don't play well with headless MCP calls.
	var ge = editor.graphics_editor
	var picked = null
	if ge.active_layer and ge.active_layer.type == LayerV2.Type.IMAGE:
		picked = ge.active_layer
	else:
		for l in ge.layers:
			if l is LayerV2 and l.type == LayerV2.Type.IMAGE:
				picked = l
				break
	if not picked:
		return MCPToolUtils.error("No IMAGE layer found in editor: %s" % editor_name)
	var img: Image = picked.image
	if img == null or img.is_empty():
		return MCPToolUtils.error("Picked layer has no image data: %s" % picked.name)

	var err: int = img.save_png(file_path)
	if err != OK:
		return MCPToolUtils.error("save_png failed: err=%d path=%s" % [err, file_path])
	if not FileAccess.file_exists(file_path):
		return MCPToolUtils.error("save_png reported OK but file missing: %s" % file_path)

	return {
		"success": true,
		"editor_name": editor_name,
		"file_path": file_path,
		"layer_name": picked.name,
		"bytes": FileAccess.get_file_as_bytes(file_path).size(),
	}

#endregion

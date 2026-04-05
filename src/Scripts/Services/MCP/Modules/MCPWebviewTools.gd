class_name MCPWebviewTools
extends MCPToolModule
## MCP tool module for Webview panel tools.
## Handles creating, updating, reading, and linking webview panels to notes.

const NoteScript := preload("res://Scripts/UI/Controls/Note.gd")


func get_tool_names() -> Array[String]:
	return [
		"minerva_create_webview_panel",
		"minerva_update_webview_panel",
		"minerva_get_webview_source",
		"minerva_link_webview_to_note",
	]


func register_tools() -> void:
	server._register_tool("minerva_create_webview_panel",
		"Creates a webview panel tab with HTML/CSS/JS content. The HTML is rendered in an isolated webview (fault-isolated from Minerva). After creating, use minerva_update_webview_panel to modify content, or minerva_get_webview_source to read current HTML.",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Display name for the webview panel tab"
				},
				"html": {
					"type": "string",
					"description": "HTML content to render in the webview"
				}
			},
			"required": ["name", "html"]
		}
	, "webview")

	server._register_tool("minerva_update_webview_panel",
		"Replace the HTML content in an existing webview panel. Supports iterative development -- generate, view, refine.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the webview panel tab"
				},
				"html": {
					"type": "string",
					"description": "New HTML content to render"
				}
			},
			"required": ["editor_name", "html"]
		}
	, "webview")

	server._register_tool("minerva_get_webview_source",
		"Get the current HTML source of a webview panel. Use to read what's rendered before making changes.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the webview panel tab"
				}
			},
			"required": ["editor_name"]
		}
	, "webview")

	server._register_tool("minerva_link_webview_to_note",
		"Create a linked note from a webview panel. The note displays the rendered HTML. Editing the note reopens the webview editor. Similar to minerva_link_spreadsheet_to_note.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "The name/title of the webview panel tab to link"
				},
				"note_title": {
					"type": "string",
					"description": "Title for the new note. Defaults to webview panel name if not provided"
				},
				"thread_name": {
					"type": "string",
					"description": "Name of the notes thread/tab to add the note to. Creates new thread if doesn't exist"
				}
			},
			"required": ["editor_name"]
		}
	, "webview")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_create_webview_panel": return _create_webview_panel(arguments)
		"minerva_update_webview_panel": return _update_webview_panel(arguments)
		"minerva_get_webview_source": return _get_webview_source(arguments)
		"minerva_link_webview_to_note": return _link_webview_to_note(arguments)
	return MCPToolUtils.error("Unknown tool: %s" % tool_name)


func _create_webview_panel(arguments: Dictionary) -> Dictionary:
	var panel_name: String = arguments.get("name", "")
	var html: String = arguments.get("html", "")
	if panel_name.is_empty() or html.is_empty():
		return MCPToolUtils.error("Both 'name' and 'html' are required")

	# Check if panel already exists (idempotency)
	var existing = MCPToolUtils.find_webview(panel_name)
	if existing:
		existing.webview_editor.set_html(html)
		return {"editor_name": panel_name, "message": "Webview panel updated (already existed).", "success": true, "already_existed": true}

	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return MCPToolUtils.error("Editor pane not available")

	var editor: Editor = editor_pane.add_webview_editor(panel_name)
	if editor and editor.webview_editor:
		editor.webview_editor.set_html(html)
		return {"editor_name": panel_name, "message": "Webview panel created.", "success": true}
	return MCPToolUtils.error("Failed to create webview panel")


func _update_webview_panel(arguments: Dictionary) -> Dictionary:
	var editor_name: String = arguments.get("editor_name", "")
	var html: String = arguments.get("html", "")
	if editor_name.is_empty() or html.is_empty():
		return MCPToolUtils.error("Both 'editor_name' and 'html' are required")
	var editor = MCPToolUtils.find_webview(editor_name)
	if not editor:
		return MCPToolUtils.error("Webview panel '%s' not found" % editor_name)
	editor.webview_editor.set_html(html)
	return {"editor_name": editor_name, "message": "Webview panel updated.", "success": true}


func _get_webview_source(arguments: Dictionary) -> Dictionary:
	var editor_name: String = arguments.get("editor_name", "")
	if editor_name.is_empty():
		return MCPToolUtils.error("'editor_name' is required")
	var editor = MCPToolUtils.find_webview(editor_name)
	if not editor:
		return MCPToolUtils.error("Webview panel '%s' not found" % editor_name)
	return {"editor_name": editor_name, "html": editor.webview_editor.get_html(), "success": true}


func _link_webview_to_note(arguments: Dictionary) -> Dictionary:
	var editor_name: String = arguments.get("editor_name", "")
	if editor_name.is_empty():
		return MCPToolUtils.error("'editor_name' is required")

	var webview_editor = MCPToolUtils.find_webview(editor_name)
	if not webview_editor:
		return MCPToolUtils.error("Webview panel '%s' not found" % editor_name)

	var html: String = webview_editor.webview_editor.get_html()
	if html.is_empty():
		return MCPToolUtils.error("Webview panel has no content")

	var note_title: String = arguments.get("note_title", editor_name)
	var thread_name: String = arguments.get("thread_name", "Webviews")

	var note = NoteScript.create_html_note(note_title, html)

	var notes_container = SingletonObject.notes_container
	if not notes_container:
		return MCPToolUtils.error("Notes container not available")

	var thread_vbox = notes_container.find_or_create_tab(thread_name)
	thread_vbox.add_note(note)

	return {
		"success": true,
		"note_uuid": note.uuid,
		"note_title": note_title,
		"thread_name": thread_name,
		"linked_webview": editor_name,
		"message": "Created linked HTML note '%s' in thread '%s'." % [note_title, thread_name]
	}

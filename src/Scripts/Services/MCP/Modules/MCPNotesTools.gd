class_name MCPNotesTools
extends MCPToolModule
## MCP tool module for the Notes domain.
## Handles creation, listing, editing, enabling/disabling, deletion,
## and chat-linking of notes and note tabs.

const NoteScript := preload("res://Scripts/UI/Controls/Note.gd")
const NotesContainerScript := preload("res://Scenes/note/NotesContainer.gd")

const TOOL_MEMORY_NOTE_TOOLS := {
	"minerva_list_agent_notes": true,
	"minerva_get_agent_note": true,
	"minerva_read_agent_note": true,
}


func get_tool_names() -> Array[String]:
	return [
		"minerva_create_note",
		"minerva_create_note_tab",
		"minerva_list_note_tabs",
		"minerva_list_notes",
		"minerva_list_agent_notes",
		"minerva_enable_notes",
		"minerva_disable_notes",
		"minerva_delete_note",
		"minerva_get_note",
		"minerva_get_agent_note",
		"minerva_read_agent_note",
		"minerva_update_note",
		"minerva_link_note_to_chat",
	]


func register_tools() -> void:
	server._register_tool("minerva_create_note",
		"Create a new note. Notes can be used as context/memory for LLM conversations. After creating, use minerva_update_note to modify content. The note is immediately available for LLM context if enabled.",
		{
			"type": "object",
			"properties": {
				"title": {
					"type": "string",
					"description": "Title of the note"
				},
				"content": {
					"type": "string",
					"description": "Content of the note. For html type, this is the HTML source."
				},
				"type": {
					"type": "string",
					"description": "Type of note: text or html. Defaults to text.",
					"enum": ["text", "html"]
				},
				"tab": {
					"type": "string",
					"description": "Optional tab name to add the note to. If not specified, uses current tab."
				}
			},
			"required": ["title", "content"]
		}
	, "notes")

	server._register_tool("minerva_create_note_tab",
		"Create a new notes tab. Next steps: use minerva_create_note to add notes to this tab.",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Name for the new tab"
				}
			},
			"required": ["name"]
		}
	, "notes")

	server._register_tool("minerva_list_note_tabs",
		"List all notes tabs with their names, ids, and note counts. Use before minerva_create_note when the caller wants to target a specific tab, or to discover empty tabs awaiting content.",
		{"type": "object", "properties": {}, "required": []}
	, "notes")

	server._register_tool("minerva_list_notes",
		"List all notes in a tab or all tabs. Each entry includes note_id, title, enabled, tab, and type (text/image/audio/video/html/plugin_data). Filter by type==\"image\" to find image notes.",
		{
			"type": "object",
			"properties": {
				"tab": {
					"type": "string",
					"description": "Optional tab name. If not specified, lists notes from all tabs."
				}
			},
			"required": []
		}
	, "notes")

	server._register_tool("minerva_list_agent_notes",
		"List hidden agent-note artifacts, optionally filtered to a specific chat. Returns note IDs, titles, and content sizes for hydration workflows.",
		{
			"type": "object",
			"properties": {
				"chat_id": {
					"type": "string",
					"description": "Optional HistoryId of the chat whose agent notes should be listed."
				}
			},
			"required": []
		}
	, "notes")

	server._register_tool("minerva_enable_notes",
		"Enable all notes in a tab (makes them active for LLM context).",
		{
			"type": "object",
			"properties": {
				"tab": {
					"type": "string",
					"description": "Tab name to enable notes in"
				}
			},
			"required": ["tab"]
		}
	, "notes")

	server._register_tool("minerva_disable_notes",
		"Disable all notes in a tab (excludes them from LLM context).",
		{
			"type": "object",
			"properties": {
				"tab": {
					"type": "string",
					"description": "Tab name to disable notes in"
				}
			},
			"required": ["tab"]
		}
	, "notes")

	server._register_tool("minerva_delete_note",
		"Delete a note by its ID. Requires note_id from minerva_list_notes.",
		{
			"type": "object",
			"properties": {
				"note_id": {
					"type": "string",
					"description": "The UUID of the note to delete"
				}
			},
			"required": ["note_id"]
		}
	, "notes")

	server._register_tool("minerva_get_note",
		"Get a note's full content by its ID. Returns title, content, tab, enabled status, and type. For image-backed notes (image/plugin_data) also returns image_path (a PNG exported to disk), image_width, image_height, and image_format so the actual image can be consumed. Requires note_id from minerva_list_notes.",
		{
			"type": "object",
			"properties": {
				"note_id": {
					"type": "string",
					"description": "The UUID of the note to read"
				}
			},
			"required": ["note_id"]
		}
	, "notes")

	server._register_tool("minerva_get_agent_note",
		"Get a hidden agent-note artifact by full ID or short prefix. Optionally restrict to a specific chat.",
		{
			"type": "object",
			"properties": {
				"note_id": {
					"type": "string",
					"description": "The UUID or unique short prefix of the agent note"
				},
				"chat_id": {
					"type": "string",
					"description": "Optional HistoryId to ensure the note belongs to a specific chat."
				}
			},
			"required": ["note_id"]
		}
	, "notes")

	server._register_tool("minerva_read_agent_note",
		"Read a windowed slice of an agent-note artifact by full ID or short prefix. Use offset/limit for large tool outputs.",
		{
			"type": "object",
			"properties": {
				"note_id": {
					"type": "string",
					"description": "The UUID or unique short prefix of the agent note"
				},
				"chat_id": {
					"type": "string",
					"description": "Optional HistoryId to ensure the note belongs to a specific chat."
				},
				"offset": {
					"type": "integer",
					"description": "Start character offset. Defaults to 0."
				},
				"limit": {
					"type": "integer",
					"description": "Maximum number of characters to return. Defaults to 4000, capped at 16000."
				}
			},
			"required": ["note_id"]
		}
	, "notes")

	server._register_tool("minerva_update_note",
		"Update a note's content and/or title in-place by its ID. Requires note_id from minerva_list_notes or minerva_create_note.",
		{
			"type": "object",
			"properties": {
				"note_id": {
					"type": "string",
					"description": "The UUID of the note to update"
				},
				"content": {
					"type": "string",
					"description": "New content for the note. If omitted, content is unchanged."
				},
				"title": {
					"type": "string",
					"description": "New title for the note. If omitted, title is unchanged."
				}
			},
			"required": ["note_id"]
		}
	, "notes")

	server._register_tool("minerva_link_note_to_chat",
		"Link or unlink a note to a specific chat. Linked notes only appear in that chat's prompts. Unlinking makes the note global (visible to all chats). Requires note_id from minerva_list_notes and chat_id from minerva_list_chats.",
		{
			"type": "object",
			"properties": {
				"note_id": {
					"type": "string",
					"description": "The UUID of the note to link/unlink"
				},
				"chat_id": {
					"type": "string",
					"description": "HistoryId of the chat to link to. If omitted, unlinks from all chats (makes global)."
				},
				"unlink": {
					"type": "boolean",
					"description": "If true, removes the link to the specified chat_id instead of adding it. Defaults to false."
				}
			},
			"required": ["note_id"]
		}
	, "notes")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	if TOOL_MEMORY_NOTE_TOOLS.has(tool_name) and not _tool_memory_optimization_enabled():
		return MCPToolUtils.error("Tool memory optimization is disabled")
	match tool_name:
		"minerva_create_note":
			return _create_note(arguments)
		"minerva_create_note_tab":
			return _create_note_tab(arguments)
		"minerva_list_note_tabs":
			return _list_note_tabs(arguments)
		"minerva_list_notes":
			return _list_notes(arguments)
		"minerva_list_agent_notes":
			return _list_agent_notes(arguments)
		"minerva_enable_notes":
			return _enable_notes(arguments)
		"minerva_disable_notes":
			return _disable_notes(arguments)
		"minerva_delete_note":
			return _delete_note(arguments)
		"minerva_get_note":
			return _get_note(arguments)
		"minerva_get_agent_note":
			return _get_agent_note(arguments)
		"minerva_read_agent_note":
			return _read_agent_note(arguments)
		"minerva_update_note":
			return _update_note(arguments)
		"minerva_link_note_to_chat":
			return _link_note_to_chat(arguments)
	return MCPToolUtils.error("Unknown tool: %s" % tool_name)


#region Tool Implementations

func _resolve_agent_note(note_id: String) -> Variant:
	if note_id.is_empty():
		return null

	var exact = SingletonObject.get_registered_object(note_id)
	if exact and exact is Note:
		return exact

	var container = SingletonObject.agent_notes_container
	if not container:
		return null

	var matches: Array[Note] = []
	for i in range(container.get_tab_count()):
		for note in container.get_notes(i):
			if note.uuid.begins_with(note_id):
				matches.append(note)

	if matches.size() == 1:
		return matches[0]
	return null


func _tool_memory_optimization_enabled() -> bool:
	if SingletonObject == null or SingletonObject.config_file == null:
		return false
	return bool(SingletonObject.config_file.get_value("ToolMemoryManager", "enabled", false))


func _note_text_content(note: Note) -> String:
	if not note:
		return ""
	var controls_container = note.get_controls_container()
	if controls_container is NoteTextControls:
		return controls_container.content
	return ""


func _type_name(note: Note) -> String:
	if note == null:
		return "UNKNOWN"
	return Note.Type.keys()[note.type] if note.type < Note.Type.size() else "UNKNOWN"


## For image-backed notes (IMAGE / PLUGIN_DATA / PCB) export the backing image as
## a PNG to a managed cache dir and return {image_path, image_width, image_height,
## image_format, caption}. Returns {} for notes without an image. The stable
## per-uuid path is overwritten on each call so the cache stays bounded.
func _export_note_image(note: Note) -> Dictionary:
	if note == null:
		return {}
	var controls = note.get_controls_container()
	if not (controls is NoteImageControls):
		return {}
	var img: Image = controls.image
	if img == null or img.is_empty():
		return {}
	var dir_path := OS.get_user_data_dir().path_join("plugin_note_images")
	DirAccess.make_dir_recursive_absolute(dir_path)
	var file_path := dir_path.path_join("%s.png" % note.uuid)
	var err := img.save_png(file_path)
	if err != OK:
		return {}
	return {
		"image_path": file_path,
		"image_width": img.get_width(),
		"image_height": img.get_height(),
		"image_format": "png",
		"caption": controls.caption,
	}


func _find_note_tab_name(container: NotesContainer, note_id: String) -> String:
	if not container:
		return ""
	for i in range(container.get_tab_count()):
		for candidate in container.get_notes(i):
			if candidate.uuid == note_id:
				return container.get_tab_title(i)
	return ""

func _create_note(args: Dictionary) -> Dictionary:
	var title: String = args.get("title", "Untitled")
	var content: String = args.get("content", "")
	var tab_name: String = args.get("tab", "")

	var notes_container = SingletonObject.notes_container
	if not notes_container:
		return MCPToolUtils.error("Notes container not available")

	# Create the note
	var note_type: String = args.get("type", "text")
	var note: Node
	match note_type:
		"html":
			note = NoteScript.create_html_note(title, content)
		_:
			note = NoteScript.create_text_note(title, content)

	# Find or create the tab
	var tab_idx := -1
	if not tab_name.is_empty():
		var note_vbox = notes_container.find_or_create_tab(tab_name)
		tab_idx = notes_container.get_tab_idx_from_control(note_vbox)

	# Add the note
	notes_container.add_note(note, tab_idx)

	return {
		"success": true,
		"note_id": note.uuid,
		"title": title
	}


func _create_note_tab(args: Dictionary) -> Dictionary:
	var name_: String = args.get("name", "Notes")

	var notes_container = SingletonObject.notes_container
	if not notes_container:
		return MCPToolUtils.error("Notes container not available")

	# Before creating, check if resource with same name exists
	# If it does, return it with already_existed: true
	if not name_.is_empty():
		var existing_vbox = notes_container.find_tab_by_name(name_)
		if existing_vbox:
			return {"success": true, "already_existed": true, "tab_name": name_, "tab_id": existing_vbox.uuid}

	var note_vbox = notes_container.create_tab(name_)
	var _tab_idx = notes_container.get_tab_idx_from_control(note_vbox)

	return {
		"success": true,
		"tab_name": name_,
		"tab_id": note_vbox.uuid
	}


func _list_note_tabs(_args: Dictionary) -> Dictionary:
	var notes_container = SingletonObject.notes_container
	if not notes_container:
		return MCPToolUtils.error("Notes container not available")

	var tabs: Array = []
	for i in range(notes_container.get_tab_count()):
		var tab_control = notes_container.get_tab_control(i)
		var tab_entry := {
			"name": notes_container.get_tab_title(i),
			"note_count": notes_container.get_notes(i).size(),
		}
		if tab_control and "uuid" in tab_control:
			tab_entry["id"] = tab_control.uuid
		tabs.append(tab_entry)

	return {"success": true, "tabs": tabs, "count": tabs.size()}


func _list_notes(args: Dictionary) -> Dictionary:
	var tab_name: String = args.get("tab", "")

	var notes_container = SingletonObject.notes_container
	if not notes_container:
		return MCPToolUtils.error("Notes container not available")

	var result: Array = []

	if tab_name.is_empty():
		# List all notes from all tabs
		for i in range(notes_container.get_tab_count()):
			var tab_title = notes_container.get_tab_title(i)
			var notes = notes_container.get_notes(i)
			for note in notes:
				result.append({
					"note_id": note.uuid,
					"title": note.title,
					"enabled": note.enabled,
					"tab": tab_title,
					"type": _type_name(note),
				})
	else:
		# List notes from specific tab
		var note_vbox = notes_container.find_tab_by_name(tab_name)
		if not note_vbox:
			return MCPToolUtils.error("Tab not found: %s" % tab_name)

		var tab_idx = notes_container.get_tab_idx_from_control(note_vbox)
		var notes = notes_container.get_notes(tab_idx)
		for note in notes:
			result.append({
				"note_id": note.uuid,
				"title": note.title,
				"enabled": note.enabled,
				"tab": tab_name,
				"type": _type_name(note),
			})

	return {
		"success": true,
		"notes": result,
		"count": result.size()
	}


func _list_agent_notes(args: Dictionary) -> Dictionary:
	var chat_id: String = args.get("chat_id", "")
	var container = SingletonObject.agent_notes_container
	if not container:
		return MCPToolUtils.error("Agent notes container not available")

	var result: Array = []
	for i in range(container.get_tab_count()):
		var tab_title = container.get_tab_title(i)
		for note in container.get_notes(i):
			if not chat_id.is_empty() and not note.is_linked_to_chat(chat_id):
				continue
			var content := _note_text_content(note)
			result.append({
				"note_id": note.uuid,
				"title": note.title,
				"tab": tab_title,
				"chars": content.length(),
				"linked_chat_ids": note.linked_chat_ids,
			})

	return {
		"success": true,
		"notes": result,
		"count": result.size(),
	}


func _enable_notes(args: Dictionary) -> Dictionary:
	var tab_name: String = args.get("tab", "")

	if tab_name.is_empty():
		return MCPToolUtils.error("tab is required")

	var notes_container = SingletonObject.notes_container
	if not notes_container:
		return MCPToolUtils.error("Notes container not available")

	var note_vbox = notes_container.find_tab_by_name(tab_name)
	if not note_vbox:
		return MCPToolUtils.error("Tab not found: %s" % tab_name)

	var tab_idx = notes_container.get_tab_idx_from_control(note_vbox)
	notes_container.enable_notes(tab_idx)

	return {"success": true, "message": "Notes enabled in tab: %s" % tab_name}


func _disable_notes(args: Dictionary) -> Dictionary:
	var tab_name: String = args.get("tab", "")

	if tab_name.is_empty():
		return MCPToolUtils.error("tab is required")

	var notes_container = SingletonObject.notes_container
	if not notes_container:
		return MCPToolUtils.error("Notes container not available")

	var note_vbox = notes_container.find_tab_by_name(tab_name)
	if not note_vbox:
		return MCPToolUtils.error("Tab not found: %s" % tab_name)

	var tab_idx = notes_container.get_tab_idx_from_control(note_vbox)
	notes_container.disable_notes(tab_idx)

	return {"success": true, "message": "Notes disabled in tab: %s" % tab_name}


func _delete_note(args: Dictionary) -> Dictionary:
	var note_id: String = args.get("note_id", "")

	if note_id.is_empty():
		return MCPToolUtils.error("note_id is required")

	# Find the note by UUID
	var note = SingletonObject.get_registered_object(note_id)
	if not note:
		return MCPToolUtils.error("Note not found: %s" % note_id)

	# Remove the note
	note.queue_free()

	return {"success": true, "message": "Note deleted"}


func _get_note(args: Dictionary) -> Dictionary:
	var note_id: String = args.get("note_id", "")

	if note_id.is_empty():
		return MCPToolUtils.error("note_id is required")

	var note = SingletonObject.get_registered_object(note_id)
	if not note or not (note is Note):
		return MCPToolUtils.error("Note not found: %s" % note_id)

	# Get content from the backing controls
	var content_text: String = ""
	var controls_container = note.get_controls_container()
	if controls_container is NoteTextControls:
		content_text = controls_container.content

	# Find which tab this note is in
	var tab_name: String = ""
	var notes_container = SingletonObject.notes_container
	if notes_container:
		for i in notes_container.get_tab_count():
			var notes = notes_container.get_notes(i)
			for n in notes:
				if n.uuid == note_id:
					tab_name = notes_container.get_tab_title(i)
					break
			if not tab_name.is_empty():
				break

	var result := {
		"success": true,
		"note_id": note_id,
		"title": note.title,
		"content": content_text,
		"tab": tab_name,
		"enabled": note.enabled,
		"type": _type_name(note),
	}

	# For image-backed notes, export the PNG and surface its path + dimensions so
	# plugins/agents can consume the actual image (e.g. flf2v keyframes), not just
	# a screenshot. The caption becomes the note's content when there's no text.
	var image_info := _export_note_image(note)
	if not image_info.is_empty():
		result.merge(image_info, true)
		if content_text.is_empty():
			result["content"] = image_info.get("caption", "")

	return result


func _get_agent_note(args: Dictionary) -> Dictionary:
	var note_id: String = args.get("note_id", "")
	var chat_id: String = args.get("chat_id", "")
	if note_id.is_empty():
		return MCPToolUtils.error("note_id is required")

	var note = _resolve_agent_note(note_id)
	if not note or not (note is Note):
		return MCPToolUtils.error("Agent note not found: %s" % note_id)
	if not chat_id.is_empty() and not note.is_linked_to_chat(chat_id):
		return MCPToolUtils.error("Agent note %s is not linked to chat %s" % [note.uuid, chat_id])

	var content := _note_text_content(note)
	return {
		"success": true,
		"note_id": note.uuid,
		"title": note.title,
		"content": content,
		"chars": content.length(),
		"tab": _find_note_tab_name(SingletonObject.agent_notes_container, note.uuid),
		"linked_chat_ids": note.linked_chat_ids,
	}


func _read_agent_note(args: Dictionary) -> Dictionary:
	var note_id: String = args.get("note_id", "")
	var chat_id: String = args.get("chat_id", "")
	if note_id.is_empty():
		return MCPToolUtils.error("note_id is required")

	var note = _resolve_agent_note(note_id)
	if not note or not (note is Note):
		return MCPToolUtils.error("Agent note not found: %s" % note_id)
	if not chat_id.is_empty() and not note.is_linked_to_chat(chat_id):
		return MCPToolUtils.error("Agent note %s is not linked to chat %s" % [note.uuid, chat_id])

	var content := _note_text_content(note)
	var offset := maxi(0, MCPToolUtils.coerce_int(args.get("offset", 0)))
	var limit := clampi(MCPToolUtils.coerce_int(args.get("limit", 4000)), 1, 16000)
	var window := content.substr(offset, min(limit, maxi(0, content.length() - offset)))

	return {
		"success": true,
		"note_id": note.uuid,
		"title": note.title,
		"offset": offset,
		"limit": limit,
		"content": window,
		"total_chars": content.length(),
		"remaining_chars": maxi(0, content.length() - (offset + window.length())),
		"tab": _find_note_tab_name(SingletonObject.agent_notes_container, note.uuid),
	}


func _update_note(args: Dictionary) -> Dictionary:
	var note_id: String = args.get("note_id", "")

	if note_id.is_empty():
		return MCPToolUtils.error("note_id is required")

	var note = SingletonObject.get_registered_object(note_id)
	if not note or not (note is Note):
		return MCPToolUtils.error("Note not found: %s" % note_id)

	var updated_fields: Array[String] = []

	if args.has("title"):
		note.title = args["title"]
		updated_fields.append("title")

	if args.has("content"):
		var controls_container = note.get_controls_container()
		if controls_container is NoteTextControls:
			controls_container.content = args["content"]
			updated_fields.append("content")
		else:
			return MCPToolUtils.error("Note is not a text note, cannot update content")

	return {
		"success": true,
		"note_id": note_id,
		"updated": updated_fields
	}


func _link_note_to_chat(args: Dictionary) -> Dictionary:
	var note_id: String = args.get("note_id", "")
	var chat_id: String = args.get("chat_id", "")
	var do_unlink: bool = args.get("unlink", false)

	if note_id.is_empty():
		return MCPToolUtils.error("note_id is required")

	var note = SingletonObject.get_registered_object(note_id)
	if not note or not (note is Note):
		return MCPToolUtils.error("Note not found: %s" % note_id)

	if chat_id.is_empty():
		note.linked_chat_ids.clear()
		return {"success": true, "message": "Note unlinked from all chats (now global)"}

	if do_unlink:
		note.linked_chat_ids.erase(chat_id)
		return {"success": true, "message": "Note unlinked from chat %s" % chat_id}
	else:
		if chat_id not in note.linked_chat_ids:
			note.linked_chat_ids.append(chat_id)
		return {"success": true, "message": "Note linked to chat %s" % chat_id}

#endregion

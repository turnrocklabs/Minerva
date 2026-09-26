class_name MCPNoteEntryTools
extends MCPToolModule
## MCP tools that add to and read a text note's entry log (NoteEntryLog)
## without sending the whole body: minerva_append_note and
## minerva_read_note_since. minerva_update_note (MCPNotesTools) is the
## whole-body writer; its if_revision guard uses the same revision.
##
## Handlers run to completion on the main thread without awaiting, so appends
## from several callers are applied one at a time and none is lost.

const DEFAULT_READ_LIMIT: int = 50
const MAX_READ_LIMIT: int = 500
## Serialized entries per read stay under this, leaving room under the 64 KiB
## MCP reply cap for the envelope and JSON escaping.
const READ_BYTE_BUDGET: int = 48 * 1024


func get_tool_names() -> Array[String]:
	return ["minerva_append_note", "minerva_read_note_since"]


func register_tools() -> void:
	server._register_tool("minerva_append_note",
		"Append text to a text note as one new entry, without resending or rewriting the rest of the note. Returns {entry_id, revision}; the body shows the entry on a new line after the existing text.\n\n"
		+ "Retry: pass a request_id unique to this append (e.g. a UUID) and reuse it when retrying after a timeout or lost reply. A repeat with a remembered request_id adds nothing and returns the original entry_id and revision with deduplicated=true. Each note remembers its last %d request_ids in memory only, so the window also ends when Minerva restarts or the note is reloaded; a retry after that appends again." % NoteEntryLog.REQUEST_MEMORY,
		{
			"type": "object",
			"properties": {
				"note_id": {"type": "string", "description": "The UUID of a text note"},
				"text": {"type": "string", "description": "Text of the new entry. May span several lines."},
				"request_id": {"type": "string", "description": "Caller-chosen id for this append; reuse it only when retrying the same append."},
				"author": {"type": "string", "description": "Optional author label stored with the entry, e.g. 'claude@Terminal 3'."},
			},
			"required": ["note_id", "text", "request_id"]
		}
	, "notes")

	server._register_tool("minerva_read_note_since",
		"Read a text note's entries after a cursor, oldest first. Start with cursor \"\"; each reply returns next_cursor, which continues exactly where that reply stopped (no gap, no overlap), and has_more when entries remain. Replies stop at limit entries or about 48 KiB, whichever comes first; a single larger entry comes back with truncated=true and its full length in chars (read it with minerva_get_note).\n\n"
		+ "Reset: appends never invalidate a cursor. If the cursor's entry, or anything before it, was edited, deleted or reordered (for example a person edited the note body, or minerva_update_note replaced it), the reply has reset=true, a reset_reason (cursor_entry_changed, earlier_entries_changed or malformed_cursor), no entries and next_cursor \"\". Recover by reading again from cursor \"\" and replacing what you held.",
		{
			"type": "object",
			"properties": {
				"note_id": {"type": "string", "description": "The UUID of a text note"},
				"cursor": {"type": "string", "description": "next_cursor from the previous read, or \"\" to read from the first entry."},
				"limit": {"type": "integer", "description": "Maximum entries to return. Defaults to %d, capped at %d." % [DEFAULT_READ_LIMIT, MAX_READ_LIMIT]},
			},
			"required": ["note_id", "cursor"]
		}
	, "notes")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_append_note":
			return _append_note(arguments)
		"minerva_read_note_since":
			return _read_note_since(arguments)
	return MCPToolUtils.error("Unknown tool: %s" % tool_name)


## The text controls of note [param note_id], or null with [param failure]
## filled with the error to return.
func _text_controls(note_id: String, failure: Dictionary) -> NoteTextControls:
	if note_id.is_empty():
		failure.merge(MCPToolUtils.error("note_id is required"))
		return null
	var note: Object = SingletonObject.get_registered_object(note_id)
	if not (note is Note):
		failure.merge(MCPToolUtils.error("Note not found: %s" % note_id))
		return null
	var controls: Variant = (note as Note).get_controls_container()
	if not (controls is NoteTextControls):
		failure.merge(MCPToolUtils.error("Note is not a text note: %s" % note_id))
		return null
	return controls


func _append_note(args: Dictionary) -> Dictionary:
	var note_id: = str(args.get("note_id", ""))
	var request_id: = str(args.get("request_id", ""))
	if request_id.is_empty():
		return MCPToolUtils.error("request_id is required")
	if not (args.get("text") is String):
		return MCPToolUtils.error("text is required")
	var failure: = {}
	var controls: = _text_controls(note_id, failure)
	if controls == null:
		return failure

	var earlier: = controls.entry_log.find_request(request_id)
	if not earlier.is_empty():
		return {"success": true, "note_id": note_id, "entry_id": earlier["entry_id"],
			"revision": earlier["revision"], "deduplicated": true}

	var entry: = controls.append_entry(args["text"], str(args.get("author", "")))
	controls.entry_log.remember_request(request_id, entry)
	return {"success": true, "note_id": note_id, "entry_id": entry.id,
		"revision": controls.entry_log.revision, "deduplicated": false}


func _read_note_since(args: Dictionary) -> Dictionary:
	var note_id: = str(args.get("note_id", ""))
	var failure: = {}
	var controls: = _text_controls(note_id, failure)
	if controls == null:
		return failure
	var limit: = clampi(MCPToolUtils.coerce_int(args.get("limit"), DEFAULT_READ_LIMIT), 1, MAX_READ_LIMIT)
	var result: = controls.entry_log.read_since(str(args.get("cursor", "")), limit, READ_BYTE_BUDGET)
	result["success"] = true
	result["note_id"] = note_id
	result["revision"] = controls.entry_log.revision
	return result

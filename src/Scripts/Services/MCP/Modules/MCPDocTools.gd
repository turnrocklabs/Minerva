class_name MCPDocTools
extends MCPToolModule
## MCP tool module for document-canonical read/write/edit/save.
##
## All `minerva_doc_*` tools route through DocumentRegistry. The buffer is
## canonical; disk is only written by minerva_doc_save / minerva_doc_save_all.


func _init(mcp_server = null) -> void:
	super._init(mcp_server)


func get_tool_names() -> Array[String]:
	return [
		"minerva_doc_read",
		"minerva_doc_write",
		"minerva_doc_edit",
		"minerva_doc_save",
		"minerva_doc_save_all",
	]


func register_tools() -> void:
	server._register_tool("minerva_doc_read",
		"Read a document's text via the document registry. Returns the buffer's text if a buffer exists; otherwise loads the file from disk into a new buffer and returns its text. Returns not_found error when the path has no buffer and no file on disk.",
		{"type": "object", "properties": {
			"path": {"type": "string", "description": "Absolute file path"},
		}, "required": ["path"]}, "documents")

	server._register_tool("minerva_doc_write",
		"Replace a document buffer's text. The buffer becomes dirty; disk is NOT modified until minerva_doc_save is called. Creates a buffer if none exists for the path.",
		{"type": "object", "properties": {
			"path": {"type": "string", "description": "Absolute file path"},
			"text": {"type": "string", "description": "Full text content for the buffer"},
		}, "required": ["path", "text"]}, "documents")

	server._register_tool("minerva_doc_edit",
		"Replace one occurrence of old_string with new_string in the document buffer. The buffer becomes dirty; disk is NOT modified until minerva_doc_save is called. old_string must match exactly once. Returns not_found if no buffer and no disk file.",
		{"type": "object", "properties": {
			"path": {"type": "string", "description": "Absolute file path"},
			"old_string": {"type": "string", "description": "String to find (must be unique in buffer)"},
			"new_string": {"type": "string", "description": "Replacement string"},
		}, "required": ["path", "old_string", "new_string"]}, "documents")

	server._register_tool("minerva_doc_save",
		"Flush a single dirty document buffer to disk and clear its dirty flag. Errors if no buffer exists for the path.",
		{"type": "object", "properties": {
			"path": {"type": "string", "description": "Absolute file path"},
		}, "required": ["path"]}, "documents")

	server._register_tool("minerva_doc_save_all",
		"Flush every dirty document buffer to disk. Returns saved_paths and any failures.",
		{"type": "object", "properties": {}}, "documents")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_doc_read": return _doc_read(arguments)
		"minerva_doc_write": return _doc_write(arguments)
		"minerva_doc_edit": return _doc_edit(arguments)
		"minerva_doc_save": return _doc_save(arguments)
		"minerva_doc_save_all": return _doc_save_all(arguments)
	return MCPToolUtils.error("Unknown tool: %s" % tool_name)


# ── Implementations ────────────────────────────────────────────────────────

func _doc_read(args: Dictionary) -> Dictionary:
	var path: String = args.get("path", "")
	if path.is_empty():
		return _err("path is required")

	var registry := DocumentRegistry.get_instance()
	if not registry.has_buffer(path) and not DiskAccess.exists(path):
		return _err("not_found: %s" % path)

	var r := registry.get_or_create_buffer(path)
	if not r.ok:
		return _err(r.error)
	var buf: DocumentBuffer = r.buffer
	return _ok({
		"text": buf.text,
		"version": buf.version,
		"dirty": buf.dirty,
	})


func _doc_write(args: Dictionary) -> Dictionary:
	var path: String = args.get("path", "")
	if path.is_empty():
		return _err("path is required")
	if not args.has("text"):
		return _err("text is required")
	var text: String = args.get("text", "")

	var registry := DocumentRegistry.get_instance()
	var r := registry.get_or_create_buffer(path)
	if not r.ok:
		return _err(r.error)
	var buf: DocumentBuffer = r.buffer
	buf.apply_edit(text)
	return _ok({
		"version": buf.version,
		"dirty": buf.dirty,
	})


func _doc_edit(args: Dictionary) -> Dictionary:
	var path: String = args.get("path", "")
	if path.is_empty():
		return _err("path is required")
	if not args.has("old_string"):
		return _err("old_string is required")
	if not args.has("new_string"):
		return _err("new_string is required")
	var old_str: String = args.get("old_string", "")
	var new_str: String = args.get("new_string", "")

	var registry := DocumentRegistry.get_instance()
	if not registry.has_buffer(path) and not DiskAccess.exists(path):
		return _err("not_found: %s" % path)

	var r := registry.get_or_create_buffer(path)
	if not r.ok:
		return _err(r.error)
	var buf: DocumentBuffer = r.buffer

	var idx := buf.text.find(old_str)
	if idx == -1:
		return _err("old_string not found in buffer")
	var second := buf.text.find(old_str, idx + old_str.length())
	if second != -1:
		return _err("old_string is not unique in buffer (matches at offsets %d and %d)" % [idx, second])

	var new_text := buf.text.substr(0, idx) + new_str + buf.text.substr(idx + old_str.length())
	buf.apply_edit(new_text)
	return _ok({
		"version": buf.version,
		"dirty": buf.dirty,
	})


func _doc_save(args: Dictionary) -> Dictionary:
	var path: String = args.get("path", "")
	if path.is_empty():
		return _err("path is required")

	var registry := DocumentRegistry.get_instance()
	if not registry.has_buffer(path):
		return _err("no buffer for path: %s" % path)

	var r := registry.get_or_create_buffer(path)
	if not r.ok:
		return _err(r.error)
	var buf: DocumentBuffer = r.buffer
	var save_r := buf.save_to_disk()
	if not save_r.ok:
		return _err(save_r.error)
	return _ok({"path": path})


func _doc_save_all(_args: Dictionary) -> Dictionary:
	var registry := DocumentRegistry.get_instance()
	var dirty_paths := registry.list_dirty_buffer_paths()
	var saved: Array = []
	var failures: Array = []

	for path in dirty_paths:
		var r := registry.get_or_create_buffer(path)
		if not r.ok:
			failures.append({"path": path, "error": r.error})
			continue
		var buf: DocumentBuffer = r.buffer
		var save_r := buf.save_to_disk()
		if save_r.ok:
			saved.append(path)
		else:
			failures.append({"path": path, "error": save_r.error})

	return _ok({
		"saved_paths": saved,
		"failures": failures,
	})


# ── Local response helpers (mirror MCPToolUtils to stay headless-testable) ──

static func _ok(data: Dictionary = {}) -> Dictionary:
	var result := {"success": true}
	result.merge(data)
	return result


static func _err(msg: String) -> Dictionary:
	return {"error": msg, "success": false}

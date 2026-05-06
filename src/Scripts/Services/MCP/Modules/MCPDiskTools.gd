class_name MCPDiskTools
extends MCPToolModule
## MCP tool module for raw disk access, bypassing the document registry.
##
## Use only when you genuinely mean "the bytes on the filesystem, ignore any
## in-memory state." For most cases prefer minerva_doc_*.
##
## minerva_disk_write to a path with an existing buffer fires
## external_change_detected on that buffer, symmetric with vim/git writing
## the file from outside Minerva.


func _init(mcp_server = null) -> void:
	super._init(mcp_server)


func get_tool_names() -> Array[String]:
	return [
		"minerva_disk_read",
		"minerva_disk_write",
		"minerva_disk_exists",
	]


func register_tools() -> void:
	server._register_tool("minerva_disk_read",
		"Read raw bytes from disk, bypassing any document buffer. Use only when you genuinely mean 'the file as it exists on disk' regardless of in-memory state. For most cases prefer minerva_doc_read.",
		{"type": "object", "properties": {
			"path": {"type": "string", "description": "Absolute file path"},
		}, "required": ["path"]}, "documents")

	server._register_tool("minerva_disk_write",
		"Write directly to disk, bypassing any document buffer. If a buffer exists for the path, fires external_change_detected on it (treating the write as an external mutation, like vim or git checkout). For most cases prefer minerva_doc_write + minerva_doc_save.",
		{"type": "object", "properties": {
			"path": {"type": "string", "description": "Absolute file path"},
			"text": {"type": "string", "description": "Content to write"},
		}, "required": ["path", "text"]}, "documents")

	server._register_tool("minerva_disk_exists",
		"Whether a file exists on disk. Does not consult the document buffer.",
		{"type": "object", "properties": {
			"path": {"type": "string", "description": "Absolute file path"},
		}, "required": ["path"]}, "documents")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_disk_read": return _disk_read(arguments)
		"minerva_disk_write": return _disk_write(arguments)
		"minerva_disk_exists": return _disk_exists(arguments)
	return MCPToolUtils.error("Unknown tool: %s" % tool_name)


# ── Implementations ────────────────────────────────────────────────────────

func _disk_read(args: Dictionary) -> Dictionary:
	var path: String = args.get("path", "")
	if path.is_empty():
		return _err("path is required")
	var r := DiskAccess.read(path)
	if r.ok:
		return _ok({"text": r.text})
	return _err(r.error)


func _disk_write(args: Dictionary) -> Dictionary:
	var path: String = args.get("path", "")
	if path.is_empty():
		return _err("path is required")
	if not args.has("text"):
		return _err("text is required")
	var text: String = args.get("text", "")

	var r := DiskAccess.write(path, text)
	if not r.ok:
		return _err(r.error)

	# Symmetric with vim/git: route through the registry's watcher path so a
	# buffered file gets the same dispatch as any external change (clean →
	# silent reload, dirty → external_change_detected with coalescing).
	# poke_path bypasses the polling tick for synchronous prompt firing.
	DocumentRegistry.get_instance().poke_path(path)

	return _ok({"path": path})


func _disk_exists(args: Dictionary) -> Dictionary:
	var path: String = args.get("path", "")
	if path.is_empty():
		return _err("path is required")
	return _ok({"exists": DiskAccess.exists(path)})


# ── Local response helpers (mirror MCPToolUtils to stay headless-testable) ──

static func _ok(data: Dictionary = {}) -> Dictionary:
	var result := {"success": true}
	result.merge(data)
	return result


static func _err(msg: String) -> Dictionary:
	return {"error": msg, "success": false}

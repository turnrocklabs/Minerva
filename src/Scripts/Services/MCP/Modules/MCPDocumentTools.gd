class_name MCPDocumentTools
extends MCPToolModule
## MCP tools for reading DATA out of office documents that Minerva can't already
## import natively. v1: .docx (OOXML wordprocessing) via OOXMLReader — pure Godot
## built-ins, cross-platform, zero deps (DCR 019e8547775c).
##
## This is a READER, not an editor: it has no UI side-effects. To land an
## extracted table in a spreadsheet, pass a table's `csv` field to
## minerva_create_spreadsheet_editor (csv_content=...).

const OOXMLReaderScript := preload("res://Scripts/Services/Documents/OOXMLReader.gd")


func _init(mcp_server = null) -> void:
	super._init(mcp_server)


func get_tool_names() -> Array[String]:
	return [
		"minerva_read_document",
	]


func register_tools() -> void:
	server._register_tool("minerva_read_document",
		"Extract DATA (text + tables + embedded-image metadata) from an office document Minerva can't import natively. v1 supports .docx (Word). Returns {text, tables, images}; each table has rows + a ready-to-import `csv` (intra-cell newlines collapsed) — pass that csv to minerva_create_spreadsheet_editor(csv_content=...) to land it in a sheet. For .csv/.tsv/.xlsx use minerva_create_spreadsheet_editor directly. Reads data only; does NOT render the document's layout.",
		{"type": "object", "properties": {
			"path": {"type": "string", "description": "Absolute path to the document (.docx)."},
			"include_text": {"type": "boolean", "description": "Include the full paragraph text (default true). Set false when you only want tables."},
			"max_text_chars": {"type": "integer", "description": "Truncate returned text to this many characters (0 = no limit, default 0)."},
		}, "required": ["path"]}, "documents")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_read_document": return _read_document(arguments)
	return _err("Unknown tool: %s" % tool_name)


func _read_document(args: Dictionary) -> Dictionary:
	var path: String = args.get("path", "")
	if path.is_empty():
		return _err("path is required")

	var ext := path.get_extension().to_lower()
	match ext:
		"docx":
			return _read_docx(path, args)
		"csv", "tsv", "xlsx", "minsheet":
			return _err("'%s' imports natively — use minerva_create_spreadsheet_editor(file_path=\"%s\")." % [ext, path])
		"doc":
			return _err("Legacy binary .doc is not supported (no cross-platform parser). Re-save as .docx.")
		_:
			return _err("Unsupported document type '.%s'. Supported: .docx." % ext)


func _read_docx(path: String, args: Dictionary) -> Dictionary:
	var res: Dictionary = OOXMLReaderScript.read_docx(path)
	if not res.get("ok", false):
		return _err(res.get("error", "Failed to read .docx"))

	var include_text: bool = args.get("include_text", true)
	var max_text_chars: int = int(args.get("max_text_chars", 0))

	var text: String = res.get("text", "") if include_text else ""
	var text_truncated := false
	if max_text_chars > 0 and text.length() > max_text_chars:
		text = text.substr(0, max_text_chars)
		text_truncated = true

	return {
		"success": true,
		"format": "docx",
		"path": path,
		"text": text,
		"text_truncated": text_truncated,
		"tables": res.get("tables", []),
		"table_count": (res.get("tables", []) as Array).size(),
		"images": res.get("images", []),
	}


# Local response helper (mirrors MCPToolUtils, but standalone so the module is
# headless-testable without the global-class registry — same pattern as MCPDiskTools).
static func _err(msg: String) -> Dictionary:
	return {"error": msg, "success": false}

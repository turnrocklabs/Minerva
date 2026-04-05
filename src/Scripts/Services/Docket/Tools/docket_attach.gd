extends RefCounted
class_name DocketAttach
## MCP tool: attach a base64-encoded file to an item.


func get_definition() -> Dictionary:
	return {
		"name": "docket_attach",
		"description": "Attach a file to a work item. Pass file data as base64-encoded string.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"item_id": {"type": "string", "description": "Full ID or short prefix (min 4 chars)"},
				"filename": {"type": "string", "description": "Original filename (e.g. screenshot.png)"},
				"data": {"type": "string", "description": "Base64-encoded file data"},
				"mime_type": {"type": "string", "description": "MIME type (default: application/octet-stream)"},
				"description": {"type": "string", "description": "Optional description of the attachment"},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
			"required": ["item_id", "filename", "data"],
		},
	}


const MAX_ATTACHMENT_SIZE: int = 5 * 1024 * 1024  # 5 MB

func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var item_id: String = args.get("item_id", "")
	if not db.has_item(item_id):
		return {"error": "Item not found: %s" % item_id}

	var filename: String = args.get("filename", "")
	var data_b64: String = args.get("data", "")
	var mime: String = args.get("mime_type", "application/octet-stream")
	var desc: String = args.get("description", "")

	var data := Marshalls.base64_to_raw(data_b64)
	if data.is_empty() and not data_b64.is_empty():
		return {"error": "Invalid base64 data"}

	if data.size() > MAX_ATTACHMENT_SIZE:
		return {"error": "File too large: %d bytes (max %d bytes / 5 MB)" % [data.size(), MAX_ATTACHMENT_SIZE]}

	var result := db.attach_file(item_id, filename, data, mime, desc)
	db.add_event(item_id, "attached", "agent", "Attached %s (%d bytes)" % [filename, data.size()])

	return result

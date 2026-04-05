extends RefCounted
class_name DocketDetach
## MCP tool: list, get, or delete attachments on an item.


func get_definition() -> Dictionary:
	return {
		"name": "docket_detach",
		"description": "List, get, or delete attachments on a work item.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"action": {"type": "string", "enum": ["list", "get", "delete"], "description": "Action to perform"},
				"item_id": {"type": "string", "description": "Full ID or short prefix (min 4 chars, required for list)"},
				"attachment_id": {"type": "integer", "description": "Attachment ID (required for get/delete)"},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
			"required": ["action"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var action: String = args.get("action", "")

	match action:
		"list":
			var item_id: String = args.get("item_id", "")
			if item_id.is_empty():
				return {"error": "item_id required for list"}
			if not db.has_item(item_id):
				return {"error": "Item not found: %s" % item_id}
			var attachments := db.list_attachments(item_id)
			return {"attachments": attachments, "count": attachments.size()}
		"get":
			var att_id: int = int(args.get("attachment_id", 0))
			if att_id <= 0:
				return {"error": "attachment_id required for get"}
			var att := db.get_attachment(att_id)
			if att.is_empty():
				return {"error": "Attachment not found: %d" % att_id}
			# Convert BLOB data to base64 for transport
			var data = att.get("data", PackedByteArray())
			if data is PackedByteArray:
				att["data"] = Marshalls.raw_to_base64(data)
			return att
		"delete":
			var att_id: int = int(args.get("attachment_id", 0))
			if att_id <= 0:
				return {"error": "attachment_id required for delete"}
			var att := db.get_attachment(att_id)
			if att.is_empty():
				return {"error": "Attachment not found: %d" % att_id}
			var item_id: String = str(att.get("item_id", ""))
			var filename: String = str(att.get("filename", ""))
			db.detach_file(att_id)
			if not item_id.is_empty():
				db.add_event(item_id, "detached", "agent", "Removed attachment: %s" % filename)
			return {"deleted": att_id}
		_:
			return {"error": "Invalid action: %s. Use list, get, or delete." % action}

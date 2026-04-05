extends RefCounted
class_name DocketDelete
## MCP tool: hard-delete an item regardless of state.
## Bypasses the state machine — deletion is administrative, not a workflow transition.
## Cascades to tags, events, links, comments, and attachments.


func get_definition() -> Dictionary:
	return {
		"name": "docket_delete",
		"description": "Permanently delete an item regardless of its current state. Cascades to tags, events, links, comments, and attachments. Use for housekeeping (duplicates, test data, items in terminal states).",
		"inputSchema": {
			"type": "object",
			"properties": {
				"id": {"type": "string", "description": "Full ID or short prefix (min 4 chars)"},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
			"required": ["id"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var id: String = str(args.get("id", ""))
	if id.is_empty():
		return {"error": "Missing 'id'"}

	if not db.has_item(id):
		return {"error": "Item not found: %s" % id}

	# Capture title before deletion for confirmation
	var item: Dictionary = db.get_item(id)
	var title: String = str(item.get("title", ""))
	var type: String = str(item.get("type", ""))
	var status: String = str(item.get("status", ""))

	db.delete_item(id)

	return {"id": id, "deleted": true, "title": title, "type": type, "was_status": status}

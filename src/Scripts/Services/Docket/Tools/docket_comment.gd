extends RefCounted
class_name DocketComment
## MCP tool: add, list, accept, reject, or reply to comments on a work item.
## Comments have an open → accepted|rejected lifecycle. Replies reference a parent comment.


func get_definition() -> Dictionary:
	return {
		"name": "docket_comment",
		"description": "Add, list, or address comments on a work item. Comments have an open/addressed lifecycle.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"action": {"type": "string", "enum": ["add", "list", "address"], "description": "Action to perform"},
				"item_id": {"type": "string", "description": "Full ID or short prefix (min 4 chars, required for add/list)"},
				"text": {"type": "string", "description": "Comment text (required for add)"},
				"author": {"type": "string", "description": "Author name or initials (optional, defaults to 'agent')"},
				"comment_id": {"type": "integer", "description": "Comment ID (required for address)"},
				"addressed_by": {"type": "string", "description": "Who addressed the comment (optional for address)"},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
			"required": ["action"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var action: String = args.get("action", "")
	match action:
		"add":
			return _add(args, db)
		"list":
			return _list(args, db)
		"accept":
			return _resolve(args, db, "accepted")
		"reject":
			return _resolve(args, db, "rejected")
		"reply":
			return _reply(args, db)
		# Backward compat
		"address":
			return _resolve(args, db, "accepted")
	return {"error": "Unknown action: %s. Use add, list, accept, reject, or reply." % action}


func _add(args: Dictionary, db: DocketDB) -> Dictionary:
	var item_id: String = args.get("item_id", "")
	if item_id.is_empty() or not db.has_item(item_id):
		return {"error": "Item not found: %s" % item_id}
	var text: String = args.get("text", "")
	if text.is_empty():
		return {"error": "Comment text is required"}
	var author: String = args.get("author", "agent")
	return db.add_comment(item_id, author, text)


func _list(args: Dictionary, db: DocketDB) -> Dictionary:
	var item_id: String = args.get("item_id", "")
	if item_id.is_empty() or not db.has_item(item_id):
		return {"error": "Item not found: %s" % item_id}
	return {"item_id": item_id, "comments": db.list_comments(item_id)}


func _resolve(args: Dictionary, db: DocketDB, resolution: String) -> Dictionary:
	var comment_id: int = int(args.get("comment_id", 0))
	if comment_id <= 0:
		return {"error": "comment_id is required"}
	var by: String = args.get("addressed_by", args.get("author", "agent"))
	return db.resolve_comment(comment_id, resolution, by)


func _reply(args: Dictionary, db: DocketDB) -> Dictionary:
	var comment_id: int = int(args.get("comment_id", 0))
	if comment_id <= 0:
		return {"error": "comment_id is required for reply"}
	var parent := db.get_comment(comment_id)
	if parent.is_empty():
		return {"error": "Parent comment not found: %d" % comment_id}
	var item_id: String = str(parent.get("item_id", ""))
	var text: String = args.get("text", "")
	if text.is_empty():
		return {"error": "Reply text is required"}
	var author: String = args.get("author", "agent")
	return db.add_comment(item_id, author, text, comment_id)

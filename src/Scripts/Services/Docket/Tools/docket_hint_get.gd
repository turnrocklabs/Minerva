extends RefCounted
class_name DocketHintGet
## Retrieve a hint by component+key. Auto-increments retrieval_count on access.
## Also auto-bumps retrieval_count on insights when retrieved by this tool.


func get_definition() -> Dictionary:
	return {
		"name": "docket_hint_get",
		"description": "Get a hint by component and key. Auto-increments retrieval_count on each access. Returns the matching hint or an error if not found.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"component": {"type": "string", "description": "Logical component to look up"},
				"key": {"type": "string", "description": "Hint key to look up"},
				"id": {"type": "string", "description": "Full ID or short prefix (min 4 chars). Auto-bumps retrieval_count."},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	# Direct ID lookup (works for hints and insights)
	if args.has("id"):
		var id: String = args.id
		if not db.has_item(id):
			return {"error": "Item not found: %s" % id}
		var item: Dictionary = db.get_item(id)
		var item_type: String = str(item.get("type", ""))
		if item_type in ["hint", "insight"]:
			db.bump_retrieval(id)
			item = db.get_item(id)
		return DocketDB._strip_empty(item)

	# Component+key lookup
	var comp: String = args.get("component", "")
	var key: String = args.get("key", "")
	if comp.is_empty() and key.is_empty():
		return {"error": "Provide component+key or id"}

	var hint := db.find_hint(comp, key)
	if hint.is_empty():
		return {"error": "No hint found for %s/%s" % [comp, key]}

	var hint_id: String = str(hint.get("id", ""))
	db.bump_retrieval(hint_id)
	return DocketDB._strip_empty(db.get_item(hint_id))

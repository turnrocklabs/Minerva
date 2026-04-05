extends RefCounted
class_name DocketGet


func get_definition() -> Dictionary:
	return {
		"name": "docket_get",
		"description": "Get a single work item by ID with full detail and event history.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"id": {"type": "string", "description": "Full ID or short prefix (min 4 chars)"},
				"include": {"type": "array", "items": {"type": "string", "enum": ["events", "links"]}, "description": "Sections to include. Default: [\"events\", \"links\"]. Pass [] to omit both."},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
			"required": ["id"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var id: String = args.get("id", "")
	if not db.has_item(id):
		return {"error": "Item not found: %s" % id}

	var item := db.get_item(id)

	# Strip excluded sections
	var include: Array = args.get("include", ["events", "links"])
	if not ("events" in include):
		item.erase("events")
	if not ("links" in include):
		item.erase("links")

	return DocketDB._strip_empty(item)

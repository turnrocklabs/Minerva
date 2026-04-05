extends RefCounted
class_name DocketSavedQuery


func get_definition() -> Dictionary:
	return {
		"name": "docket_saved_query",
		"description": "Save, load, or list saved queries within the .dct file.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"action": {"type": "string", "enum": ["save", "load", "list"]},
				"name": {"type": "string"},
				"filter": {"type": "object"},
				"sort": {"type": "array"},
				"columns": {"type": "array", "items": {"type": "string"}},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
			"required": ["action"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var action: String = args.get("action", "")

	match action:
		"save":
			var name: String = args.get("name", "")
			if name.is_empty():
				return {"error": "Query name required for save"}
			var query := {}
			if args.has("filter"):
				query["filter"] = args.filter
			if args.has("sort"):
				query["sort"] = args.sort
			if args.has("columns"):
				query["columns"] = args.columns
			db.save_query(name, query)
			return {"saved": name}
		"load":
			var name: String = args.get("name", "")
			var query := db.load_query(name)
			if query.is_empty():
				return {"error": "Query not found: %s" % name}
			return query
		"list":
			var queries := db.list_queries()
			var names: Array = []
			for q in queries:
				names.append(q.name)
			return {"queries": names}
		_:
			return {"error": "Invalid action: %s. Use save, load, or list." % action}

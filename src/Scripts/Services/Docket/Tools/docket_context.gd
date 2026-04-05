extends RefCounted
class_name DocketContext


func get_definition() -> Dictionary:
	return {
		"name": "docket_context",
		"description": "Get a curated briefing for an area. Shows insights, open bugs, recent RCAs, and questions matching the given tags.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"tags": {"type": "array", "items": {"type": "string"}},
				"include": {"type": "array", "items": {"type": "string"}, "description": "Item types to include"},
				"lookback_days": {"type": "integer", "default": 30},
				"detail": {"type": "string", "enum": ["lean", "full"], "description": "Response detail level. Default: lean."},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
			"required": ["tags"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var tags: Array = args.get("tags", [])
	var include_types: Array = args.get("include", [])

	var detail: String
	if args.has("detail") and str(args.detail) == "full":
		detail = "full_stripped"
	else:
		detail = "lean"

	var results := db.query_context(tags, include_types, detail)
	return {"items": results, "count": results.size(), "tags": tags}

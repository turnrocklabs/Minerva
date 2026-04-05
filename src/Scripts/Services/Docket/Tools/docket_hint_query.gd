extends RefCounted
class_name DocketHintQuery
## Query hints (and optionally insights) with component/key/tag filtering.
## Auto-increments retrieval_count on each returned item.


func get_definition() -> Dictionary:
	return {
		"name": "docket_hint_query",
		"description": "Query hints by component, key pattern, or tags. Auto-increments retrieval_count on returned items. Set include_insights=true to also search insights.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"component": {"type": "string", "description": "Filter by component (exact match)"},
				"key": {"type": "string", "description": "Filter by key (exact match)"},
				"tags": {"type": "array", "items": {"type": "string"}, "description": "Filter: item must have all these tags"},
				"include_insights": {"type": "boolean", "description": "Also return matching insights (default false)"},
				"promoted_only": {"type": "boolean", "description": "Only return promoted hints (for CLAUDE.md graduation)"},
				"min_retrievals": {"type": "integer", "description": "Only return items retrieved at least this many times"},
				"min_research_cost": {"type": "integer", "description": "Only return items with research cost >= this value"},
				"limit": {"type": "integer", "minimum": 1},
				"detail": {"type": "string", "enum": ["lean", "full"], "description": "Response detail level. Default: lean."},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var query_args := args.duplicate()

	# If not including insights, restrict to hints only at SQL level
	var hints_only: bool = not args.get("include_insights", false)
	if hints_only:
		query_args["_hints_only"] = true

	var detail: String
	if args.has("detail") and str(args.detail) == "full":
		detail = "full_stripped"
	else:
		detail = "lean"

	var results := db.query_hints(query_args, detail)

	# Auto-bump retrieval count on each returned item
	for item in results:
		var id: String = str(item.get("id", ""))
		if not id.is_empty():
			db.bump_retrieval(id)

	return {"items": results, "count": results.size()}

extends RefCounted
class_name DocketQuery


func get_definition() -> Dictionary:
	return {
		"name": "docket_query",
		"description": "Query work items with filtering, sorting, and limiting. Three filter formats: (1) Old flat dict: {\"type\": \"bug\", \"status__ne\": \"closed\"} with __ne/__in/tags_contains suffixes. (2) Nested tree: {\"$or\": [{\"field\":\"type\",\"op\":\"eq\",\"value\":\"bug\"}, {\"$and\": [...]}]} for complex boolean logic. (3) Conditions list: {\"conditions\": [{\"field\":\"type\",\"op\":\"eq\",\"value\":\"bug\"}, {\"conj\":\"and\",\"field\":\"priority\",\"op\":\"gt\",\"value\":2}]}. Operators: eq, neq, contains, not_contains, like (wildcards: . for single char, * for any), gt, lt, gte, lte, before, after, is_empty, is_not_empty. Pseudo-fields: tags (eq/neq for tag presence), has_attachment (eq true/false).",
		"inputSchema": {
			"type": "object",
			"properties": {
				"filter": {"type": "object", "description": "Field filters. Supports three formats: flat dict (legacy), {\"$or\":[...]}/{\"$and\":[...]} tree, or {\"conditions\":[...]} list."},
				"sort": {"type": "array", "items": {"type": "object", "properties": {"field": {"type": "string"}, "dir": {"type": "string", "enum": ["asc", "desc"]}}}},
				"limit": {"type": "integer", "minimum": 1},
				"detail": {"type": "string", "enum": ["lean", "full"], "description": "Response detail level. Default: auto (lean when unfiltered or >5 results; full null-stripped when filtered and ≤5 results)."},
				"project": {"type": "string", "description": "Query specific project (optional, omit for cross-project)"},
			},
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var query := {}
	if args.has("filter"):
		var filter = args.filter
		# Strip routing params that aren't DB columns
		if filter is Dictionary and filter.has("project"):
			filter = filter.duplicate()
			filter.erase("project")
		query["filter"] = filter
	if args.has("sort"):
		query["sort"] = args.sort
	if args.has("limit"):
		query["limit"] = args.limit

	# Smart default: auto-hydrate only when filter narrows to ≤5 results.
	# >5 results always lean (browse first, hydrate via docket_get).
	# Explicit detail param overrides everything.
	var detail: String
	if args.has("detail"):
		var req: String = str(args.detail)
		detail = "lean" if req == "lean" else "full_stripped"
	else:
		var filter = args.get("filter", {})
		var has_filter: bool = filter is Dictionary and not filter.is_empty()
		if has_filter:
			# Two-pass: count first, hydrate only if small result set
			var lean_results := db.execute_query(query, "lean")
			if lean_results.size() == 1 and lean_results[0] is Dictionary and lean_results[0].has("_error"):
				return {"error": lean_results[0]["_error"]}
			if lean_results.size() <= 5:
				var full_results := db.execute_query(query, "full_stripped")
				return {"items": full_results, "count": full_results.size()}
			return {"items": lean_results, "count": lean_results.size()}
		else:
			detail = "lean"

	var results = db.execute_query(query, detail)
	if results.size() == 1 and results[0] is Dictionary and results[0].has("_error"):
		return {"error": results[0]["_error"]}
	return {"items": results, "count": results.size()}

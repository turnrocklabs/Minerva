extends RefCounted
class_name DocketSkillList
## List skills with optional filtering. Returns title + description for catalog view,
## or full content when few results. Designed for LLM skill discovery.


func get_definition() -> Dictionary:
	return {
		"name": "docket_skill_list",
		"description": "List available skills. Returns title + description for discovery. Filtered results (≤5) include full steps/preconditions/outcome.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"query": {"type": "string", "description": "Search term — matched against title, description, tags, component"},
				"tags": {"type": "array", "items": {"type": "string"}, "description": "Filter by tags"},
				"status": {"type": "string", "enum": ["draft", "active", "archived"], "description": "Filter by status (default: active)"},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var status_filter: String = str(args.get("status", "active"))
	var query_text: String = str(args.get("query", ""))
	var tags: Array = args.get("tags", [])

	# Build filter for skills
	var filter := {"type": "skill"}
	if not status_filter.is_empty():
		filter["status"] = status_filter

	var query := {"filter": filter}

	# Execute query — lean first
	var results := db.execute_query(query, "lean")
	if results.size() == 1 and results[0] is Dictionary and results[0].has("_error"):
		return {"error": results[0]["_error"]}

	# Apply text search and tag filters in post-processing
	var filtered: Array = []
	for item in results:
		var id: String = str(item.get("id", ""))
		if id.is_empty():
			continue

		# Tag filter
		if tags.size() > 0:
			var full_item := db.get_item(id)
			if full_item.is_empty():
				continue
			var item_tags: Array = full_item.get("tags", [])
			var has_all_tags := true
			for tag in tags:
				if not item_tags.has(str(tag)):
					has_all_tags = false
					break
			if not has_all_tags:
				continue

		# Text search (title, description, component)
		if not query_text.is_empty():
			var full_item := db.get_item(id)
			if full_item.is_empty():
				continue
			var searchable := "%s %s %s %s" % [
				str(full_item.get("title", "")),
				str(full_item.get("description", "")),
				str(full_item.get("component", "")),
				str(full_item.get("steps", "")),
			]
			if not searchable.to_lower().contains(query_text.to_lower()):
				continue

		filtered.append(item)

	# If few results, hydrate with full content
	if filtered.size() <= 5 and filtered.size() > 0:
		var hydrated: Array = []
		for item in filtered:
			var full := db.get_item(str(item.get("id", "")))
			if full.is_empty():
				continue
			var entry := {
				"id": full.get("id", ""),
				"title": full.get("title", ""),
				"description": full.get("description", ""),
				"status": full.get("status", ""),
				"steps": full.get("steps", ""),
				"preconditions": full.get("preconditions", ""),
				"outcome": full.get("outcome", ""),
				"tags": full.get("tags", []),
				"component": full.get("component", ""),
			}
			# Strip empty fields
			var clean := {}
			for key in entry:
				var val = entry[key]
				if val is String and val.is_empty():
					continue
				if val is Array and val.is_empty():
					continue
				clean[key] = val
			hydrated.append(clean)
		return {"skills": hydrated, "count": hydrated.size()}

	# Many results — return lean catalog (title + description only)
	var catalog: Array = []
	for item in filtered:
		var full := db.get_item(str(item.get("id", "")))
		if full.is_empty():
			continue
		var entry := {"id": full.get("id", ""), "title": full.get("title", "")}
		var desc: String = str(full.get("description", ""))
		if not desc.is_empty():
			entry["description"] = desc
		catalog.append(entry)
	return {"skills": catalog, "count": catalog.size()}

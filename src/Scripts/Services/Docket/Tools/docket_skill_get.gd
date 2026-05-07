extends RefCounted
class_name DocketSkillGet
## Get a single skill by ID or title search. Returns full content including steps,
## preconditions, and outcome. Designed for LLM skill execution.


func get_definition() -> Dictionary:
	return {
		"name": "docket_skill_get",
		"description": "Get a skill's full content by ID or title. Returns steps, preconditions, outcome — everything needed to execute the skill.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"id": {"type": "string", "description": "Full ID or short prefix (min 4 chars)"},
				"title": {"type": "string", "description": "Exact or partial title match (used if id not provided)"},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
		},
	}


func execute(args: Dictionary, _schema: Dictionary, db: DocketDB) -> Dictionary:
	var id: String = str(args.get("id", ""))
	var title_query: String = str(args.get("title", ""))

	# By ID
	if not id.is_empty():
		var item := db.get_item(id)
		if item.is_empty():
			return {"error": "Skill not found: %s" % id}
		if str(item.get("type", "")) != "skill":
			return {"error": "Item %s is type '%s', not a skill" % [id, item.get("type", "")]}
		return _format_skill(item)

	# By title search
	if not title_query.is_empty():
		var query := {"filter": {"type": "skill"}}
		var results := db.execute_query(query, "lean")
		if results.size() == 1 and results[0] is Dictionary and results[0].has("_error"):
			return {"error": results[0]["_error"]}

		# Find best match — exact first, then contains
		var exact_match: Dictionary = {}
		var partial_matches: Array = []
		for item in results:
			var item_title: String = str(item.get("title", ""))
			if item_title.to_lower() == title_query.to_lower():
				exact_match = db.get_item(str(item.get("id", "")))
				break
			elif item_title.to_lower().contains(title_query.to_lower()):
				partial_matches.append(item)

		if not exact_match.is_empty():
			return _format_skill(exact_match)

		if partial_matches.size() == 1:
			var full := db.get_item(str(partial_matches[0].get("id", "")))
			if not full.is_empty():
				return _format_skill(full)

		if partial_matches.size() > 1:
			var titles: Array = []
			for m in partial_matches:
				titles.append(str(m.get("title", "")))
			return {"error": "Multiple skills match '%s': %s" % [title_query, str(titles)]}

		return {"error": "No skill found matching title: %s" % title_query}

	return {"error": "Provide either 'id' or 'title'"}


func _format_skill(item: Dictionary) -> Dictionary:
	var result := {
		"id": item.get("id", ""),
		"title": item.get("title", ""),
		"status": item.get("status", ""),
	}
	# Include all non-empty skill fields
	for field in ["description", "steps", "preconditions", "outcome",
				   "component", "topic", "tags", "quality", "tool_deps",
				   # prompt_text holds the long-form §0–§N system_prompt
				   # (manifest's `system_prompt`). Without it, MCPSkillTools'
				   # _compose_skill_instructions falls back to steps-only and
				   # plugin-shipped guidance (e.g. cad's "MCAD is NOT OpenSCAD"
				   # callout) never reaches the activated agent.
				   "prompt_text",
				   # Plugin-shipped skills metadata (DCR 019df57b).
				   # source: plugin badge; deprecated: hide rule;
				   # unsatisfied_deps: picker hides when non-empty (T5).
				   # pristine_hash / pristine_content / customised are
				   # reconciliation-time only and would bloat lean responses.
				   "source", "deprecated", "unsatisfied_deps"]:
		var val = item.get(field, "")
		if val is String and val.is_empty():
			continue
		if val is Array and val.is_empty():
			continue
		if val is int and val == 0:
			continue
		if val is bool and not val:
			continue
		result[field] = val
	return result

extends RefCounted
class_name DocketUpdate


func get_definition() -> Dictionary:
	return {
		"name": "docket_update",
		"description": "Update fields on an existing item. Not for state transitions — use docket_transition.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"id": {"type": "string", "description": "Full ID or short prefix (min 4 chars)"},
				"title": {"type": "string"},
				"description": {"type": "string"},
				"priority": {"type": "integer"},
				"severity": {"type": "integer"},
				"tags": {"type": "array", "items": {"type": "string"}},
				"assigned_to": {"type": "string"},
				"directed_to": {"type": "string"},
				"parent": {"type": "string", "description": "Parent item ID (e.g. DKT-0009)"},
				# Bug fields
				"environment": {"type": "string"},
				"repro_steps": {"type": "string"},
				# RCA fields
				"occurred_at": {"type": "string"},
				"detected_at": {"type": "string"},
				"reported_at": {"type": "string"},
				"why_chain": {"type": "string"},
				"significant_events": {"type": "string"},
				"contributing_factors": {"type": "string"},
				# Hint fields
				"value": {"type": "string"},
				"component": {"type": "string"},
				"key": {"type": "string"},
				"confidence": {"type": "string"},
				"research_cost": {"type": "integer", "minimum": 0},
				# Insight fields
				"assumed": {"type": "string"},
				"corrected": {"type": "string"},
				"surprise": {"type": "string"},
				"surfaced_from": {"type": "string"},
				# Question fields
				"findings": {"type": "string"},
				"answer": {"type": "string"},
				# Test fields
				"test_setup": {"type": "string", "description": "Setup instructions (conda envs, libs, resources)"},
				"test_steps": {"type": "string", "description": "Execution steps"},
				"expected_result": {"type": "string", "description": "Expected outcome"},
				# Skill fields
				"steps": {"type": "string", "description": "The executable pipeline — ordered commands/actions for an LLM to follow"},
				"preconditions": {"type": "string", "description": "What must be true before using this skill"},
				"outcome": {"type": "string", "description": "What success looks like when the skill completes"},
				# Prompt fields
				"parameters": {"type": "string", "description": "Variables or placeholders in the prompt"},
				# KB fields
				"article": {"type": "string", "description": "The full article body (long-form content)"},
				"summary": {"type": "string", "description": "Short preview (1-2 sentences) for search results"},
				# Knowledge quality fields
				"quality": {"type": "integer", "minimum": -5, "maximum": 5, "description": "Quality score (-5 to +5, knowledge types only)"},
				"last_reviewed": {"type": "string", "description": "ISO 8601 timestamp of last quality review"},
				# Work item fields
				"blocked_by": {"type": "string"},
				# Model targeting
				"target": {"type": "string", "description": "Model targeting expression. Grammar: family[:version][@provider]. Examples: 'all', 'sonnet', 'sonnet:<=4.6', 'sonnet:<=4.6@openrouter'. Comma-separated for OR."},
				# Multi-project
				"project": {"type": "string", "description": "Target project name (optional, defaults to primary)"},
			},
			"required": ["id"],
		},
	}


func execute(args: Dictionary, schema: Dictionary, db: DocketDB) -> Dictionary:
	var id: String = args.get("id", "")
	if not db.has_item(id):
		return {"error": "Item not found: %s" % id}

	# Auto-qualify parent if bare ID
	if args.has("parent") and not str(args.parent).is_empty():
		var parent_str: String = str(args.parent)
		if not parent_str.contains(":"):
			var proj_name := db.get_project_name()
			if not proj_name.is_empty():
				args["parent"] = "%s:%s" % [proj_name, parent_str]

	var item: Dictionary = db.get_item(id)
	var changes := args.duplicate()
	changes.erase("id")
	changes.erase("project")

	var result = DataModel.update_item(schema, item, changes)
	if result.has("error"):
		return result

	var write_back := DataModel.build_write_back(item, changes)
	db.update_item_fields(id, write_back)
	var changed_keys := PackedStringArray(changes.keys())

	if changed_keys.size() > 0:
		db.add_event(id, "updated", "", "Updated: %s" % ", ".join(changed_keys))

	return {"id": id, "status": "updated"}

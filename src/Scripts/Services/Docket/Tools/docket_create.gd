extends RefCounted
class_name DocketCreate


func get_definition() -> Dictionary:
	return {
		"name": "docket_create",
		"description": "Create a new work item. Supports types: bug, dcr, rca, chore, hint, insight, question, work_item, test, discussion, skill, prompt, kb, policy. For secrets, use docket_secret_set instead.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"type": {"type": "string", "enum": ["bug", "dcr", "rca", "chore", "hint", "insight", "question", "work_item", "test", "discussion", "skill", "prompt", "kb", "policy"]},
				"title": {"type": "string"},
				"description": {"type": "string"},
				"priority": {"type": "integer", "minimum": 1, "maximum": 4},
				"severity": {"type": "integer", "minimum": 1, "maximum": 4},
				"tags": {"type": "array", "items": {"type": "string"}},
				"assigned_to": {"type": "string"},
				"directed_to": {"type": "string"},
				"parent": {"type": "string", "description": "Parent item ID (e.g. DKT-0009)"},
				# Bug fields
				"environment": {"type": "string"},
				"repro_steps": {"type": "string"},
				"resolution": {"type": "string"},
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
				"parameters": {"type": "string", "description": "Variables or placeholders in the prompt, e.g. {{language}}"},
				# KB fields
				"article": {"type": "string", "description": "The full article body (long-form content)"},
				"summary": {"type": "string", "description": "Short preview (1-2 sentences) for search results"},
				# Work item fields
				"blocked_by": {"type": "string"},
				# Multi-project
				"project": {"type": "string", "description": "Target project name (optional, defaults to primary)"},
			},
			"required": ["type", "title"],
		},
	}


func execute(args: Dictionary, schema: Dictionary, db: DocketDB) -> Dictionary:
	# Auto-qualify parent if bare ID
	if args.has("parent") and not str(args.parent).is_empty():
		var parent_str: String = str(args.parent)
		if not parent_str.contains(":"):
			var proj_name := db.get_project_name()
			if not proj_name.is_empty():
				args["parent"] = "%s:%s" % [proj_name, parent_str]

	var item_type: String = str(args.get("type", ""))

	# Reject secret/encrypted_note — use docket_secret_set for vault storage
	if item_type in ["secret", "encrypted_note"]:
		return {"error": "type:%s is not allowed in docket_create. Use docket_secret_set for vault-only secret storage." % item_type}

	# Validate tags is an Array before passing to DataModel
	if args.has("tags") and not (args.tags is Array):
		args["tags"] = [str(args.tags)]

	var item = DataModel.create_item(schema, item_type, args)
	if item.has("error"):
		return item

	var id := db.next_uuid7_id()
	var insert_err := db.insert_item(id, item)
	if not insert_err.is_empty():
		return {"error": "Failed to persist item: %s" % insert_err}

	return {"id": id, "type": str(item.get("type", "")), "status": str(item.get("status", "")), "title": str(item.get("title", ""))}

extends RefCounted
class_name DocketLink


func get_definition() -> Dictionary:
	return {
		"name": "docket_link",
		"description": "Link two work items with a typed relationship.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"from": {"type": "string", "description": "Full ID or short prefix (min 4 chars)"},
				"to": {"type": "string", "description": "Full ID or short prefix (min 4 chars), optionally cross-project qualified like 'project:DKT-0042'"},
				"relation": {"type": "string", "enum": ["caused_by", "blocks", "duplicates", "follow_up", "surfaced"]},
				"project": {"type": "string", "description": "Project name (optional, defaults to primary)"},
			},
			"required": ["from", "to", "relation"],
		},
	}


func execute(args: Dictionary, schema: Dictionary, db: DocketDB, project_dbs: Dictionary = {}) -> Dictionary:
	var from_id: String = args.get("from", "")
	var to_id_raw: String = args.get("to", "")
	var relation: String = args.get("relation", "")

	# Resolve the "from" item in the specified project DB
	var from_db := _resolve_db(args, db, project_dbs)
	if not from_db.has_item(from_id):
		return {"error": "Item not found: %s" % from_id}

	# Parse cross-project qualifier on "to" (e.g. "otherproject:DKT-0002")
	var to_id := to_id_raw
	var to_project := ""
	if ":" in to_id_raw:
		var parts := to_id_raw.split(":", true, 1)
		to_project = parts[0]
		to_id = parts[1]

	# Validate the "to" item exists
	if not to_project.is_empty():
		if not project_dbs.has(to_project):
			return {"error": "Unknown project: %s" % to_project}
		var to_db: DocketDB = project_dbs[to_project]
		if not to_db.has_item(to_id):
			return {"error": "Item not found in project '%s': %s" % [to_project, to_id]}
	else:
		if not from_db.has_item(to_id):
			return {"error": "Item not found: %s" % to_id}

	var valid_relations: Array = schema.get("link_relations", [])
	if not valid_relations.has(relation):
		return {"error": "Invalid relation '%s'. Valid: %s" % [relation, str(valid_relations)]}

	# Store the link — use qualified ID for cross-project refs
	var stored_to := to_id_raw if not to_project.is_empty() else to_id
	from_db.add_link(from_id, stored_to, relation)
	from_db.add_event(from_id, "linked", "agent",
		"Linked %s → %s (%s)" % [from_id, stored_to, relation])

	return {"from": from_id, "to": stored_to, "relation": relation}


func _resolve_db(args: Dictionary, default_db: DocketDB, project_dbs: Dictionary) -> DocketDB:
	var proj_name: String = str(args.get("project", ""))
	if not proj_name.is_empty() and project_dbs.has(proj_name):
		return project_dbs[proj_name]
	return default_db

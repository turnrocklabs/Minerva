extends RefCounted
class_name DocketMove


func get_definition() -> Dictionary:
	return {
		"name": "docket_move",
		"description": "Move an item from one project to another. Transfers all data (tags, events, comments, attachments) and updates cross-project parent/blocked_by references.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"id": {"type": "string", "description": "Full ID or short prefix (min 4 chars)"},
				"target_project": {"type": "string", "description": "Name of the target project"},
			},
			"required": ["id", "target_project"],
		},
	}


func execute(args: Dictionary, _schema: Dictionary, _primary_db: DocketDB, project_dbs: Dictionary = {}) -> Dictionary:
	var item_id: String = str(args.get("id", ""))
	var target_project: String = str(args.get("target_project", ""))

	if item_id.is_empty() or target_project.is_empty():
		return {"error": "Missing 'id' or 'target_project'"}

	# If no multi-project context, can't move
	if project_dbs.is_empty():
		return {"error": "No projects loaded — cannot move items"}

	# Find source DB
	var source_db: DocketDB = null
	var source_name: String = ""
	for proj_name in project_dbs:
		var pdb: DocketDB = project_dbs[proj_name]
		if pdb.has_item(item_id):
			source_db = pdb
			source_name = proj_name
			break
	if source_db == null:
		return {"error": "Item not found: %s" % item_id}

	# Find target DB (case-insensitive match)
	var target_db: DocketDB = null
	var canonical_target := target_project
	for proj_name in project_dbs:
		if proj_name.to_lower() == target_project.to_lower():
			target_db = project_dbs[proj_name]
			canonical_target = proj_name
			break
	if target_db == null:
		return {"error": "Target project not found: %s" % target_project}
	if source_db == target_db:
		return {"error": "Item is already in project '%s'" % canonical_target}

	# Export full item (data + events + comments + attachments)
	var exported := source_db.export_item_full(item_id)
	if exported.is_empty():
		return {"error": "Failed to export item %s" % item_id}

	var new_id: String
	var refs_updated := 0

	if DocketDB._is_uuid7(item_id):
		# UUID7 items keep their ID — globally unique, no rewrite needed
		new_id = item_id
		target_db.import_item_full(new_id, exported)
		source_db.delete_item(item_id)
	else:
		# Legacy items get upgraded to UUID7 on move
		new_id = target_db.next_uuid7_id()
		target_db.import_item_full(new_id, exported)
		source_db.delete_item(item_id)
		# Rewrite cross-project references in ALL projects
		var old_qualified := "%s:%s" % [source_name, item_id]
		var new_qualified := "%s:%s" % [canonical_target, new_id]
		for proj_name in project_dbs:
			var pdb: DocketDB = project_dbs[proj_name]
			refs_updated += pdb.rewrite_refs(old_qualified, new_qualified, item_id, new_qualified)

	return {
		"old_id": item_id,
		"new_id": new_id,
		"old_project": source_name,
		"new_project": canonical_target,
		"refs_updated": refs_updated,
	}

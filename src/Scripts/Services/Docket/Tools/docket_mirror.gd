extends RefCounted
class_name DocketMirror
## MCP tool: mirror fields (and optionally state) from one item to another across projects.
## Pull mode (fields is Array): read named fields from source, copy to target.
## Push mode (fields is Dict): write provided values directly to target.


func get_definition() -> Dictionary:
	return {
		"name": "docket_mirror",
		"description": "Mirror fields from a source item to a target item across projects. Pull mode (fields=Array) copies field values from source; push mode (fields=Dict) writes values directly. Optionally transitions the target and adds an audit comment.",
		"inputSchema": {
			"type": "object",
			"properties": {
				"source_id": {"type": "string", "description": "Source item ID (full or short prefix)"},
				"source_project": {"type": "string", "description": "Source project name (optional, defaults to primary)"},
				"target_id": {"type": "string", "description": "Target item ID (full or short prefix)"},
				"target_project": {"type": "string", "description": "Target project name (optional, defaults to primary)"},
				"fields": {"description": "Array of field names to pull from source, or Dict of field:value pairs to push"},
				"transition_to": {"type": "string", "description": "Optional state to transition the target to"},
				"note": {"type": "string", "description": "Optional audit note"},
			},
			"required": ["source_id", "target_id", "fields"],
		},
	}


func execute(args: Dictionary, schema: Dictionary, primary_db: DocketDB, project_dbs: Dictionary = {}) -> Dictionary:
	var source_id: String = str(args.get("source_id", ""))
	var target_id: String = str(args.get("target_id", ""))
	if source_id.is_empty() or target_id.is_empty():
		return {"error": "Missing 'source_id' or 'target_id'"}

	var fields = args.get("fields", null)
	if fields == null:
		return {"error": "Missing 'fields' parameter"}

	var source_project: String = str(args.get("source_project", ""))
	var target_project: String = str(args.get("target_project", ""))
	var transition_to: String = str(args.get("transition_to", ""))
	var note: String = str(args.get("note", ""))

	# Resolve DBs
	var source_db := _resolve_project_db(source_project, primary_db, project_dbs)
	var target_db := _resolve_project_db(target_project, primary_db, project_dbs)

	# Build payload from pull or push mode
	var payload := {}
	var field_list: PackedStringArray = []
	var source_proj_label := source_project if not source_project.is_empty() else _primary_name(primary_db, project_dbs)

	if fields is Array:
		# Pull mode: read from source
		if not source_db.has_item(source_id):
			return {"error": "Source item not found: %s" % source_id}
		var source_item: Dictionary = source_db.get_item(source_id)
		for field_name in fields:
			var fname: String = str(field_name)
			if source_item.has(fname) and str(source_item[fname]) != "":
				payload[fname] = source_item[fname]
				field_list.append(fname)
		if payload.is_empty():
			return {"error": "No matching non-empty fields found on source item"}
	elif fields is Dictionary:
		# Push mode: use provided values directly
		for key in fields:
			payload[str(key)] = fields[key]
			field_list.append(str(key))
		if payload.is_empty():
			return {"error": "Fields dictionary is empty"}
	else:
		return {"error": "'fields' must be an Array (pull mode) or Dictionary (push mode)"}

	# Validate target exists
	if not target_db.has_item(target_id):
		return {"error": "Target item not found: %s" % target_id}

	# Apply field updates via DataModel validation
	var target_item: Dictionary = target_db.get_item(target_id)
	var update_result = DataModel.update_item(schema, target_item, payload)
	if update_result.has("error"):
		return update_result

	var write_back := DataModel.build_write_back(target_item, payload)
	target_db.update_item_fields(target_id, write_back)

	# Optional transition
	var transitioned_to := ""
	if not transition_to.is_empty():
		var extra := {}
		var trans_result = StateMachine.perform_transition(schema, target_item, transition_to, "agent", note, extra)
		if trans_result.has("error"):
			return trans_result

		var trans_write := {"status": target_item.status, "updated_at": target_item.updated_at}
		target_db.update_item_fields(target_id, trans_write)

		# Persist transition event
		var events: Array = target_item.get("events", [])
		if events.size() > 0:
			var ev: Dictionary = events[events.size() - 1]
			target_db.add_event(target_id, str(ev.get("event_type", "")), str(ev.get("actor", "")), str(ev.get("note", "")))

		transitioned_to = transition_to

	# Audit comment
	var comment_text := "Mirrored from %s:%s [%s]" % [source_proj_label, source_id, ", ".join(field_list)]
	if not note.is_empty():
		comment_text += ": %s" % note
	var comment_result := target_db.add_comment(target_id, "agent", comment_text)

	# Mirrored event
	target_db.add_event(target_id, "mirrored", "agent", comment_text)

	var result := {
		"target_id": target_id,
		"target_project": target_project if not target_project.is_empty() else source_proj_label,
		"pushed_fields": Array(field_list),
	}
	if not transitioned_to.is_empty():
		result["transitioned_to"] = transitioned_to
	if comment_result.has("id"):
		result["comment_id"] = comment_result.id
	return result


func _resolve_project_db(name: String, primary_db: DocketDB, project_dbs: Dictionary) -> DocketDB:
	if name.is_empty():
		return primary_db
	# Case-insensitive lookup
	for proj_name in project_dbs:
		if proj_name.to_lower() == name.to_lower():
			return project_dbs[proj_name]
	return primary_db


func _primary_name(primary_db: DocketDB, project_dbs: Dictionary) -> String:
	# Find the project name that maps to the primary DB
	for proj_name in project_dbs:
		if project_dbs[proj_name] == primary_db:
			return proj_name
	return "primary"

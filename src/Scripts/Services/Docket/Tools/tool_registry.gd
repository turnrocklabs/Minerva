extends RefCounted
class_name ToolRegistry
## Maps tool names to handlers. Generates MCP schemas.

var _schema: Dictionary
var _db: DocketDB
var _project_dbs: Dictionary = {}  # project_name → DocketDB
var _tools: Dictionary = {}
var add_project_fn: Callable  # func(path: String) -> Dictionary
var remove_project_fn: Callable  # func(name: String) -> Dictionary
var gui_open_fn: Callable  # func(request: Dictionary) -> Dictionary


## Reads that also bump a retrieval counter.
const _COUNTING_READS := ["docket_hint_get", "docket_hint_query"]


func _build_tools() -> Dictionary:
	return {
		"docket_create": DocketCreate.new(),
		"docket_get": DocketGet.new(),
		"docket_update": DocketUpdate.new(),
		"docket_transition": DocketTransition.new(),
		"docket_query": DocketQuery.new(),
		"docket_link": DocketLink.new(),
		"docket_context": DocketContext.new(),
		"docket_saved_query": DocketSavedQuery.new(),
		"docket_hint_set": DocketHintSet.new(),
		"docket_hint_get": DocketHintGet.new(),
		"docket_hint_query": DocketHintQuery.new(),
		"docket_attach": DocketAttach.new(),
		"docket_detach": DocketDetach.new(),
		"docket_comment": DocketComment.new(),
		"docket_move": DocketMove.new(),
		"docket_mirror": DocketMirror.new(),
		"docket_delete": DocketDelete.new(),
		"docket_transition_report": DocketTransitionReport.new(),
		"docket_error_report": DocketErrorReport.new(),
		"docket_secret_get": DocketSecretGet.new(),
		"docket_secret_set": DocketSecretSet.new(),
		"docket_secret_list": DocketSecretList.new(),
		"docket_secret_delete": DocketSecretDelete.new(),
		"docket_project_list": DocketProjectList.new(),
		"docket_project_add": DocketProjectAdd.new(),
		"docket_project_remove": DocketProjectRemove.new(),
		"docket_gui_open": DocketGuiOpen.new(),
		"docket_get_state_machine": DocketGetStateMachine.new(),
		"docket_quality": DocketQuality.new(),
		"docket_project_meta": DocketProjectMeta.new(),
		"docket_skill_list": DocketSkillList.new(),
		"docket_skill_get": DocketSkillGet.new(),
		"docket_persist": DocketPersist.new(),
	}


func init(schema: Dictionary, db: DocketDB, project_dbs: Dictionary = {}) -> void:
	_schema = schema
	_db = db
	_project_dbs = project_dbs
	_tools = _build_tools()
	_init_schema_dependent_tools(schema)


func update_db(schema: Dictionary, db: DocketDB, project_dbs: Dictionary = {}) -> void:
	_schema = schema
	_db = db
	_project_dbs = project_dbs
	_tools = _build_tools()
	_init_schema_dependent_tools(schema)


func has_tool(name: String) -> bool:
	return _tools.has(name)


func list_tools() -> Array:
	var result: Array = []
	for tool_name in _tools:
		result.append(_tools[tool_name].get_definition())
	return result


const _ID_FIELDS := ["id", "item_id", "from", "to", "source_id", "target_id"]


func call_tool(name: String, arguments: Dictionary) -> Dictionary:
	if not _tools.has(name):
		var err := {"error": "Unknown tool: %s" % name}
		_log_error(name, arguments, err)
		return err
	# Pre-resolve short ID prefixes to full IDs before dispatching
	var resolution_error := _resolve_id_args(arguments)
	if not resolution_error.is_empty():
		return {"error": resolution_error}
	var refusal := _mutation_precheck(name, arguments)
	if not refusal.is_empty():
		return {"error": refusal}
	# These tools need access to all project DBs for cross-project operations
	var result: Dictionary
	if name in ["docket_move", "docket_mirror", "docket_link"]:
		result = _tools[name].execute(arguments, _schema, _db, _project_dbs)
	elif name in ["docket_project_list", "docket_project_add", "docket_project_remove", "docket_project_meta"]:
		result = _tools[name].execute(arguments, _schema, _db, _project_dbs, add_project_fn, remove_project_fn)
	elif name == "docket_gui_open":
		result = _tools[name].execute(arguments, _schema, _db, _project_dbs, gui_open_fn)
	else:
		var db := _resolve_db(arguments)
		db.write_error = ""
		var writes := db.writes
		result = _tools[name].execute(arguments, _schema, db)
		# A change is reported made only once it is stored. A hint read's
		# retrieval count is bookkeeping: failing to store it fails no read.
		if not result.has("error") and db.writes != writes and not name in _COUNTING_READS:
			var unsaved := db.persist()
			if not unsaved.is_empty():
				result = {"error": "Docket could not save the change: %s" % unsaved}
	if result.has("error"):
		_log_error(name, arguments, result)
	return result


func _mutation_precheck(name: String, args: Dictionary) -> String:
	if name in ["docket_get", "docket_query", "docket_context", "docket_transition_report", "docket_error_report", "docket_secret_get", "docket_secret_list", "docket_project_list", "docket_project_add", "docket_project_remove", "docket_gui_open", "docket_get_state_machine", "docket_skill_list", "docket_skill_get"] or name in _COUNTING_READS:
		return ""
	if name == "docket_comment" and args.get("action", "") == "list":
		return ""
	if name in ["docket_saved_query", "docket_project_meta"] and args.get("action", "") != "set" and args.get("action", "") != "save":
		return ""
	var targets: Array[DocketDB] = [_resolve_db(args)]
	if name == "docket_mirror":
		for field in ["source_project", "target_project"]:
			var requested := str(args.get(field, ""))
			var found := requested.is_empty()
			for project in _project_dbs:
				found = found or project.to_lower() == requested.to_lower()
			if not found:
				return "Unknown project: %s" % requested
		var target := str(args.get("target_project", ""))
		targets = [_db]
		for project in _project_dbs:
			if project.to_lower() == target.to_lower():
				targets = [_project_dbs[project]]
	elif name == "docket_move":
		targets.clear()
		var id := str(args.get("id", ""))
		var target := str(args.get("target_project", ""))
		for project in _project_dbs:
			var db: DocketDB = _project_dbs[project]
			if db.has_item(id) or project.to_lower() == target.to_lower():
				targets.append(db)
	for db in targets:
		if not db.ensure_writable():
			return db.write_error
	return ""


func _log_error(tool_name: String, args: Dictionary, result: Dictionary) -> void:
	if _db and _db.is_open():
		var arg_keys := ",".join(PackedStringArray(args.keys()))
		_db.log_mcp_error(tool_name, str(result.error), arg_keys)


func _resolve_id_args(args: Dictionary) -> String:
	for field in _ID_FIELDS:
		var val := str(args.get(field, ""))
		if val.length() < 4 or DocketDB._is_uuid7(val) or not val.is_valid_hex_number(false):
			continue
		var projects := _project_dbs.duplicate()
		if not projects.values().has(_db):
			projects[_db.get_project_name()] = _db
		var candidates: Array = []
		for project in projects:
			var db: DocketDB = projects[project]
			for item in db.execute_query({"filter": {"conditions": [{"field": "id", "value": val}]}}):
				candidates.append({"id": item.id, "name": "%s:%s (%s)" % [project, item.id, item.get("title", "")]})
		if candidates.size() > 1:
			var names := PackedStringArray()
			for candidate in candidates:
				names.append(candidate.name)
			return "Ambiguous ID '%s': %s" % [val, ", ".join(names)]
		if candidates.size() == 1:
			args[field] = candidates[0].id
	return ""


func _resolve_db(arguments: Dictionary) -> DocketDB:
	var proj_name: String = str(arguments.get("project", ""))
	if not proj_name.is_empty() and _project_dbs.has(proj_name):
		return _project_dbs[proj_name]
	return _db


func _init_schema_dependent_tools(schema: Dictionary) -> void:
	## Initialize tools that need the schema for their definitions
	if _tools.has("docket_transition"):
		(_tools["docket_transition"] as DocketTransition).init(schema)

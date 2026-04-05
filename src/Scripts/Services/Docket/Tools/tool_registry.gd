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
	_resolve_id_args(arguments)
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
		result = _tools[name].execute(arguments, _schema, db)
	if result.has("error"):
		_log_error(name, arguments, result)
	return result


func _log_error(tool_name: String, args: Dictionary, result: Dictionary) -> void:
	if _db and _db.is_open():
		var arg_keys := ",".join(PackedStringArray(args.keys()))
		_db.log_mcp_error(tool_name, str(result.error), arg_keys)


func _resolve_id_args(args: Dictionary) -> void:
	## Try to resolve short hex prefixes in ID fields to full IDs.
	for field in _ID_FIELDS:
		if not args.has(field):
			continue
		var val: String = str(args[field])
		if val.is_empty():
			continue
		# Skip if it's already a full UUID7 or a known legacy ID
		if DocketDB._is_uuid7(val):
			continue
		# Skip legacy-format IDs (PREFIX-NNNN) — they use exact match
		if val.contains("-"):
			continue
		# Try resolving as a short hex prefix (min 4 chars)
		if val.length() >= 4 and val.is_valid_hex_number(false):
			var resolved := ""
			# Search across all project DBs
			for proj_name in _project_dbs:
				var pdb: DocketDB = _project_dbs[proj_name]
				var r := pdb.resolve_short_id(val)
				if not r.is_empty():
					resolved = r
					break
			# Fallback to primary DB
			if resolved.is_empty():
				resolved = _db.resolve_short_id(val)
			if not resolved.is_empty():
				args[field] = resolved


func _resolve_db(arguments: Dictionary) -> DocketDB:
	var proj_name: String = str(arguments.get("project", ""))
	if not proj_name.is_empty() and _project_dbs.has(proj_name):
		return _project_dbs[proj_name]
	return _db


func _init_schema_dependent_tools(schema: Dictionary) -> void:
	## Initialize tools that need the schema for their definitions
	if _tools.has("docket_transition"):
		(_tools["docket_transition"] as DocketTransition).init(schema)

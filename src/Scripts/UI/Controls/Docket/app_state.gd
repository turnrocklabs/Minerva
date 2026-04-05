extends RefCounted
class_name AppState
## Centralized state container for the Docket GUI.
## Holds schema, db(s), dct_path. Emits signals on file/data changes.
## Supports multiple loaded .dct projects simultaneously.

signal file_changed
signal data_changed
@warning_ignore("unused_signal")
signal open_item_requested(id: String)
@warning_ignore("unused_signal")
signal open_query_requested(filter: String, label: String)

var schema: Dictionary
var db: DocketDB  # Primary DB (first loaded)
var dct_path: String
var prefs: UserPrefs

# Multi-project support: project_name → DocketDB
var _project_dbs: Dictionary = {}


func load_from_docket_manager(dm: DocketManager) -> void:
	## Populate state from DocketManager (Minerva integration path).
	_project_dbs.clear()
	for proj_name in dm.get_loaded_projects():
		var pdb := dm.get_db(proj_name)
		if pdb:
			_project_dbs[proj_name] = pdb
			if db == null:
				db = pdb
	file_changed.emit()


func sync_from_docket_manager(dm: DocketManager) -> void:
	## Re-sync project DBs from DocketManager (after project load/unload).
	var old_primary_name := db.get_project_name() if db else ""
	_project_dbs.clear()
	db = null
	for proj_name in dm.get_loaded_projects():
		var pdb := dm.get_db(proj_name)
		if pdb:
			_project_dbs[proj_name] = pdb
			if proj_name == old_primary_name or db == null:
				db = pdb
	file_changed.emit()


func move_item(item_id: String, target_project: String) -> Dictionary:
	## Route through DocketManager's tool dispatch for move operations.
	var dm: DocketManager = SingletonObject.docket_manager
	if not dm:
		return {"error": "DocketManager not available"}
	var result := dm.call_tool("docket_move", {"id": item_id, "target_project": target_project})
	if not result.has("error"):
		data_changed.emit()
	return result


func get_project_dbs() -> Dictionary:
	return _project_dbs


func get_db_for_project(project_name: String) -> DocketDB:
	return _project_dbs.get(project_name)


func find_item_db(id: String) -> DocketDB:
	## Search all loaded project DBs for an item by ID.
	for proj_name in _project_dbs:
		var pdb: DocketDB = _project_dbs[proj_name]
		if pdb.has_item(id):
			return pdb
	return null


func get_project_name_for_item(id: String) -> String:
	## Return the project name that owns this item ID.
	for proj_name in _project_dbs:
		var pdb: DocketDB = _project_dbs[proj_name]
		if pdb.has_item(id):
			return proj_name
	return ""


func remove_project(project_name: String) -> Dictionary:
	## Close and remove a project. Zero open projects is allowed.
	if not _project_dbs.has(project_name):
		return {"error": "Project not found: %s" % project_name}

	var closing_db: DocketDB = _project_dbs[project_name]
	closing_db.close()
	_project_dbs.erase(project_name)

	# If we just closed the primary, promote the next one or clear
	if closing_db == db:
		if _project_dbs.size() > 0:
			var first_name: String = _project_dbs.keys()[0]
			db = _project_dbs[first_name]
			dct_path = db.get_path()
		else:
			db = null
			dct_path = ""

	file_changed.emit()
	return {"closed": project_name, "remaining": _project_dbs.keys()}


func find_children_across_projects(qualified_id: String) -> Array:
	## Search ALL loaded projects for items whose parent matches the given qualified ref.
	## Also matches bare ID form for backwards compatibility.
	var parsed := DocketDB.parse_qualified_ref(qualified_id)
	var bare_id: String = parsed.id
	var results: Array = []
	for proj_name in _project_dbs:
		var pdb: DocketDB = _project_dbs[proj_name]
		# Match qualified form (project:ID) and bare ID
		var rows := pdb.execute_query({"filter": {"$or": [
			{"field": "parent", "op": "eq", "value": qualified_id},
			{"field": "parent", "op": "eq", "value": bare_id},
		]}})
		for item in rows:
			item["project"] = proj_name
		results.append_array(rows)
	return results




func _extract_project_filter(query: Dictionary) -> Dictionary:
	## Extract and remove "project" conditions from a query filter.
	## Returns {op, value} if found, or {} if no project filter.
	var filter = query.get("filter")
	if not filter is Dictionary:
		return {}

	# Conditions-list format: {"conditions": [{field, op, value}, ...]}
	if filter.has("conditions") and filter.conditions is Array:
		var kept: Array = []
		var result := {}
		for cond in filter.conditions:
			if cond is Dictionary and str(cond.get("field", "")) == "project":
				result = {"op": str(cond.get("op", "eq")), "value": cond.get("value", "")}
			else:
				kept.append(cond)
		filter["conditions"] = kept
		if kept.is_empty():
			query.erase("filter")
		return result

	# Flat dict format: {"project": "x"} or {"project__ne": "x"}
	if filter.has("project"):
		var val = filter["project"]
		filter.erase("project")
		if filter.is_empty():
			query.erase("filter")
		return {"op": "eq", "value": val}
	if filter.has("project__ne"):
		var val = filter["project__ne"]
		filter.erase("project__ne")
		if filter.is_empty():
			query.erase("filter")
		return {"op": "neq", "value": val}

	return {}


func _project_matches(proj_name: String, pf: Dictionary) -> bool:
	var op: String = pf.get("op", "eq")
	var val: String = str(pf.get("value", ""))
	match op:
		"eq": return proj_name == val
		"neq": return proj_name != val
		"contains": return proj_name.contains(val)
		"not_contains": return not proj_name.contains(val)
		"like": return proj_name.matchn(val)
	return true


func execute_cross_project_query(query: Dictionary, detail: String = "full") -> Array:
	## Run a query across all loaded projects, inject "project" field into results.
	# Strip sort/limit from per-DB queries — "project" is a pseudo-field that
	# doesn't exist in SQL, and sort/limit must apply to the merged union.
	var db_query := query.duplicate(true)
	db_query.erase("sort")
	db_query.erase("limit")

	# Extract project filter from conditions — "project" is a pseudo-field
	var project_filter := _extract_project_filter(db_query)

	var all_results: Array = []
	for proj_name in _project_dbs:
		# Apply project filter: skip DBs that don't match
		if not project_filter.is_empty() and not _project_matches(proj_name, project_filter):
			continue
		var pdb: DocketDB = _project_dbs[proj_name]
		var results := pdb.execute_query(db_query, detail)
		for item in results:
			item["project"] = proj_name
		all_results.append_array(results)

	# Apply sort across union
	var sort_spec: Array = query.get("sort", [])
	if sort_spec.size() > 0:
		var field: String = str(sort_spec[0].get("field", ""))
		var dir: String = str(sort_spec[0].get("dir", "asc")).to_lower()
		if not field.is_empty():
			all_results.sort_custom(func(a, b):
				var va = a.get(field, "")
				var vb = b.get(field, "")
				if dir == "desc":
					return va > vb
				return va < vb
			)

	# Apply limit across union
	var limit: int = int(query.get("limit", 0))
	if limit > 0 and all_results.size() > limit:
		all_results.resize(limit)

	return all_results


func save() -> void:
	# SQLite writes are immediate; this is now just a signal emitter
	data_changed.emit()


func load_schema() -> void:
	var sf := FileAccess.open("res://Scripts/Services/Docket/Core/data/schema.json", FileAccess.READ)
	if sf:
		schema = JSON.parse_string(sf.get_as_text())
		sf.close()
	prefs = UserPrefs.load_prefs()

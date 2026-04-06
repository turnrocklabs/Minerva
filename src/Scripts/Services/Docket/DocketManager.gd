extends Node
class_name DocketManager
## Manages docket databases (master, personal, project) with signal-based event routing.
## Lives on SingletonObject. Master + personal load at startup; project dockets lazy-load.

# -- Signals ------------------------------------------------------------------

signal item_created(item_id: String, item_type: String, project_name: String)
signal item_transitioned(item_id: String, old_status: String, new_status: String, project_name: String)
signal item_updated(item_id: String, project_name: String)
signal comment_added(item_id: String, project_name: String)
signal project_loaded(project_name: String)
signal project_unloaded(project_name: String)

# -- Constants ----------------------------------------------------------------

const MASTER_DCT_RES := "res://Data/master.dct"
const MASTER_DCT_USER := "user://master.dct"
const MASTER_SHIPPED_HASH := "user://master.dct.shipped_hash"
const PERSONAL_DCT_USER := "user://personal.dct"
const REGISTRY_PATH := "user://docket_projects.cfg"

# -- State --------------------------------------------------------------------

var _master_db: DocketDB = null
var _personal_db: DocketDB = null
var _project_dbs: Dictionary = {}  # project_name → DocketDB
var _project_paths: Dictionary = {}  # project_name → filesystem path (for registry)
var _tool_registry: ToolRegistry = null
var _schema: Dictionary = {}
var _ready_done: bool = false

## Cached system prompts: key (e.g. "agentic-base") → prompt_text
var _prompt_cache: Dictionary = {}
var _prompt_cache_valid: bool = false

# -- Lifecycle ----------------------------------------------------------------

func _ready() -> void:
	_load_schema()
	_init_master()
	_init_personal()
	_load_registry()
	_restore_session()
	_init_tool_registry()
	_ready_done = true


func _restore_session() -> void:
	## Re-open project dockets that were loaded in the previous session.
	var paths := UserPrefs.load_session()
	for path in paths:
		# Skip cache files (stale session data from before the fix)
		if path.ends_with(".cache"):
			continue
		if FileAccess.file_exists(path) and not _is_already_loaded(path):
			open_project(path)


func _is_already_loaded(abs_path: String) -> bool:
	for proj_name in _project_paths:
		if _project_paths[proj_name] == abs_path:
			return true
	return false


func _exit_tree() -> void:
	close_all()


func _load_schema() -> void:
	var f := FileAccess.open("res://Scripts/Services/Docket/Core/data/schema.json", FileAccess.READ)
	if f:
		var parsed = JSON.parse_string(f.get_as_text())
		if parsed is Dictionary:
			_schema = parsed
		f.close()
	if _schema.is_empty():
		push_warning("DocketManager: could not load schema.json")


func _init_master() -> void:
	var user_path := ProjectSettings.globalize_path(MASTER_DCT_USER)
	# Copy from res:// on first run
	if not FileAccess.file_exists(MASTER_DCT_USER):
		if FileAccess.file_exists(MASTER_DCT_RES):
			var res_path := ProjectSettings.globalize_path(MASTER_DCT_RES)
			DirAccess.copy_absolute(res_path, user_path)
			# Also copy .cache if it exists
			if FileAccess.file_exists(MASTER_DCT_RES + ".cache"):
				DirAccess.copy_absolute(res_path + ".cache", user_path + ".cache")
	if FileAccess.file_exists(MASTER_DCT_USER):
		_master_db = JSONLCache.open_or_rebuild(user_path)
		if _master_db:
			_master_db.set_project_name("master")
	else:
		# No shipped master.dct — create empty
		_master_db = DocketDB.create_new(user_path + ".cache")
		if _master_db:
			_master_db.set_project_name("master")
	if _master_db:
		_project_dbs["master"] = _master_db
		_project_paths["master"] = user_path
		# Merge any shipped updates from res://master.dct into user://
		if FileAccess.file_exists(MASTER_DCT_RES):
			_merge_shipped_master()


func _merge_shipped_master() -> void:
	## Compare shipped res://master.dct against a stored hash. If changed,
	## upsert shipped items into the user:// DB (preserving user-created items).
	var res_path := ProjectSettings.globalize_path(MASTER_DCT_RES)
	var hash_path := ProjectSettings.globalize_path(MASTER_SHIPPED_HASH)

	# Compute hash of shipped file
	var f := FileAccess.open(MASTER_DCT_RES, FileAccess.READ)
	if not f:
		return
	var content := f.get_as_text()
	f.close()
	var current_hash := str(content.hash())

	# Compare with stored hash
	var stored_hash := ""
	if FileAccess.file_exists(MASTER_SHIPPED_HASH):
		var hf := FileAccess.open(MASTER_SHIPPED_HASH, FileAccess.READ)
		if hf:
			stored_hash = hf.get_as_text().strip_edges()
			hf.close()

	if current_hash == stored_hash:
		return  # No changes since last sync

	# Parse shipped items
	var parsed := JSONLParser.parse_file(res_path)
	var shipped_items: Array = parsed.get("items", [])
	if shipped_items.is_empty():
		return

	# Upsert each shipped item into the master DB
	var updated := 0
	var inserted := 0
	for item: Dictionary in shipped_items:
		var id: String = str(item.get("id", ""))
		if id.is_empty():
			continue
		if _master_db.has_item(id):
			# Update existing — overwrite with shipped version
			var changes := {}
			for key in item:
				if key not in ["id", "_type", "events"]:
					changes[key] = item[key]
			# Tags are comma-separated strings in JSONL but update_item_fields expects Array
			if changes.has("tags") and changes["tags"] is String:
				var tag_str: String = changes["tags"]
				changes["tags"] = tag_str.split(",") if not tag_str.is_empty() else []
			_master_db.update_item_fields(id, changes)
			updated += 1
		else:
			# Insert new shipped item
			_master_db.insert_item(id, item)
			inserted += 1

	# Save the hash so we don't re-merge next startup
	var hf := FileAccess.open(MASTER_SHIPPED_HASH, FileAccess.WRITE)
	if hf:
		hf.store_string(current_hash)
		hf.close()

	if updated > 0 or inserted > 0:
		print("[DocketManager] Merged shipped master.dct: %d updated, %d inserted" % [updated, inserted])
		invalidate_prompt_cache()


func _init_personal() -> void:
	var user_path := ProjectSettings.globalize_path(PERSONAL_DCT_USER)
	if FileAccess.file_exists(PERSONAL_DCT_USER):
		_personal_db = JSONLCache.open_or_rebuild(user_path)
		if _personal_db:
			_personal_db.set_project_name("personal")
			_project_dbs["personal"] = _personal_db
			_project_paths["personal"] = user_path


func _ensure_personal() -> DocketDB:
	## Create personal.dct on demand (first write).
	if _personal_db:
		return _personal_db
	var user_path := ProjectSettings.globalize_path(PERSONAL_DCT_USER)
	# Create empty JSONL file first, then build cache
	var f := FileAccess.open(PERSONAL_DCT_USER, FileAccess.WRITE)
	if f:
		var meta_line := JSON.stringify({"_type": "meta", "version": "1.0.0", "counter": 0, "id_prefix": "PRS", "project": "personal"})
		f.store_line(meta_line)
		f.close()
	_personal_db = JSONLCache.open_or_rebuild(user_path)
	if not _personal_db:
		_personal_db = DocketDB.create_new(user_path + ".cache")
	if _personal_db:
		_personal_db.set_project_name("personal")
		_project_dbs["personal"] = _personal_db
		_project_paths["personal"] = user_path
	return _personal_db


func _init_tool_registry() -> void:
	_tool_registry = ToolRegistry.new()
	var primary := _master_db if _master_db else DocketDB.new()
	_tool_registry.init(_schema, primary, _project_dbs)
	_tool_registry.add_project_fn = _add_project_from_tool
	_tool_registry.remove_project_fn = _remove_project_from_tool


# -- Project registry ---------------------------------------------------------

func _load_registry() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(REGISTRY_PATH) == OK:
		if cfg.has_section("projects"):
			for key in cfg.get_section_keys("projects"):
				_project_paths[key] = cfg.get_value("projects", key, "")


func _save_registry() -> void:
	var cfg := ConfigFile.new()
	for proj_name in _project_paths:
		cfg.set_value("projects", proj_name, _project_paths[proj_name])
	cfg.save(REGISTRY_PATH)


# -- Project open/close -------------------------------------------------------

func open_project(dct_path: String) -> Dictionary:
	## Open a project docket from a .dct JSONL file path. Returns status dict.
	var abs_path: String = dct_path
	if dct_path.begins_with("res://") or dct_path.begins_with("user://"):
		abs_path = ProjectSettings.globalize_path(dct_path)
	if not FileAccess.file_exists(abs_path):
		return {"error": "File not found: %s" % abs_path}
	var db := JSONLCache.open_or_rebuild(abs_path)
	if not db:
		return {"error": "Failed to open docket: %s" % abs_path}
	var proj_name := db.get_project_name()
	if proj_name.is_empty():
		proj_name = abs_path.get_file().get_basename()
		db.set_project_name(proj_name)
	# Close existing if same name
	if _project_dbs.has(proj_name) and _project_dbs[proj_name] != db:
		_project_dbs[proj_name].close()
	_project_dbs[proj_name] = db
	_project_paths[proj_name] = abs_path
	_save_registry()
	_refresh_tool_registry()
	project_loaded.emit(proj_name)
	return {"success": true, "project": proj_name, "path": abs_path}


func close_project(project_name: String) -> Dictionary:
	## Close a project docket. Cannot close master.
	if project_name == "master":
		return {"error": "Cannot close master docket"}
	if not _project_dbs.has(project_name):
		return {"error": "Project '%s' not loaded" % project_name}
	_save_project_to_jsonl(project_name)
	_project_dbs[project_name].close()
	_project_dbs.erase(project_name)
	_refresh_tool_registry()
	project_unloaded.emit(project_name)
	return {"success": true, "project": project_name}


func get_db(project_name: String = "master") -> DocketDB:
	## Get a loaded project's DB. Returns null if not loaded.
	return _project_dbs.get(project_name)


func get_master_db() -> DocketDB:
	return _master_db


func get_personal_db() -> DocketDB:
	return _personal_db


func get_loaded_projects() -> Array[String]:
	var names: Array[String] = []
	for key in _project_dbs:
		names.append(key)
	return names


func get_known_projects() -> Dictionary:
	## Returns {project_name: {"path": ..., "loaded": bool}} for all known projects.
	var result := {}
	for proj_name in _project_paths:
		result[proj_name] = {
			"path": _project_paths[proj_name],
			"loaded": _project_dbs.has(proj_name),
		}
	return result


func is_project_loaded(project_name: String) -> bool:
	return _project_dbs.has(project_name)


func get_project_path(project_name: String) -> String:
	## Get the JSONL .dct file path for a project (not the .cache path).
	return _project_paths.get(project_name, "")


# -- Tool dispatch (with signal emission) -------------------------------------

func call_tool(tool_name: String, arguments: Dictionary) -> Dictionary:
	## Call a docket tool. Emits signals on successful mutations.
	if not _tool_registry:
		return {"error": "DocketManager not initialized"}
	# Ensure personal docket exists for hint/personal writes
	if tool_name in ["docket_hint_set"] and str(arguments.get("project", "")).is_empty():
		# Default hint writes to master (skill queries hit master)
		pass
	var result := _tool_registry.call_tool(tool_name, arguments)
	if not result.has("error"):
		_emit_signals_for(tool_name, arguments, result)
	return result


func get_tool_definitions() -> Array:
	## Get MCP tool definitions for registration.
	if _tool_registry:
		return _tool_registry.list_tools()
	return []


func has_tool(tool_name: String) -> bool:
	return _tool_registry != null and _tool_registry.has_tool(tool_name)


# -- System prompt loading ----------------------------------------------------

func get_system_prompt(key: String, model_id: String = "") -> String:
	## Get a system prompt by key (e.g. "agentic-base").
	## Searches: project dockets → master docket. Only returns active prompts.
	## Model-specific lookup: tries "key:model_id" → "key:family" → "key".
	## Returns "" if not found (caller should fall back to hardcoded constant).
	if not _prompt_cache_valid:
		_rebuild_prompt_cache()

	# Model-specific fallback chain
	if not model_id.is_empty():
		# Try exact model: "agentic-base:claude-sonnet-4-6"
		var exact_key := "%s:%s" % [key, model_id]
		if _prompt_cache.has(exact_key):
			return _prompt_cache[exact_key]
		# Try family: "agentic-base:claude" (first segment before hyphen-digit)
		var family := _extract_model_family(model_id)
		if not family.is_empty() and family != model_id:
			var family_key := "%s:%s" % [key, family]
			if _prompt_cache.has(family_key):
				return _prompt_cache[family_key]

	# Generic key: "agentic-base"
	if _prompt_cache.has(key):
		return _prompt_cache[key]

	return ""


func invalidate_prompt_cache() -> void:
	_prompt_cache_valid = false


func _rebuild_prompt_cache() -> void:
	## Build prompt cache: project overrides win over master.
	_prompt_cache.clear()

	# Layer 1: master docket prompts (lowest priority)
	if _master_db:
		_load_prompts_from_db(_master_db)

	# Layer 2: project docket prompts (override master)
	for proj_name in _project_dbs:
		if proj_name == "master" or proj_name == "personal":
			continue
		_load_prompts_from_db(_project_dbs[proj_name])

	_prompt_cache_valid = true


func _load_prompts_from_db(db: DocketDB) -> void:
	## Load active prompts with component="system-prompt" into cache.
	var results := db.execute_query({
		"filter": {
			"conditions": [
				{"field": "type", "op": "eq", "value": "prompt"},
				{"conj": "and", "field": "status", "op": "eq", "value": "active"},
				{"conj": "and", "field": "component", "op": "eq", "value": "system-prompt"},
			]
		}
	})
	for item in results:
		var item_key: String = str(item.get("key", ""))
		var prompt_text: String = str(item.get("prompt_text", ""))
		if not item_key.is_empty() and not prompt_text.is_empty():
			_prompt_cache[item_key] = prompt_text


static func _extract_model_family(model_id: String) -> String:
	## Extract model family from ID: "claude-sonnet-4-6" → "claude"
	## "gemini-2.5-pro" → "gemini". Takes first segment before a digit.
	var parts := model_id.split("-")
	var family := ""
	for part in parts:
		if not part.is_empty() and part[0] >= "0" and part[0] <= "9":
			break
		if not family.is_empty():
			family += "-"
		family += part
	return family


# -- Signal emission ----------------------------------------------------------

func _emit_signals_for(tool_name: String, args: Dictionary, result: Dictionary) -> void:
	var proj := str(args.get("project", "master"))
	match tool_name:
		"docket_create":
			item_created.emit(
				str(result.get("id", "")),
				str(result.get("type", "")),
				proj
			)
		"docket_transition":
			item_transitioned.emit(
				str(args.get("id", "")),
				str(result.get("previous_status", "")),
				str(result.get("status", "")),
				proj
			)
		"docket_update":
			item_updated.emit(str(args.get("id", "")), proj)
		"docket_comment":
			comment_added.emit(str(args.get("id", "")), proj)
		"docket_delete":
			item_updated.emit(str(args.get("id", "")), proj)
		"docket_hint_set":
			item_created.emit(str(result.get("id", "")), "hint", proj)
		"docket_quality":
			item_updated.emit(str(result.get("id", "")), proj)

	# Invalidate prompt cache on any mutation — prompt items are rare so the
	# cost of an unnecessary rebuild is negligible, and docket_update results
	# do not include a "type" field, making per-type checks unreliable.
	if tool_name in ["docket_create", "docket_update", "docket_transition", "docket_delete"]:
		invalidate_prompt_cache()


# -- JSONL persistence --------------------------------------------------------

func save_project(project_name: String) -> void:
	## Write a project's SQLite state back to its .dct JSONL file.
	_save_project_to_jsonl(project_name)


func save_all() -> void:
	## Save all loaded projects to JSONL.
	for proj_name in _project_dbs:
		_save_project_to_jsonl(proj_name)


func _save_project_to_jsonl(project_name: String) -> void:
	if not _project_dbs.has(project_name):
		return
	var path: String = _project_paths.get(project_name, "")
	if path.is_empty():
		return
	var db: DocketDB = _project_dbs[project_name]
	var jsonl_text := JSONLSerializer.serialize_all(db)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(jsonl_text)
		f.close()


func close_all() -> void:
	## Save and close all dockets. Called on exit.
	save_all()
	for proj_name in _project_dbs.keys():
		_project_dbs[proj_name].close()
	_project_dbs.clear()
	_master_db = null
	_personal_db = null


# -- Internal helpers ---------------------------------------------------------

func _refresh_tool_registry() -> void:
	if _tool_registry:
		var primary := _master_db if _master_db else DocketDB.new()
		_tool_registry.update_db(_schema, primary, _project_dbs)
		_tool_registry.add_project_fn = _add_project_from_tool
		_tool_registry.remove_project_fn = _remove_project_from_tool


func _add_project_from_tool(path: String) -> Dictionary:
	## Callback for ToolRegistry's docket_project_add tool.
	return open_project(path)


func _remove_project_from_tool(project_name_: String) -> Dictionary:
	## Callback for ToolRegistry's docket_project_remove tool.
	return close_project(project_name_)

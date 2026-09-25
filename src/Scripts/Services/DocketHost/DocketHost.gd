class_name DocketHost
extends Node
## Minerva's side of the Docket plugin, which owns every Docket project
## file: which projects Minerva keeps open there and in which roles.
##
## Each time the plugin's process becomes ready (plugin_ready) the host
## declares Minerva's schema, installs or updates the shipped master at
## user://master.dct (the plugin merges it and keeps a person's changes),
## opens user://personal.dct if it exists, and reopens the projects of the
## last session in their order, never creating one. Until that is done every
## agent's and panel's Docket tool call waits (the plugin's tool guard);
## after it, and while the plugin runs without being ready, a call is
## refused if Docket is unavailable, and closing the master is refused
## always. A project that cannot be reopened stays in the session and is
## reported in `problems`; so is anything else this could not do.
##
## The plugin is authoritative for which projects are open (its
## docket_project_list); the host remembers only their paths, in the order
## they were opened (the "session_paths" of user://docket_prefs.json).
## After an agent or a panel adds or removes a project the list is read
## again and the session updated: a path that was open and no longer is
## leaves it, a newly open one joins it, and one that never opened (a failed
## reopen) stays.
##
## Every step belongs to one process of the plugin: its connection (a new
## one for each start) and that connection's process generation. A result
## that arrives once the process has changed is dropped.
##
## The embedded DocketManager owns the same files, so the host stays
## inactive while it exists: the two never run together.

signal state_changed(state: String)

const PLUGIN_ID := "docket"
const MASTER_RES := "res://Data/master.dct"
const MASTER_USER := "user://master.dct"
const PERSONAL_USER := "user://personal.dct"
const SCHEMA_RES := "res://Scripts/Services/Docket/Core/data/schema.json"
const PREFS_PATH := "user://docket_prefs.json"
const SESSION_KEY := "session_paths"
## The backend tools that open or close projects.
const PROJECT_TOOLS := ["docket_project_add", "docket_project_remove"]

## "inactive" (the embedded DocketManager owns Docket's files), "unavailable"
## (the plugin is not running, or not ready), "starting" (its process is
## being set up), "ready", "degraded" (ready, with `problems`) or "failed"
## (the schema or the master could not be set up; `problems` says why).
var state := "inactive"
## What is wrong now, one line each: what setting up the process could not
## do, and what the last update of the session could not.
var problems: Array[String] = []
## Master items a person changed that an update left as they were, rather
## than take the shipped version: one line each. Not a problem.
var notices: Array[String] = []
## The master's install or update report (MasterBootstrap's, with
## `project` and `capability_gaps`), from the last ready process.
var master_report: Dictionary = {}
## Canonical paths of the master and of personal.dct, as the plugin opened
## them ("" when not open).
var master_path := ""
var personal_path := ""
## The open projects as the plugin last listed them: [{name, display_name,
## path, open_generation, ...}]. Valid for the current process only.
var projects: Array = []

var _plugin_manager
# The process the current state belongs to: its connection and generation.
var _connection = null
var _generation := -1
# What setting up the current process could not do.
var _setup_problems: Array[String] = []
# Paths of ordinary projects to keep open, in order (the session), and the
# session as last saved.
var _session := PackedStringArray()
var _saved_session := PackedStringArray()
# The open paths the session was last brought up to date with.
var _reconciled_paths := PackedStringArray()
var _reconciling := false
var _reconcile_again := false


## Takes up the Docket plugin through `plugin_manager`, unless the embedded
## DocketManager owns Docket's files (`embedded_owner`): then it stays
## inactive.
func start(plugin_manager, embedded_owner: bool) -> void:
	if embedded_owner:
		state = "inactive"
		return
	_plugin_manager = plugin_manager
	_plugin_manager.plugin_ready.connect(_on_plugin_ready)
	_plugin_manager.plugin_stopped.connect(_on_plugin_gone)
	_plugin_manager.plugin_crashed.connect(_on_plugin_gone)
	_plugin_manager.backend_tool_called.connect(_on_backend_tool_called)
	_plugin_manager.set_backend_tool_guard(PLUGIN_ID, _guard)
	_set_state("unavailable")
	if _plugin_manager.get_plugin_status(PLUGIN_ID).get("running", false) \
			and _plugin_manager.get_connection(PLUGIN_ID) != null:
		_prepare()


## The ordinary projects of the session in order, as open descriptors (the
## master and personal.dct excluded); a path not open now is left out.
func session_projects() -> Array:
	var ordered := []
	for path in _session:
		var open := _descriptor_of(path)
		if not open.is_empty():
			ordered.append(open)
	return ordered


## The master's open descriptor, or {} when it is not open.
func master_project() -> Dictionary:
	return _descriptor_of(master_path) if not master_path.is_empty() else {}


## Backend tool `tool` of the plugin with `arguments`, called by the host
## itself on the current process: {value} (its result) or {error}.
func call_tool(tool: String, arguments: Dictionary) -> Dictionary:
	return await _call(_connection, tool, arguments)


func _call(connection, tool: String, arguments: Dictionary) -> Dictionary:
	if connection == null or _plugin_manager.get_connection(PLUGIN_ID) != connection:
		return {"error": "the Docket plugin is not running"}
	var answered: Dictionary = await connection.call_tool(tool, arguments)
	if answered.has("error") or answered.get("success", true) == false:
		return {"error": str(answered.get("error", answered.get("error_message", "%s failed" % tool)))}
	return {"value": answered}


func _on_plugin_ready(id: String) -> void:
	if id == PLUGIN_ID:
		_prepare()


func _on_plugin_gone(id: String) -> void:
	if id == PLUGIN_ID:
		_connection = null
		_generation = -1
		projects = []
		_set_state("unavailable")


# Sets up the plugin's current process once: schema, master, personal.dct
# and the session, in that order, before any other project can be opened.
func _prepare() -> void:
	var connection = _plugin_manager.get_connection(PLUGIN_ID)
	if connection == null:
		return
	var generation: int = connection.process_generation()
	if connection == _connection and generation == _generation:
		return  # already set up, or being set up, for this process
	_connection = connection
	_generation = generation
	_setup_problems.clear()
	problems.clear()
	notices.clear()
	master_report = {}
	master_path = ""
	personal_path = ""
	projects = []
	_set_state("starting")
	var authority = _plugin_manager.get_panel_authority(PLUGIN_ID)
	if authority == null:
		_fail("the Docket plugin has no private channel for its host")
		return

	var schema = JSON.parse_string(FileAccess.get_file_as_string(SCHEMA_RES))
	if not schema is Dictionary:
		_fail("Minerva's Docket schema (%s) cannot be read" % SCHEMA_RES)
		return
	var version := "minerva-" + FileAccess.get_sha256(SCHEMA_RES)
	var declared: Dictionary = await authority.host_request("declare_schema", {"schema": schema, "version": version})
	if _stale(connection, generation):
		return
	var declared_error := _channel_error(declared)
	if not declared_error.is_empty():
		_fail("Docket did not accept Minerva's schema: %s" % declared_error)
		return

	var shipped := FileAccess.get_file_as_bytes(MASTER_RES)
	if shipped.is_empty():
		_fail("Minerva's shipped master (%s) cannot be read" % MASTER_RES)
		return
	var bootstrapped: Dictionary = await authority.host_request("bootstrap_project",
		{"path": ProjectSettings.globalize_path(MASTER_USER), "content": Marshalls.raw_to_base64(shipped)})
	if _stale(connection, generation):
		return
	var bootstrap_error := _channel_error(bootstrapped)
	if not bootstrap_error.is_empty():
		_fail("the master could not be set up: %s" % bootstrap_error)
		return
	master_report = bootstrapped.result
	master_path = str(master_report.get("project", {}).get("path", ""))
	for conflict in master_report.get("conflicts", []):
		notices.append("master item %s kept as changed here, not updated as shipped (%s)"
			% [conflict.get("id", ""), conflict.get("reason", "")])
	for gap in master_report.get("capability_gaps", []):
		_setup_problems.append("master: %s" % str(gap))

	if FileAccess.file_exists(PERSONAL_USER):
		var personal := await _open(connection, generation, ProjectSettings.globalize_path(PERSONAL_USER))
		if _stale(connection, generation):
			return
		personal_path = str(personal.get("path", ""))
	# Each reopened path is kept as the plugin names the file (canonical);
	# one that failed is kept as it was.
	var session := PackedStringArray()
	var personal_file := ProjectSettings.globalize_path(PERSONAL_USER)
	for path in _load_session():
		if path == personal_file:
			continue  # opened above, or not at all
		var opened := {}
		if path != master_path and path != personal_path:
			opened = await _open(connection, generation, path)
			if _stale(connection, generation):
				return
		var kept := str(opened.get("path", path))
		if kept != master_path and kept != personal_path and not kept in session:
			session.append(kept)
	_session = session
	var listed := await _refresh(connection, generation)
	if _stale(connection, generation):
		return
	if not listed.is_empty():
		_setup_problems.append(listed)
	_reconciled_paths = _open_paths()
	_publish()


# Opens the existing project at `path` (never creating it): its descriptor,
# or {} with the reason among the setup problems.
func _open(connection, generation: int, path: String) -> Dictionary:
	var opened := await _call(connection, "docket_project_add", {"path": path, "create": false})
	if _stale(connection, generation):
		return {}
	if opened.has("error"):
		_setup_problems.append("%s could not be opened: %s" % [path, opened.error])
		return {}
	return opened.value


# Reads the open projects again into `projects`: "" or why it could not.
func _refresh(connection, generation: int) -> String:
	var listed := await _call(connection, "docket_project_list", {})
	if _stale(connection, generation):
		return "the Docket plugin's process changed"
	if listed.has("error") or not listed.value.get("projects") is Array:
		return "the open projects could not be listed: %s" % listed.get("error", "no list")
	projects = listed.value.projects
	return ""


# Waits for the current process to be set up, then allows `tool` (with
# `arguments`) unless Docket is unavailable, or it would close the master.
func _guard(tool: String, arguments: Dictionary) -> String:
	while state == "starting":
		await state_changed
	if state in ["inactive", "unavailable", "failed"]:
		return "Docket is unavailable: %s" % ("; ".join(problems) if not problems.is_empty() else state)
	if tool == "docket_project_remove" and not master_path.is_empty():
		# Only a fresh list tells which project the name resolves to now.
		var listed := await _refresh(_connection, _generation)
		if not listed.is_empty():
			return "Docket's open projects could not be listed, so none is closed now"
		var closing := _resolve(str(arguments.get("name", "")))
		if str(closing.get("path", "")) == master_path:
			return "the master project stays open; it is Minerva's"
	return ""


# The open project `project_name` names, as the plugin resolves a project
# name: the one whose selector it is, else the only one whose selector or
# stored name it is in any case; {} for none, or when it is ambiguous (which
# the plugin refuses too).
func _resolve(project_name: String) -> Dictionary:
	var found := []
	for project in projects:
		if str(project.get("name", "")) == project_name:
			return project
		if str(project.get("name", "")).nocasecmp_to(project_name) == 0 \
				or str(project.get("display_name", "")).nocasecmp_to(project_name) == 0:
			found.append(project)
	return found[0] if found.size() == 1 else {}


func _on_backend_tool_called(id: String, tool: String) -> void:
	if id == PLUGIN_ID and tool in PROJECT_TOOLS and state in ["ready", "degraded"]:
		_reconcile()


# Brings the session up to date with the plugin's open projects, one run at
# a time; a change noticed meanwhile runs it again.
func _reconcile() -> void:
	if _reconciling:
		_reconcile_again = true
		return
	_reconciling = true
	while true:
		_reconcile_again = false
		var connection = _connection
		var generation := _generation
		var listed := await _refresh(connection, generation)
		if _stale(connection, generation):
			break
		if listed.is_empty():
			var before := _reconciled_paths
			var after := _open_paths()
			_reconciled_paths = after
			var session := PackedStringArray()
			for path in _session:
				if not (path in before and not path in after):
					session.append(path)
			for path in after:
				if path != master_path and path != personal_path and not path in session:
					session.append(path)
			_session = session
		_publish([listed] if not listed.is_empty() else [])
		if not _reconcile_again:
			break
	_reconciling = false


# Saves the session if it changed, and sets `problems` and the state from
# the setup's problems, `more`, a master no longer open and a session that
# could not be saved.
func _publish(more: Array = []) -> void:
	var now: Array[String] = _setup_problems.duplicate()
	for problem in more:
		now.append(str(problem))
	if not master_path.is_empty() and master_project().is_empty():
		now.append("the master project is not open")
	var saved := _save_if_changed()
	if not saved.is_empty():
		now.append(saved)
	problems = now
	_set_state("degraded" if not problems.is_empty() else "ready")


# Writes the session when it differs from the one last saved: "" or why it
# could not (it is tried again at the next change).
func _save_if_changed() -> String:
	if _session == _saved_session:
		return ""
	var saved := _save_session(_session)
	if saved.is_empty():
		_saved_session = _session.duplicate()
	return saved


func _open_paths() -> PackedStringArray:
	var paths := PackedStringArray()
	for project in projects:
		paths.append(str(project.get("path", "")))
	return paths


func _descriptor_of(path: String) -> Dictionary:
	for project in projects:
		if str(project.get("path", "")) == path:
			return project
	return {}


func _stale(connection, generation: int) -> bool:
	return connection == null or connection != _connection or generation != _generation \
		or _plugin_manager.get_connection(PLUGIN_ID) != connection or connection.process_generation() != generation


# What went wrong with a private-channel answer, or "": a refusal, or a
# result that is itself an {error, kind}.
static func _channel_error(answered: Dictionary) -> String:
	if answered.has("error_code"):
		return str(answered.get("error_message", answered.error_code))
	var result = answered.get("result")
	if not result is Dictionary:
		return "no result"
	if result.has("error"):
		return "%s (%s)" % [result.error, result.get("kind", "")]
	return ""


func _fail(why: String) -> void:
	_setup_problems.append(why)
	problems = _setup_problems.duplicate()
	push_error("[DocketHost] %s" % why)
	_set_state("failed")


func _set_state(new_state: String) -> void:
	state = new_state
	state_changed.emit(state)


# The session as last saved, each path absolute, in order, once.
static func _load_session() -> PackedStringArray:
	var paths := PackedStringArray()
	var data = _read_prefs()
	if data is Dictionary and data.get(SESSION_KEY) is Array:
		for entry in data[SESSION_KEY]:
			var path := str(entry)
			if path.begins_with("user://") or path.begins_with("res://"):
				path = ProjectSettings.globalize_path(path)
			# Older sessions also listed the embedded Docket's cache files.
			if not path.ends_with(".cache") and not path in paths:
				paths.append(path)
	return paths


# The preferences file's contents: a Dictionary ({} when it is absent or
# empty), or null when it cannot be read as one. Absent, its ".new" copy is
# read instead if it is whole: a save whose final move failed after the old
# file was removed (Windows) left it there.
static func _read_prefs():
	var fallback := not FileAccess.file_exists(PREFS_PATH)
	var path := PREFS_PATH + ".new" if fallback else PREFS_PATH
	if not FileAccess.file_exists(path):
		return {}
	var text := FileAccess.get_file_as_string(path)
	if text.strip_edges().is_empty():
		return {}
	var data = JSON.parse_string(text)
	if data is Dictionary:
		return data
	return {} if fallback else null


# Writes `session` as the session's paths, keeping the file's other
# preferences: written whole beside it (".new"), then moved over it, so a
# failed write leaves the file as it was. The move replaces the file in one
# step on Linux and macOS, not on Windows, where Godot removes the old file
# first. If the move fails, the new file is copied into place instead, and
# if that fails too it stays whole beside it (_read_prefs falls back to it
# while the file itself is missing). "" or why it could not.
func _save_session(session: PackedStringArray) -> String:
	var data = _read_prefs()
	if data == null:
		return "%s is not readable, so the session was not saved" % PREFS_PATH
	data[SESSION_KEY] = Array(session)
	var written := PREFS_PATH + ".new"
	var file := FileAccess.open(written, FileAccess.WRITE)
	if file == null:
		return "the session could not be saved to %s: %s" % [PREFS_PATH, error_string(FileAccess.get_open_error())]
	file.store_string(JSON.stringify(data))
	var failed := file.get_error()
	file.close()
	if failed != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(written))
		return "the session could not be saved to %s: %s" % [PREFS_PATH, error_string(failed)]
	var from := ProjectSettings.globalize_path(written)
	var to := ProjectSettings.globalize_path(PREFS_PATH)
	var moved := DirAccess.rename_absolute(from, to)
	if moved != OK:
		moved = DirAccess.copy_absolute(from, to)
		if moved == OK:
			DirAccess.remove_absolute(from)
	if moved != OK:
		return "the session could not be saved to %s (%s); the preferences are whole in %s" \
			% [PREFS_PATH, error_string(moved), written]
	return ""

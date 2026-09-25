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
## they were opened, in its own file (SESSION_PATH; the first time, taken
## from the embedded Docket's preferences, which it never writes). After an
## agent or a panel adds or removes a project the list is read again and the
## session updated: a path that was open and no longer is leaves it, a newly
## open one joins it, and one that never opened (a failed reopen) stays. A
## saved session that cannot be read is reported, kept as it is and never
## overwritten.
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
## Where DocketHost keeps the session: {"version": SESSION_VERSION,
## "paths": [...]}.
const SESSION_PATH := "user://docket_host_session.json"
const SESSION_VERSION := 1
## Where the embedded Docket kept it; read (once, when there is no session
## file yet), never written, as it holds a person's other preferences too.
const LEGACY_PREFS_PATH := "user://docket_prefs.json"
const LEGACY_SESSION_KEY := "session_paths"
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
# Why the saved session could not be read ("" when it was): then it is
# neither restored nor overwritten, and prompts cannot be read.
var _session_error := ""
# The session was taken from the embedded Docket's preferences and is not in
# DocketHost's own file yet.
var _migrating := false
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


## The active system prompt `key` for `model_id` ("" for none), read from
## the plugin afresh: the master's prompts, overridden by those of the
## session's projects in order (personal.dct's never count), looked up as
## "key:model_id", then "key:<model family>", then "key". {prompt} ("" when
## none is defined: the caller's own default applies), or {error} when
## Docket could not be read, or some of the prompts could be missing (see
## _prompts_unknown), which is never to be taken for "none".
func system_prompt(key: String, model_id: String = "") -> Dictionary:
	while state == "starting":
		await state_changed
	if not state in ["ready", "degraded"]:
		return {"error": "Docket is unavailable: %s" % ("; ".join(problems) if not problems.is_empty() else state)}
	var connection = _connection
	var generation := _generation
	# Selectors as they are now, not as a pending reconcile last saw them.
	var listed := await _refresh(connection, generation)
	if not listed.is_empty():
		return {"error": listed}
	var master := master_project()
	if master.is_empty():
		return {"error": "the master project is not open"}
	var unmet := _prompts_unknown()
	if not unmet.is_empty():
		return {"error": unmet}
	var prompts := {}
	for project in [master] + session_projects():
		var read := await _call(connection, "docket_query", {"project": str(project.get("name", "")), "detail": "full",
			"filter": {"conditions": [
				{"field": "type", "op": "eq", "value": "prompt"},
				{"conj": "and", "field": "status", "op": "eq", "value": "active"},
				{"conj": "and", "field": "component", "op": "eq", "value": "system-prompt"}]}})
		if _stale(connection, generation):
			return {"error": "the Docket plugin's process changed while its prompts were read"}
		if read.has("error") or not read.value.get("items") is Array:
			return {"error": "the prompts of %s could not be read: %s"
				% [project.get("display_name", project.get("name", "")), read.get("error", "no items")]}
		for item in read.value.items:
			var item_key := str(item.get("key", "")) if item is Dictionary else ""
			var text := str(item.get("prompt_text", "")) if item is Dictionary else ""
			if not item_key.is_empty() and not text.is_empty():
				prompts[item_key] = text
	for candidate in prompt_keys(key, model_id):
		if prompts.has(candidate):
			return {"prompt": prompts[candidate]}
	return {"prompt": ""}


# Why some prompt could be missing from what the open projects give, or "":
# the saved session unread, a project of the session not open (its
# overrides would be missed), or the master's prompt type not as declared.
func _prompts_unknown() -> String:
	if not _session_error.is_empty():
		return "the saved session could not be read, so its projects' prompts are unknown"
	for path in _session:
		if _descriptor_of(path).is_empty():
			return "%s, a project of the session, is not open, so its prompts are unknown" % path
	for gap in master_report.get("capability_gaps", []):
		if gap is Dictionary and (gap.has("error") or str(gap.get("slug", "")) == "prompt"):
			return "the master's prompt type is not as Minerva declares it: %s" % str(gap)
	return ""


## The keys prompt `key` is looked up by for `model_id`, most specific
## first: "key:claude-sonnet-4-6", "key:claude-sonnet", "key".
static func prompt_keys(key: String, model_id: String) -> PackedStringArray:
	var keys := PackedStringArray()
	if not model_id.is_empty():
		keys.append("%s:%s" % [key, model_id])
		var family := model_family(model_id)
		if not family.is_empty() and family != model_id:
			keys.append("%s:%s" % [key, family])
	keys.append(key)
	return keys


## A model id's family: its "-"-separated parts before the first that starts
## with a digit ("claude-sonnet-4-6" → "claude-sonnet", "gemini-2.5-pro" →
## "gemini").
static func model_family(model_id: String) -> String:
	var family := ""
	for part in model_id.split("-"):
		if not part.is_empty() and part[0] >= "0" and part[0] <= "9":
			break
		if not family.is_empty():
			family += "-"
		family += part
	return family


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
	var loaded := _load_session()
	_session_error = str(loaded.get("error", ""))
	_migrating = bool(loaded.get("legacy", false))
	if _session_error.is_empty() and not _migrating:
		_saved_session = loaded.paths
	if not _session_error.is_empty():
		_setup_problems.append("the saved session could not be read: %s" % _session_error)
	var session := PackedStringArray()
	var personal_file := ProjectSettings.globalize_path(PERSONAL_USER)
	for path in loaded.get("paths", PackedStringArray()):
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
	if not _session_error.is_empty():
		return ""  # an unreadable saved session is kept as it is
	if _session == _saved_session and not _migrating:
		return ""
	var saved := _save_session(_session)
	if saved.is_empty():
		_saved_session = _session.duplicate()
		_migrating = false
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


# The saved session: {paths} (absolute, in order, once, with `legacy` when
# they come from the embedded Docket) or {error}. DocketHost's own file is
# authoritative; while it is absent, a whole ".new" (left by a move that
# failed) stands for it, and without either the session the embedded Docket
# kept in docket_prefs.json is read, never written. None of them is an empty
# session; one that is there but cannot be read is an error, not empty.
static func _load_session() -> Dictionary:
	for path in [SESSION_PATH, SESSION_PATH + ".new"]:
		if FileAccess.file_exists(path):
			var own = _read_json(path)
			if own is Dictionary and int(own.get("version", 0)) == SESSION_VERSION and own.get("paths") is Array:
				return {"paths": _paths(own.paths)}
			return {"error": "%s cannot be read as a version %d session" % [path, SESSION_VERSION]}
	if not FileAccess.file_exists(LEGACY_PREFS_PATH):
		return {"paths": PackedStringArray()}
	var legacy = _read_json(LEGACY_PREFS_PATH)
	if not legacy is Dictionary:
		return {"error": "%s cannot be read" % LEGACY_PREFS_PATH}
	var entries = legacy.get(LEGACY_SESSION_KEY, [])
	if not entries is Array:
		return {"error": "%s has no readable %s" % [LEGACY_PREFS_PATH, LEGACY_SESSION_KEY]}
	return {"paths": _paths(entries), "legacy": true}


# A JSON file's contents, {} when it is empty, or null when it cannot be
# read or parsed.
static func _read_json(path: String):
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty() and FileAccess.get_open_error() != OK:
		return null
	if text.strip_edges().is_empty():
		return {}
	return JSON.parse_string(text)


# `entries` as absolute paths, in order, once.
static func _paths(entries: Array) -> PackedStringArray:
	var paths := PackedStringArray()
	for entry in entries:
		var path := str(entry)
		if path.begins_with("user://") or path.begins_with("res://"):
			path = ProjectSettings.globalize_path(path)
		# Older sessions also listed the embedded Docket's cache files.
		if not path.ends_with(".cache") and not path in paths:
			paths.append(path)
	return paths


# Writes `session` to DocketHost's own file: whole beside it (".new"), then
# moved over it. The move replaces the file in one step on Linux and macOS,
# not on Windows, where Godot removes the old file first; a move that fails
# there leaves the ".new", which _load_session reads. "" or why it could not.
func _save_session(session: PackedStringArray) -> String:
	var written := SESSION_PATH + ".new"
	var file := FileAccess.open(written, FileAccess.WRITE)
	if file == null:
		return "the session could not be saved to %s: %s" % [SESSION_PATH, error_string(FileAccess.get_open_error())]
	file.store_string(JSON.stringify({"version": SESSION_VERSION, "paths": Array(session)}))
	var failed := file.get_error()
	file.close()
	if failed != OK:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(written))
		return "the session could not be saved to %s: %s" % [SESSION_PATH, error_string(failed)]
	var moved := DirAccess.rename_absolute(ProjectSettings.globalize_path(written), ProjectSettings.globalize_path(SESSION_PATH))
	if moved != OK:
		return "the session could not be moved into %s (%s); it is whole in %s" % [SESSION_PATH, error_string(moved), written]
	return ""

## Docket as plugin content seeding reaches it, from whichever owns Docket's
## files: the embedded DocketManager (or a ToolRegistry standing in for it in
## tests), or the Docket plugin through DocketHost. Every call is awaited and
## answers the tool's result Dictionary, or {error}. One is made for each
## lifecycle operation (PluginContentSeeding.docket()).
##
## Under the plugin, each project the operation touches is bound, the first
## time it is named, to the opening, plugin process and session it is found
## in (DocketHost.seeding_target): absent, "" or "master" name the master,
## an OpenProject the project open at its path, any other name the one open
## project whose stored name it is exactly (none is a missing project; more
## than one stops the operation). Every call is sent to that opening only (DocketHost.call_bound),
## never named again. Once any binding no longer holds, the operation stops:
## nothing more is sent, incomplete() says why, and uncertain() lists the
## changes that were sent but may or may not have been made.
##
## Under either owner, a read that fails (but for an item that is not there)
## also stops the operation, rather than be taken for an empty answer.
class_name PluginSeedingDocket extends RefCounted

## The project name a manifest's knowledge defaults to, and the embedded
## owner's primary project.
const MASTER := "master"
## The tools whose calls change Docket (an uncertain one is listed).
const CHANGING := ["docket_create", "docket_update", "docket_transition", "docket_delete"]
## The tools that read Docket (a failed one stops the operation).
const READS := ["docket_query", "docket_get", "docket_project_list"]
## A project argument naming the project open at `path` (as project_names
## gives them under the plugin); no manifest name can stand for one.
class OpenProject extends RefCounted:
	var path: String
	func _init(open_path: String) -> void:
		path = open_path
	func _to_string() -> String:
		return path

# The DocketManager or ToolRegistry (answering call_tool synchronously), or
# the DocketHost.
var _target
var _plugin_owner := false
# Under the plugin: project key ("" for the master) -> its target, and the
# keys found naming no open project.
var _bound: Dictionary = {}
var _missing: Dictionary = {}
# The names a journal pinned (pin): the only projects the operation reaches,
# no other name being bound once it has.
var _pinned: Array = []
var _recovery := false
# Under the embedded owner: the names found open, for bound_paths.
var _embedded_names: Dictionary = {}
var _stopped := ""
var _uncertain: Array[Dictionary] = []


func _init(target, plugin_owner: bool) -> void:
	_target = target
	_plugin_owner = plugin_owner


## Why Docket cannot be reached for seeding now, or "".
func unavailable() -> String:
	if _target == null:
		return "Docket is not available"
	if _plugin_owner and not _target.state in ["ready", "degraded"]:
		return "Docket is %s" % _target.state
	return ""


## Why this operation stopped before it finished, or "".
func incomplete() -> String:
	return _stopped


## The canonical path each project name the operation bound is open at
## ("" for the master), and "" for each it found naming no open project:
## what a journal records, so recovery under the plugin reaches the same
## files (pin). Under the embedded owner, the paths of the project files
## it found (recovery there goes by name, as it always has).
func bound_paths() -> Dictionary:
	var paths := {}
	for key in _missing:
		if key is String:
			paths[key] = ""
	if not _plugin_owner:
		for key in _embedded_names:
			var db = _target.get_db(MASTER if key.is_empty() else key) if _target.has_method("get_db") else null
			paths[key] = ProjectSettings.globalize_path(db.get_path()) if db != null else ""
		return paths
	for key in _bound:
		if key is String:
			paths[key] = str(_bound[key].project.get("path", ""))
	return paths


## The project names a journal pinned (pin), or [] when none drives the
## operation.
func pinned_names() -> Array:
	return _pinned


## Under the plugin, a recovery reaches only the files its journal recorded:
## every name in `required` ("" or "master" the master) and in the journal's
## paths must have a recorded path, or the operation stops before any
## Docket access, its journal left pending to be repaired by hand (a name
## never goes to whatever project it names now). Each is then bound to the
## project open at its path (one not open is missing), and no other name is
## bound for the rest of the operation. Nothing is done under the embedded
## owner, whose recovery goes by name.
func pin(journal: Dictionary, required: Array) -> void:
	if not _plugin_owner:
		return
	var recorded = journal.get("paths")
	var paths: Dictionary = recorded if recorded is Dictionary else {}
	var names := {}
	for name in required + paths.keys():
		names["" if str(name) == MASTER else str(name)] = true
	for key in names:
		if str(paths.get(key, paths.get(MASTER, "") if key.is_empty() else "")).is_empty():
			_stopped = "its Docket record does not say which file project '%s' is, so it is not repaired automatically" % [
				MASTER if key.is_empty() else key]
			return
	_recovery = true
	for key in names:
		_pinned.append(key)
	var why := unavailable()
	if not why.is_empty():
		_stopped = why
		return
	for key in names:
		var found := await _target_of(OpenProject.new(str(paths.get(key, paths.get(MASTER, "")))))
		if found.has("error"):
			_missing[key] = found
		else:
			_bound[key] = found


## Whether this serves the Docket plugin (rather than the embedded owner).
func plugin_owner() -> bool:
	return _plugin_owner


## Whether the operation found `project` (a name) naming no open project.
func was_missing(project: String) -> bool:
	return _missing.has("" if project == MASTER else project)


## The changes sent before it stopped that may or may not have been made:
## {tool, arguments, project_path}.
func uncertain() -> Array[Dictionary]:
	return _uncertain


## Tool `tool` with `arguments`: its result, or {error}. Docket becoming
## unreachable during the operation stops it.
func call_tool(tool: String, arguments: Dictionary) -> Dictionary:
	if not _stopped.is_empty():
		return {"error": _stopped}
	var why := unavailable()
	if not why.is_empty():
		_stopped = why
		return {"error": why}
	if not _plugin_owner:
		var result = _target.call_tool(tool, arguments)
		return _read_checked(tool, result if result is Dictionary else {"error": "%s answered %s" % [tool, str(result)]})
	var found := await _target_of(arguments.get("project", ""))
	if found.has("error"):
		return found
	var answered: Dictionary = await _target.call_bound(found, tool, arguments)
	if answered.get("stale", false):
		_stopped = "Docket changed while plugin content was being written (%s)" % answered.error
		if answered.get("sent", false) and tool in CHANGING:
			_uncertain.append({"tool": tool, "arguments": arguments.duplicate(true),
				"project_path": str(found.project.get("path", ""))})
		return {"error": _stopped}
	if answered.has("error"):
		return _read_checked(tool, {"error": str(answered.error)})
	return answered.value if answered.get("value") is Dictionary \
		else _read_checked(tool, {"error": "%s answered %s" % [tool, str(answered)]})


## Whether `project` (a name, "" or "master" being the master, or an
## OpenProject) is open.
func has_project(project) -> bool:
	if not unavailable().is_empty():
		_stopped = unavailable() if _stopped.is_empty() else _stopped
		return false
	if _plugin_owner:
		return not (await _target_of(project)).has("error")
	var key := "" if str(project) == MASTER else str(project)
	var loaded: bool = (MASTER if key.is_empty() else key) in await project_names()
	if loaded:
		_embedded_names[key] = true
	else:
		_missing[key] = {"error": "Docket project '%s' is not open" % project}
	return loaded


## The open projects, as project arguments name them (under the plugin, as
## OpenProject, by their paths).
func project_names() -> Array:
	if not unavailable().is_empty():
		return []
	if _plugin_owner:
		return _target.projects.map(func(p: Dictionary) -> OpenProject: return OpenProject.new(str(p.get("path", ""))))
	var listed := await call_tool("docket_project_list", {})
	return listed.get("projects", []).map(func(p) -> String: return str(p.get("name", ""))) \
		if listed.get("projects") is Array else []


## Whether every change to `project` ("" being the primary one) is settled
## in its file: docket_persist under the embedded owner, a checked
## docket_flush of exactly that one project under the plugin (sent under its
## bound selector, never none: a flush naming no project writes them all).
func settle(project) -> bool:
	var tool := "docket_flush" if _plugin_owner else "docket_persist"
	return not (await call_tool(tool, {"project": project})).has("error")


# `result` of `tool`; a failed read (but for an item that is not there)
# stops the operation.
func _read_checked(tool: String, result: Dictionary) -> Dictionary:
	if tool in READS and result.has("error") and not str(result.error).begins_with("Item not found"):
		_stopped = "Docket could not be read (%s)" % result.error
		return {"error": _stopped}
	return result


# The target `project` is bound to under the plugin, binding it now when it
# is first named: {status: "ok", project, process, session_changes}, or
# {error} when it names no open project (kept, so the operation does not
# find it later), or cannot be bound for any other reason (Docket
# unreachable, a name several open projects share, a process other than one
# bound before), which stops the operation.
func _target_of(project) -> Dictionary:
	if not _stopped.is_empty():
		return {"error": _stopped}
	var key = project if project is OpenProject else ("" if str(project) == MASTER else str(project))
	if _bound.has(key):
		return _bound[key]
	if _missing.has(key):
		return _missing[key]
	if _recovery and key is String:
		_stopped = "Docket project '%s' is not among the files its record names" % project
		return {"error": _stopped}
	if key is OpenProject and key.path.is_empty():
		_stopped = "a Docket project with no path cannot be written to"
		return {"error": _stopped}
	var found: Dictionary = await _target.seeding_target("", key.path) if key is OpenProject \
		else await _target.seeding_target(key)
	if found.get("status", "") != "ok":
		var failed := {"error": str(found.get("message", "Docket project '%s' is not open" % project))}
		if found.get("code", "") == "missing_project":
			_missing[key] = failed
		else:
			_stopped = failed.error
		return failed
	if str(found.project.get("name", "")).is_empty():
		_stopped = "Docket project '%s' has no selector" % project
		return {"error": _stopped}
	for other in _bound.values():
		if other.process != found.process:
			_stopped = "the Docket plugin's process changed while plugin content was being written"
			return {"error": _stopped}
	_bound[key] = found
	return found

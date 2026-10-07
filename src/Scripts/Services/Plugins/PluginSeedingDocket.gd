## Docket as plugin content seeding reaches it through DocketHost. Every call is awaited and
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
## A read that fails (but for an item that is not there)
## also stops the operation, rather than be taken for an empty answer.
class_name PluginSeedingDocket extends RefCounted

## The project name a manifest's knowledge defaults to.
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

var _target: DocketHost
# Under the plugin: project key ("" for the master) -> its target, and the
# keys found naming no open project.
var _bound: Dictionary = {}
var _missing: Dictionary = {}
# The names a journal pinned (pin): the only projects the operation reaches,
# no other name being bound once it has.
var _pinned: Array = []
var _recovery := false
var _unbound: Array[String] = []
var _stopped := ""
var _uncertain: Array[Dictionary] = []


func _init(target: DocketHost) -> void:
	_target = target


## Why Docket cannot be reached for seeding now, or "".
func unavailable() -> String:
	if _target == null:
		return "Docket is not available"
	if not _target.state in ["ready", "degraded"]:
		return "Docket is %s" % _target.state
	return ""


## Why this operation stopped before it finished, or "".
func incomplete() -> String:
	return _stopped


## The canonical path each project name the operation bound is open at
## ("" for the master), and "" for each it found naming no open project:
## what a journal records, so recovery under the plugin reaches the same
## files (pin).
func bound_paths() -> Dictionary:
	var paths := {}
	for key in _missing:
		if key is String:
			paths[key] = ""
	for key in _bound:
		if key is String:
			paths[key] = str(_bound[key].project.get("path", ""))
	return paths


## The project names (and OpenProject) a journal pinned (pin), or the
## operation was scoped to (scope_to), or [] when neither drives it.
func pinned_names() -> Array:
	return _pinned


## Limits the projects an enumeration reaches (Knowledge.unseed_everywhere)
## to `projects` (names and OpenProject), as found before anything is
## changed, so a retry can be given exactly the same (enumerated_paths).
func scope_to(projects: Array) -> void:
	_pinned = projects.duplicate()


## The paths of the projects the operation reaches by path (OpenProject),
## whether bound, missing or only named in its scope: what a journal records
## beside bound_paths, so a retry reaches exactly those files.
func enumerated_paths() -> Array:
	var paths: Array = []
	for project in _pinned + _bound.keys() + _missing.keys():
		if project is OpenProject and not project.path in paths:
			paths.append(project.path)
	return paths


## What identifies the binding `project` (a name) got in this operation: its
## canonical path and, under the plugin, its opening, the plugin's process
## generation and the session. "" when it was not bound. Equal keys from two
## operations mean the same project file, opened the same way.
func binding_key(project: String) -> String:
	var key := "" if project == MASTER else project
	if not _bound.has(key):
		return ""
	var found: Dictionary = _bound[key]
	return "%s|%s|%s|%s" % [found.project.get("path", ""), found.project.get("open_generation", ""),
		found.process[1], found.session_changes]


## Under the plugin, a recovery reaches only the files its journal recorded:
## every name in `required` ("" or "master" the master) and in the journal's
## paths must have a recorded path, or the operation stops before any
## Docket access, its journal left pending to be repaired by hand (a name
## never goes to whatever project it names now). Each is then bound to the
## project open at its path (one not open is missing), and no other name is
## bound for the rest of the operation. With `enumerating` (a removal's
## retry, which reaches every project it listed), a journal must also list
## those projects' files, even as none.
func pin(journal: Dictionary, required: Array, enumerating := false, allow_unbound := false) -> void:
	var recorded = journal.get("paths")
	var paths: Dictionary = recorded if recorded is Dictionary else {}
	var enumerated = journal.get("enumerated", null if enumerating else [])
	var names := {}
	for name in required + paths.keys():
		names["" if str(name) == MASTER else str(name)] = true
	for key in names:
		if str(paths.get(key, paths.get(MASTER, "") if key.is_empty() else "")).is_empty():
			if allow_unbound:
				_unbound.append(str(key))
				continue
			_stopped = "its Docket record does not say which file project '%s' is, so it is not repaired automatically" % [
				MASTER if key.is_empty() else key]
			return
	if not enumerated is Array or enumerated.any(func(path) -> bool: return str(path).is_empty()):
		_stopped = "its Docket record does not say which project files it was to reach, so it is not repaired automatically"
		return
	_recovery = true
	for key in names:
		_pinned.append(key)
	for path in enumerated:
		_pinned.append(OpenProject.new(str(path)))
	var why := unavailable()
	if not why.is_empty():
		_stopped = why
		return
	for key in names:
		if key in _unbound: continue
		var found := await _target_of(OpenProject.new(str(paths.get(key, paths.get(MASTER, "")))))
		if found.has("error"):
			_missing[key] = found
		else:
			_bound[key] = found
	for project in _pinned:
		if project is OpenProject:
			await _target_of(project)


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
	var found := await _target_of(arguments.get("project", ""))
	if found.has("error"):
		return found
	var answered: Dictionary = await _target.call_bound(found, tool, arguments)
	var changing: bool = tool in CHANGING or tool == "docket_flush"
	if answered.get("stale", false):
		_stopped = "Docket changed while plugin content was being written (%s)" % answered.error
		if answered.get("sent", false) and changing:
			_uncertain.append({"tool": tool, "arguments": _portable(arguments),
				"project_path": str(found.project.get("path", ""))})
		return {"error": _stopped}
	if answered.has("error"):
		# A change that was sent and then failed in any way (a timeout, a lost
		# connection, a bad reply, even Docket's own error) may have been
		# made: the operation stops, and it is uncertain.
		if answered.get("unconfirmed", false) and changing:
			_stopped = "Docket did not confirm a change it was sent (%s)" % answered.error
			_uncertain.append({"tool": tool, "arguments": _portable(arguments),
				"project_path": str(found.project.get("path", ""))})
			return {"error": _stopped}
		return _read_checked(tool, {"error": str(answered.error)})
	if not answered.get("value") is Dictionary:
		return _read_checked(tool, {"error": "%s answered %s" % [tool, str(answered)]})
	# A create answered without the new record's id may still have made it.
	if tool == "docket_create" and str(answered.value.get("id", "")).is_empty():
		_stopped = "Docket did not say which record it created (%s)" % str(answered.value)
		_uncertain.append({"tool": tool, "arguments": _portable(arguments),
			"project_path": str(found.project.get("path", ""))})
		return {"error": _stopped}
	return answered.value


## Whether `project` (a name, "" or "master" being the master, or an
## OpenProject) is open.
func has_project(project) -> bool:
	if not _stopped.is_empty():
		return false
	if not unavailable().is_empty():
		_stopped = unavailable()
		return false
	return not (await _target_of(project)).has("error")


## The open projects, as project arguments name them (under the plugin, as
## OpenProject, by their paths, listed afresh by the plugin: a list that
## cannot be had stops the operation, rather than leave a project out).
func project_names() -> Array:
	if not _stopped.is_empty() or not unavailable().is_empty():
		return []
	var listed: Dictionary = await _target.open_projects()
	if not listed.get("projects") is Array:
		_stopped = "Docket's open projects could not be listed (%s)" % listed.get("message", "no list")
		return []
	return listed.projects.map(func(p: Dictionary) -> OpenProject: return OpenProject.new(str(p.get("path", ""))))


## Whether every change to `project` is settled in its file: a checked
## docket_flush of exactly that one project (sent under its
## bound selector, never none: a flush naming no project writes them all).
func settle(project) -> bool:
	return not (await call_tool("docket_flush", {"project": project})).has("error")


# `arguments` as a journal can keep them (an OpenProject as its path).
static func _portable(arguments: Dictionary) -> Dictionary:
	var kept := arguments.duplicate(true)
	if kept.get("project") is OpenProject:
		kept["project"] = kept.project.path
	return kept


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
	if _recovery and key is String and key not in _unbound:
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

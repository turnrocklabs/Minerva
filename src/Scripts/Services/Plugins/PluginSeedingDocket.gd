## Docket as plugin content seeding reaches it, from whichever owns Docket's
## files: the embedded DocketManager (or a ToolRegistry standing in for it in
## tests), or the Docket plugin through DocketHost. Every call is awaited and
## answers the tool's result Dictionary, or {error}.
##
## Under the plugin, a project argument that is absent, "" or "master" names
## the master (the embedded owner's primary project), and any other name the
## open project it names; a call whose project names no open one is refused
## here, never sent to be answered for another project.
class_name PluginSeedingDocket extends RefCounted

## The project name a manifest's knowledge defaults to, and the embedded
## owner's primary project.
const MASTER := "master"

# The DocketManager or ToolRegistry (answering call_tool synchronously), or
# the DocketHost (answering {value}|{error} after an await).
var _target
var _plugin_owner := false


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


## Tool `tool` with `arguments`: its result, or {error}.
func call_tool(tool: String, arguments: Dictionary) -> Dictionary:
	var why := unavailable()
	if not why.is_empty():
		return {"error": why}
	if not _plugin_owner:
		var result = _target.call_tool(tool, arguments)
		return result if result is Dictionary else {"error": "%s answered %s" % [tool, str(result)]}
	var mapped := arguments
	if tool != "docket_project_list":
		var selector := str(_open_project(str(arguments.get("project", ""))).get("name", ""))
		if selector.is_empty():
			return {"error": "Docket project '%s' is not open" % str(arguments.get("project", MASTER))}
		mapped = arguments.duplicate(true)
		mapped["project"] = selector
	var answered: Dictionary = await _target.call_tool(tool, mapped)
	if answered.has("error"):
		return {"error": str(answered.error)}
	return answered.value if answered.get("value") is Dictionary else {"error": "%s answered %s" % [tool, str(answered)]}


## Whether `project` ("" or "master" being the master) is open.
func has_project(project: String) -> bool:
	if not unavailable().is_empty():
		return false
	if _plugin_owner:
		return not _open_project(project).is_empty()
	return project in await project_names()


## The names of the open projects, as their project arguments take them.
func project_names() -> Array:
	if not unavailable().is_empty():
		return []
	if _plugin_owner:
		return _target.projects.map(func(p: Dictionary) -> String: return str(p.get("name", "")))
	var listed := await call_tool("docket_project_list", {})
	return listed.get("projects", []).map(func(p) -> String: return str(p.get("name", ""))) \
		if listed.get("projects") is Array else []


## Whether every change to `project` ("" being the primary one) is settled
## in its file: docket_persist under the embedded owner, a checked
## docket_flush of exactly that one open project under the plugin (one it
## cannot name is not settled: a flush naming no project writes them all).
func settle(project: String) -> bool:
	if not _plugin_owner:
		return not (await call_tool("docket_persist", {"project": project})).has("error")
	if not unavailable().is_empty():
		return false
	var selector := str(_open_project(project).get("name", ""))
	if selector.is_empty():
		return false
	return not (await call_tool("docket_flush", {"project": selector})).has("error")


# The open project `project` names under the plugin ({} for none).
func _open_project(project: String) -> Dictionary:
	if project.is_empty() or project == MASTER:
		return _target.master_project()
	return _target.project_named(project)


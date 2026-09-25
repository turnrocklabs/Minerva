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
## The backend tools that can change what policy_items and the skill reads
## read: items, their types, and which projects are open.
const CHANGING_TOOLS := ["docket_create", "docket_update", "docket_transition", "docket_delete",
	"docket_move", "docket_type_define", "docket_type_evolve", "docket_type_activate", "docket_reload",
	"docket_project_add", "docket_project_remove"]

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
# Whether the last reconcile could list the open projects.
var _reconciled_ok := false
# A person's change to the session (retry, locate, forget) is under way.
var _changing := false
# How many such changes have begun: one may open and close projects without
# leaving a trace in the open set, so a skill read overlapping one is not
# trusted.
var _session_changes := 0
# Session path → why the last try to open it failed.
var _open_errors := {}
var _reconcile_again := false
# How many CHANGING_TOOLS calls by agents and panels have completed: a
# policy or skill read that overlaps one is not trusted.
var _changes := 0


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
## "key:model_id", then "key:<model family>", then "key"; pending session
## updates are applied first, and a change to the projects read while reading
## is an error. {prompt} ("" when none is defined: the caller's own default
## applies), or {error} when Docket could not be read, or some of the prompts
## could be missing (see _prompts_unknown), which is never to be taken for
## "none".
func system_prompt(key: String, model_id: String = "") -> Dictionary:
	while state == "starting":
		await state_changed
	if not state in ["ready", "degraded"]:
		return {"error": "Docket is unavailable: %s" % ("; ".join(problems) if not problems.is_empty() else state)}
	var connection = _connection
	var generation := _generation
	# The session brought up to date first (a project an agent or panel
	# opened or closed, a person's change), so the projects whose prompts
	# count are the current ones.
	while _changing or _reconciling:
		await get_tree().process_frame
	if _stale(connection, generation) or not state in ["ready", "degraded"]:
		return {"error": "Docket is unavailable: %s" % ("; ".join(problems) if not problems.is_empty() else state)}
	_reconciled_ok = false
	_reconcile()
	while _reconciling:
		await get_tree().process_frame
	if _stale(connection, generation) or not state in ["ready", "degraded"]:
		return {"error": "Docket is unavailable: %s" % ("; ".join(problems) if not problems.is_empty() else state)}
	if not _reconciled_ok:
		return {"error": "Docket's open projects could not be listed, so the session is not known"}
	var untracked := _untracked_projects()
	if not untracked.is_empty():
		return {"error": "%s open but not yet in the session" % ", ".join(untracked)}
	var master := master_project()
	if master.is_empty():
		return {"error": "the master project is not open"}
	var unmet := _prompts_unknown()
	if not unmet.is_empty():
		return {"error": unmet}
	var layers: Array = [master] + session_projects()
	var prompts := {}
	for project in layers:
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
	# The projects read must still be the session's, each the same opening.
	var listed := await _refresh(connection, generation)
	if not listed.is_empty():
		return {"error": listed}
	if _changing or _reconciling or not _untracked_projects().is_empty() \
			or _layer_openings([master_project()] + session_projects()) != _layer_openings(layers):
		return {"error": "Docket's projects changed while the prompt was read; send again"}
	for candidate in prompt_keys(key, model_id):
		if prompts.has(candidate):
			return {"prompt": prompts[candidate]}
	return {"prompt": ""}


## The master's policies, read from the plugin afresh: {items} (its items
## of type policy whose status is proposed or active, in full), or {error}
## when Docket is unavailable, the master is not open, its policy type is not
## as Minerva declares it, the read fails, or the master or the plugin's
## process changed while it was read. An agent's or a panel's change to
## Docket that completed while it was read makes it {error, changed: true}:
## read again. The master is checked against a fresh list before the read,
## so nothing is awaited after it. Policies are the master's only; the
## session's projects never count. No items is a successful read.
func policy_items() -> Dictionary:
	while state == "starting":
		await state_changed
	if not state in ["ready", "degraded"]:
		return {"error": "Docket is unavailable: %s" % ("; ".join(problems) if not problems.is_empty() else state)}
	var connection = _connection
	var generation := _generation
	for gap in master_report.get("capability_gaps", []):
		if gap is Dictionary and (gap.has("error") or str(gap.get("slug", "")) == "policy"):
			return {"error": "the master's policy type is not as Minerva declares it: %s" % str(gap)}
	var listed := await _refresh(connection, generation)
	if not listed.is_empty():
		return {"error": listed}
	var master := master_project()
	if master.is_empty():
		return {"error": "the master project is not open"}
	var changes := _changes
	var read := await _call(connection, "docket_query", {"project": str(master.get("name", "")), "detail": "full",
		"filter": {"conditions": [
			{"field": "type", "op": "eq", "value": "policy"},
			{"conj": "and", "field": "status", "op": "in", "value": ["proposed", "active"]}]}})
	if _stale(connection, generation):
		return {"error": "the Docket plugin's process changed while the policies were read"}
	if read.has("error") or not read.value.get("items") is Array:
		return {"error": "the master's policies could not be read: %s" % read.get("error", "no items")}
	if _changes != changes or _layer_openings([master_project()]) != _layer_openings([master]):
		return {"error": "Docket changed while the master's policies were read", "changed": true}
	return {"items": read.value.items}


## The knowledge items policy rules name by id (`refs`), read afresh from
## the master, as the embedded Docket reads them, in the order of `refs`:
## {items}, or {error, index}: when Docket is unavailable, its projects
## cannot be listed or the master is not open (index -1, no ref read), or a
## ref's read fails, answers with another item or sees the plugin's process
## change (that ref's index). No refs is a successful empty read.
func policy_knowledge(refs: PackedStringArray) -> Dictionary:
	if refs.is_empty():
		return {"items": []}
	while state == "starting":
		await state_changed
	if not state in ["ready", "degraded"]:
		return {"error": "Docket is unavailable: %s" % ("; ".join(problems) if not problems.is_empty() else state),
			"index": -1}
	var connection = _connection
	var generation := _generation
	var listed := await _refresh(connection, generation)
	if not listed.is_empty():
		return {"error": listed, "index": -1}
	var master := master_project()
	if master.is_empty():
		return {"error": "the master project is not open", "index": -1}
	var items := []
	for index in refs.size():
		var read := await _call(connection, "docket_get",
			{"id": refs[index], "project": str(master.get("name", "")), "include": []})
		if _stale(connection, generation):
			return {"error": "the Docket plugin's process changed while policy knowledge was read", "index": index}
		if read.has("error"):
			return {"error": str(read.error), "index": index}
		if not read.value is Dictionary or not _names_item(refs[index], str(read.value.get("id", ""))):
			return {"error": "the master answered with another item", "index": index}
		items.append(read.value)
	return {"items": items}


# Whether `ref`, as a policy names knowledge, names the item whose id is
# `id`: the same id, or a short hex prefix of it (four or more digits, any
# case), as Docket's docket_get resolves one.
static func _names_item(ref: String, id: String) -> bool:
	return id == ref or (ref.length() >= 4 and ref.is_valid_hex_number(false)
		and id.to_lower().begins_with(ref.to_lower()))


## Adds `text` as a comment by the policy engine on policy rule `rule_id` in
## the master: "" or why it could not.
func write_policy_observation(rule_id: String, text: String) -> String:
	while state == "starting":
		await state_changed
	if not state in ["ready", "degraded"]:
		return "Docket is unavailable: %s" % ("; ".join(problems) if not problems.is_empty() else state)
	var master := master_project()
	if master.is_empty():
		return "the master project is not open"
	var written := await _call(_connection, "docket_comment", {"action": "add", "item_id": rule_id,
		"author": "policy-engine", "text": text, "project": str(master.get("name", ""))})
	return str(written.error) if written.has("error") else ""


## The active skills of every open project (the master, personal.dct and the
## session's), read afresh in full: {status: "ok", skills: [skill records,
## see skill_record]} (none is a successful empty read) or {status: "error",
## code, message, project?}.
func skill_catalog() -> Dictionary:
	var read := await _read_skills(true)
	if read.status != "ok":
		return read
	var skills := []
	for found in read.found:
		skills.append_array(found.skills)
	return {"status": "ok", "skills": skills}


## The one skill `selector` names, read afresh in full, in any status:
## - a qualified Docket reference (SkillRef) names a skill of that open
##   project only;
## - any other string is matched against every open project's skills by
##   exact id, then id prefix (four or more hex digits), then exact title
##   (any case), then a title containing it; the first tier with a match
##   decides, and more than one match there is ambiguous.
## A `project_name` (a project's name or display name, as tools give it)
## limits the search to that open project; one not open, or naming more than
## one, is an error rather than a wider search.
## {status: "found", item: skill record, ref, target (where it was read, as
## skill_target gives it: what an update of it is held to)}, {status:
## "missing", selector},
## or {status: "error", code ("bad_ref", "not_docket", "unavailable",
## "unknown_project", "ambiguous", "read_failed", "changed", ...), message,
## project?, candidates?}.
func skill_lookup(selector: String, project_name: String = "") -> Dictionary:
	if selector.strip_edges().is_empty():
		return {"status": "error", "code": "bad_ref", "message": "no skill was named"}
	var qualified := SkillRef.parse(selector)
	if qualified.is_empty() and SkillRef.is_qualified(selector):
		return {"status": "error", "code": "bad_ref", "message": "%s is not a valid skill reference" % selector}
	if qualified.get("origin", "") == SkillRef.LOCAL:
		return {"status": "error", "code": "not_docket", "message": "%s is a local skill" % selector}
	var only := str(qualified.get("project_path", ""))
	var read := await _read_skills(false, only, project_name)
	if read.status != "ok":
		return read
	var skills := []
	var targets := {}
	for found in read.found:
		skills.append_array(found.skills)
		targets[str(found.project.get("path", ""))] = found.target
	var tiers: Array[Callable] = []
	if not qualified.is_empty():
		var id := str(qualified.id)
		tiers.append(func(skill: Dictionary) -> bool: return skill.id == id)
	else:
		var wanted := selector.strip_edges()
		var lower := wanted.to_lower()
		var hex := wanted.length() >= 4 and wanted.is_valid_hex_number(false)
		tiers.append(func(skill: Dictionary) -> bool: return skill.id == wanted)
		tiers.append(func(skill: Dictionary) -> bool: return hex and skill.id.to_lower().begins_with(lower))
		tiers.append(func(skill: Dictionary) -> bool: return skill.title.to_lower() == lower)
		tiers.append(func(skill: Dictionary) -> bool: return not lower.is_empty() and skill.title.to_lower().contains(lower))
	for tier in tiers:
		var matched := skills.filter(tier)
		if matched.size() == 1:
			return {"status": "found", "item": matched[0], "ref": matched[0].ref,
				"target": targets[matched[0].project_path]}
		if matched.size() > 1:
			var candidates := []
			for skill in matched:
				candidates.append({"ref": skill.ref, "title": skill.title, "project": skill.project})
			return {"status": "error", "code": "ambiguous", "candidates": candidates,
				"message": "%s names %d skills; name one by its reference" % [selector, matched.size()]}
	return {"status": "missing", "selector": selector}


## The hints and insights of the open project at `project_path` for each of
## `components` (at most `limit` of each type per component; the caller
## picks those targeted at its model), read afresh in full: {status: "ok", items} (none is a
## successful empty read) or {status: "error", code, message, project?}.
func skill_knowledge(project_path: String, components: PackedStringArray, limit: int = 10) -> Dictionary:
	var begun := await _begin_read()
	if begun.has("status"):
		return begun
	var project := _descriptor_of(project_path)
	if project.is_empty():
		return {"status": "error", "code": "unknown_project", "message": "%s is not open" % project_path}
	var changes := _changes
	var items := []
	for component in components:
		for item_type in ["hint", "insight"]:
			var read := await _call(begun.connection, "docket_query", {"project": str(project.get("name", "")),
				"detail": "full", "limit": limit, "filter": {"conditions": [
					{"field": "type", "op": "eq", "value": item_type},
					{"conj": "and", "field": "component", "op": "eq", "value": component}]}})
			var failed := _read_failure(read, begun, project)
			if not failed.is_empty():
				return failed
			items.append_array(read.value.items)
	var unsettled := await _unsettled(begun, changes, [project], false)
	if not unsettled.is_empty():
		return unsettled
	return {"status": "ok", "items": items}


## Where a skill is created, listed afresh: the open project `project_name`
## names (a name or display name), else the master. {status: "ok", project
## (its descriptor), process, session_changes} or {status: "error", code,
## message}: the target a write's binding holds it to (_unbound_write);
## `process` is also for same_process().
func skill_target(project_name: String) -> Dictionary:
	var begun := await _begin_read()
	if begun.has("status"):
		return begun
	var project := master_project() if project_name.is_empty() else _resolve(project_name)
	if project.is_empty():
		return {"status": "error", "code": "unknown_project", "message": "the master project is not open"
			if project_name.is_empty() else "%s names no one open project" % project_name}
	return {"status": "ok", "project": project, "process": [begun.connection, begun.generation],
		"session_changes": begun.session_changes}


## Whether the plugin's process is still the one `process` (from
## skill_target or skill_lookup) names: when it is not, a write sent
## meanwhile may or may not have been made.
func same_process(process: Array) -> bool:
	return not _stale(process[0], process[1])


# Why an agent's skill write, bound (write_binding: {tool, arguments,
# target}) to the target it was aimed at, may not be sent now, or "". The
# target (from skill_target or skill_lookup) is the project opening, plugin
# process and session it was chosen in: the call must be the bound tool with
# the bound arguments, the process and session unchanged, and the project its
# arguments name still that opening (a project closed and another opened
# under its name is not the same). Nothing here awaits.
func _unbound_write(tool: String, arguments: Dictionary, write_binding: Dictionary) -> String:
	var target: Dictionary = write_binding.get("target", {})
	if tool != write_binding.get("tool", "") or arguments != write_binding.get("arguments", {}) or target.is_empty():
		return "the skill was not written: the call is not the write it was bound to"
	if _stale(target.process[0], target.process[1]) or _changing or _session_changes != target.session_changes:
		return "the skill was not written: Docket changed since its project was chosen"
	var now := _resolve(str(arguments.get("project", "")))
	if _layer_openings([now]) != _layer_openings([target.project]):
		return "the skill was not written: project %s changed since it was chosen" % arguments.get("project", "")
	return ""


# Waits while Docket starts and while a person's change to the session is
# under way, then lists the open projects afresh: {connection, generation,
# session_changes}, or a {status: "error"} result.
func _begin_read() -> Dictionary:
	while state == "starting" or _changing:
		await get_tree().process_frame
	if not state in ["ready", "degraded"]:
		return {"status": "error", "code": "unavailable",
			"message": "Docket is unavailable: %s" % ("; ".join(problems) if not problems.is_empty() else state)}
	var connection = _connection
	var generation := _generation
	var session_changes := _session_changes
	var listed := await _refresh(connection, generation)
	if not listed.is_empty():
		return {"status": "error", "code": "unavailable", "message": listed}
	return {"connection": connection, "generation": generation, "session_changes": session_changes}


# Every skill of each open project (only the one at `only_path`, or the
# one `only_name` names, when given), active ones only when `active_only`: {status: "ok", found:
# [{project, skills, target}]} or a {status: "error"} result. A change to Docket, to
# any project read or (when reading them all) to which projects are open,
# while reading is an error (_unsettled).
func _read_skills(active_only: bool, only_path: String = "", only_name: String = "") -> Dictionary:
	var begun := await _begin_read()
	if begun.has("status"):
		return begun
	var read_projects := projects.duplicate()
	if not only_name.is_empty():
		var named := _resolve(only_name)
		if named.is_empty():
			return {"status": "error", "code": "unknown_project",
				"message": "%s names no one open project" % only_name}
		if not only_path.is_empty() and str(named.get("path", "")) != only_path:
			return {"status": "error", "code": "unknown_project",
				"message": "the reference is to another project than %s" % only_name}
		only_path = str(named.get("path", ""))
	if not only_path.is_empty():
		var project := _descriptor_of(only_path)
		if project.is_empty():
			return {"status": "error", "code": "unknown_project", "message": "%s is not open" % only_path}
		read_projects = [project]
	var changes := _changes
	var conditions := [{"field": "type", "op": "eq", "value": "skill"}]
	if active_only:
		conditions.append({"conj": "and", "field": "status", "op": "eq", "value": "active"})
	var found := []
	for project in read_projects:
		var read := await _call(begun.connection, "docket_query", {"project": str(project.get("name", "")),
			"detail": "full", "filter": {"conditions": conditions}})
		var failed := _read_failure(read, begun, project)
		if not failed.is_empty():
			return failed
		var skills := []
		for item in read.value.items:
			if item is Dictionary:
				skills.append(skill_record(item, project))
		# Where these skills were read: the target a write to them is held to.
		found.append({"project": project, "skills": skills, "target": {"project": project.duplicate(),
			"process": [begun.connection, begun.generation], "session_changes": begun.session_changes}})
	var unsettled := await _unsettled(begun, changes, read_projects, only_path.is_empty())
	if not unsettled.is_empty():
		return unsettled
	return {"status": "ok", "found": found}


# Whether a read of `read_projects` that began with `begun` and `changes`
# still holds: {} when it does, else a {status: "error"} result. The open
# projects are listed afresh (a project the host opened or replaced during
# the read shows there even though no agent or panel call counted); each
# project read must still be open with the same opening and, when the read
# covered `every` open project, the open set must be exactly the one read.
# A person's change to the session that began meanwhile, or is still under
# way, fails it too, even when it left the open set as it was.
func _unsettled(begun: Dictionary, changes: int, read_projects: Array, every: bool) -> Dictionary:
	var listed := await _refresh(begun.connection, begun.generation)
	if not listed.is_empty():
		return {"status": "error", "code": "unavailable", "message": listed}
	var now := []
	for project in read_projects:
		now.append(_descriptor_of(str(project.get("path", ""))))
	var before := _layer_openings(read_projects)
	var after := _layer_openings(projects if every else now)
	before.sort()
	after.sort()
	if _changes != changes or before != after or _changing or _session_changes != begun.session_changes:
		return _changed(read_projects[0] if read_projects.size() == 1 and not every else {})
	return {}


# The {status: "error"} result for a query `read` of `project` that failed,
# answered malformed, or saw the process change; {} when it is good.
func _read_failure(read: Dictionary, begun: Dictionary, project: Dictionary) -> Dictionary:
	var name := str(project.get("display_name", project.get("name", "")))
	if _stale(begun.connection, begun.generation):
		return {"status": "error", "code": "changed", "project": name,
			"message": "the Docket plugin's process changed while %s was read" % name}
	if read.has("error"):
		return {"status": "error", "code": "read_failed", "project": name,
			"message": "%s could not be read: %s" % [name, read.error]}
	if not read.value.get("items") is Array:
		return {"status": "error", "code": "malformed", "project": name,
			"message": "%s answered without items" % name}
	return {}


func _changed(project: Dictionary) -> Dictionary:
	var result := {"status": "error", "code": "changed",
		"message": "Docket changed while its skills were read; read again"}
	if not project.is_empty():
		result["project"] = str(project.get("display_name", project.get("name", "")))
	return result


## A skill item of `project` as its consumers use it: its fields (strings,
## tool_deps and tags as arrays of strings, optimization as a dictionary),
## where it is (project name, display name, path) and its reference.
static func skill_record(item: Dictionary, project: Dictionary) -> Dictionary:
	var record := {}
	for field in ["id", "title", "description", "status", "prompt_text", "steps", "preconditions",
			"outcome", "component", "topic", "source"]:
		record[field] = str(item.get(field, ""))
	for field in ["tool_deps", "tags", "unsatisfied_deps"]:
		var value = item.get(field, [])
		if value is String:
			value = Array(value.split(",", false)).map(func(part: String) -> String: return part.strip_edges())
		record[field] = (value as Array).map(func(part) -> String: return str(part)) if value is Array else []
	var optimization = item.get("optimization", {})
	record["optimization"] = optimization if optimization is Dictionary else {}
	record["deprecated"] = item.get("deprecated", false) == true
	record["project"] = str(project.get("name", ""))
	record["project_display_name"] = str(project.get("display_name", project.get("name", "")))
	record["project_path"] = str(project.get("path", ""))
	record["ref"] = SkillRef.docket(record.project_path, record.id)
	return record


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


# Open projects, as last listed, that are neither the master, personal.dct nor
# in the session (a change not reconciled yet): their prompts would be missed.
func _untracked_projects() -> PackedStringArray:
	var untracked := PackedStringArray()
	for path in _open_paths():
		if path != master_path and path != personal_path and not path in _session:
			untracked.append(path)
	return untracked


# Each layer's path and opening, in order: what a prompt read depends on.
static func _layer_openings(layers: Array) -> Array:
	var openings := []
	for project in layers:
		openings.append([str(project.get("path", "")), str(project.get("open_generation", ""))])
	return openings


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


## The session's projects that are not open now: [{path, error}], `error`
## saying why the last try to open it failed ("" when none was made).
func failed_projects() -> Array:
	var failed := []
	for path in _session:
		if _descriptor_of(path).is_empty():
			failed.append({"path": path, "error": str(_open_errors.get(path, ""))})
	return failed


## A person's retry of failed session project `path`: opened again, it stays
## in the session (as the plugin names it). "" or why not.
func retry_project(path: String) -> String:
	return await _change_session(path, path)


## A person's replacement of failed session project `path` by the project
## at `replacement`: once that opens, it takes the entry's place. "" or why
## not.
func locate_project(path: String, replacement: String) -> String:
	return await _change_session(path, replacement)


## A person's removal of failed session project `path` from the session; the
## file is not touched. "" or why not.
func forget_project(path: String) -> String:
	return await _change_session(path, "")


# Puts the project at `replacement` in the place of failed session entry
# `path` once it is open ("" leaves the entry out), and saves the session
# before saying so; one change or reconcile at a time. "" or why not.
func _change_session(path: String, replacement: String) -> String:
	while _changing or _reconciling:
		await get_tree().process_frame
	_changing = true
	_session_changes += 1
	var why := await _changed_session(path, replacement)
	_changing = false
	if state in ["ready", "degraded"]:
		_publish()
	return why


func _changed_session(path: String, replacement: String) -> String:
	if not state in ["ready", "degraded"]:
		return "Docket is not ready: %s" % state
	if not _session_error.is_empty():
		return "the saved session could not be read, so it is not changed"
	var connection = _connection
	var generation := _generation
	var listed := await _refresh(connection, generation)
	if not listed.is_empty():
		return listed
	# The entry must still be one that failed: nothing else changed it meanwhile.
	if not path in _session or not _descriptor_of(path).is_empty():
		return "%s is not a session project that failed to open" % path
	var kept := ""
	var opened_here := {}
	if not replacement.is_empty():
		var open_before := _open_paths()
		var opened := await _open(connection, generation, replacement)
		if _stale(connection, generation):
			return "the Docket plugin's process changed"
		if opened.is_empty():
			return "%s could not be opened: %s" % [replacement, _open_errors.get(replacement, "no reason given")]
		kept = str(opened.get("path", replacement))
		if kept == master_path or kept == personal_path:
			return "%s is the master or personal project, not a session project" % kept
		if not kept in open_before:
			opened_here = opened
		listed = await _refresh(connection, generation)
		if not listed.is_empty():
			return await _unopened(connection, generation, opened_here, listed)
	var session := PackedStringArray()
	for entry in _session:
		if entry == path:
			if not kept.is_empty() and not kept in session:
				session.append(kept)
		elif entry != kept:
			session.append(entry)
	var saved := _save_session(session)
	if not saved.is_empty():
		return await _unopened(connection, generation, opened_here, saved)
	_session = session
	_saved_session = session.duplicate()
	_migrating = false
	# Only this change joins the baseline the session is reconciled against:
	# a project closed or opened meanwhile by an agent or panel is still seen
	# as that, at the next reconcile.
	if not kept.is_empty() and not kept in _reconciled_paths:
		_reconciled_paths.append(kept)
	return ""


# A change that failed after opening `opened` (a project that was not open
# before; {} for none) closes it again, so it does not join the session
# unasked; `why` is returned, with anything that went wrong closing it.
func _unopened(connection, generation: int, opened: Dictionary, why: String) -> String:
	if opened.is_empty() or _stale(connection, generation):
		return why
	var closed := await _call(connection, "docket_project_remove", {"name": str(opened.get("name", ""))})
	if not _stale(connection, generation):
		await _refresh(connection, generation)
	return why if not closed.has("error") else "%s; %s stays open: %s" % [why, opened.get("path", ""), closed.error]


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
	_open_errors.clear()
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
		var personal_file := ProjectSettings.globalize_path(PERSONAL_USER)
		var personal := await _open(connection, generation, personal_file)
		if _stale(connection, generation):
			return
		personal_path = str(personal.get("path", ""))
		if personal_path.is_empty():
			_setup_problems.append("%s could not be opened: %s" % [personal_file, _open_errors.get(personal_file, "")])
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
# or {} with the reason in _open_errors.
func _open(connection, generation: int, path: String) -> Dictionary:
	var opened := await _call(connection, "docket_project_add", {"path": path, "create": false})
	if _stale(connection, generation):
		return {}
	if opened.has("error"):
		_open_errors[path] = str(opened.error)
		return {}
	_open_errors.erase(path)
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
# `arguments`, called by `caller`) unless Docket is unavailable, it would
# close the master, it is an agent's change that would lower a policy's
# enforcement and a person does not approve it (_approved), or it is a skill
# write bound (`write_binding`, from that call only) to a target that no
# longer holds (_unbound_write, checked before and after the others).
func _guard(tool: String, arguments: Dictionary, caller: String = "agent", write_binding: Dictionary = {}) -> String:
	if write_binding.is_empty():
		return await _guard_checks(tool, arguments, caller)
	# A bound skill write: its target checked against a fresh list first, then
	# the usual checks (the policy item stays the last thing read), then its
	# target again, with nothing awaited between that and the dispatch.
	var listed := await _refresh(_connection, _generation)
	var refused := listed if not listed.is_empty() else _unbound_write(tool, arguments, write_binding)
	if refused.is_empty():
		refused = await _guard_checks(tool, arguments, caller)
	if refused.is_empty():
		refused = _unbound_write(tool, arguments, write_binding)
	return refused


func _guard_checks(tool: String, arguments: Dictionary, caller: String) -> String:
	while state == "starting":
		await state_changed
	if state in ["inactive", "unavailable", "failed"]:
		return "Docket is unavailable: %s" % ("; ".join(problems) if not problems.is_empty() else state)
	if caller == "agent" and tool in PolicyApproval.TOOLS:
		return await _approved(tool, arguments)
	if tool == "docket_project_remove" and not master_path.is_empty():
		# Only a fresh list tells which project the name resolves to now.
		var listed := await _refresh(_connection, _generation)
		if not listed.is_empty():
			return "Docket's open projects could not be listed, so none is closed now"
		var closing := _resolve(str(arguments.get("name", "")))
		if str(closing.get("path", "")) == master_path:
			return "the master project stays open; it is Minerva's"
	return ""


# An agent's `tool` call with `arguments`, as PolicyApproval judges it: ""
# when it lowers no policy's enforcement, or a person approved it and the
# plugin's process, its open projects, the item and the arguments are still
# what the person was shown; else why not. A call that names no item, or an
# item that cannot be looked up, is refused, since it cannot be told not to
# be a policy.
func _approved(tool: String, arguments: Dictionary) -> String:
	var item_id := str(arguments.get("id", ""))
	if item_id.is_empty():
		return "the call names no item, so it cannot be checked for a policy"
	var connection = _connection
	var generation := _generation
	var shown := arguments.duplicate(true)
	var get_args := {"id": item_id, "include": []}
	if arguments.has("project"):
		get_args["project"] = arguments.project
	var listed := await _refresh(connection, generation)
	if not listed.is_empty():
		return "the item could not be checked for a policy: %s" % listed
	var openings := _layer_openings(projects)
	var before := await _call(connection, "docket_get", get_args)
	if _stale(connection, generation):
		return "the Docket plugin's process changed while the item was checked for a policy"
	if before.has("error"):
		return "the item could not be checked for a policy: %s" % before.error
	if not PolicyApproval.lowers_enforcement(tool, arguments, before.value):
		return ""
	if not await _request_policy_approval(tool, arguments, str(before.value.get("title", item_id))):
		return "Policy modification denied — human approval required"
	# The item is read last, after the projects, so nothing is awaited between
	# its check and the call's dispatch.
	listed = await _refresh(connection, generation)
	var after := await _call(connection, "docket_get", get_args)
	if _stale(connection, generation) or after.has("error") or not listed.is_empty() or after.value != before.value \
			or _layer_openings(projects) != openings or arguments != shown:
		return "the policy, its project or the requested change changed while a person decided, so nothing was changed"
	return ""


# Asks a person to approve an agent's `tool` call with `arguments` on the
# policy titled `title` (PolicyApproval.request): whether they did.
func _request_policy_approval(tool: String, arguments: Dictionary, title: String) -> bool:
	return await PolicyApproval.request(tool, arguments, title)


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
	if id == PLUGIN_ID and tool in CHANGING_TOOLS:
		_changes += 1
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
		while _changing:
			await get_tree().process_frame
		var connection = _connection
		var generation := _generation
		var listed := await _refresh(connection, generation)
		if _stale(connection, generation):
			break
		_reconciled_ok = listed.is_empty()
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
	for failed in failed_projects():
		now.append("%s could not be opened: %s" % [failed.path, failed.error])
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
# kept in docket_prefs.json is read, never written; with none of them the
# session is empty. One that is there but cannot be read is an error, not an
# empty session.
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


# A JSON file's contents, or null when it cannot be read or parsed (an
# empty or blank file included: a file that is there says something).
static func _read_json(path: String):
	var text := FileAccess.get_file_as_string(path)
	if text.strip_edges().is_empty():
		return null
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
	# A ".new" standing in for an absent file goes into place first: writing
	# the next one would otherwise empty the only whole copy.
	if not FileAccess.file_exists(SESSION_PATH) and FileAccess.file_exists(written):
		var recovered := DirAccess.rename_absolute(ProjectSettings.globalize_path(written), ProjectSettings.globalize_path(SESSION_PATH))
		if recovered != OK:
			return "the session in %s could not be moved into %s (%s), so no new one was saved" \
				% [written, SESSION_PATH, error_string(recovered)]
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

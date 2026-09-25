extends SceneTree
## Headless test of Docket skills as Minerva's skill tools meet them when the
## Docket plugin owns Minerva's projects (the embedded DocketManager set
## aside), through the public server dispatch and its execution context:
## - the skill contract: get gives a skill's full content (prompt_text,
##   steps, tool_deps, optimization applied); create stores its tools and
##   optimization and activates its tools, update changes its steps, get and
##   activate load it back;
##   same-titled skills of two projects stay apart and are named by
##   reference; a local skill is served locally; a failed read, a missing
##   skill and failed targeted knowledge are told apart; a policy that refuses
##   a write leaves nothing written;
## - interleavings: a skill update held to where it was read is refused when
##   that project was reopened, the plugin's process changed or a person
##   changed the session while it was on its way, while an unrelated direct
##   update meanwhile is not held back (a changed process is refused by the
##   policy read before the write's own check); a skill create stopped before
##   it was sent, while it was sent, before or while its activation was sent,
##   tells its caller what it had done, activates no tools and is not
##   retried, while one not stopped does activate them; an object sent as a
##   JSON string is written as the object.
##
## Run only in a throwaway profile, made before Godot starts, from the
## repository root:
##   ( source scripts/lib/test-profile.sh && root="$(mktemp -d)" && seed_test_profile "$root" \
##     && MINERVA_TEST_PROFILE_ROOT="$root" timeout 300 \
##        "${GODOT:-godot}" --headless --path src --script test/test_docket_skill_owner.gd )
## The plugin-tool dispatch validates its arguments with the JSON Schema
## helper (res://bin/minerva-json-schema-helper, from
## scripts/build-extensions.sh --helper-only); without it the writes fail.
##
## REAL: MinervaMCPServer's dispatch and policy admission, MCPSkillTools,
## DocketHost (setup, skill reads, write targets and its backend tool guard),
## PluginToolRegistry's dispatch (argument validation included) through a
## PluginManager's guard check, MCPExecutionContext's stop and recovery,
## SkillManager, the tool budget, ModelTargeting. FAKED (STORE_SRC and the
## doubles below): the Docket plugin's backend, answering as it does
## (project list; queries by type, status and component; get, create,
## update, transition, comment) over in-memory items in two projects, where
## any call can be held and a query of a type made to fail; its private
## channel; the plugin manager DocketHost is given; and the running plugin
## the registry dispatches to. The embedded Docket tools' module is set
## aside, as it is absent once the plugin owns Docket; their definitions stay
## registered and give the argument schemas the dispatch coerces with. A tool
## (CREATE_DEP) is registered for the created skills to depend on. Not covered: a real Docket
## process or package, and cancellation inside the transport's reply
## delivery.

const CONTEXT_PATH := "res://Scripts/Services/MCP/MCPExecutionContext.gd"
const REGISTRY_PATH := "res://Scripts/Services/Plugins/PluginToolRegistry.gd"
const USER_FILES := ["user://docket_host_session.json", "user://docket_host_session.json.new"]
const WORK_PATH := "/b10f-test/work.dct"
## Skills: one with everything, two sharing a title in different projects.
const FULL := "019f0000aaaabbbbccccddddeeee0001"
const TWIN_MASTER := "019f0000aaaabbbbccccddddeeee0002"
const TWIN_WORK := "019f0000aaaabbbbccccddddeeee0003"
const HINT := "019f0000aaaabbbbccccddddeeee0004"
const BLOCK_UPDATES := "019f0000aaaabbbbccccddddeeee0005"
const LOCAL_ID := "b10f_local_probe"
const DEP_TOOL := "minerva_tool_search"
const CREATE_DEP := "b10f_created_dep"

## The Docket plugin's backend over in-memory items. A call of `tool` whose
## number (1, 2, ... per tool) is in `holds` as "tool#n" waits until it is
## taken out, and so does the policy read numbered `hold_policy_read` (1, 2,
## ... over all policy queries) until that is set to 0; `reached` counts
## calls per tool and `policy_reads` policy queries; `writes` lists the
## create, update and transition calls received, in order.
const STORE_SRC := """
extends RefCounted
var tree: SceneTree = null
var generation := 1
var master := {"name": "master", "display_name": "Master", "path": "", "open_generation": "1"}
var work := {"name": "work", "display_name": "Work", "path": "", "open_generation": "1"}
var items := {}
var failing_types := []
var holds := {}
var reached := {}
var writes := []
var next_id := 100
var policy_reads := 0
var hold_policy_read := 0
func process_generation() -> int:
	return generation
func _in_project(arguments: Dictionary) -> String:
	var name := str(arguments.get("project", "master"))
	return "work" if name in ["work", "Work"] else "master"
func _holds(item: Dictionary, condition: Dictionary) -> bool:
	var value = item.get(str(condition.get("field", "")))
	if str(condition.get("op", "eq")) == "in":
		return value in condition.get("value", [])
	return value == condition.get("value")
func _matches(item: Dictionary, filter: Dictionary) -> Array:
	var conditions: Array = filter.get("conditions", [])
	if not filter.has("conditions"):
		for field in filter:
			conditions.append({"field": field, "op": "eq", "value": filter[field]})
	var type := ""
	var all := true
	for condition in conditions:
		if str(condition.get("field", "")) == "type":
			type = str(condition.get("value", ""))
		all = all and _holds(item, condition)
	return [all, type]
func call_tool(tool: String, arguments: Dictionary) -> Dictionary:
	reached[tool] = reached.get(tool, 0) + 1
	var number: int = reached[tool]
	while holds.has("%s#%d" % [tool, number]):
		await tree.process_frame
	if tool == "docket_query" and _matches({}, arguments.get("filter", {}))[1] == "policy":
		policy_reads += 1
		var read := policy_reads
		while hold_policy_read == read:
			await tree.process_frame
	var project := _in_project(arguments)
	match tool:
		"docket_project_list":
			return {"success": true, "projects": [master, work]}
		"docket_query":
			var found := []
			var type := ""
			for item in items.values():
				var matched := _matches(item, arguments.get("filter", {}))
				type = matched[1]
				if item._project == project and matched[0]:
					found.append(item.duplicate(true))
			if type.is_empty():
				type = str(_matches({}, arguments.get("filter", {}))[1])
			if type in failing_types:
				return {"success": false, "error": "the query failed"}
			return {"success": true, "items": found}
		"docket_get":
			var item = items.get(str(arguments.get("id", "")))
			return item.merged({"success": true}) if item != null else {"success": false, "error": "Item not found"}
		"docket_create":
			writes.append([tool, arguments.duplicate(true)])
			next_id += 1
			var id := "019f0000aaaabbbbccccddddeee%05d" % next_id
			var created := arguments.duplicate(true)
			created.erase("project")
			created["id"] = id
			created["status"] = "draft"
			created["_project"] = project
			items[id] = created
			return {"success": true, "id": id, "status": "draft", "title": created.get("title", "")}
		"docket_update":
			writes.append([tool, arguments.duplicate(true)])
			var id := str(arguments.get("id", ""))
			if not items.has(id) or items[id]._project != project:
				return {"success": false, "error": "Item not found: %s" % id}
			for key in arguments:
				if not key in ["id", "project"]:
					items[id][key] = arguments[key]
			return {"success": true, "id": id, "status": "updated"}
		"docket_transition":
			writes.append([tool, arguments.duplicate(true)])
			var id := str(arguments.get("id", ""))
			if not items.has(id):
				return {"success": false, "error": "Item not found: %s" % id}
			items[id].status = str(arguments.get("to", ""))
			return {"success": true, "id": id, "status": items[id].status}
		"docket_comment":
			return {"success": true}
	return {"success": false, "error": "unexpected tool %s" % tool}
"""

## The plugin's private channel: the schema is accepted, the master installed.
const AUTHORITY_SRC := """
extends RefCounted
var store = null
func host_request(name: String, params: Dictionary) -> Dictionary:
	if name == "declare_schema":
		return {"result": {"version": params.version}}
	store.master.path = str(params.path)
	return {"result": {"status": "installed", "path": params.path, "project": store.master,
		"conflicts": [], "capability_gaps": []}}
"""

## The plugin manager DocketHost is given (its guard is kept for the
## registry's manager).
const HOST_MANAGER_SRC := """
extends Node
signal plugin_ready(id: String)
signal plugin_stopped(id: String)
signal plugin_crashed(id: String)
signal backend_tool_called(id: String, tool: String)
var connection = null
var authority = null
var guard := Callable()
func get_connection(_id: String):
	return connection
func get_panel_authority(_id: String):
	return authority
func get_plugin_status(_id: String) -> Dictionary:
	return {"running": true}
func set_backend_tool_guard(_id: String, backend_guard: Callable) -> void:
	guard = backend_guard
"""

## The running plugin the registry dispatches to: its check_backend_tool is
## PluginManager's own, with DocketHost's guard.
const RUNNING_MANAGER_SRC := """
extends "res://Scripts/Services/Plugins/PluginManager.gd"
var connection = null
func get_plugin_status(_id: String) -> Dictionary:
	return {"running": true}
func get_connection(_id: String) -> MCPServerConnection:
	return connection
"""

## The registry's connection to the plugin's backend: the store answers.
const WIRE_SRC := """
extends "res://Scripts/Services/MCP/MCPServerConnection.gd"
var store = null
func call_tool_outcome_with_context(tool_name: String, arguments: Dictionary, _context: MCPExecutionContext):
	var outcome = load("res://Scripts/Services/MCP/MCPToolCallOutcome.gd").new()
	outcome.application = await store.call_tool(tool_name, arguments)
	return outcome
"""

var _pass := 0
var _fail := 0
var _so: Node = null
var _made: Array[Node] = []
var _store = null
var _host = null
## The longest any wait here may take, in frames: a wait that runs out fails.
const MAX_FRAMES := 300


func _init() -> void:
	print("=== Docket skill owner ===\n")
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("PASS: %s" % label)
	else:
		_fail += 1
		print("FAIL: %s%s" % [label, ("  — " + detail) if detail else ""])


func _make(source: String):
	var script := GDScript.new()
	script.source_code = source
	if script.reload() != OK:
		check("a test double compiles", false, source.left(80))
		return null
	var made = script.new()
	if made is Node:
		_made.append(made)
	return made


## Waits until `ready` holds, at most MAX_FRAMES frames: whether it held.
func _wait(ready: Callable) -> bool:
	for frame in MAX_FRAMES:
		if ready.call():
			return true
		await process_frame
	return ready.call()


func _server():
	return _so.get_mcp_manager().minerva_server


# A tool called as an agent would, through the server's public dispatch.
func _call(tool: String, arguments: Dictionary, context = null) -> Dictionary:
	if context == null:
		context = load(CONTEXT_PATH).create("test")
	return await _server().call_tool(tool, arguments, context)


func _skill(id: String, project: String, title: String, extra: Dictionary = {}) -> Dictionary:
	return {"id": id, "type": "skill", "status": "active", "title": title, "_project": project,
		"description": "about %s" % title}.merged(extra)


func _run() -> void:
	await process_frame
	_so = root.get_node_or_null("/root/SingletonObject")
	check("the SingletonObject autoload is live", _so != null)
	if _so == null:
		return
	var profile := OS.get_environment("MINERVA_TEST_PROFILE_ROOT")
	var user_dir := OS.get_user_data_dir()
	if profile.is_empty() or not user_dir.begins_with(profile.trim_suffix("/") + "/"):
		check("Godot's user directory is in the throwaway profile (see the header)", false, user_dir)
		return
	for path in USER_FILES:
		if FileAccess.file_exists(path):
			check("the throwaway profile holds no %s yet" % path, false)
			return
	var saved_manager = _so.docket_manager
	var saved_host = _so.docket_host
	var saved_registry = _so.plugin_tool_registry
	var docket_tools = null
	var saved_names: Array[String] = []
	for module in _server()._modules:
		if module.get_script().resource_path.ends_with("/MCPDocketTools.gd"):
			docket_tools = module
			saved_names.assign(module._tool_names)
			module._tool_names.clear()
	var index = _server().tool_search_index
	index.register_tool(CREATE_DEP, "a tool created skills depend on",
		{"name": CREATE_DEP, "description": "a tool created skills depend on", "input_schema": {"type": "object"}}, "")
	if await _set_up():
		await _test_skill_contract()
		await _test_interleavings()
	index.unregister_tool(CREATE_DEP)
	_server().tool_budget_manager.reset()
	_so.docket_manager = saved_manager
	_so.docket_host = saved_host
	_so.plugin_tool_registry = saved_registry
	if docket_tools != null:
		docket_tools._tool_names.assign(saved_names)
	_server().policy_engine.reload()
	var skills = _so.get_skill_manager()
	for skill in skills.skills.duplicate():
		if skill.id == LOCAL_ID:
			skills.skills.erase(skill)
	for node in _made:
		if is_instance_valid(node):
			node.queue_free()
	for path in USER_FILES:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# The plugin as owner (DocketHost over the store), the registry dispatching
# its write tools to the same store, a local skill, and the master's and the
# work project's items.
func _set_up() -> bool:
	_store = _make(STORE_SRC)
	var authority = _make(AUTHORITY_SRC)
	var host_manager = _make(HOST_MANAGER_SRC)
	var running = _make(RUNNING_MANAGER_SRC)
	var wire = _make(WIRE_SRC)
	var host = _make("extends \"res://Scripts/Services/DocketHost/DocketHost.gd\"")
	if _store == null or authority == null or host_manager == null or running == null or wire == null or host == null:
		return false
	_store.tree = self
	_store.work.path = WORK_PATH
	_store.items = {
		FULL: _skill(FULL, "master", "Full probe", {"prompt_text": "Section zero: read everything first.",
			"steps": "1. Look\n2. Act", "tool_deps": [DEP_TOOL], "optimization": {"max_tool_call_rounds": 7},
			"tags": ["b10fprobe"]}),
		TWIN_MASTER: _skill(TWIN_MASTER, "master", "Twin probe", {"steps": "master twin"}),
		TWIN_WORK: _skill(TWIN_WORK, "work", "Twin probe", {"steps": "work twin"}),
		HINT: {"id": HINT, "type": "hint", "_project": "master", "title": "Probe hint", "component": "b10fprobe",
			"value": "prefer the second path", "target": "all"},
	}
	authority.store = _store
	host_manager.connection = _store
	host_manager.authority = authority
	root.add_child(host_manager)
	root.add_child(host)
	_so.docket_manager = null
	_so.docket_host = host
	host.start(host_manager, false)
	host_manager.plugin_ready.emit("docket")
	var ready := await _wait(func(): return host.state in ["ready", "degraded"])
	check("DocketHost sets up the plugin as the owner", ready, "%s %s" % [host.state, host.problems])
	if not ready:
		return false
	_host = host

	wire.store = _store
	var object_schema := {"type": "object", "properties": {"project": {"type": "string"},
		"id": {"type": "string"}, "title": {"type": "string"}, "tool_deps": {"type": "array"},
		"optimization": {"type": "object"}}}
	var tools := []
	for name in ["docket_create", "docket_update", "docket_transition"]:
		tools.append(MCPToolDefinition.from_dict({"name": name, "description": name, "inputSchema": object_schema}))
	wire.tools = tools
	running.connection = wire
	running.set_backend_tool_guard("docket", host_manager.guard)
	running.backend_tool_called.connect(func(id: String, tool: String) -> void:
		host_manager.backend_tool_called.emit(id, tool))
	var registry = load(REGISTRY_PATH).new(running)
	var published: Dictionary = registry.publish_backend_tools("docket", wire)
	_so.plugin_tool_registry = registry

	var local := SkillDefinition.new()
	local.id = LOCAL_ID
	local.name = "Local probe"
	local.origin = "user"
	local.instructions = "local instructions"
	_so.get_skill_manager().skills.append(local)
	check("the plugin's write tools are registered under their Minerva names", published.get("ok", false)
		and registry.is_plugin_tool("minerva_docket_create") and registry.is_plugin_tool("minerva_docket_update"),
		str(published))
	return published.get("ok", false)


func _test_skill_contract() -> void:
	var listed := await _call("minerva_list_skills", {})
	var refs: Array = listed.get("skills", []).map(func(entry: Dictionary) -> String: return str(entry.get("ref", "")))
	var wanted := [SkillRef.local(LOCAL_ID), SkillRef.docket(_host.master_path, FULL),
		SkillRef.docket(_host.master_path, TWIN_MASTER), SkillRef.docket(WORK_PATH, TWIN_WORK)]
	check("the list holds the local skill and each Docket skill once, by reference, same-titled ones apart",
		listed.get("success") == true and wanted.all(func(ref: String) -> bool: return refs.count(ref) == 1),
		str(listed).left(400))

	# The full skill, loaded by a chat whose model is known (so targeted
	# knowledge is read): its whole content and its targeted hint.
	var provider = _so.API_MODEL_PROVIDER_SCRIPTS[0].new()
	var chat = load("res://Scripts/Models/ChatHistory.gd").new(provider)
	_so.ChatList.append(chat)
	var got := await _call("minerva_get_skill", {"skill_id": FULL}, load(CONTEXT_PATH).create("test", chat.HistoryId))
	var instructions := str(got.get("instructions", ""))
	check("a Docket skill is got whole: prompt text and steps, its tools, its optimization applied, its targeted hint",
		got.get("success") == true and instructions.contains("Section zero") and instructions.contains("2. Act")
		and got.get("tool_deps", []) == [DEP_TOOL] and chat.MaxToolCallRounds == 7
		and str(got.get("insights", [])).contains("prefer the second path"), str(got).left(500))
	_store.failing_types = ["hint"]
	var unknowing := await _call("minerva_get_skill", {"skill_id": FULL}, load(CONTEXT_PATH).create("test", chat.HistoryId))
	_store.failing_types = []
	_so.ChatList.erase(chat)
	if provider is Node:
		provider.free()
	check("when its targeted knowledge cannot be read the skill is still given, and says so",
		unknowing.get("success") == true and unknowing.get("knowledge_status", "") == "error"
		and not unknowing.has("insights"), str(unknowing).left(400))

	var ambiguous := await _call("minerva_get_skill", {"title": "Twin probe"})
	var named := await _call("minerva_get_skill", {"skill_id": SkillRef.docket(WORK_PATH, TWIN_WORK)})
	check("a title two projects share is refused with both candidates; a reference names one",
		ambiguous.get("success") != true and ambiguous.get("candidates", []).size() == 2
		and named.get("success") == true and str(named.get("instructions", "")) == "work twin", "%s %s" % [ambiguous, named])

	var local_got := await _call("minerva_get_skill", {"skill_id": LOCAL_ID})
	check("a local skill is served by SkillManager", local_got.get("success") == true
		and local_got.get("instructions", "") == "local instructions", str(local_got))

	_store.failing_types = ["skill"]
	var unlisted := await _call("minerva_list_skills", {})
	var unread := await _call("minerva_get_skill", {"skill_id": FULL})
	_store.failing_types = []
	var missing := await _call("minerva_get_skill", {"skill_id": "019f0000ffffffffffffffffffffffff"})
	check("a Docket read that fails is not an empty catalog or a missing skill: the list is incomplete with the local skills, the get says why",
		unlisted.get("success") == false and unlisted.get("incomplete") == true
		and str(unlisted.get("skills", [])).contains(LOCAL_ID) and unread.get("success") == false
		and str(unread.get("error", "")).contains("could not be read") and not str(unread.get("error", "")).contains("not found")
		and str(missing.get("error", "")).begins_with("Skill not found"), "%s | %s | %s" % [unlisted, unread, missing])

	# Create in the work project, then update, then load it back.
	var budget = _server().tool_budget_manager
	budget.reset()
	var inactive_before: bool = not budget.is_active(CREATE_DEP)
	var created := await _call("minerva_skill_create", {"title": "Made probe", "project": "work",
		"steps": "made steps", "tool_deps": [CREATE_DEP], "optimization": {"max_tool_rounds": 3}})
	var made_id := str(created.get("id", ""))
	# Its tools are active from the create itself (before any get loads it).
	var active_after_create: bool = budget.is_active(CREATE_DEP)
	var updated := await _call("minerva_skill_update", {"id": made_id, "steps": "changed steps"})
	var reloaded := await _call("minerva_get_skill", {"skill_id": made_id})
	var stored: Dictionary = _store.items.get(made_id, {})
	check("a created skill lands in the named project, active, with its tools activated and its optimization; an update changes it there",
		inactive_before and active_after_create
		and created.get("success") == true and created.get("status") == "active" and stored.get("_project") == "work"
		and stored.get("status") == "active" and stored.get("tool_deps") == [CREATE_DEP]
		and stored.get("optimization") == {"max_tool_rounds": 3} and updated.get("success") == true
		and str(reloaded.get("instructions", "")) == "changed steps", "%s %s %s %s" % [created, updated, reloaded, stored])

	var activated := await _call("minerva_activate_skill", {"skill_id": FULL})
	check("activating a Docket skill loads it", activated.get("success") == true
		and str(activated.get("instructions", "")).contains("Section zero"), str(activated).left(300))

	# A master policy blocks the plugin's update tool: the skill update is
	# refused and nothing reaches the backend.
	_store.items[BLOCK_UPDATES] = {"id": BLOCK_UPDATES, "type": "policy", "status": "active", "_project": "master",
		"title": "No Docket updates", "description": "---policy-rule---\n%s\n---end-rule---"
			% JSON.stringify({"effect": "block", "priority": 10, "tool_pattern": "^minerva_docket_update$"})}
	var writes_before: int = _store.writes.size()
	var refused := await _call("minerva_skill_update", {"id": made_id, "steps": "blocked steps"})
	_store.items.erase(BLOCK_UPDATES)
	check("a write a policy refuses writes nothing and says so", refused.get("success") != true
		and str(refused.get("error", "")).contains("Blocked by policy")
		and _store.writes.size() == writes_before and _store.items[made_id].steps == "changed steps", str(refused))


func _test_interleavings() -> void:
	# A skill update on its way (held at its dispatch's policy read, after the
	# skill was looked up) while its project, the plugin's process or the
	# session changes: refused, unwritten.
	await _held_update("the work project is reopened", func() -> void: _store.work.open_generation = "2")
	await _held_update("the plugin's process changes", func() -> void: _store.generation = 2,
		func() -> void: _store.generation = 1)
	await _held_update("a person changes the session", func() -> void: _host.retry_project("/b10f-test/none.dct"))

	# While a skill update is held there, an unrelated direct update of the
	# same item runs as usual, and the held update then goes ahead.
	_store.hold_policy_read = _store.policy_reads + 2
	var held := []
	(func(): held.append(await _call("minerva_skill_update", {"id": TWIN_WORK, "steps": "held steps"}))).call()
	var reached := await _wait(func(): return _store.policy_reads >= _store.hold_policy_read)
	var direct := await _call("minerva_docket_update", {"project": "work", "id": TWIN_WORK, "title": "Twin probe"})
	_store.hold_policy_read = 0
	var answered := await _wait(func(): return held.size() == 1)
	check("an unrelated direct update of the same item is not held back by a skill update on its way, which then goes ahead",
		reached and direct.get("success") == true and answered and held[0].get("success") == true
		and _store.items[TWIN_WORK].steps == "held steps", "%s %s" % [direct, held])

	await _stopped_creates()

	# An object sent as a JSON string (as an MCP client over HTTP may) is
	# written as the object: the write's binding holds what is sent.
	var outcome = await _server().execute_tool_for_http_outcome("minerva_skill_create",
		{"title": "String probe", "optimization": "{\"max_tool_call_rounds\": 2}"})
	var id := str(outcome.application.get("id", ""))
	var written = _store.items.get(id, {}).get("optimization")
	check("a JSON-string object is written as the object", outcome.application.get("success") == true
		and written is Dictionary and int(written.get("max_tool_call_rounds", 0)) == 2, str(outcome.application))


# A skill update of TWIN_WORK held at its dispatch's policy read (the
# second after it starts: the first is its own admission) while `change`
# happens: refused, nothing written. `undo`, when given, restores the store.
func _held_update(what: String, change: Callable, undo: Callable = Callable()) -> void:
	_store.hold_policy_read = _store.policy_reads + 2
	var writes_before: int = _store.writes.size()
	var result := []
	(func(): result.append(await _call("minerva_skill_update", {"id": TWIN_WORK, "steps": "should not land"}))).call()
	var reached := await _wait(func(): return _store.policy_reads >= _store.hold_policy_read)
	change.call()
	_store.hold_policy_read = 0
	var answered := await _wait(func(): return result.size() == 1)
	if undo.is_valid():
		undo.call()
	check("a skill update on its way is refused, unwritten, when %s" % what,
		reached and answered and result[0].get("success") != true and _store.writes.size() == writes_before
		and _store.items[TWIN_WORK].get("steps", "") != "should not land", str(result))


# Frames for a stopped call's own coroutine to finish what it still does.
func _settle() -> void:
	for frame in 30:
		await process_frame


# minerva_skill_create stopped at each point of its way, through the public
# context: what the caller is told at once, what was written, that nothing
# is retried and no tools are activated. Its policy reads: 1 its own
# admission, 2 its create's, 3 its activation's.
func _stopped_creates() -> void:
	var budget = _server().tool_budget_manager
	budget.reset()
	for point in ["before its create is sent", "while its create is sent", "before its activation is sent",
			"while its activation is sent"]:
		var writes_before: int = _store.writes.size()
		var items_before: Dictionary = _store.items.duplicate()
		match point:
			"before its create is sent":
				_store.hold_policy_read = _store.policy_reads + 2
			"while its create is sent":
				_store.holds["docket_create#%d" % (_store.reached.get("docket_create", 0) + 1)] = true
			"before its activation is sent":
				_store.hold_policy_read = _store.policy_reads + 3
			"while its activation is sent":
				_store.holds["docket_transition#%d" % (_store.reached.get("docket_transition", 0) + 1)] = true
		var context = load(CONTEXT_PATH).create("test")
		var result := []
		(func(): result.append(await _server().call_tool("minerva_skill_create", {"title": "Stop probe",
			"tool_deps": [CREATE_DEP]}, context))).call()
		var reached := await _wait(_held_reached)
		context.cancel()
		var told := await _wait(func(): return result.size() == 1)
		_store.hold_policy_read = 0
		_store.holds.clear()
		await _settle()
		var recovery: Dictionary = result[0].get("recovery", {}) if told else {}
		var writes: Array = _store.writes.slice(writes_before)
		var sent: Array = writes.map(func(w: Array) -> String: return w[0])
		# The skill this iteration created, and the one its activation named.
		var made := ""
		for id in _store.items:
			if not items_before.has(id):
				made = id
		var moved: String = str(writes[1][1].get("id", "")) if writes.size() > 1 else ""
		var ok: bool = reached and told and result[0].get("error_code", "") == "cancelled"
		match point:
			"before its create is sent":
				ok = ok and recovery.is_empty() and sent.is_empty()
			"while its create is sent":
				ok = ok and recovery.get("outcome") == "unknown" and not recovery.has("id") \
					and sent == ["docket_create"]
			"before its activation is sent":
				ok = ok and recovery.get("status") == "draft" and not made.is_empty() and recovery.get("id") == made \
					and sent == ["docket_create"]
			"while its activation is sent":
				ok = ok and recovery.get("status") == "unknown" and recovery.get("outcome") == "unknown" \
					and not made.is_empty() and recovery.get("id") == made and moved == made \
					and sent == ["docket_create", "docket_transition"]
		check("a skill create stopped %s tells its caller at once what it did, is not retried and activates no tools" % point,
			ok and not budget.is_active(CREATE_DEP), "%s %s" % [result, sent])


# Whether the call the store holds has reached its hold.
func _held_reached() -> bool:
	if _store.hold_policy_read > 0:
		return _store.policy_reads >= _store.hold_policy_read
	for key: String in _store.holds:
		if _store.reached.get(key.get_slice("#", 0), 0) >= int(key.get_slice("#", 1)):
			return true
	return false

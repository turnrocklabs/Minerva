extends SceneTree
## Headless test of the master policy as Minerva's governed calls meet it
## when the Docket plugin owns Minerva's projects: a policy blocks a call
## before it runs, a person's approval lets an agent retire it, a policy that
## cannot be read refuses the call, no policy allows it, and a read overtaken
## by a newer one cannot allow what the newer one blocks. Then, with rules
## shaped like the shipped master's (a navigation blocked until a guide is
## read, a scope the read opens, a hint injected by short id): the knowledge a
## call needs is read through the plugin before the call runs, a scope opens
## only for a call that succeeded (skills included), a refusal leaves the
## agent able to read what it names, or says why not, and the Docket plugin's
## tools keep their Minerva names.
##
## Run only in a throwaway profile, made before Godot starts, from the
## repository root:
##   ( source scripts/lib/test-profile.sh && root="$(mktemp -d)" && seed_test_profile "$root" \
##     && MINERVA_TEST_PROFILE_ROOT="$root" timeout 300 \
##        "${GODOT:-godot}" --headless --path src --script test/test_docket_policy_owner.gd )
## The test fails at once unless Godot's user directory is under
## MINERVA_TEST_PROFILE_ROOT and holds none of the files DocketHost writes.
## The plugin-tool dispatch validates its arguments with the JSON Schema
## helper (res://bin/minerva-json-schema-helper, from
## scripts/build-extensions.sh --helper-only); without it that check fails.
##
## REAL: MinervaMCPServer's governed dispatch (call_tool of a native tool),
## MCPManager's skill dispatch and a skill's executable (/bin/sh), the tool
## budget and the tools a chat is offered, PolicyEngine's admission, DocketHost
## (setup, policy_items, policy knowledge and observations, and its backend
## tool guard with the approval check), PolicyApproval's rule,
## PluginToolRegistry's naming and its dispatch of a backend tool (argument
## validation included). FAKED: the plugin manager, the plugin's connection
## and its private channel, answering as the Docket plugin does
## (project list, policy queries, item lookups by id or short id,
## transitions, comments) over in-memory items, where a policy query can be
## held or made to fail and a read or comment made to fail; the person asked
## for approval (the test's DocketHost answers _request_policy_approval
## itself); the two tools the master-shaped rules govern (StandInTools); and,
## for the dispatch, a running plugin (RUNNING_PLUGIN_MANAGER_SRC) whose
## backend records what it is sent (RECORDING_CONNECTION_SRC).
## The embedded DocketManager is set aside while the test runs, so the plugin
## owns the policy.

const CONTEXT_PATH := "res://Scripts/Services/MCP/MCPExecutionContext.gd"
const USER_FILES := ["user://docket_host_session.json", "user://docket_host_session.json.new"]
## A native tool that only reads: the governed call the policies judge.
const TOOL := "minerva_tool_search"
## The governed stand-ins, the skill, and the tool a refusal offers.
const NAVIGATE := "b10e_navigate"
const READ_GUIDE := "b10e_read_guide"
const SKILL_TOOL := "skill_b10e_probe"
const GET_TOOL := "minerva_docket_get"
## Master items: the guide, the hint (named by a short id, in capitals), an
## unrelated hint, and the three rules.
const GUIDE := "019e3333aaaabbbbccccddddeeeeffff"
const HINT := "019e1111aaaabbbbccccddddeeeeffff"
const HINT_REF := "019E1111AAAA"
const OTHER := "019e2222aaaabbbbccccddddeeeeffff"
const BLOCK_RULE := "019e4444aaaabbbbccccddddeeee0001"
const SCOPE_RULE := "019e4444aaaabbbbccccddddeeee0002"
const INJECT_RULE := "019e4444aaaabbbbccccddddeeee0003"

## The tools the master-shaped rules govern: a guide read that can be made
## to fail, and a navigation that counts its runs.
class StandInTools extends RefCounted:
	var read_fails := false
	var navigations := 0
	func can_handle(tool: String) -> bool:
		return tool in ["b10e_navigate", "b10e_read_guide"]
	func handle(tool: String, _arguments: Dictionary) -> Dictionary:
		if tool == "b10e_read_guide":
			return {"success": false, "error": "the guide could not be read"} if read_fails \
				else {"success": true, "content": "the guide"}
		navigations += 1
		return {"success": true, "navigated": navigations}

## The registry and the connection it forwards to, loaded by path when used:
## their scripts name the SingletonObject autoload, so naming their classes
## here would make this script uncompilable where autoloads are not loaded.
const REGISTRY_PATH := "res://Scripts/Services/Plugins/PluginToolRegistry.gd"
const CONNECTION_PATH := "res://Scripts/Services/MCP/MCPServerConnection.gd"

## A backend connection that records the calls sent to it and answers each.
const RECORDING_CONNECTION_SRC := """
extends "res://Scripts/Services/MCP/MCPServerConnection.gd"
var sent := []
func call_tool_outcome_with_context(tool_name: String, arguments: Dictionary, _context: MCPExecutionContext):
	sent.append([tool_name, arguments.duplicate(true)])
	var outcome = load("res://Scripts/Services/MCP/MCPToolCallOutcome.gd").new()
	outcome.application = {"success": true}
	return outcome
"""

## The plugin manager as the registry's dispatch asks it: one running plugin
## whose calls the host allows.
const RUNNING_PLUGIN_MANAGER_SRC := """
extends "res://Scripts/Services/Plugins/PluginManager.gd"
var connection = null
func get_plugin_status(_id: String) -> Dictionary:
	return {"running": true}
func get_connection(_id: String) -> MCPServerConnection:
	return connection
func check_backend_tool(_id: String, _tool: String, _arguments: Dictionary, _caller: String = "agent",
		_write_binding: Dictionary = {}) -> String:
	return ""
"""

## The chat whose offered tools are read (MCPManager.get_tools_for_chat).
class ToolHistory extends RefCounted:
	var DisabledTools: Array[String] = []
	var ActiveSkills: Array[String] = []
	var AgentDefinitionId := ""
	var StaticToolMode := false

## The plugin's connection: the master open, items by id; each policy query
## answers the policies as they were when it was asked, once released.
const CONNECTION_SRC := """
extends RefCounted
var tree: SceneTree = null
var master := {"name": "master", "display_name": "Master", "path": "", "open_generation": "1"}
var items := {}
var query_fails := false
var queries := 0
var held := {}
## Ids whose reads fail, and ids answered with another item's.
var failing_reads := []
var answers_instead := {}
## The items commented on, in order; whether comments fail.
var comments := []
var comments_fail := false
func process_generation() -> int:
	return 1
func policies() -> Array:
	var found := []
	for item in items.values():
		if item.type == "policy" and item.status in ["proposed", "active"]:
			found.append(item.duplicate(true))
	return found
func call_tool(tool: String, arguments: Dictionary) -> Dictionary:
	match tool:
		"docket_project_list":
			return {"success": true, "projects": [master]}
		"docket_query":
			var number := queries
			queries += 1
			var answer := {"success": false, "error": "the query failed"} if query_fails \\
				else {"success": true, "items": policies()}
			while held.has(number):
				await tree.process_frame
			return answer
		"docket_get":
			var id := str(arguments.id)
			if id in failing_reads:
				return {"success": false, "error": "the read failed"}
			if answers_instead.has(id):
				id = answers_instead[id]
			var item = items.get(id)
			# Like the plugin's docket_get: a short hex prefix names the one item it starts.
			if item == null and id.length() >= 4 and id.is_valid_hex_number(false):
				var starting := items.keys().filter(func(key: String) -> bool: return key.begins_with(id.to_lower()))
				item = items[starting[0]] if starting.size() == 1 else null
			return item.merged({"success": true}) if item != null else {"success": false, "error": "Item not found"}
		"docket_transition":
			items[str(arguments.id)].status = str(arguments.to)
			return {"success": true}
		"docket_comment":
			comments.append(str(arguments.item_id))
			return {"success": false, "error": "the comment failed"} if comments_fail else {"success": true}
	return {"success": false, "error": "unexpected tool %s" % tool}
"""

## DocketHost with the person it asks for approval replaced by `answer`,
## given once `deciding` is false (the person takes frames to decide);
## `asked` counts the questions.
const HOST_SRC := """
extends "res://Scripts/Services/DocketHost/DocketHost.gd"
var answer := false
var deciding := false
var asked := 0
func _request_policy_approval(_tool: String, _arguments: Dictionary, _title: String) -> bool:
	asked += 1
	while deciding:
		await get_tree().process_frame
	return answer
"""

## The plugin's private channel: the schema is accepted, the master installed.
const AUTHORITY_SRC := """
extends RefCounted
var connection = null
func host_request(name: String, params: Dictionary) -> Dictionary:
	if name == "declare_schema":
		return {"result": {"version": params.version}}
	connection.master.path = str(params.path)
	return {"result": {"status": "installed", "path": params.path, "project": connection.master,
		"conflicts": [], "capability_gaps": []}}
"""

const PLUGIN_MANAGER_SRC := """
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

var _pass := 0
var _fail := 0
var _so: Node = null
var _made: Array[Node] = []
## The plugin's connection, once DocketHost owns the master through it.
var _connection = null
var _host = null
## The longest any wait here may take, in frames: a wait that runs out fails.
const MAX_FRAMES := 300


func _init() -> void:
	print("=== Docket policy owner ===\n")
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
	await _test_policy_owner()
	if _connection != null:
		await _test_governed_knowledge()
		await _test_skill_scopes()
		await _test_recovery_tools()
	await _test_docket_tool_names()
	_so.docket_manager = saved_manager
	_so.docket_host = saved_host
	# The server's rules come from the embedded Docket again.
	_so.get_mcp_manager().minerva_server.policy_engine.reload()
	for node in _made:
		if is_instance_valid(node):
			node.queue_free()
	for path in USER_FILES:
		if FileAccess.file_exists(path):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _policy(id: String, status: String) -> Dictionary:
	return {"id": id, "type": "policy", "status": status, "title": "No tool search (%s)" % id,
		"description": "---policy-rule---\n%s\n---end-rule---"
			% JSON.stringify({"effect": "block", "priority": 10, "tool_pattern": "^%s$" % TOOL})}


func _governed_call() -> Dictionary:
	var server = _so.get_mcp_manager().minerva_server
	return await server.call_tool(TOOL, {"query": "docket"}, load(CONTEXT_PATH).create("test"))


static func _refused_by(result: Dictionary, rule_id: String) -> bool:
	return result.get("allowed", true) == false and result.get("blocked_by_rule", "") == rule_id


# Whether the tool ran: its own answer (success and a message), not a
# refusal or an error.
static func _ran(result: Dictionary) -> bool:
	return result.get("success") == true and result.has("message") \
		and (result.has("activated") or result.has("tools")) \
		and not result.has("allowed") and not result.has("error_code")


func _test_policy_owner() -> void:
	var connection = _make(CONNECTION_SRC)
	var authority = _make(AUTHORITY_SRC)
	var manager = _make(PLUGIN_MANAGER_SRC)
	if connection == null or authority == null or manager == null:
		return
	connection.tree = self
	connection.items = {"POL-1": _policy("POL-1", "active")}
	authority.connection = connection
	manager.connection = connection
	manager.authority = authority
	root.add_child(manager)
	var host = _make(HOST_SRC)
	if host == null:
		return
	root.add_child(host)
	_so.docket_manager = null
	_so.docket_host = host
	host.start(manager, false)
	manager.plugin_ready.emit("docket")
	var ready := await _wait(func(): return host.state in ["ready", "degraded"])
	check("DocketHost sets up the plugin as the owner, with the master open",
		ready and not host.master_path.is_empty() and host.master_path == connection.master.path,
		"%s %s" % [host.state, host.problems])
	if not ready:
		return
	_connection = connection
	_host = host

	# A blocking master policy refuses the call before it runs.
	var blocked := [0]
	var on_blocked := func(_tool, _arguments, _result, _agent): blocked[0] += 1
	_so.mcp_tool_blocked.connect(on_blocked)
	var refused := await _governed_call()
	check("a blocking master policy refuses the call before it runs, and says so",
		_refused_by(refused, "POL-1") and blocked[0] == 1, "%s / blocked=%d" % [refused, blocked[0]])
	_so.mcp_tool_blocked.disconnect(on_blocked)

	# Retiring the policy: an agent's archive waits for a person; a person's
	# own panel edit does not ask. A no leaves the policy in force.
	var archive := {"id": "POL-1", "to": "archived"}
	host.answer = false
	var denied: String = await manager.guard.call("docket_transition", archive, "agent")
	check("an agent's archive of a policy is refused when the person says no", not denied.is_empty(), denied)
	var panel: String = await manager.guard.call("docket_transition", archive, "panel")
	check("a person's own panel edit of a policy is not asked about", panel.is_empty(), panel)
	# An approval given after the policy changed, or the master was reopened,
	# while the person was still deciding is not used.
	host.answer = true
	host.deciding = true
	var changed: Array = []
	var asked_first: int = host.asked
	(func(): changed.append(await manager.guard.call("docket_transition", archive, "agent"))).call()
	var waiting := await _wait(func(): return host.asked > asked_first)
	connection.items["POL-1"].title = "changed while the person decided"
	host.deciding = false
	var answered_change := await _wait(func(): return changed.size() == 1)
	check("an approval is not used when the policy changed while the person decided",
		waiting and answered_change and not str(changed[0]).is_empty(), str(changed))
	host.deciding = true
	var stale: Array = []
	var asked_before: int = host.asked
	(func(): stale.append(await manager.guard.call("docket_transition", archive, "agent"))).call()
	var deciding := await _wait(func(): return host.asked > asked_before)
	connection.master.open_generation = "2"
	host.deciding = false
	var decided := await _wait(func(): return stale.size() == 1)
	check("an approval is not used when the master was reopened while the person decided",
		deciding and decided and not str(stale[0]).is_empty(), str(stale))
	var approved: String = await manager.guard.call("docket_transition", archive, "agent")
	check("an agent's archive of a policy goes ahead when the person approves", approved.is_empty(), approved)
	if approved.is_empty():
		await connection.call_tool("docket_transition", archive)
		manager.backend_tool_called.emit("docket", "docket_transition")

	# With no policy in force the call runs.
	var allowed := await _governed_call()
	check("once no policy is in force the call runs", _ran(allowed), str(allowed).left(200))

	# A policy that cannot be read refuses the call rather than allow it.
	connection.query_fails = true
	var unread := await _governed_call()
	connection.query_fails = false
	check("a policy read that fails refuses the call as policy_unavailable",
		unread.get("allowed", true) == false and unread.get("error_code", "") == "policy_unavailable",
		str(unread))

	# A read overtaken by a newer one cannot allow what the newer one blocks:
	# the first call's read (no policy) is held while a blocking policy
	# arrives and a second call reads and is refused by it; released, the
	# first call is refused too.
	var first_query: int = connection.queries
	connection.held[first_query] = true
	var older: Array = []
	(func(): older.append(await _governed_call())).call()
	var asked := await _wait(func(): return connection.queries > first_query)
	connection.items["POL-2"] = _policy("POL-2", "active")
	var newer := await _governed_call()
	connection.held.erase(first_query)
	var answered := await _wait(func(): return older.size() == 1)
	check("a call whose older read was overtaken is refused by the newer policy",
		asked and answered and _refused_by(newer, "POL-2") and _refused_by(older[0], "POL-2"),
		"newer=%s older=%s" % [newer, older])

	check("DocketHost wrote no session file for this owner",
		not USER_FILES.any(func(path): return FileAccess.file_exists(path)))


func _call(tool: String, chat: String) -> Dictionary:
	var server = _so.get_mcp_manager().minerva_server
	return await server.call_tool(tool, {}, load(CONTEXT_PATH).create("test", chat))


func _rule(id: String, rule: Dictionary) -> Dictionary:
	return {"id": id, "type": "policy", "status": "active", "title": "Rule %s" % id.right(4),
		"description": "---policy-rule---\n%s\n---end-rule---" % JSON.stringify(rule)}


# Whether `result` refuses the call because rule `rule_id`'s knowledge `ref`
# could not be read.
static func _knowledge_refused(result: Dictionary, rule_id: String, ref: String) -> bool:
	return result.get("allowed", true) == false \
		and result.get("error_code", "") == "policy_knowledge_unavailable" \
		and result.get("blocked_by_rule", "") == rule_id and str(result.get("error", "")).contains(ref)


# The master's guide, hints and the three rules: navigation is blocked until
# the guide is read (by the guide tool or the skill), and the first
# navigation after it carries the hint.
func _master_rules() -> void:
	_connection.items[GUIDE] = {"id": GUIDE, "type": "kb", "title": "Guide", "summary": "read before navigating"}
	_connection.items[HINT] = {"id": HINT, "type": "hint", "title": "Hint", "value": "the button is #buy"}
	_connection.items[OTHER] = {"id": OTHER, "type": "hint", "title": "Other", "value": "not this one"}
	_connection.items[BLOCK_RULE] = _rule(BLOCK_RULE, {"tool_pattern": "^%s$" % NAVIGATE, "effect": "block",
		"priority": 100, "context_predicates": {"scope_not_active": "guide-read"}, "knowledge_ref": GUIDE,
		"alternatives": ["Read the guide first: %s id=%s" % [GET_TOOL, GUIDE]]})
	_connection.items[SCOPE_RULE] = _rule(SCOPE_RULE, {"triggers": [{"tool_pattern": "^%s$" % READ_GUIDE},
		{"tool_pattern": "^%s$" % SKILL_TOOL}], "effect": "scope", "priority": 50,
		"activate_scope": "guide-read", "scope_max_actions": 100, "scope_ttl_ms": 600000})
	_connection.items[INJECT_RULE] = _rule(INJECT_RULE, {"tool_pattern": "^%s$" % NAVIGATE, "effect": "inject",
		"priority": 90, "activate_scope": "hint-given", "scope_max_actions": 100, "scope_ttl_ms": 600000,
		"context_predicates": {"scope_active": "guide-read", "scope_not_active": "hint-given"},
		"knowledge_ref": HINT_REF})


func _test_governed_knowledge() -> void:
	var tools := StandInTools.new()
	var server = _so.get_mcp_manager().minerva_server
	server._modules.push_front(tools)
	_master_rules()

	var first := await _call(NAVIGATE, "flow")
	check("navigation is refused until the guide is read, and the refusal names the guide and how to read it",
		_refused_by(first, BLOCK_RULE) and first.get("knowledge_ref", "") == GUIDE
		and str(first.get("allowed_next_actions", [])).contains(GET_TOOL) and tools.navigations == 0, str(first))

	tools.read_fails = true
	var unread := await _call(READ_GUIDE, "flow")
	tools.read_fails = false
	var still := await _call(NAVIGATE, "flow")
	check("a guide read that fails leaves navigation refused",
		unread.get("success") == false and _refused_by(still, BLOCK_RULE) and tools.navigations == 0, str(still))

	var read := await _call(READ_GUIDE, "flow")
	_connection.failing_reads = [HINT_REF]
	var hintless := await _call(NAVIGATE, "flow")
	_connection.failing_reads = []
	_connection.answers_instead[HINT_REF] = OTHER
	var misanswered := await _call(NAVIGATE, "flow")
	_connection.answers_instead.clear()
	check("once the guide is read, a navigation whose hint cannot be read is refused before it runs, naming the rule and the hint",
		read.get("success") == true and _knowledge_refused(hintless, INJECT_RULE, HINT_REF) and tools.navigations == 0,
		str(hintless))
	check("a hint read answered with another item is refused the same way",
		_knowledge_refused(misanswered, INJECT_RULE, HINT_REF) and tools.navigations == 0, str(misanswered))

	var commented: int = _connection.comments.size()
	_connection.comments_fail = true
	var hinted := await _call(NAVIGATE, "flow")
	var attempted := await _wait(func(): return INJECT_RULE in _connection.comments.slice(commented))
	_connection.comments_fail = false
	var knowledge: Array = hinted.get("_injected_knowledge", [])
	check("with the hint readable by its short id the navigation runs once and carries it, though its observation could not be written",
		hinted.get("success") == true and tools.navigations == 1 and knowledge.size() == 1
		and knowledge[0].get("value", "") == "the button is #buy" and knowledge[0].get("from_rule", "") == INJECT_RULE
		and attempted, str(hinted))
	# The host answers a short id with the item's own, full id.
	var by_short: Dictionary = await _host.policy_knowledge(PackedStringArray([HINT_REF]))
	var items: Array = by_short.get("items", [])
	check("policy knowledge read by a short id is the item under its full id",
		items.size() == 1 and items[0].get("id", "") == HINT, str(by_short))
	var again := await _call(NAVIGATE, "flow")
	check("the next navigation runs without the hint again",
		again.get("success") == true and not again.has("_injected_knowledge") and tools.navigations == 2, str(again))
	server._modules.erase(tools)


# The skill opens the guide-read scope when it succeeds; whether it did is
# seen by the navigation that follows in the same chat (refused by the block
# rule while the scope is closed). Uses the master's items and rules
# _test_governed_knowledge left, with its own stand-in tools.
func _test_skill_scopes() -> void:
	if not FileAccess.file_exists("/bin/sh"):
		check("a POSIX shell runs the skill's executable", false)
		return
	var manager = _so.get_mcp_manager()
	var skills = _so.get_skill_manager()
	var tools := StandInTools.new()
	manager.minerva_server._modules.push_front(tools)
	var skill := SkillDefinition.new()
	skill.id = SKILL_TOOL.trim_prefix("skill_")
	skill.origin = "user"
	skill.executable_path = "/bin/sh"
	skills.skills.append(skill)
	manager.tool_registry[SKILL_TOOL] = MCPToolDefinition.from_dict({"name": SKILL_TOOL,
		"description": "probe", "input_schema": {"type": "object", "properties": {}}}, "minerva")
	var marker := OS.get_user_data_dir().path_join("b10e-skill-ran")
	if FileAccess.file_exists(marker):
		DirAccess.remove_absolute(marker)

	skill.executable_args.assign(["-c", "exit 3"])
	var failed: Dictionary = await manager.execute_tool(SKILL_TOOL, {}, "skill-failed")
	var after_failed := await _call(NAVIGATE, "skill-failed")
	check("a skill whose executable exits nonzero fails, and opens no scope",
		failed.get("success") == false and str(failed.get("error", "")).contains("code 3")
		and _refused_by(after_failed, BLOCK_RULE), "%s %s" % [failed, after_failed])

	# The executable is still running when the caller's one second is up; it
	# runs to its end (OS.execute blocks), and its late result is what is judged.
	skill.executable_args.assign(["-c", "touch '%s'; sleep 2" % marker])
	var late: Dictionary = await manager.execute_tool(SKILL_TOOL, {}, "skill-late",
		load(CONTEXT_PATH).create("test", "skill-late", "", 1.0))
	var after_late := await _call(NAVIGATE, "skill-late")
	check("a skill whose result comes after its caller's deadline returns stopped, and opens no scope",
		FileAccess.file_exists(marker) and late.get("error_code", "") == "deadline_exceeded"
		and _refused_by(after_late, BLOCK_RULE), "%s %s" % [late, after_late])

	skill.executable_args.assign(["-c", "exit 0"])
	var ran: Dictionary = await manager.execute_tool(SKILL_TOOL, {}, "skill-ok")
	var after_ran := await _call(NAVIGATE, "skill-ok")
	check("a skill whose executable succeeds opens its scope",
		ran.get("success") == true and after_ran.get("success") == true, "%s %s" % [ran, after_ran])

	skills.skills.erase(skill)
	manager.tool_registry.erase(SKILL_TOOL)
	manager.minerva_server._modules.erase(tools)
	if FileAccess.file_exists(marker):
		DirAccess.remove_absolute(marker)


# Registers minerva_docket_get as the agent would find it, described by
# `description`.
func _register_get(description: String) -> void:
	var manager = _so.get_mcp_manager()
	var definition = MCPToolDefinition.from_dict({"name": GET_TOOL, "description": description,
		"input_schema": {"type": "object", "properties": {"id": {"type": "string"}}}}, "minerva")
	definition.tool_set = ""
	manager.tool_registry[GET_TOOL] = definition
	manager.minerva_server.tool_search_index.register_tool(GET_TOOL, description,
		definition.to_anthropic_format(), "")


# minerva_docket_get as offered to `history`'s chat on its next turn, or {}.
func _offered_get(history: ToolHistory) -> Dictionary:
	for schema: Dictionary in _so.get_mcp_manager().get_tools_for_chat(history):
		if schema.get("name", "") == GET_TOOL:
			return schema
	return {}


# A refusal naming knowledge (the block rule, left by
# _test_governed_knowledge) with automatic tool management: minerva_docket_get
# is offered on the chat's next turn, or the refusal says why it cannot be
# read. The budget and its lease are the server's, shared by every chat.
func _test_recovery_tools() -> void:
	var manager = _so.get_mcp_manager()
	var server = manager.minerva_server
	var budget = server.tool_budget_manager
	var saved_definition = manager.tool_registry.get(GET_TOOL)
	var saved_hits: Array = server.tool_search_index.search(GET_TOOL, "", 1)
	var saved_auto: bool = server.auto_tool_management
	var saved_budget: int = budget.get_budget()
	var saved_idle: int = budget.get_max_idle_turns()
	var was_connected: bool = manager.is_minerva_connected()
	if not was_connected:
		manager.connect_minerva_server()
	server.auto_tool_management = true
	budget.set_max_idle_turns(0)
	budget.reset()
	budget.set_budget(10000)
	var history := ToolHistory.new()

	_register_get("Reads one Docket item.")
	var offered := await _call(NAVIGATE, "recovery")
	# A competing activation in the same turn, smaller than minerva_docket_get
	# but fitting only if something is pushed out, cannot push it out.
	budget.set_budget(budget.get_token_usage() + 5)
	var filler: Dictionary = budget.activate_tool("f", {"name": "f", "description": "", "input_schema": {}})
	budget.set_budget(10000)
	var visible := _offered_get(history)
	check("a refusal that names knowledge leaves minerva_docket_get offered on the next turn, even against a competing activation",
		_refused_by(offered, BLOCK_RULE) and not offered.has("knowledge_unavailable")
		and not filler.get("active", true) and visible.get("description", "") == "Reads one Docket item.",
		"%s %s %s" % [offered, filler, visible])

	_register_get("Reads one Docket item, with its comments.")
	var changed := await _call(NAVIGATE, "recovery")
	visible = _offered_get(history)
	check("a refusal offers minerva_docket_get as now registered, not an earlier schema",
		_refused_by(changed, BLOCK_RULE) and visible.get("description", "") == "Reads one Docket item, with its comments.",
		str(visible))

	budget.reset()
	budget.set_budget(budget.get_token_usage() + 1)
	var squeezed := await _call(NAVIGATE, "recovery")
	check("when the tool budget cannot hold minerva_docket_get the refusal says its knowledge cannot be read now",
		str(squeezed.get("knowledge_unavailable", "")).contains(GET_TOOL) and _offered_get(history).is_empty(),
		str(squeezed))

	budget.set_budget(10000)
	manager.tool_registry.erase(GET_TOOL)
	var absent := await _call(NAVIGATE, "recovery")
	check("when no minerva_docket_get is registered the refusal says so",
		str(absent.get("knowledge_unavailable", "")).contains("not registered"), str(absent))

	server.tool_search_index.unregister_tool(GET_TOOL)
	if saved_definition != null:
		manager.tool_registry[GET_TOOL] = saved_definition
	if not saved_hits.is_empty() and saved_hits[0].get("name", "") == GET_TOOL:
		server.tool_search_index.register_tool(GET_TOOL, str(saved_hits[0].get("description", "")),
			saved_hits[0].get("schema", {}), str(saved_definition.tool_set) if saved_definition != null else "")
	budget.reset()
	budget.set_budget(saved_budget)
	budget.set_max_idle_turns(saved_idle)
	server.auto_tool_management = saved_auto
	if not was_connected:
		manager.disconnect_minerva_server()


func _backend_tool(name: String):
	return MCPToolDefinition.from_dict({"name": name, "description": name,
		"inputSchema": {"type": "object", "properties": {}}})


# The Docket plugin's backend tools register under the names the embedded
# Docket's had, so rules, skills and prompts that name them keep matching,
# and a call is sent to the backend under the backend's own name.
func _test_docket_tool_names() -> void:
	var docket = _make(RECORDING_CONNECTION_SRC)
	var manager = _make(RUNNING_PLUGIN_MANAGER_SRC)
	if docket == null or manager == null:
		return
	docket.tools = [_backend_tool("docket_get"), _backend_tool("docket_query")]
	manager.connection = docket
	var registry = load(REGISTRY_PATH).new(manager)
	var published: Dictionary = registry.publish_backend_tools("docket", docket)
	var probe = load(CONNECTION_PATH).new("probe")
	probe.tools = [_backend_tool("docket_get")]
	manager.connection = probe
	registry.publish_backend_tools("probe", probe)
	manager.connection = docket
	check("the Docket plugin's tools keep their Minerva names; another plugin's stay under its prefix",
		published.get("ok", false) and registry.tool_for("docket", "docket_get") == GET_TOOL
		and registry.tool_for("docket", "docket_query") == "minerva_docket_query"
		and registry.tool_for("probe", "docket_get") == "minerva_probe_docket_get", str(published))
	var outcome = await registry.handle_tool_call_outcome(GET_TOOL, {"id": GUIDE}, load(CONTEXT_PATH).create("test"))
	check("a call to minerva_docket_get is sent to the backend once, as docket_get with its arguments",
		docket.sent == [["docket_get", {"id": GUIDE}]] and outcome.application.get("success") == true,
		"%s %s" % [docket.sent, outcome.application])

	var twice = load(CONNECTION_PATH).new("docket")
	twice.tools = [_backend_tool("docket_get"), _backend_tool(GET_TOOL)]
	var doubled = load(REGISTRY_PATH).new()
	var duplicate: Dictionary = doubled.publish_backend_tools("docket", twice)
	check("two backend tools that would share one Minerva name are refused together",
		duplicate.has("error") and doubled.get_plugin_tools("docket").is_empty(), str(duplicate))

	var embedded = load(REGISTRY_PATH).new()
	embedded.set_builtin_tool_names([GET_TOOL])
	var clash: Dictionary = embedded.publish_backend_tools("docket", docket)
	check("while a built-in minerva_docket_get exists the Docket plugin's whole tool set is refused",
		clash.has("error") and embedded.get_plugin_tools("docket").is_empty(), str(clash))

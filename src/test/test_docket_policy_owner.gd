extends SceneTree
## Headless test of the master policy as Minerva's governed calls meet it
## when the Docket plugin owns Minerva's projects: a policy blocks a call
## before it runs, a person's approval lets an agent retire it, a policy that
## cannot be read refuses the call, no policy allows it, and a read overtaken
## by a newer one cannot allow what the newer one blocks.
##
## Run only in a throwaway profile, made before Godot starts, from the
## repository root:
##   ( source scripts/lib/test-profile.sh && root="$(mktemp -d)" && seed_test_profile "$root" \
##     && MINERVA_TEST_PROFILE_ROOT="$root" timeout 300 \
##        "${GODOT:-godot}" --headless --path src --script test/test_docket_policy_owner.gd )
## The test fails at once unless Godot's user directory is under
## MINERVA_TEST_PROFILE_ROOT and holds none of the files DocketHost writes.
##
## REAL: MinervaMCPServer's governed dispatch (call_tool of a native tool),
## PolicyEngine's admission, DocketHost (setup, policy_items, and its backend
## tool guard with the approval check), PolicyApproval's rule. FAKED: the
## plugin manager, the plugin's connection and its private channel, answering
## as the Docket plugin does (project list, policy queries, item lookups and
## transitions) over in-memory items, where a policy query can be held or made
## to fail; and the person asked for approval (the test's DocketHost answers
## _request_policy_approval itself).
## The embedded DocketManager is set aside while the test runs, so the plugin
## owns the policy.

const CONTEXT_PATH := "res://Scripts/Services/MCP/MCPExecutionContext.gd"
const USER_FILES := ["user://docket_host_session.json", "user://docket_host_session.json.new"]
## A native tool that only reads: the governed call the policies judge.
const TOOL := "minerva_tool_search"

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
			var item = items.get(str(arguments.id))
			return item.merged({"success": true}) if item != null else {"success": false, "error": "Item not found"}
		"docket_transition":
			items[str(arguments.id)].status = str(arguments.to)
			return {"success": true}
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

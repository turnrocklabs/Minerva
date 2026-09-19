extends SceneTree
## Headless test of which chat supervises a spawned worker.
##
## Run: godot --headless --path src --script test/test_worker_parent_chat.gd
##
## WHAT IS REAL HERE
##   the real MCPAgentTools._spawn_worker / _resolve_parent_chat_id /
##   _list_workers / _on_worker_chat_finished / _inject_completion_into_parent,
##   a real WorkerRegistry with its budgets, real ChatHistory objects in the
##   real SingletonObject.ChatList, and a real ChatPane subclass as the pane.
##
## WHAT IS FAKED, AND WHY
##   the MCP server behind `server.call_tool` — creating a chat, setting a system
##   prompt and enabling agent mode all need the booted UI — so the stand-in
##   creates a ChatHistory and a tab for it and answers the other two calls with
##   success. The pane's turn path is replaced by a recorder, so "which chat was
##   woken" is read off the tab the pane was on when the turn started. No
##   provider is ever contacted.
##
## THE CASE THIS COVERS: a harness running in a Minerva terminal calls
## minerva_spawn_worker over MCP with no caller chat. Without an explicit
## parent it adopts whatever tab happens to be current, and the worker's
## completion wakes a stranger's chat.

const AGENT_TOOLS_PATH := "res://Scripts/Services/MCP/Modules/MCPAgentTools.gd"
const CHAT_HISTORY_PATH := "res://Scripts/Models/ChatHistory.gd"
const WORKER_REGISTRY_PATH := "res://Scripts/Services/Agents/WorkerRegistry.gd"
const CONTEXT_PATH := "res://Scripts/Services/MCP/MCPExecutionContext.gd"

## Pane stand-in: keeps ChatPane's real identity (tabs, current_tab) and records
## turns instead of running them. _ready() is skipped because the unique-name
## nodes it wires only exist in the booted scene.
const HARNESS_PANE_SRC := """
extends "res://Scripts/UI/Views/ChatPane.gd"

## One entry per started turn: {"tab": int, "text": String}
var turns: Array[Dictionary] = []

func _ready() -> void:
	pass

func execute_regular_chat(text: String, _generation_options: Dictionary = {}) -> void:
	turns.append({"tab": current_tab, "text": text})
"""

## MCP server stand-in for the three tools _spawn_worker calls.
const FAKE_SERVER_SRC := """
extends RefCounted

## The test object, which owns chat creation (it must add a tab as well).
var host = null
var calls: Array[String] = []

func call_tool(tool_name: String, args: Dictionary, _context = null) -> Dictionary:
	calls.append(tool_name)
	match tool_name:
		"minerva_create_chat":
			var history = host.add_chat(str(args.get("name", "worker")))
			return {"success": true, "chat_id": history.HistoryId, "provider": "fake"}
		_:
			return {"success": true}
"""

var _pass := 0
var _fail := 0
## Autoloads register after this script is compiled, so SingletonObject is
## resolved as a node at runtime rather than by identifier.
var _so: Node = null
var _pane: Node = null
var _server = null
var _module = null
var _registry = null
var _saved_registry = null
var _chats: Array = []


func _init() -> void:
	print("=== Worker parent chat selection ===\n")
	await _run()
	_teardown()
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


func _make_script(source: String) -> GDScript:
	var script := GDScript.new()
	script.source_code = source
	script.reload()
	return script


## Register a chat in ChatList and give the pane a tab for it, so the tab index
## the production code looks up with find_chat_tab_index really exists.
func add_chat(chat_name: String):
	var history = load(CHAT_HISTORY_PATH).new(null)
	history.HistoryName = chat_name
	_so.ChatList.append(history)
	_chats.append(history)
	_pane.add_child(Control.new())
	return history


func _tab_of(history) -> int:
	return _so.ChatList.find(history)


func _context(caller_chat_id: String):
	return load(CONTEXT_PATH).create("mcp", caller_chat_id)


func _spawn(args: Dictionary, caller_chat_id: String = "") -> Dictionary:
	var full := {"name": "W", "system_prompt": "You are a worker.", "task": "do it"}
	full.merge(args, true)
	return await _module._spawn_worker(full, _context(caller_chat_id))


func _setup() -> void:
	_pane = _make_script(HARNESS_PANE_SRC).new()
	_pane.name = "HarnessChatPane"
	root.add_child(_pane)
	_so.Chats = _pane
	# Tab index and ChatList index are the same number in production, so give the
	# pane a page for every chat that is already registered.
	for i in range(_so.ChatList.size()):
		_pane.add_child(Control.new())

	_registry = load(WORKER_REGISTRY_PATH).new()
	_saved_registry = _so.worker_registry
	_so.worker_registry = _registry

	_server = _make_script(FAKE_SERVER_SRC).new()
	_server.host = self
	_module = load(AGENT_TOOLS_PATH).new(_server)


func _teardown() -> void:
	if _so == null:
		return
	for history in _chats:
		_so.ChatList.erase(history)
	_so.worker_registry = _saved_registry
	if _pane:
		_pane.queue_free()


func _run() -> void:
	await process_frame
	_so = root.get_node_or_null("/root/SingletonObject")
	check("S0: the SingletonObject autoload is live", _so != null)
	if _so == null:
		return
	_setup()
	await _test_explicit_parent_wins()
	await _test_unknown_parent_is_an_error()
	await _test_caller_chat_is_the_default()
	await _test_current_tab_is_the_last_resort()


#region A — the oracle: an explicit parent that is not the current tab

func _test_explicit_parent_wins() -> void:
	var bystander = add_chat("Bystander")
	var supervisor = add_chat("Harness supervisor")
	_pane.current_tab = _tab_of(bystander)

	# A terminal harness: an MCP caller with no chat of its own.
	var result: Dictionary = await _spawn({"parent_chat_id": supervisor.HistoryId})
	check("A1: the spawn succeeds", result.get("success", false), str(result.get("error", "")))
	check("A2: the worker reports the requested parent, not the current tab",
		result.get("parent_chat_id", "") == supervisor.HistoryId,
		"got %s, current tab is %s" % [result.get("parent_chat_id", ""), bystander.HistoryId])

	check("A3: the registry files it under that parent",
		_registry.get_workers_for_parent(supervisor.HistoryId).size() == 1
			and _registry.get_workers_for_parent(bystander.HistoryId).is_empty())

	var listed: Dictionary = _module._list_workers({"parent_chat_id": supervisor.HistoryId})
	check("A4: minerva_list_workers filters on the same parent",
		listed.get("count", 0) == 1, str(listed))

	check("A5: the spawn is billed to that parent's budget",
		_registry.get_budget_summary(supervisor.HistoryId).get("total_workers_spawned", 0) == 1
			and _registry.get_budget_summary(bystander.HistoryId).get("total_workers_spawned", 0) == 0,
		"%s / %s" % [str(_registry.get_budget_summary(supervisor.HistoryId)),
			str(_registry.get_budget_summary(bystander.HistoryId))])

	# The worker finishes while the user is still sitting on the bystander tab.
	var worker_chat_id: String = result.get("chat_id", "")
	var worker_chat = _find_chat(worker_chat_id)
	if worker_chat:
		worker_chat.termination_reason = "completed"
	_pane.current_tab = _tab_of(bystander)
	_pane.turns.clear()
	_module._on_worker_chat_finished(worker_chat_id, "")
	await process_frame

	check("A6: exactly one chat is woken by the completion",
		_pane.turns.size() == 1, str(_pane.turns))
	if _pane.turns.size() == 1:
		var turn: Dictionary = _pane.turns[0]
		check("A7: the completion is injected into the requested parent",
			turn["tab"] == _tab_of(supervisor),
			"woke tab %d, supervisor is %d" % [turn["tab"], _tab_of(supervisor)])
		check("A8: and it is the sub-agent completion message",
			str(turn["text"]).begins_with('[Sub-agent "W"'), str(turn["text"]))

#endregion


#region B — an unknown parent is refused, not swallowed

func _test_unknown_parent_is_an_error() -> void:
	var before: int = _registry.get_all_workers().size()
	_server.calls.clear()

	var result: Dictionary = await _spawn({"parent_chat_id": "no-such-chat"})
	check("B1: a parent_chat_id naming no open chat fails",
		not result.get("success", true), str(result))
	check("B2: the error names the argument",
		str(result.get("error", "")).find("parent_chat_id") != -1, str(result.get("error", "")))
	check("B3: no worker is registered", _registry.get_all_workers().size() == before)
	check("B4: and no worker chat is created — the refusal is before any side effect",
		_server.calls.is_empty(), str(_server.calls))

#endregion


#region C — default: the calling chat

func _test_caller_chat_is_the_default() -> void:
	var caller = add_chat("Calling supervisor")
	var elsewhere = add_chat("Elsewhere")
	_pane.current_tab = _tab_of(elsewhere)

	var result: Dictionary = await _spawn({}, caller.HistoryId)
	check("C1: with no argument the caller chat supervises",
		result.get("parent_chat_id", "") == caller.HistoryId, str(result))
	check("C2: the registry agrees",
		_registry.get_workers_for_parent(caller.HistoryId).size() == 1)

#endregion


#region D — last resort: the current tab

func _test_current_tab_is_the_last_resort() -> void:
	var current = add_chat("Current tab")
	_pane.current_tab = _tab_of(current)

	var result: Dictionary = await _spawn({})
	check("D1: with neither argument nor caller chat the current tab supervises",
		result.get("parent_chat_id", "") == current.HistoryId, str(result))
	# _spawn_worker leaves the pane on the new worker's tab until a deferred call
	# restores it, so put it back by hand before the next spawn.
	_pane.current_tab = _tab_of(current)
	var blank: Dictionary = await _spawn({"parent_chat_id": "  "})
	check("D2: an empty parent_chat_id argument is treated as absent, not as unknown",
		blank.get("parent_chat_id", "") == current.HistoryId, str(blank))

#endregion


func _find_chat(chat_id: String):
	for history in _so.ChatList:
		if history.HistoryId == chat_id:
			return history
	return null

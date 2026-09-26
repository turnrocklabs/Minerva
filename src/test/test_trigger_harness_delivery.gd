extends SceneTree
## Minerva triggers delivering to existing harness sessions (TriggerDestination,
## TriggerHarnessDelivery) through the terminal notification path, driven with
## real TriggerManagers over the notify suite's world (test/helpers/
## notify_world.gd): the real MCPTerminalTools with its terminal listing and
## relay send scripted, real chat bindings, the real chat queue.
##
## Covered: addressing and exact routing; chat queueing without duplicates;
## holds that retry and a hold limit that is not overrun; disable, edit and
## delete (held, queued, still resolving, or in the relay's round trip);
## missing, earlier-run, restarted, changed and unidentifiable targets (never
## an internal spawn, never another session); restart binding; every trigger
## source; the unchanged internal-agent path; the MCP trigger tools and the
## trigger editor, including conflicts with changes made while they wait; and
## the host's session guards at the write (the real TerminalInputArbiter).
##
## Run: godot --headless --path src --script test/test_trigger_harness_delivery.gd

const World := preload("res://test/helpers/notify_world.gd")
const FAKE_PROVIDER_SRC := World.FAKE_PROVIDER_SRC
const HARNESS_PANE_SRC := World.HARNESS_PANE_SRC
const CHAT_HISTORY_PATH := "res://Scripts/Models/ChatHistory.gd"
const TRIGGER_MANAGER_PATH := "res://Scripts/Services/Agents/TriggerManager.gd"
const AGENT_TOOLS_PATH := "res://Scripts/Services/MCP/Modules/MCPAgentTools.gd"
const AGENT_WINDOW_PATH := "res://Scripts/UI/Windows/AgentManagerWindow.gd"
const ARBITER_PATH := "res://Scripts/Services/Terminal/TerminalInputArbiter.gd"

## A terminal session as the host's write guard reads it: the foreground
## harness and its process group, which a test replaces mid-flight, and the
## container pane's mode (TerminalSession.pane_mode).
const FAKE_SESSION_SRC := """
extends Node
var harness: String = "codex"
var pid: int = 5050
var last_input_ticks_ms: int = 0
var pane: String = "not_container"

func pane_mode() -> String:
	return pane

func foreground_supported() -> bool:
	return true

func get_foreground_process() -> Dictionary:
	return {"name": harness, "pid": pid}

func harness_of(_process: Dictionary) -> String:
	return harness
"""

var _pass := 0
var _fail := 0
## Autoloads register after this script is compiled, so SingletonObject is
## resolved as a node at runtime rather than by identifier.
var _so: Node = null
var _saved_chats = null
## Real PreferencesPopup + NotesContainers for the host fields the real render
## path reads; without them the production code renders against nulls.
var _host_render := preload("res://test/helpers/chat_host_render_fixture.gd").new()


func _init() -> void:
	print("=== triggers delivering to harness sessions ===\n")
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _run() -> void:
	await process_frame
	_so = root.get_node_or_null("/root/SingletonObject")
	check("S0: the SingletonObject autoload is live", _so != null)
	if _so == null:
		return
	_saved_chats = _so.Chats
	_host_render.install(_so)
	await _test_triggers_deliver_to_harness_sessions()
	_host_render.restore()


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("PASS: %s" % label)
	else:
		_fail += 1
		print("FAIL: %s%s" % [label, ("  — " + detail) if detail else ""])


func _make_script(source: String) -> GDScript:
	return World.make_script(source)


func _make_bound_chat(chat_name: String, terminal_id: String):
	return World.make_bound_chat(chat_name, terminal_id)


func _make_pane(chats: Array, source: String = HARNESS_PANE_SRC) -> Node:
	return World.make_pane(self, _so, chats, source)


func _teardown(pane: Node, chats: Array) -> void:
	World.teardown(_so, _saved_chats, pane, chats)


func _make_module(terminals: Array, profiles: Dictionary) -> Object:
	return World.make_module(terminals, profiles)


#region T — triggers deliver to harness sessions through this path

const HELD_REPLY := {"error": "terminal 505 is showing a permission dialog that wants a keystroke; nothing was written", "held": true}
const OK_REPLY := {"ok": true, "submit": {"state": "submitted", "evidence": "echo"}}


func _test_triggers_deliver_to_harness_sessions() -> void:
	var claude_chat = _make_bound_chat("Claude Session", "101")
	var codex_chat = _make_bound_chat("Codex Session", "202")
	var agent := AgentDefinition.new()
	agent.name = "T11 agent"
	_so.agent_registry.add_agent(agent)
	var agent_chat = load(CHAT_HISTORY_PATH).new(null)
	agent_chat.HistoryName = "Agent Chat"
	agent_chat.AgentDefinitionId = agent.id
	var chats: Array = [claude_chat, codex_chat, agent_chat]
	var pane = _make_pane(chats)
	var provider = _make_script(FAKE_PROVIDER_SRC).new()
	provider.tree = self
	pane.provider = provider
	var module = _make_module([
		{"id": "101", "name": "Claude Session", "harness": "claude", "alive": true},
		{"id": "202", "name": "Codex Session", "harness": "codex", "alive": true},
		{"id": "303", "name": "Scratch", "foreground_process": "bash", "alive": true},
		{"id": "505", "name": "Codex Bare", "harness": "codex", "foreground_process": "codex", "foreground_pid": 5050, "alive": true},
	], {"101": "claude", "202": "codex"})
	TriggerDestination.address_tools = module
	var tm = load(TRIGGER_MANAGER_PATH).new()
	root.add_child(tm)
	tm.harness_delivery.tools = module
	var chats_before: int = _so.ChatList.size()

	# T1 — addressing: resolved once, to a stable name.
	var bare: Dictionary = await TriggerDestination.from_address("codex@Codex Bare")
	var chat: Dictionary = await TriggerDestination.from_address("claude")
	check("T1: a terminal with no chat is named by its id and this run",
		bare.has("destination") and bare.destination.kind == TriggerDestination.Kind.TERMINAL
			and bare.destination.terminal_id == "505" and bare.destination.run_id == TriggerDestination.current_run, str(bare))
	check("T1: a session with a chat is named by the chat",
		chat.has("destination") and chat.destination.kind == TriggerDestination.Kind.CHAT
			and chat.destination.chat_id == str(claude_chat.HistoryId)
			and chat.destination.label == "claude@Claude Session", str(chat))
	var shell: Dictionary = await TriggerDestination.from_address("Scratch")
	var ambiguous: Dictionary = await TriggerDestination.from_address("codex")
	check("T1: a shell, or an address matching two sessions, is refused",
		shell.has("error") and ambiguous.has("error") and "matches 2" in str(ambiguous.error), str([shell, ambiguous]))

	# T2 — a timer fire reaches exactly the named terminal, and nothing is spawned.
	var to_bare := await _harness_trigger(tm, "night watch", "codex@Codex Bare", "T2 check the build")
	tm._on_timer_fired(to_bare.id)
	var r2: Dictionary = await _await_receipt(tm, to_bare.id, ["handed_to_harness", "failed"])
	check("T2: the line is written into that terminal, in the trigger's envelope",
		r2.get("status") == "handed_to_harness" and module.relay_calls.size() == 1
			and str(module.relay_calls[0].get("terminal_id")) == "505"
			and str(module.relay_calls[0].get("text")) == "[MINERVA NOTIFY from trigger night watch] T2 check the build",
		str(r2) + " " + str(module.relay_calls))
	check("T2: no agent chat was spawned", _so.ChatList.size() == chats_before)

	# T3 — an idle chat takes it as its next turn.
	var to_claude := await _harness_trigger(tm, "reviewer", "claude", "T3 look at the diff")
	var envelope3 := "[MINERVA NOTIFY from trigger reviewer] T3 look at the diff"
	tm._fire_trigger(to_claude.id)
	var r3: Dictionary = await _await_receipt(tm, to_claude.id, ["handed_to_harness", "failed"])
	check("T3: an idle chat's next turn is the envelope",
		r3.get("status") == "handed_to_harness" and str(r3.get("target", {}).get("chat_id")) == str(claude_chat.HistoryId)
			and str(provider.texts_for("Claude Session")) == str(PackedStringArray([envelope3])),
		str(r3) + " " + str(provider.calls))
	provider.release("Claude Session", envelope3)
	for _i in range(4):
		await process_frame

	# T4 — a busy chat queues it; a fire while it waits is folded in, not added.
	pane.current_tab = _so.ChatList.find(claude_chat)
	pane.execute_regular_chat("T4 mid-turn")
	await process_frame
	tm._fire_trigger(to_claude.id)
	var r4: Dictionary = await _await_receipt(tm, to_claude.id, ["queued", "failed"])
	var second_fire: bool = tm._fire_trigger(to_claude.id)
	check("T4: behind a busy turn the delivery is queued, and a second fire is coalesced into it",
		r4.get("status") == "queued" and not second_fire
			and int(tm.harness_delivery.receipt(to_claude.id).get("coalesced", 0)) == 1
			and pane._outgoing_queue.pending_texts(claude_chat.HistoryId).size() == 1, str(r4))
	provider.release("Claude Session", "T4 mid-turn")
	for _i in range(6):
		await process_frame
	check("T4: it becomes the chat's next turn exactly once, and the receipt follows",
		str(provider.texts_for("Claude Session")) == str(PackedStringArray([envelope3, "T4 mid-turn", envelope3]))
			and tm.harness_delivery.receipt(to_claude.id).get("status") == "handed_to_harness",
		str(provider.calls) + " " + str(tm.harness_delivery.receipt(to_claude.id)))
	provider.release("Claude Session", envelope3)
	for _i in range(4):
		await process_frame

	# T5 — a held delivery is retried, never duplicated, and written once it clears.
	module.relay_reply = HELD_REPLY
	var held := await _harness_trigger(tm, "held", "codex@Codex Bare", "T5 marker")
	tm._fire_trigger(held.id)
	var r5: Dictionary = await _await_receipt(tm, held.id, ["held", "failed"])
	var coalesced: bool = not tm._fire_trigger(held.id)
	var calls_at_clear: int = module.relay_calls.size()
	module.relay_reply = OK_REPLY
	var r5b: Dictionary = await _await_receipt(tm, held.id, ["handed_to_harness", "failed"], 3.0 * tm.harness_delivery.RETRY_S)
	check("T5: a dialog holds it, a fire meanwhile is coalesced, and the next look writes it once",
		r5.get("status") == "held" and coalesced and r5b.get("status") == "handed_to_harness"
			and module.relay_calls.size() == calls_at_clear + 1, str([r5, r5b]))

	# T6 — disabling abandons a held delivery.
	module.relay_reply = HELD_REPLY
	var disabled := await _harness_trigger(tm, "disabled", "codex@Codex Bare", "T6 marker")
	tm._fire_trigger(disabled.id)
	await _await_receipt(tm, disabled.id, ["held", "failed"])
	tm.set_trigger_enabled(disabled.id, false)
	module.relay_reply = OK_REPLY
	var calls_at_disable: int = module.relay_calls.size()
	await create_timer(2.0 * tm.harness_delivery.RETRY_S).timeout
	check("T6: after disable nothing more is sent and the receipt says cancelled",
		module.relay_calls.size() == calls_at_disable
			and tm.harness_delivery.receipt(disabled.id).get("status") == "cancelled",
		str(tm.harness_delivery.receipt(disabled.id)))

	# T7 — deleting takes a still-queued delivery back out of the chat's queue.
	pane.current_tab = _so.ChatList.find(claude_chat)
	pane.execute_regular_chat("T7 mid-turn")
	await process_frame
	var deleted := await _harness_trigger(tm, "deleted", "claude", "T7 marker")
	tm._fire_trigger(deleted.id)
	await _await_receipt(tm, deleted.id, ["queued", "failed"])
	tm.remove_trigger(deleted.id)
	check("T7: delete withdraws the queued envelope",
		tm.harness_delivery.receipt(deleted.id).get("status") == "withdrawn"
			and pane._outgoing_queue.pending_texts(claude_chat.HistoryId).is_empty(),
		str(tm.harness_delivery.receipt(deleted.id)))
	provider.release("Claude Session", "T7 mid-turn")
	for _i in range(6):
		await process_frame
	check("T7: the withdrawn envelope never becomes a turn",
		not str(provider.calls).contains("T7 marker"), str(provider.calls))

	# T8 — a missing terminal, or one from an earlier run, fails without a fallback.
	var gone := await _harness_trigger(tm, "gone", "codex@Codex Bare", "T8 marker")
	var terminals_before: Array = module.terminals
	module.terminals = terminals_before.filter(func(t: Dictionary) -> bool: return t.id != "505")
	var calls_at_gone: int = module.relay_calls.size()
	tm._fire_trigger(gone.id)
	var r8: Dictionary = await _await_receipt(tm, gone.id, ["failed", "handed_to_harness"])
	module.terminals = terminals_before
	var earlier := await _harness_trigger(tm, "earlier", "codex@Codex Bare", "T8 earlier")
	earlier.destination.run_id = "an-earlier-run"
	var fired_earlier: bool = tm._fire_trigger(earlier.id)
	check("T8: a terminal that is gone fails, naming why, with nothing sent or spawned",
		r8.get("status") == "failed" and "No terminal matches" in str(r8.get("reason"))
			and module.relay_calls.size() == calls_at_gone and _so.ChatList.size() == chats_before, str(r8))
	check("T8: a terminal of an earlier run is unresolved, not rebound",
		not fired_earlier and "earlier Minerva run" in str(tm.harness_delivery.receipt(earlier.id).get("reason"))
			and module.relay_calls.size() == calls_at_gone, str(tm.harness_delivery.receipt(earlier.id)))

	# T9 — after a restart a chat destination follows the chat to its new terminal.
	var saved: TriggerDefinition = TriggerDefinition.deserialize(to_claude.serialize())
	claude_chat.provider.entry_id = "terminal-707"
	var relaunched: Dictionary = saved.destination.resolve()
	claude_chat.provider.entry_id = "terminal-101"
	var saved_bare: TriggerDefinition = TriggerDefinition.deserialize(to_bare.serialize())
	var this_run: String = TriggerDestination.current_run
	TriggerDestination.current_run = "a-later-run"
	var after_restart: Dictionary = saved_bare.destination.resolve()
	TriggerDestination.current_run = this_run
	check("T9: a saved chat destination resolves to the terminal the chat is bound to now",
		str(relaunched.get("terminal_id")) == "707", str(relaunched))
	check("T9: a saved terminal destination is unresolved in a later run",
		after_restart.has("error"), str(after_restart))

	# T10 — every trigger source reaches a destination through the same dispatch.
	var sources: Array[TriggerDefinition] = []
	var note_trig := await _harness_trigger(tm, "note", "codex@Codex Bare", "T10 note", TriggerDefinition.TriggerType.EVENT,
		{"event_type": TriggerDefinition.EventType.NOTE_CHANGED})
	var time_trig := await _harness_trigger(tm, "time", "codex@Codex Bare", "T10 time", TriggerDefinition.TriggerType.TIME,
		{"schedule_type": TriggerDefinition.ScheduleType.DAILY, "schedule_time": "00:00"})
	var docket_trig := await _harness_trigger(tm, "docket", "codex@Codex Bare", "", TriggerDefinition.TriggerType.DOCKET_POLL,
		{"docket_project": "t10project"})
	var plugin_trig := await _harness_trigger(tm, "plugin", "codex@Codex Bare", "T10 plugin {event_name}",
		TriggerDefinition.TriggerType.PLUGIN_EVENT, {"plugin_id": "t10plugin"})
	var timer_trig := await _harness_trigger(tm, "timer", "codex@Codex Bare", "T10 timer", TriggerDefinition.TriggerType.TIMER,
		{"interval_seconds": 5.0})
	_so.note_changed.emit(null)
	tm._on_schedule_check()
	if _so.docket_manager != null:
		_so.docket_manager.item_created.emit("t10item", "bug", "t10project")
	if _so.plugin_event_broker != null:
		_so.plugin_event_broker.plugin_event.emit("t10plugin", "ping", {})
	for trig in [note_trig, time_trig, docket_trig, plugin_trig, timer_trig]:
		var seconds: float = 8.0 if trig == timer_trig else 3.0
		var got: Dictionary = await _await_receipt(tm, trig.id, ["handed_to_harness", "failed"], seconds)
		check("T10: the %s source delivers" % trig.name, got.get("status") == "handed_to_harness", str(got))
	check("T10: the docket and plugin events arrive as one line each",
		_sent_containing(module, "Docket event in project 't10project'") == 1
			and _sent_containing(module, "T10 plugin ping") == 1, str(module.relay_calls))
	# Its 5 s timer would keep writing into the counts below.
	tm.set_trigger_enabled(timer_trig.id, false)

	# T11 — a trigger without a destination still messages its agent's chat.
	var internal := TriggerDefinition.new()
	internal.name = "internal"
	internal.agent_id = agent.id
	internal.action_type = TriggerDefinition.ActionType.MESSAGE_EXISTING
	internal.initial_message = "T11 for the agent"
	internal.trigger_type = TriggerDefinition.TriggerType.TIMER
	internal.interval_seconds = 3600.0
	internal.enabled = true
	tm.add_trigger(internal)
	var calls_at_internal: int = module.relay_calls.size()
	var fired_internal: bool = tm._fire_trigger(internal.id)
	for _i in range(4):
		await process_frame
	check("T11: an agent trigger messages its agent's existing chat, through no terminal",
		fired_internal and str(provider.texts_for("Agent Chat")) == str(PackedStringArray(["T11 for the agent"]))
			and module.relay_calls.size() == calls_at_internal, str(provider.calls))
	provider.release("Agent Chat", "T11 for the agent")
	for _i in range(4):
		await process_frame

	# T12 — the MCP tools take a destination, refuse what it cannot do, and list
	# it. They act on the app's TriggerManager, so it delivers through the
	# scripted terminals too until T18 is done.
	var app_delivery_tools: RefCounted = _so.trigger_manager.harness_delivery.tools
	_so.trigger_manager.harness_delivery.tools = module
	var tools = load(AGENT_TOOLS_PATH).new(null)
	var created: Dictionary = await tools.handle("minerva_create_trigger", {"name": "T12",
		"destination": "claude", "initial_message": "T12 marker", "interval_seconds": 3600})
	var listed: Dictionary = _listed(await tools.handle("minerva_list_triggers", {}), str(created.get("trigger_id", "")))
	var batched: Dictionary = await tools.handle("minerva_create_trigger", {"name": "T12 batch",
		"destination": "claude", "initial_message": "x", "batch_params": ["a"]})
	var neither: Dictionary = await tools.handle("minerva_create_trigger", {"name": "T12 none", "initial_message": "x"})
	var to_shell: Dictionary = await tools.handle("minerva_create_trigger", {"name": "T12 shell",
		"destination": "Scratch", "initial_message": "x"})
	check("T12: create resolves the destination and list reports it",
		created.get("success", false) and listed.get("destination", {}).get("label") == "claude@Claude Session"
			and listed.get("destination", {}).get("kind") == "chat" and listed.get("destination", {}).get("bound") == true
			and listed.get("destination", {}).get("available") == true,
		str([created, listed]))
	check("T12: batching, no target at all, and a shell target are refused",
		not batched.get("success", true) and not neither.get("success", true) and not to_shell.get("success", true),
		str([batched, neither, to_shell]))
	var created_id: String = str(created.get("trigger_id", ""))
	var moved: Dictionary = await tools.handle("minerva_update_trigger", {"trigger_id": created_id,
		"destination": "codex@Codex Bare"})
	var moved_listing: Dictionary = _listed(await tools.handle("minerva_list_triggers", {}), created_id)
	var calls_at_fire: int = module.relay_calls.size()
	var fired: Dictionary = await tools.handle("minerva_fire_trigger", {"trigger_id": created_id})
	var fire_receipt: Dictionary = await _await_receipt(_so.trigger_manager, created_id, ["handed_to_harness", "failed"])
	check("T12: update moves the destination, and fire reports whether a delivery started and its receipt",
		moved.get("success", false) and moved_listing.get("destination", {}).get("label") == "codex@Codex Bare"
			and moved_listing.get("destination", {}).get("kind") == "terminal"
			and fired.get("success", false) and fired.get("started") == true and fired.has("delivery")
			and fire_receipt.get("status") == "handed_to_harness" and module.relay_calls.size() == calls_at_fire + 1
			and _sent_containing(module, "T12 marker") == 1,
		str([moved, moved_listing, fired, fire_receipt]))
	var orphaned: Dictionary = await tools.handle("minerva_update_trigger", {"trigger_id": created_id, "destination": ""})
	var to_agent: Dictionary = await tools.handle("minerva_update_trigger", {"trigger_id": created_id,
		"destination": "", "agent_id": agent.id})
	check("T12: clearing the destination needs an agent, and then targets it",
		not orphaned.get("success", true) and to_agent.get("success", false)
			and not _listed(await tools.handle("minerva_list_triggers", {}), created_id).has("destination"),
		str([orphaned, to_agent]))
	var silent: Dictionary = await tools.handle("minerva_create_trigger", {"name": "T12 silent", "destination": "claude"})
	var hook: Dictionary = await tools.handle("minerva_create_trigger", {"name": "T12 hook", "destination": "claude",
		"trigger_type": TriggerDefinition.TriggerType.EVENT, "event_type": TriggerDefinition.EventType.MCP_TOOL_ABOUT_TO_EXECUTE})
	check("T12: a destination needs a message unless the source writes one (an about-to-execute hook)",
		not silent.get("success", true) and hook.get("success", false), str([silent, hook]))
	for trigger_id in [created_id, str(hook.get("trigger_id", ""))]:
		await tools.handle("minerva_delete_trigger", {"trigger_id": trigger_id})

	# T21 — an MCP update that awaited a destination lookup applies only to the
	# trigger as it read it: a disable or a delete meanwhile wins.
	var profiles_gate := [false]
	module.watch_profile_source = func(_ids: PackedStringArray) -> Dictionary:
		while profiles_gate[0]:
			await process_frame
		return {"101": "claude", "202": "codex"}
	var contested: Dictionary = await tools.handle("minerva_create_trigger", {"name": "T21", "enabled": true,
		"destination": "codex@Codex Bare", "initial_message": "T21 marker", "interval_seconds": 3600})
	var contested_id: String = str(contested.get("trigger_id", ""))
	for meanwhile in ["disable", "reload", "delete"]:
		_so.trigger_manager.set_trigger_enabled(contested_id, true)
		profiles_gate[0] = true
		var box := [null]
		(func() -> void: box[0] = await tools.handle("minerva_update_trigger",
			{"trigger_id": contested_id, "destination": "claude"})).call()
		for _i in range(3):
			await process_frame
		if meanwhile == "disable":
			_so.trigger_manager.set_trigger_enabled(contested_id, false)
		elif meanwhile == "reload":
			# The project is loaded again: the same ids, fresh objects.
			_so.trigger_manager.deserialize(_so.trigger_manager.serialize())
		else:
			_so.trigger_manager.remove_trigger(contested_id)
		profiles_gate[0] = false
		await _until_set(box)
		var now_trig: TriggerDefinition = _so.trigger_manager.get_trigger(contested_id)
		check("T21: an update that meets a %s during its lookup is refused, and the %s stands" % [meanwhile, meanwhile],
			box[0] != null and not box[0].get("success", true)
				and (now_trig == null if meanwhile == "delete"
					else (now_trig.enabled == (meanwhile == "reload") and now_trig.destination.label == "codex@Codex Bare")),
			str(box[0]))

	# T13 — a person typing holds it on both paths; it lands once they stop.
	var now_ms := func() -> int: return int(Time.get_unix_time_from_system() * 1000.0)
	for case: Array in [["codex@Codex Bare", "505", "handed_to_harness"], ["claude", "101", "handed_to_harness"]]:
		var entry: Dictionary = module.terminals.filter(func(t: Dictionary) -> bool: return t.id == case[1])[0]
		entry["last_input_ms"] = now_ms.call() - 3000
		var typed := await _harness_trigger(tm, "typed " + case[1], case[0], "T13 after typing")
		var calls_before_typing: int = module.relay_calls.size()
		tm._fire_trigger(typed.id)
		var first: Dictionary = await _await_receipt(tm, typed.id, ["held", "failed", case[2]])
		var landed: Dictionary = await _await_receipt(tm, typed.id, [case[2], "failed"], 4.0 * tm.harness_delivery.RETRY_S)
		entry.erase("last_input_ms")
		check("T13: typing in %s holds the delivery, which lands once when it stops" % case[0],
			first.get("status") == "held" and first.get("hold_reason") == "human_typing" and landed.get("status") == case[2]
				and (case[1] != "505" or module.relay_calls.size() == calls_before_typing + 1),
			str([first, landed]))
		if case[1] == "101":
			provider.release("Claude Session", "[MINERVA NOTIFY from trigger typed 101] T13 after typing")
			for _i in range(4):
				await process_frame

	# T14 — editing a trigger withdraws its queued delivery; a closed chat is unresolved.
	pane.current_tab = _so.ChatList.find(claude_chat)
	pane.execute_regular_chat("T14 mid-turn")
	await process_frame
	var edited := await _harness_trigger(tm, "edited", "claude", "T14 marker")
	tm._fire_trigger(edited.id)
	await _await_receipt(tm, edited.id, ["queued", "failed"])
	var replacement := TriggerDefinition.deserialize(edited.serialize())
	replacement.initial_message = "T14 edited"
	tm.update_trigger(edited.id, replacement)
	check("T14: an edit withdraws the queued envelope",
		tm.harness_delivery.receipt(edited.id).get("status") == "withdrawn"
			and pane._outgoing_queue.pending_texts(claude_chat.HistoryId).is_empty(),
		str(tm.harness_delivery.receipt(edited.id)))
	provider.release("Claude Session", "T14 mid-turn")
	for _i in range(6):
		await process_frame
	var claude_at: int = _so.ChatList.find(claude_chat)
	_so.ChatList.erase(claude_chat)
	var fired_closed: bool = tm._fire_trigger(edited.id)
	_so.ChatList.insert(claude_at, claude_chat)
	check("T14: a destination whose chat is closed is unresolved, and nothing is spawned",
		not fired_closed and "is not open" in str(tm.harness_delivery.receipt(edited.id).get("reason"))
			and _so.ChatList.size() == chats_before, str(tm.harness_delivery.receipt(edited.id)))

	# T15 — a terminal now running another harness is not delivered to.
	var swapped := await _harness_trigger(tm, "swapped", "codex@Codex Bare", "T15 marker")
	var bare_entry: Dictionary = module.terminals.filter(func(t: Dictionary) -> bool: return t.id == "505")[0]
	bare_entry["harness"] = "claude"
	var calls_at_swap: int = module.relay_calls.size()
	tm._fire_trigger(swapped.id)
	var r15: Dictionary = await _await_receipt(tm, swapped.id, ["failed", "handed_to_harness"])
	bare_entry["harness"] = "codex"
	check("T15: a terminal whose harness changed is refused, naming both",
		r15.get("status") == "failed" and "now runs claude, not codex" in str(r15.get("reason"))
			and module.relay_calls.size() == calls_at_swap, str(r15))

	# T16 — the plugin-event limit counts deliveries started, not fires folded in.
	check("T16/T17: the plugin event broker and docket manager exist",
		_so.plugin_event_broker != null and _so.docket_manager != null)
	if _so.plugin_event_broker == null or _so.docket_manager == null:
		TriggerDestination.address_tools = null
		_so.trigger_manager.harness_delivery.tools = app_delivery_tools
		_so.agent_registry.remove_agent(agent.id)
		tm.queue_free()
		_teardown(pane, chats)
		return
	var limited := await _harness_trigger(tm, "limited", "codex@Codex Bare", "T16 {event_name}",
		TriggerDefinition.TriggerType.PLUGIN_EVENT, {"plugin_id": "t16plugin", "consecutive_fire_limit": 2})
	module.relay_reply = HELD_REPLY
	for n in 3:
		_so.plugin_event_broker.plugin_event.emit("t16plugin", "e%d" % n, {})
	await _await_receipt(tm, limited.id, ["held", "failed"])
	check("T16: while one delivery is held, further events are folded in and not counted",
		int(tm._plugin_event_consecutive_counts.get(limited.id, 0)) == 1 and not tm._plugin_event_paused.has(limited.id),
		str(tm._plugin_event_consecutive_counts))
	module.relay_reply = OK_REPLY
	await _await_receipt(tm, limited.id, ["handed_to_harness", "failed"], 3.0 * tm.harness_delivery.RETRY_S)
	_so.plugin_event_broker.plugin_event.emit("t16plugin", "e3", {})
	await _await_receipt(tm, limited.id, ["handed_to_harness", "failed"])
	var calls_at_limit: int = module.relay_calls.size()
	_so.plugin_event_broker.plugin_event.emit("t16plugin", "e4", {})
	await process_frame
	check("T16: after two deliveries it pauses and sends nothing",
		tm._plugin_event_paused.has(limited.id) and module.relay_calls.size() == calls_at_limit)
	tm.set_trigger_enabled(limited.id, false)
	tm.set_trigger_enabled(limited.id, true)
	_so.plugin_event_broker.plugin_event.emit("t16plugin", "e5", {})
	await _await_receipt(tm, limited.id, ["handed_to_harness", "failed"])
	check("T16: re-enabling resumes it", module.relay_calls.size() == calls_at_limit + 1
		and _sent_containing(module, "T16 e5") == 1, str(module.relay_calls.size()))

	# T17 — two triggers on one event source each keep their own handler:
	# edits, disable and re-enable of one leave one handler each, and deleting
	# one leaves the other connected and delivering.
	var sources_watched: Array[Signal] = [_so.note_changed, _so.docket_manager.item_created]
	var baseline: Array = sources_watched.map(func(sig: Signal) -> int: return _handlers_for(tm, sig))
	var handlers_are := func(extra: int) -> bool:
		for i in sources_watched.size():
			if _handlers_for(tm, sources_watched[i]) != baseline[i] + extra:
				return false
		return true
	var once_note := await _harness_trigger(tm, "once note", "codex@Codex Bare", "T17 note", TriggerDefinition.TriggerType.EVENT,
		{"event_type": TriggerDefinition.EventType.NOTE_CHANGED})
	var twin_note := await _harness_trigger(tm, "twin note", "codex@Codex Bare", "T17 twin", TriggerDefinition.TriggerType.EVENT,
		{"event_type": TriggerDefinition.EventType.NOTE_CHANGED})
	var once_docket := await _harness_trigger(tm, "once docket", "codex@Codex Bare", "", TriggerDefinition.TriggerType.DOCKET_POLL,
		{"docket_project": "t17project"})
	var twin_docket := await _harness_trigger(tm, "twin docket", "codex@Codex Bare", "", TriggerDefinition.TriggerType.DOCKET_POLL,
		{"docket_project": "t17project"})
	check("T17: a second trigger on the same source gets its own handler", handlers_are.call(2))
	for trig: TriggerDefinition in [once_note, once_docket]:
		tm.update_trigger(trig.id, TriggerDefinition.deserialize(trig.serialize()))
		tm.update_trigger(trig.id, TriggerDefinition.deserialize(trig.serialize()))
		tm.set_trigger_enabled(trig.id, false)
	check("T17: disabling one leaves only the other's handler", handlers_are.call(1))
	for trig: TriggerDefinition in [once_note, once_docket]:
		tm.set_trigger_enabled(trig.id, true)
	check("T17: after two edits and a re-enable each trigger has exactly one handler", handlers_are.call(2))
	_so.note_changed.emit(null)
	_so.docket_manager.item_created.emit("t17item", "bug", "t17project")
	for trig: TriggerDefinition in [once_note, twin_note, once_docket, twin_docket]:
		await _await_receipt(tm, trig.id, ["handed_to_harness", "failed"])
	check("T17: each trigger delivers each event exactly once",
		_sent_containing(module, "T17 note") == 1 and _sent_containing(module, "T17 twin") == 1
			and _sent_containing(module, "t17item") == 2, str(module.relay_calls))
	tm.remove_trigger(once_note.id)
	tm.remove_trigger(once_docket.id)
	_so.note_changed.emit(null)
	_so.docket_manager.item_created.emit("t17gone", "bug", "t17project")
	for trig: TriggerDefinition in [twin_note, twin_docket]:
		await _await_receipt(tm, trig.id, ["handed_to_harness", "failed"])
	check("T17: deleting one removes only its handler; the other still delivers",
		handlers_are.call(1) and _sent_containing(module, "T17 note") == 1
			and _sent_containing(module, "T17 twin") == 2 and _sent_containing(module, "t17gone") == 1, str(module.relay_calls))
	tm.remove_trigger(twin_note.id)
	tm.remove_trigger(twin_docket.id)

	# T18 — the editor keeps what it does not show, and saving enabled approves.
	var app_tm = _so.trigger_manager
	var edited_trig := TriggerDefinition.new()
	edited_trig.name = "T18 plugin"
	edited_trig.agent_id = agent.id
	edited_trig.trigger_type = TriggerDefinition.TriggerType.PLUGIN_EVENT
	edited_trig.plugin_id = "t18plugin"
	edited_trig.plugin_event_name = "done"
	edited_trig.consecutive_fire_limit = 7
	edited_trig.pending_approval = true
	edited_trig.initial_message = "T18 marker"
	app_tm.add_trigger(edited_trig)
	# By path: naming the window's class would compile it, and what it uses,
	# before the SingletonObject autoload exists.
	var window_script: GDScript = load(AGENT_WINDOW_PATH)
	var window = window_script.new(window_script.ManagerMode.TRIGGERS)
	root.add_child(window)
	await process_frame
	window._on_trigger_selected(app_tm.triggers.find(edited_trig))
	for i in window.trigger_destination_option.item_count:
		if window.trigger_destination_option.get_item_metadata(i) == "101":
			window.trigger_destination_option.select(i)
	await window._on_trigger_save()
	var kept: TriggerDefinition = app_tm.get_trigger(edited_trig.id)
	check("T18: choosing a session keeps the plugin event, its limit and pending approval",
		kept != null and kept.trigger_type == TriggerDefinition.TriggerType.PLUGIN_EVENT
			and kept.plugin_id == "t18plugin" and kept.plugin_event_name == "done" and kept.consecutive_fire_limit == 7
			and kept.pending_approval and kept.destination != null and kept.destination.label == "claude@Claude Session",
		str(kept.serialize() if kept != null else null))
	window._on_trigger_selected(app_tm.triggers.find(kept))
	window.trigger_enabled_check.button_pressed = true
	await window._on_trigger_save()
	var approved: TriggerDefinition = app_tm.get_trigger(edited_trig.id)
	check("T18: saving it enabled approves it and keeps its destination",
		approved != null and approved.enabled and not approved.pending_approval and approved.plugin_id == "t18plugin"
			and approved.destination != null and approved.destination.chat_id == str(claude_chat.HistoryId),
		str(approved.serialize() if approved != null else null))
	var claude_entry: Dictionary = module.terminals.filter(func(t: Dictionary) -> bool: return t.id == "101")[0]
	claude_entry["alive"] = false
	window._on_trigger_selected(app_tm.triggers.find(approved))
	var current_text: String = window.trigger_destination_option.get_item_text(window.trigger_destination_option.selected)
	claude_entry["alive"] = true
	check("T18: the editor marks a destination whose terminal has exited as unavailable",
		"unavailable" in current_text and "exited" in current_text, current_text)
	# A save whose destination lookup meets a disable is refused.
	window._on_trigger_selected(app_tm.triggers.find(approved))
	for i in window.trigger_destination_option.item_count:
		if window.trigger_destination_option.get_item_metadata(i) == "202":
			window.trigger_destination_option.select(i)
	profiles_gate[0] = true
	var saved_box := [null]
	(func() -> void:
		await window._on_trigger_save()
		saved_box[0] = true).call()
	for _i in range(3):
		await process_frame
	app_tm.set_trigger_enabled(edited_trig.id, false)
	profiles_gate[0] = false
	await _until_set(saved_box)
	var after_race: TriggerDefinition = app_tm.get_trigger(edited_trig.id)
	check("T18: an editor save that meets a disable during its lookup changes nothing",
		after_race != null and not after_race.enabled and after_race.destination.chat_id == str(claude_chat.HistoryId),
		str(after_race.serialize() if after_race != null else null))
	# Reopening a saved trigger selects its type and shows that type's fields;
	# a type the picker does not list is left unselected, and still saved.
	var shown := {}
	for type: int in [TriggerDefinition.TriggerType.TIMER, TriggerDefinition.TriggerType.EVENT, TriggerDefinition.TriggerType.TIME]:
		var saved_type := TriggerDefinition.new()
		saved_type.name = "T18 type %d" % type
		saved_type.trigger_type = type
		saved_type.schedule_type = TriggerDefinition.ScheduleType.INTERVAL if type != TriggerDefinition.TriggerType.TIME \
			else TriggerDefinition.ScheduleType.DAILY
		app_tm.add_trigger(saved_type)
		window._on_trigger_selected(app_tm.triggers.find(saved_type))
		shown[type] = [window.trigger_type_option.get_selected_id(), window.trigger_interval_spin.visible,
			window.trigger_event_option.visible, window.trigger_schedule_type_option.visible]
		app_tm.remove_trigger(saved_type.id)
	check("T18: a saved Timer, Event and Time reopen as themselves with their own fields",
		shown[TriggerDefinition.TriggerType.TIMER] == [TriggerDefinition.TriggerType.TIMER, true, false, false]
			and shown[TriggerDefinition.TriggerType.EVENT] == [TriggerDefinition.TriggerType.EVENT, false, true, false]
			and shown[TriggerDefinition.TriggerType.TIME] == [TriggerDefinition.TriggerType.TIME, false, false, true], str(shown))
	window._on_trigger_selected(app_tm.triggers.find(after_race))
	var plugin_shown: Array = [window.trigger_type_option.selected, window.trigger_interval_spin.visible,
		window.trigger_event_option.visible, window.trigger_schedule_type_option.visible]
	window.trigger_name_edit.text = "T18 plugin renamed"
	await window._on_trigger_save()
	var resaved: TriggerDefinition = app_tm.get_trigger(edited_trig.id)
	check("T18: a plugin event opened after a Time shows no other type's fields and is saved still a plugin event",
		plugin_shown == [-1, false, false, false] and resaved != null and resaved.name == "T18 plugin renamed"
			and resaved.trigger_type == TriggerDefinition.TriggerType.PLUGIN_EVENT and resaved.plugin_id == "t18plugin",
		str(plugin_shown) + " " + str(resaved.serialize() if resaved != null else null))
	window._on_trigger_new()
	check("T18: a new trigger starts as a Timer with the Timer's fields",
		[window.trigger_type_option.get_selected_id(), window.trigger_interval_spin.visible, window.trigger_event_option.visible]
			== [TriggerDefinition.TriggerType.TIMER, true, false])
	app_tm.remove_trigger(edited_trig.id)
	window.queue_free()
	_so.trigger_manager.harness_delivery.tools = app_delivery_tools

	# T19 — the session is checked where the write happens, after every wait.
	var retargeted := await _harness_trigger(tm, "retargeted", "codex@Codex Bare", "T19 foreground")
	var calls_at_19: int = module.relay_calls.size()
	profiles_gate[0] = true
	tm._fire_trigger(retargeted.id)
	for _i in range(3):
		await process_frame
	var bare_now: Dictionary = module.terminals.filter(func(t: Dictionary) -> bool: return t.id == "505")[0]
	# The scripted listing hands out these same dictionaries, so the change is
	# what the next look sees (a live session would be read afresh instead).
	bare_now["harness"] = "claude"
	profiles_gate[0] = false
	var r19a: Dictionary = await _await_receipt(tm, retargeted.id, ["failed", "handed_to_harness"])
	bare_now["harness"] = "codex"
	check("T19: a harness that changes while the send waits is refused at the write, nothing sent",
		r19a.get("status") == "failed" and "now runs claude, not codex" in str(r19a.get("reason"))
			and module.relay_calls.size() == calls_at_19, str(r19a))
	var rebound := await _harness_trigger(tm, "rebound", "claude", "T19 rebound")
	profiles_gate[0] = true
	tm._fire_trigger(rebound.id)
	for _i in range(3):
		await process_frame
	claude_chat.provider.entry_id = "terminal-707"
	codex_chat.provider.entry_id = "terminal-101"
	profiles_gate[0] = false
	var r19b: Dictionary = await _await_receipt(tm, rebound.id, ["failed", "handed_to_harness", "queued"])
	claude_chat.provider.entry_id = "terminal-101"
	codex_chat.provider.entry_id = "terminal-202"
	check("T19: a chat rebound while the send waits is refused; the chat now on that terminal gets nothing",
		r19b.get("status") == "failed" and "no longer the terminal of the chat" in str(r19b.get("reason"))
			and not str(provider.texts_for("Codex Session")).contains("T19 rebound"), str(r19b))
	bare_now["foreground_pid"] = 6060
	var replaced := await _harness_trigger(tm, "replaced", "codex@Codex Bare", "T19 replaced")
	replaced.destination.process = 5050
	var r19c_available: Dictionary = replaced.destination.availability(module.list_terminals())
	tm._fire_trigger(replaced.id)
	var r19c: Dictionary = await _await_receipt(tm, replaced.id, ["failed", "handed_to_harness"])
	bare_now["foreground_pid"] = 5050
	check("T19: a codex started again in the same terminal is another session: unavailable, refused, nothing sent",
		not r19c_available.ok and "was replaced" in str(r19c_available.reason)
			and r19c.get("status") == "failed" and "was replaced" in str(r19c.get("reason"))
			and module.relay_calls.size() == calls_at_19, str([r19c_available, r19c]))
	var gone_available: Dictionary = {}
	module.terminals = module.terminals.filter(func(t: Dictionary) -> bool: return t.id != "505")
	gone_available = retargeted.destination.availability(module.list_terminals())
	module.terminals.append(bare_now)
	check("T19: a terminal that is gone is reported unavailable, not resolved",
		not gone_available.ok and "is gone" in str(gone_available.reason), str(gone_available))

	# T20 — a cancelled attempt that finishes late never overwrites the newer
	# attempt's receipt, even after that one has finished.
	var plain_relay: Callable = module.relay_send_source
	var relay_gate := [true]
	# The first send ends in a failure, so an overwrite would show as one.
	module.relay_send_source = func(args: Dictionary) -> Dictionary:
		module.relay_calls.append(args)
		if str(args.get("text", "")).contains("T20 first"):
			while relay_gate[0]:
				await process_frame
			return {"error": "T20 first failed late"}
		return module.relay_reply
	var generations := await _harness_trigger(tm, "generations", "codex@Codex Bare", "T20 first")
	tm._fire_trigger(generations.id)
	for _i in range(3):
		await process_frame
	var second_edit := TriggerDefinition.deserialize(generations.serialize())
	second_edit.initial_message = "T20 second"
	tm.update_trigger(generations.id, second_edit)
	tm._fire_trigger(generations.id)
	var r20b: Dictionary = await _await_receipt(tm, generations.id, ["handed_to_harness", "failed"])
	relay_gate[0] = false
	for _i in range(6):
		await process_frame
	var r20: Dictionary = tm.harness_delivery.receipt(generations.id)
	module.relay_send_source = plain_relay
	check("T20: the finished newer receipt keeps its status, line and target after the old send returns",
		r20b.get("status") == "handed_to_harness" and r20.get("status") == "handed_to_harness" and r20.get("line") == "T20 second"
			and str(r20.get("target", {}).get("terminal_id")) == "505" and r20.get("at") == r20b.get("at"),
		str([r20b, r20]))
	# The same when the newer fire fails at once (its destination unresolved).
	relay_gate[0] = true
	module.relay_send_source = func(args: Dictionary) -> Dictionary:
		if str(args.get("text", "")).contains("T20 third"):
			while relay_gate[0]:
				await process_frame
		module.relay_calls.append(args)
		return module.relay_reply
	var third := await _harness_trigger(tm, "third", "codex@Codex Bare", "T20 third")
	tm._fire_trigger(third.id)
	for _i in range(3):
		await process_frame
	tm.set_trigger_enabled(third.id, false)
	tm.set_trigger_enabled(third.id, true)
	third.destination.run_id = "an-earlier-run"
	var unresolved_fire: bool = tm._fire_trigger(third.id)
	relay_gate[0] = false
	for _i in range(6):
		await process_frame
	module.relay_send_source = plain_relay
	var r20c: Dictionary = tm.harness_delivery.receipt(third.id)
	check("T20: a newer fire that failed at once keeps its own receipt, with nothing from the old send",
		not unresolved_fire and r20c.get("status") == "failed" and "earlier Minerva run" in str(r20c.get("reason"))
			and not r20c.has("target") and not r20c.has("line"), str(r20c))

	# T22 — a scheduled time whose destination is unavailable is retried at the
	# next minute check and delivered once when it can be.
	var daily := await _harness_trigger(tm, "daily", "claude", "T22 daily", TriggerDefinition.TriggerType.TIME,
		{"schedule_type": TriggerDefinition.ScheduleType.DAILY, "schedule_time": "00:00"})
	var claude_index: int = _so.ChatList.find(claude_chat)
	_so.ChatList.erase(claude_chat)
	tm._on_schedule_check()
	var missed_fire: String = daily.last_fired_at
	_so.ChatList.insert(claude_index, claude_chat)
	tm._on_schedule_check()
	var r22: Dictionary = await _await_receipt(tm, daily.id, ["handed_to_harness", "failed"])
	tm._on_schedule_check()
	for _i in range(4):
		await process_frame
	var daily_envelope := "[MINERVA NOTIFY from trigger daily] T22 daily"
	check("T22: unavailable, the occurrence stays unfired; available, it is delivered once and recorded",
		missed_fire.is_empty() and r22.get("status") == "handed_to_harness" and not daily.last_fired_at.is_empty()
			and provider.texts_for("Claude Session").count(daily_envelope) == 1,
		str([missed_fire, r22, daily.last_fired_at]))
	provider.release("Claude Session", daily_envelope)
	for _i in range(4):
		await process_frame

	# T23 — a delivery held past its limit is given up before its next look,
	# even when the hold clears in between: nothing is written late.
	tm.harness_delivery.hold_limit_s = 0.5
	module.relay_reply = HELD_REPLY
	var patient := await _harness_trigger(tm, "patient", "codex@Codex Bare", "T23 marker")
	tm._fire_trigger(patient.id)
	await _await_receipt(tm, patient.id, ["held", "failed"])
	module.relay_reply = OK_REPLY
	var calls_at_clear_23: int = module.relay_calls.size()
	var r23: Dictionary = await _await_receipt(tm, patient.id, ["failed", "handed_to_harness"], 3.0 * tm.harness_delivery.RETRY_S)
	tm.harness_delivery.hold_limit_s = tm.harness_delivery.HOLD_LIMIT_S
	check("T23: a hold that clears after the limit sends nothing; the delivery fails, saying so",
		r23.get("status") == "failed" and "held for over" in str(r23.get("reason"))
			and module.relay_calls.size() == calls_at_clear_23, str(r23))

	# T24 — the host decides the session guards at the relay's own write. The
	# scripted relay does what the relay plugin does: it forwards the guards
	# to host.terminal.write, here the real TerminalInputArbiter.check_guards
	# over a session whose foreground the test controls.
	var session_node: Node = _make_script(FAKE_SESSION_SRC).new()
	root.add_child(session_node)
	var arbiter = load(ARBITER_PATH).new()
	arbiter.setup(session_node)
	var host_writes: Array = []
	var in_relay := [true]
	var plain_relay_24: Callable = module.relay_send_source
	module.relay_send_source = func(args: Dictionary) -> Dictionary:
		module.relay_calls.append(args)
		while in_relay[0]:
			await process_frame
		var verdict: Dictionary = arbiter.check_guards({"expect_harness": args.get("expect_harness", ""),
			"expect_process": args.get("expect_process", 0), "write_ticket": args.get("write_ticket", "")})
		if not verdict.get("success", false):
			# The relay also marks as held any refusal carrying its hold phrase.
			verdict["held"] = bool(verdict.get("held", false)) or str(verdict.get("error", "")).contains("nothing was written")
			return verdict
		host_writes.append(str(args.get("text", "")))
		return OK_REPLY
	var bare_24: Dictionary = module.terminals.filter(func(t: Dictionary) -> bool: return t.id == "505")[0]
	# A codex restarted while the relay's round trip is in flight.
	var restarted := await _harness_trigger(tm, "restarted", "codex@Codex Bare", "T24 restarted")
	tm._fire_trigger(restarted.id)
	for _i in range(3):
		await process_frame
	session_node.pid = 6060
	bare_24["foreground_pid"] = 6060
	in_relay[0] = false
	var r24_host: Dictionary = await _await_receipt(tm, restarted.id, ["held", "failed", "handed_to_harness"])
	var r24a: Dictionary = await _await_receipt(tm, restarted.id, ["failed", "handed_to_harness"], 3.0 * tm.harness_delivery.RETRY_S)
	session_node.pid = 5050
	bare_24["foreground_pid"] = 5050
	check("T24: a harness restarted during the relay's round trip is refused by the host at the write (held on the process guard)",
		host_writes.is_empty() and r24_host.get("status") == "held" and r24_host.get("hold_reason") == "expect_process",
		str(r24_host))
	check("T24: the next look finds the session replaced and fails the delivery, nothing written",
		host_writes.is_empty() and r24a.get("status") == "failed" and "was replaced" in str(r24a.get("reason")), str(r24a))
	# A trigger disabled while the relay's round trip is in flight.
	in_relay[0] = true
	var withdrawn := await _harness_trigger(tm, "withdrawn", "codex@Codex Bare", "T24 withdrawn")
	tm._fire_trigger(withdrawn.id)
	for _i in range(3):
		await process_frame
	tm.set_trigger_enabled(withdrawn.id, false)
	in_relay[0] = false
	for _i in range(6):
		await process_frame
	check("T24: a delivery withdrawn during the relay's round trip is refused by the host; the receipt stays cancelled",
		host_writes.is_empty() and tm.harness_delivery.receipt(withdrawn.id).get("status") == "cancelled",
		str(tm.harness_delivery.receipt(withdrawn.id)))
	tm.set_trigger_enabled(withdrawn.id, true)
	tm._fire_trigger(withdrawn.id)
	var r24b: Dictionary = await _await_receipt(tm, withdrawn.id, ["handed_to_harness", "failed"])
	check("T24: the next delivery goes through, with its own receipt",
		r24b.get("status") == "handed_to_harness" and host_writes.size() == 1 and host_writes[0].contains("T24 withdrawn"), str(r24b))
	module.relay_send_source = plain_relay_24

	# T27 — a container pane in a mode holds the delivery at the host's write,
	# for as long as it lasts; the verdict reaches the receipt either way. The
	# scripted relay hands notify's typing guard, harness, process and ticket
	# to the real host guard and returns the host's pane_mode_check, as the
	# relay plugin does. No one types here, so only the mode can hold.
	var writes_27: Array = []
	module.relay_send_source = func(args: Dictionary) -> Dictionary:
		module.relay_calls.append(args)
		var verdict: Dictionary = arbiter.check_guards({
			"unless_typed_within_ms": args.get("human_guard_ms", 0),
			"expect_harness": args.get("expect_harness", ""),
			"expect_process": args.get("expect_process", 0), "write_ticket": args.get("write_ticket", "")})
		if not verdict.get("success", false):
			return verdict
		writes_27.append(str(args.get("text", "")))
		var reply: Dictionary = OK_REPLY.duplicate()
		reply["pane_mode_check"] = verdict.get("pane_mode_check", "")
		return reply
	session_node.pane = "unknown"
	var unreported := await _harness_trigger(tm, "unreported", "codex@Codex Bare", "T27 unreported")
	tm._fire_trigger(unreported.id)
	var r27u: Dictionary = await _await_receipt(tm, unreported.id, ["handed_to_harness", "failed", "held"])
	check("T27: a container that does not report its mode is written to, and the receipt says unknown",
		r27u.get("status") == "handed_to_harness" and r27u.get("pane_mode_check") == "unknown" and writes_27.size() == 1,
		str(r27u))
	session_node.pane = "in_mode"
	var dropped_27 := await _harness_trigger(tm, "dropped while held", "codex@Codex Bare", "T27 dropped")
	var kept_27 := await _harness_trigger(tm, "kept while held", "codex@Codex Bare", "T27 kept")
	tm._fire_trigger(dropped_27.id)
	tm._fire_trigger(kept_27.id)
	var r27h: Dictionary = await _await_receipt(tm, kept_27.id, ["held", "handed_to_harness", "failed"])
	await create_timer(2.5 * tm.harness_delivery.RETRY_S).timeout
	var r27still: Dictionary = tm.harness_delivery.receipt(kept_27.id)
	check("T27: in a mode both deliveries are held on it across retries, nothing written",
		r27h.get("status") == "held" and r27h.get("hold_reason") == "pane_mode"
			and r27still.get("status") == "held" and writes_27.size() == 1, "%s / %s" % [str(r27h), str(r27still)])
	tm.set_trigger_enabled(dropped_27.id, false)
	session_node.pane = "live"
	var r27k: Dictionary = await _await_receipt(tm, kept_27.id, ["handed_to_harness", "failed"], 3.0 * tm.harness_delivery.RETRY_S)
	await create_timer(1.5 * tm.harness_delivery.RETRY_S).timeout
	check("T27: leaving the mode delivers the still-active attempt exactly once, its receipt saying live",
		r27k.get("status") == "handed_to_harness" and r27k.get("pane_mode_check") == "live"
			and writes_27.filter(func(t: String) -> bool: return t.contains("T27 kept")).size() == 1, str(r27k))
	check("T27: the attempt cancelled while held writes nothing, even after the mode ends",
		tm.harness_delivery.receipt(dropped_27.id).get("status") == "cancelled"
			and writes_27.filter(func(t: String) -> bool: return t.contains("T27 dropped")).is_empty(),
		str(tm.harness_delivery.receipt(dropped_27.id)))
	for trig: TriggerDefinition in [unreported, dropped_27, kept_27]:
		tm.remove_trigger(trig.id)
	module.relay_send_source = plain_relay_24
	session_node.queue_free()

	# T25 — a delivery disabled while notify is still resolving its target
	# writes and queues nothing, on either path; the next one goes through.
	var calls_at_25: int = module.relay_calls.size()
	var to_bare_25 := await _harness_trigger(tm, "resolving bare", "codex@Codex Bare", "T25 bare")
	var to_chat_25 := await _harness_trigger(tm, "resolving chat", "claude", "T25 chat")
	profiles_gate[0] = true
	tm._fire_trigger(to_bare_25.id)
	tm._fire_trigger(to_chat_25.id)
	for _i in range(3):
		await process_frame
	tm.set_trigger_enabled(to_bare_25.id, false)
	tm.remove_trigger(to_chat_25.id)
	profiles_gate[0] = false
	for _i in range(6):
		await process_frame
	check("T25: nothing was written or queued for deliveries cancelled during their lookup",
		module.relay_calls.size() == calls_at_25 and not str(provider.calls).contains("T25 chat")
			and pane._outgoing_queue.pending_texts(claude_chat.HistoryId).is_empty(),
		str(module.relay_calls.size() - calls_at_25))
	tm.set_trigger_enabled(to_bare_25.id, true)
	tm._fire_trigger(to_bare_25.id)
	var r25: Dictionary = await _await_receipt(tm, to_bare_25.id, ["handed_to_harness", "failed"])
	check("T25: re-enabled, the next delivery is written with its own receipt",
		r25.get("status") == "handed_to_harness" and _sent_containing(module, "T25 bare") == 1, str(r25))

	# T26 — an identity that cannot be established is not assumed.
	var no_pid := {"id": "606", "name": "Codex Unknown", "harness": "codex", "foreground_process": "codex", "alive": true}
	module.terminals.append(no_pid)
	var unidentified: Dictionary = await TriggerDestination.from_address("606")
	module.terminals.erase(no_pid)
	var paused := await _harness_trigger(tm, "unknown now", "codex@Codex Bare", "T26 unknown")
	bare_24.erase("foreground_pid")
	var calls_at_26: int = module.relay_calls.size()
	var unknown_now: Dictionary = paused.destination.availability(module.list_terminals())
	tm._fire_trigger(paused.id)
	var r26: Dictionary = await _await_receipt(tm, paused.id, ["held", "failed", "handed_to_harness"])
	bare_24["foreground_pid"] = 5050
	var r26b: Dictionary = await _await_receipt(tm, paused.id, ["handed_to_harness", "failed"], 3.0 * tm.harness_delivery.RETRY_S)
	check("T26: a terminal whose harness process cannot be read cannot be picked",
		unidentified.has("error") and "cannot be identified" in str(unidentified.error), str(unidentified))
	check("T26: a picked terminal whose process cannot be read now is unavailable and held, then written once readable",
		not unknown_now.ok and r26.get("status") == "held" and r26.get("hold_reason") == "process_unknown"
			and r26b.get("status") == "handed_to_harness" and module.relay_calls.size() == calls_at_26 + 1, str([unknown_now, r26, r26b]))
	# A terminal destination whose terminal has since gained a passthrough chat.
	var chatted := await _harness_trigger(tm, "chatted", "codex@Codex Bare", "T26 chatted")
	codex_chat.provider.entry_id = "terminal-505"
	tm._fire_trigger(chatted.id)
	var r26c: Dictionary = await _await_receipt(tm, chatted.id, ["failed", "handed_to_harness", "queued"])
	codex_chat.provider.entry_id = "terminal-202"
	check("T26: a terminal destination whose terminal now has a chat is refused; that chat gets nothing",
		r26c.get("status") == "failed" and "now has a passthrough chat" in str(r26c.get("reason"))
			and not str(provider.calls).contains("T26 chatted"), str(r26c))

	TriggerDestination.address_tools = null
	_so.agent_registry.remove_agent(agent.id)
	tm.queue_free()
	_teardown(pane, chats)


## A harness trigger to `address`, enabled and added to `tm`. It is a timer
## that would not fire during the test unless `fields` say otherwise.
func _harness_trigger(tm: Node, trig_name: String, address: String, message: String,
		type: int = TriggerDefinition.TriggerType.TIMER, fields: Dictionary = {}) -> TriggerDefinition:
	var trig := TriggerDefinition.new()
	trig.name = trig_name
	trig.trigger_type = type
	trig.interval_seconds = 3600.0
	trig.initial_message = message
	for key in fields:
		trig.set(key, fields[key])
	var made: Dictionary = await TriggerDestination.from_address(address)
	trig.destination = made.get("destination")
	trig.enabled = true
	tm.add_trigger(trig)
	return trig


## `trigger_id`'s receipt once its status is one of `statuses`, or as it
## stands when `seconds` pass.
func _await_receipt(tm: Node, trigger_id: String, statuses: Array, seconds: float = 3.0) -> Dictionary:
	var give_up: int = Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < give_up:
		if str(tm.harness_delivery.receipt(trigger_id).get("status", "")) in statuses:
			break
		await process_frame
	return tm.harness_delivery.receipt(trigger_id)


## How many of `tm`'s handlers are connected to `sig`.
func _handlers_for(tm: Node, sig: Signal) -> int:
	var count: int = 0
	for connection: Dictionary in sig.get_connections():
		var callable: Callable = connection.callable
		if callable.get_object() == tm:
			count += 1
	return count


## Wait, at most 10 s, until box[0] holds a result from a detached coroutine.
func _until_set(box: Array) -> void:
	var give_up: int = Time.get_ticks_msec() + 10000
	while box[0] == null and Time.get_ticks_msec() < give_up:
		await process_frame


## The minerva_list_triggers entry for `trigger_id`, or {}.
func _listed(listing: Dictionary, trigger_id: String) -> Dictionary:
	for entry: Dictionary in listing.get("triggers", []):
		if entry.get("id") == trigger_id:
			return entry
	return {}


func _sent_containing(module: Object, fragment: String) -> int:
	var count: int = 0
	for call_args: Dictionary in module.relay_calls:
		if str(call_args.get("text", "")).contains(fragment):
			count += 1
	return count

#endregion

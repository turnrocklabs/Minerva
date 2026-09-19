extends SceneTree
## Wide headless test of the per-chat outgoing message queue: a message sent to a
## chat whose request is already in flight is queued, shown as a pending bubble,
## and promoted in order when the active request ends.
##
## Run: godot --headless --path src --script test/test_chat_outgoing_queue.gd
##
## WHAT IS REAL HERE
##   real ChatOutgoingQueue, real ChatPane._queue_if_busy / _release_chat_turn /
##   _drain_outgoing_queue / _clear_outgoing_queue / _add_pending_bubble, the real
##   pending-bubble scene, a real VBoxChat as the message container, and real
##   ChatHistory objects registered in the real SingletonObject.ChatList.
##
## WHAT IS FAKED, AND WHY
##   ChatPane's full UI turn path cannot boot headless (same limitation recorded
##   in test_passthrough_e2e.gd), so the harness pane subclasses ChatPane and
##   replaces ONLY the body of execute_regular_chat with the same three-step
##   shape the real one has — gate, turn, single release — driving a fake
##   provider whose generate_content blocks until the test releases it. The
##   decision logic under test is ChatPane's own code, not a copy. Section F
##   asserts by source inspection that the real execute_regular_chat has the gate
##   in that position and that no turn-end path skips the release helper, so this
##   substitution cannot hide a missing wire.
##
## CANCEL RULE UNDER TEST: cancelling the active request DISCARDS that chat's
## pending entries. Stop means stop; a queued message must never fire by itself
## straight after the user pressed the stop button.
##
## THE ZOMBIE (section G): stopping a turn does not stop its coroutine — the
## provider call is still awaited and still returns. Section G starts a NEW
## turn in that window and then lets the stopped turn finish, which without the
## per-turn token releases the live turn and drains the queue underneath it.

const CHATPANE_PATH := "res://Scripts/UI/Views/ChatPane.gd"
const QUEUE_PATH := "res://Scripts/Models/ChatOutgoingQueue.gd"
const BUBBLE_SCENE_PATH := "res://Scenes/pending_message_bubble.tscn"
const CHAT_HISTORY_PATH := "res://Scripts/Models/ChatHistory.gd"
const VBOX_CHAT_PATH := "res://Scripts/UI/Controls/vboxChat.gd"
const CHAT_HISTORY_ITEM_PATH := "res://Scripts/Models/ChatHistoryItem.gd"
const PLUGIN_PROVIDER_PATH := "res://Scripts/Services/Providers/PluginProvider.gd"
const PARALLEL_RUN_PATH := "res://Scripts/Models/ChatParallelRun.gd"
const HUMAN_PROVIDER_PATH := "res://Scripts/Services/Providers/Human/HumanProvider.gd"

## Blocking provider stand-in: generate_content does not return until the test
## releases that message, so "is a second generate running?" is directly
## observable as concurrency, not inferred from timing.
const FAKE_PROVIDER_SRC := """
extends RefCounted
var tree: SceneTree = null
var calls: Array[String] = []
var active: int = 0
var max_concurrent: int = 0
var _released: Dictionary = {}

func release(text: String) -> void:
	_released[text] = true

func generate_content(text: String) -> String:
	calls.append(text)
	active += 1
	max_concurrent = maxi(max_concurrent, active)
	while not _released.get(text, false):
		await tree.process_frame
	active -= 1
	return "reply-" + text
"""

## Harness pane. Keeps ChatPane's real queue helpers and replaces the turn body
## with the fake provider. The UI button refreshers are no-ops because their
## unique-name nodes only exist in the booted scene.
const HARNESS_PANE_SRC := """
extends "res://Scripts/UI/Views/ChatPane.gd"

var provider = null
var events: Array[String] = []
## ChatPane._ready() wires the booted scene's unique-name nodes; skipping it (and
## with it the @onready assignments it carries) is what lets the pane exist
## headless. Nothing the queue path touches is set up there.
func _ready() -> void:
	pass

func _update_stop_button() -> void:
	pass

func _update_compact_button() -> void:
	pass

func execute_regular_chat(text: String, generation_options: Dictionary = {}, _promoted: bool = false) -> void:
	var history: ChatHistory = SingletonObject.ChatList[current_tab]
	if _queue_if_busy(history, text, ChatOutgoingQueue.Mode.REGULAR, generation_options):
		return
	var turn_token: int = _begin_chat_turn(history)
	events.append("start:" + text)
	var answer = await provider.generate_content(text)
	events.append("answer:" + str(answer))
	_release_chat_turn(history, turn_token)

## regenerate_response itself stays REAL — only the two calls it makes into the
## network path are replaced. create_prompt keeps its await, because the window
## a regeneration used to start a second turn in is exactly that await.
var regen_calls: Array[String] = []

func create_prompt(append_item: ChatHistoryItem = null, refresh_detached := true, provider_fallback: BaseProvider = null, predicate: Callable = Callable(), history_override: ChatHistory = null) -> Array[Variant]:
	await get_tree().process_frame
	return []

func generate_content_from_provider(history: ChatHistory, history_list: Array, request_options: Variant = null, provider_override: BaseProvider = null) -> Variant:
	regen_calls.append("regen")
	return null
"""

## Pane that keeps the REAL execute_regular_chat and replaces only its two
## network-facing calls. Everything the promotion path depends on — the queue
## gate, the turn token, the "last item is a user message" guard — is ChatPane's
## own code here, so section K measures the real decision.
const REAL_TURN_PANE_SRC := """
extends "res://Scripts/UI/Views/ChatPane.gd"

## Texts that reached a real request, in order.
var real_generates: PackedStringArray = PackedStringArray()
## The request never resolves, so the turn stays in flight and the test never
## depends on the UI-bound tail of execute_regular_chat.
var blocked := true

func _ready() -> void:
	pass

func _update_stop_button() -> void:
	pass

func _update_compact_button() -> void:
	pass

func create_prompt(append_item: ChatHistoryItem = null, refresh_detached := true, provider_fallback: BaseProvider = null, predicate: Callable = Callable(), history_override: ChatHistory = null) -> Array[Variant]:
	await get_tree().process_frame
	return []

func generate_content_from_provider(history: ChatHistory, history_list: Array, request_options: Variant = null, provider_override: BaseProvider = null) -> Variant:
	var sent: ChatHistoryItem = history.HistoryItemList[history.HistoryItemList.size() - 1]
	real_generates.append(sent.Message)
	while blocked:
		await get_tree().process_frame
	return null
"""

## Pane for the parallel worker path. `create_message_new` — the worker body —
## stays REAL; only the two network-facing calls and the promotion target are
## replaced, so "did this worker issue a provider request" and "did the release
## promote the queued message" are both directly observable headless.
const PARALLEL_WORKER_PANE_SRC := """
extends "res://Scripts/UI/Views/ChatPane.gd"

## One entry per provider request a worker actually issued, and one per text the
## drain promoted out of the queue.
var real_generates: PackedStringArray = PackedStringArray()
var drained: PackedStringArray = PackedStringArray()
## The request never resolves, so a worker that issues one holds its run open.
var blocked := true

func _ready() -> void:
	pass

func _update_stop_button() -> void:
	pass

func _update_compact_button() -> void:
	pass

## The queue gate is ChatPane's own; only the turn body is replaced, because the
## real one needs the booted UI.
func execute_regular_chat(text: String, generation_options: Dictionary = {}, _promoted: bool = false) -> void:
	var history: ChatHistory = SingletonObject.ChatList[current_tab]
	if _queue_if_busy(history, text, ChatOutgoingQueue.Mode.REGULAR, generation_options):
		return
	drained.append(text)

func create_prompt(append_item: ChatHistoryItem = null, refresh_detached := true, provider_fallback: BaseProvider = null, predicate: Callable = Callable(), history_override: ChatHistory = null) -> Array[Variant]:
	await get_tree().process_frame
	return []

func generate_content_from_provider(history: ChatHistory, history_list: Array, request_options: Variant = null, provider_override: BaseProvider = null) -> Variant:
	real_generates.append(history.provider.provider_name)
	while blocked:
		await get_tree().process_frame
	return null

## Which thread the response handler ran on. The handler adds and renders
## message nodes, refreshes controls and drains the queue, so a worker that
## emits response_arrived on its own thread runs all of that off the main one.
var handler_thread_id: int = -1

func _on_thread_bot_response_arrived(chat_hist_item: ChatHistoryItem = null, run: ChatParallelRun = null) -> void:
	handler_thread_id = OS.get_thread_caller_id()
	super(chat_hist_item, run)
"""

var _pass := 0
var _fail := 0
## Autoloads register after this script is compiled, so SingletonObject is
## resolved as a node at runtime rather than by identifier.
var _so: Node = null


func _init() -> void:
	print("=== Per-chat outgoing message queue ===\n")
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


func _make_script(source: String) -> GDScript:
	var script: = GDScript.new()
	script.source_code = source
	script.reload()
	return script


func _make_history(name: String):
	var history = load(CHAT_HISTORY_PATH).new(null)
	history.HistoryName = name
	return history


## A pane whose two chats are registered in ChatList, with live message
## containers so the pending bubbles are really rendered.
func _make_pane(chats: Array, source: String = HARNESS_PANE_SRC) -> Node:
	var pane = _make_script(source).new()
	pane.name = "HarnessChatPane"
	root.add_child(pane)
	for history in chats:
		var scroll: = ScrollContainer.new()
		pane.add_child(scroll)
		var vbox = load(VBOX_CHAT_PATH).new(pane)
		vbox.chat_history = history
		scroll.add_child(vbox)
		history.VBox = vbox
		_so.ChatList.append(history)
	return pane


func _teardown(pane: Node, chats: Array) -> void:
	for history in chats:
		_so.ChatList.erase(history)
	pane.queue_free()


## A parallel run with `count` workers already waiting, shaped the way
## execute_parallel_chat builds one. `tag` makes the run's slider ids readable
## in a failure message, so "which run stamped this item" is directly visible.
func _make_parallel_run(history, turn_token: int, count: int, tag: String):
	var run = load(PARALLEL_RUN_PATH).new()
	var item_script: = load(CHAT_HISTORY_ITEM_PATH)
	run.history = history
	run.turn_token = turn_token
	run.expected = count
	run.user_slider_uuid = tag + "-user"
	run.model_slider_uuid = tag + "-model"
	run.multi_slider_uuid = tag + "-multi"
	for _i in range(count):
		run.user_items.append(item_script.new())
	return run


func _pending_bubbles(history) -> Array:
	var found: Array = []
	for child in history.VBox.get_children():
		if child.get_script() != null and child.has_method("get_message"):
			found.append(child)
	return found


func _run() -> void:
	await process_frame
	_so = root.get_node_or_null("/root/SingletonObject")
	check("S0: the SingletonObject autoload is live", _so != null)
	if _so == null:
		return
	_test_queue_semantics()
	await _test_queue_then_promote_in_order()
	await _test_cancel_discards_pending()
	await _test_worker_completion_injection_queues()
	await _test_pending_bubble_remove()
	_test_wiring_is_present()
	await _test_cancel_then_new_turn_is_not_released_by_the_zombie()
	await _test_a_late_parallel_response_releases_its_own_turn()
	await _test_a_late_parallel_response_releases_its_own_chat()
	await _test_a_cancelled_runs_leftovers_do_not_pair_with_the_new_run()
	await _test_regenerate_waits_for_the_active_turn()
	await _test_a_promoted_message_is_sent_past_the_last_user_guard()
	await _test_a_promoted_sequential_message_is_sent_past_the_guard()
	await _test_a_human_parallel_worker_ends_its_share_of_the_run()
	await _test_a_worker_delivers_its_response_on_the_main_thread()


#region A — queue semantics

func _test_queue_semantics() -> void:
	var queue = load(QUEUE_PATH).new()
	check("A1: an idle chat has nothing pending", not queue.has_pending("chat-1"))

	var first = queue.enqueue("chat-1", "one")
	var second = queue.enqueue("chat-1", "two")
	queue.enqueue("chat-2", "other")
	check("A2: entries are per chat", queue.pending_count("chat-1") == 2
		and queue.pending_count("chat-2") == 1)
	check("A3: order is FIFO",
		str(queue.pending_texts("chat-1")) == str(PackedStringArray(["one", "two"])),
		str(queue.pending_texts("chat-1")))

	check("A4: remove drops exactly one entry", queue.remove(first)
		and queue.pending_count("chat-1") == 1)
	check("A5: removing twice is a no-op", not queue.remove(first))
	check("A6: the survivor is still queued", queue.peek("chat-1") == second)

	var dropped: Array = queue.clear("chat-1")
	check("A7: clear returns the dropped entries and empties the chat",
		dropped.size() == 1 and dropped[0] == second and not queue.has_pending("chat-1"))
	check("A8: clear touches only that chat", queue.pending_count("chat-2") == 1)

	# DEFERRED entries: a background message (a notify envelope) keeps its place
	# in the FIFO, but a drain that excludes deferred entries passes over it and
	# takes the oldest ordinary one instead. That is how the human's answer to a
	# question card starts before a notification that arrived first.
	var deferred_first = queue.enqueue("chat-3", "notify", ChatOutgoingQueue.Mode.REGULAR,
		{}, true)
	var human = queue.enqueue("chat-3", "answer")
	check("A9: a deferred entry is queued like any other",
		str(queue.pending_texts("chat-3")) == str(PackedStringArray(["notify", "answer"])),
		str(queue.pending_texts("chat-3")))
	check("A10: a drain that excludes deferred entries skips to the human's message",
		queue.pop_next("chat-3", false) == human)
	check("A11: the deferred entry is still queued, in its place",
		queue.pending_count("chat-3") == 1 and queue.peek("chat-3") == deferred_first)
	check("A12: with nothing else eligible, an excluding drain takes nothing",
		queue.pop_next("chat-3", false) == null and queue.pending_count("chat-3") == 1)
	check("A13: and an ordinary drain takes it",
		queue.pop_next("chat-3") == deferred_first and not queue.has_pending("chat-3"))

#endregion


#region B — the oracle: queue while busy, promote in order

func _test_queue_then_promote_in_order() -> void:
	var chat = _make_history("Main")
	var pane = _make_pane([chat])
	var provider = _make_script(FAKE_PROVIDER_SRC).new()
	provider.tree = self
	pane.provider = provider
	pane.current_tab = _so.ChatList.find(chat)

	pane.execute_regular_chat("A")
	await process_frame
	check("B1: the first message starts a turn",
		provider.calls.size() == 1 and provider.calls[0] == "A", str(provider.calls))

	pane.execute_regular_chat("B")
	await process_frame
	check("B2: a message sent mid-turn does NOT start a second generate",
		provider.calls.size() == 1, str(provider.calls))
	check("B3: it is queued on that chat",
		str(pane._outgoing_queue.pending_texts(chat.HistoryId))
			== str(PackedStringArray(["B"])))
	check("B4: and shown immediately as a pending bubble",
		_pending_bubbles(chat).size() == 1
			and _pending_bubbles(chat)[0].get_message() == "B")
	check("B5: nothing overlapped", provider.max_concurrent == 1)

	provider.release("A")
	for _i in range(6):
		await process_frame
	check("B6: A's answer renders, then B's generate starts",
		provider.calls.size() == 2 and provider.calls[1] == "B", str(provider.calls))
	check("B7: the pending bubble is replaced by the real turn",
		_pending_bubbles(chat).is_empty())
	check("B8: still exactly one request at a time", provider.max_concurrent == 1)

	provider.release("B")
	for _i in range(6):
		await process_frame
	check("B9: both answers rendered in order",
		str(pane.events) == str(["start:A", "answer:reply-A", "start:B", "answer:reply-B"]),
		str(pane.events))
	check("B10: the chat is idle with an empty queue",
		not chat.is_request_active and not pane._outgoing_queue.has_pending(chat.HistoryId))

	_teardown(pane, [chat])

#endregion


#region C — the cancel rule

func _test_cancel_discards_pending() -> void:
	var chat = _make_history("Cancelled")
	var pane = _make_pane([chat])
	var provider = _make_script(FAKE_PROVIDER_SRC).new()
	provider.tree = self
	pane.provider = provider
	pane.current_tab = _so.ChatList.find(chat)

	pane.execute_regular_chat("A")
	await process_frame
	pane.execute_regular_chat("B")
	await process_frame
	check("C1: B is pending while A runs",
		pane._outgoing_queue.pending_count(chat.HistoryId) == 1)

	# What the stop button does (the handler itself needs the booted scene;
	# section F asserts it calls this helper on cancel).
	pane._cancel_chat_turn(chat)
	await process_frame
	check("C2: cancel DISCARDS the chat's pending messages",
		not pane._outgoing_queue.has_pending(chat.HistoryId))
	check("C3: no cancelled-away message is promoted behind the user's back",
		provider.calls.size() == 1, str(provider.calls))
	check("C4: its pending bubble is gone too", _pending_bubbles(chat).is_empty())

	provider.release("A")
	_teardown(pane, [chat])

#endregion


#region D — worker-completion injection into a busy parent

func _test_worker_completion_injection_queues() -> void:
	var parent_chat = _make_history("Supervisor")
	var other = _make_history("Bystander")
	var pane = _make_pane([other, parent_chat])
	var provider = _make_script(FAKE_PROVIDER_SRC).new()
	provider.tree = self
	pane.provider = provider

	var parent_tab: int = _so.ChatList.find(parent_chat)
	pane.current_tab = parent_tab
	pane.execute_regular_chat("supervisor turn")
	await process_frame

	# The injection idiom used by MCPAgentTools and TriggerManager: switch to the
	# target chat's tab, call execute_regular_chat, switch back.
	pane.current_tab = _so.ChatList.find(other)
	var original_tab: int = pane.current_tab
	pane.current_tab = parent_tab
	pane.execute_regular_chat('[Sub-agent "w1" completed successfully]')
	pane.current_tab = original_tab
	await process_frame

	check("D1: injection into a busy parent chat queues instead of overlapping",
		provider.calls.size() == 1 and provider.max_concurrent == 1, str(provider.calls))
	check("D2: the injected message is pending on the PARENT chat",
		pane._outgoing_queue.pending_count(parent_chat.HistoryId) == 1
			and not pane._outgoing_queue.has_pending(other.HistoryId))

	provider.release("supervisor turn")
	for _i in range(6):
		await process_frame
	check("D3: it runs once the supervisor turn ends, on its own chat",
		provider.calls.size() == 2
			and provider.calls[1].begins_with("[Sub-agent"), str(provider.calls))
	check("D4: the user's tab is restored after the promotion",
		pane.current_tab == original_tab, str(pane.current_tab))

	provider.release(provider.calls[1])
	for _i in range(4):
		await process_frame
	_teardown(pane, [parent_chat, other])

#endregion


#region E — the pending bubble

func _test_pending_bubble_remove() -> void:
	var chat = _make_history("Removable")
	var pane = _make_pane([chat])
	var provider = _make_script(FAKE_PROVIDER_SRC).new()
	provider.tree = self
	pane.provider = provider
	pane.current_tab = _so.ChatList.find(chat)

	pane.execute_regular_chat("A")
	await process_frame
	pane.execute_regular_chat("drop me")
	await process_frame
	var bubbles: = _pending_bubbles(chat)
	check("E1: the queued message has a bubble", bubbles.size() == 1)

	if bubbles.size() == 1:
		var bubble = bubbles[0]
		var remove_button: Button = bubble.get_node("%RemovePending")
		remove_button.pressed.emit()
		await process_frame
		check("E2: removing the bubble drops the entry from the queue",
			not pane._outgoing_queue.has_pending(chat.HistoryId))
		check("E3: the bubble is freed", _pending_bubbles(chat).is_empty())

		provider.release("A")
		for _i in range(6):
			await process_frame
		check("E4: a removed message is never sent",
			provider.calls.size() == 1, str(provider.calls))
	else:
		_fail += 2
		print("  SKIP E2-E4: no bubble")

	provider.release("A")
	_teardown(pane, [chat])

#endregion


#region F — the wiring the harness stands in for

func _test_wiring_is_present() -> void:
	var source: = FileAccess.get_file_as_string(CHATPANE_PATH)
	var body_start: = source.find("func execute_regular_chat(")
	var gate: = source.find("_queue_if_busy(history, text", body_start)
	var activate: = source.find("_begin_chat_turn(history)", body_start)
	check("F2: the real execute_regular_chat gates on the queue before starting a turn",
		body_start != -1 and gate != -1 and activate != -1 and gate < activate,
		"gate=%d activate=%d" % [gate, activate])

	# Every turn end goes through the one release helper, which drains the queue.
	# The only places allowed to clear the flag by hand are that helper itself and
	# _cancel_chat_turn (which must apply the discard rule on the spot).
	var lines: = source.split("\n")
	var stray: = 0
	var release_count: = 0
	for i in range(lines.size()):
		var trimmed: = lines[i].strip_edges()
		if trimmed.begins_with("_release_chat_turn("):
			release_count += 1
		if trimmed != "history.is_request_active = false":
			continue
		# Which function the line sits in: walk back to the nearest `func `.
		var owner: = ""
		for back in range(i, -1, -1):
			if lines[back].begins_with("func "):
				owner = lines[back]
				break
		if not (owner.begins_with("func _release_chat_turn(")
				or owner.begins_with("func _cancel_chat_turn(")):
			stray += 1
	check("F3: every turn end routes through _release_chat_turn", release_count >= 4,
		"found %d" % release_count)
	check("F4: no turn-end path clears the active flag behind the queue's back",
		stray == 0, "found %d" % stray)
	check("F5: cancel applies the discard rule",
		source.find("_clear_outgoing_queue(history)") != -1)
	# The token is what a stopped turn's coroutine fails on; a release that
	# ignored it would be the overlap section G reproduces.
	check("F8: the release helper refuses a token the chat has moved past",
		source.find("if turn_token != history.request_turn_token:") != -1)

	# An early return that left is_request_active set would wedge that chat's
	# queue shut forever, so execute_regular_chat's bail-outs release too.
	var body_end: = source.find("\nfunc ", body_start + 10)
	var body: = source.substr(body_start, body_end - body_start)
	check("F7: execute_regular_chat releases the turn on its early returns too",
		body.count("_release_chat_turn(history, turn_token)") >= 3,
		"found %d" % body.count("_release_chat_turn(history, turn_token)"))

	# The other entry points reach the gate because they call execute_regular_chat.
	for path in ["res://Scripts/Services/MCP/Modules/MCPChatTools.gd",
			"res://Scripts/Services/MCP/Modules/MCPAgentTools.gd",
			"res://Scripts/Services/Agents/TriggerManager.gd"]:
		var text: = FileAccess.get_file_as_string(path)
		check("F6: %s still funnels through execute_regular_chat" % path.get_file(),
			text.find("execute_regular_chat") != -1)

#endregion


#region G — a stopped turn's coroutine must not release the turn that replaced it

## Stop does not stop the coroutine: it is parked on the provider call and will
## return. The user sends again in that window, so by the time the stopped turn
## unwinds, a DIFFERENT turn owns the chat. Without the per-turn token its
## release clears the flag and drains the queue while that turn is still
## running — two live requests on one chat, the state the queue exists to stop.
func _test_cancel_then_new_turn_is_not_released_by_the_zombie() -> void:
	var chat = _make_history("Zombie")
	var pane = _make_pane([chat])
	var provider = _make_script(FAKE_PROVIDER_SRC).new()
	provider.tree = self
	pane.provider = provider
	pane.current_tab = _so.ChatList.find(chat)

	pane.execute_regular_chat("A")
	await process_frame
	pane._cancel_chat_turn(chat)
	await process_frame
	check("G1: after a stop the chat is free for a new turn", not chat.is_request_active)

	pane.execute_regular_chat("B")
	await process_frame
	check("G2: B is the live turn", chat.is_request_active
		and provider.calls.has("B"), str(provider.calls))

	pane.execute_regular_chat("C")
	await process_frame
	check("G3: C is queued behind B",
		pane._outgoing_queue.pending_count(chat.HistoryId) == 1)

	# The stopped turn's coroutine returns NOW and reaches its release.
	provider.release("A")
	for _i in range(6):
		await process_frame
	check("G4: the stopped turn does not end the turn that replaced it",
		chat.is_request_active, str(pane.events))
	# A and B really do overlap here — that is what a stop leaves behind — so
	# the assertion is about C: the queue must not advance on a dead turn.
	check("G5: it does not drain B's queue either",
		pane._outgoing_queue.pending_count(chat.HistoryId) == 1
			and not provider.calls.has("C"),
		"pending=%d calls=%s" % [
			pane._outgoing_queue.pending_count(chat.HistoryId), str(provider.calls)])

	provider.release("B")
	for _i in range(6):
		await process_frame
	check("G6: C runs once B really ends", provider.calls.has("C"), str(provider.calls))
	provider.release("C")
	for _i in range(6):
		await process_frame
	_teardown(pane, [chat])

#endregion


#region H — a parallel run's late response belongs to ITS turn, not the current one

## The parallel path releases its turn from a signal handler, so the token has
## to travel WITH the response: one pane-wide token would be overwritten the
## moment a replacement run starts, and the cancelled run's late response would
## then release the live one — the section G zombie, by another door.
func _test_a_late_parallel_response_releases_its_own_turn() -> void:
	var source: = FileAccess.get_file_as_string(CHATPANE_PATH)
	check("H1: the parallel response handler releases with its own run's token",
		source.find("func _on_thread_bot_response_arrived(chat_hist_item: ChatHistoryItem = null,\n\t\trun: ChatParallelRun = null) -> void:")
			!= -1
		and source.find("_release_chat_turn(history, run.turn_token)") != -1)
	check("H2: each parallel worker binds its own run into the handler",
		source.find("_on_thread_bot_response_arrived.bind(run))") != -1)
	# The guard has to come before the pop, or a dead run still consumes a
	# pending message; positions, because "it returns early" is the whole point.
	check("H2b: the stale-run guard precedes every state touch in the handler",
		source.find("if run.turn_token != history.request_turn_token:")
			< source.find("var user_msg: ChatHistoryItem = run.user_items.pop_front()")
		and source.find("if run.turn_token != history.request_turn_token:") != -1)

	# And the handler really behaves that way. Run A is cancelled, run B starts,
	# then A's response finally arrives carrying A's token.
	var chat = _make_history("LateParallel")
	var pane = _make_pane([chat])
	pane.current_tab = _so.ChatList.find(chat)

	var token_a: int = pane._begin_chat_turn(chat)
	var run_a = _make_parallel_run(chat, token_a, 1, "run-a")
	pane._cancel_chat_turn(chat)
	var token_b: int = pane._begin_chat_turn(chat)
	var run_b = _make_parallel_run(chat, token_b, 1, "run-b")
	check("H3: run B owns the chat", chat.is_request_active)

	# The handler's UI half needs the booted scene, so the cancelled-chat early
	# return is used to stop right after the release decision — the decision is
	# the whole subject here.
	_so.cancelled_history_ids.append(chat.HistoryId)
	var item_script: = load(CHAT_HISTORY_ITEM_PATH)
	pane._on_thread_bot_response_arrived(item_script.new(), run_a)
	await process_frame
	check("H4: run A's late response does not end run B's turn", chat.is_request_active)

	_so.cancelled_history_ids.append(chat.HistoryId)
	pane._on_thread_bot_response_arrived(item_script.new(), run_b)
	await process_frame
	check("H5: run B's own response does end it", not chat.is_request_active)

	_teardown(pane, [chat])


## Two chats, each on its FIRST turn — so both hold token 1. Chat A's parallel
## response arrives late, after the user switched to chat B. Resolving the chat
## from current_tab releases B (token 1 == token 1) and drains B's queue
## underneath its live request, while A stays active for ever.
func _test_a_late_parallel_response_releases_its_own_chat() -> void:
	var chat_a = _make_history("ParallelA")
	var chat_b = _make_history("ParallelB")
	var pane = _make_pane([chat_a, chat_b])

	pane.current_tab = _so.ChatList.find(chat_a)
	var token_a: int = pane._begin_chat_turn(chat_a)
	var token_b: int = pane._begin_chat_turn(chat_b)
	check("H6: both chats are on the same turn number",
		token_a == token_b and chat_a.is_request_active and chat_b.is_request_active,
		"a=%d b=%d" % [token_a, token_b])

	# The user switches to B; A's worker finally emits.
	pane.current_tab = _so.ChatList.find(chat_b)
	var item_script: = load(CHAT_HISTORY_ITEM_PATH)
	_so.cancelled_history_ids.append(chat_a.HistoryId)
	var run_a = _make_parallel_run(chat_a, token_a, 1, "chat-a")
	pane._on_thread_bot_response_arrived(item_script.new(), run_a)
	await process_frame
	check("H7: chat A's late response does not end chat B's turn",
		chat_b.is_request_active)
	check("H8: and it does end chat A's own turn", not chat_a.is_request_active)

	_teardown(pane, [chat_a, chat_b])


## Before the run object, a cancelled run's leftovers and a new run's messages
## shared ONE pane-wide queue of pending user items, so the new run's responses
## were paired with whatever sat at the front of it — the dead run's messages —
## and the run-wide completion count never emptied, so the turn never ended.
##
## Nothing is cleared between the callbacks here: the clearing the other H cases
## do is what hid this, because it left exactly one run's data in place at a time.
func _test_a_cancelled_runs_leftovers_do_not_pair_with_the_new_run() -> void:
	var chat = _make_history("CrossRun")
	var pane = _make_pane([chat])
	pane.current_tab = _so.ChatList.find(chat)
	var item_script: = load(CHAT_HISTORY_ITEM_PATH)

	# Run A: two workers whose user items are still pending when the user stops.
	var token_a: int = pane._begin_chat_turn(chat)
	var run_a = _make_parallel_run(chat, token_a, 2, "run-a")
	pane._cancel_chat_turn(chat)

	# Run B: two workers of its own.
	var token_b: int = pane._begin_chat_turn(chat)
	var run_b = _make_parallel_run(chat, token_b, 2, "run-b")

	# A's late response lands first. It has no claim on anything.
	_so.cancelled_history_ids.append(chat.HistoryId)
	pane._on_thread_bot_response_arrived(item_script.new(), run_a)
	await process_frame
	check("H9: a stopped run's late response touches neither run's bookkeeping",
		run_b.user_items.size() == 2 and run_a.user_items.size() == 2
			and run_a.delivered == 0
			and run_a.user_items[0].SliderContainerId == "",
		"b=%d a=%d delivered=%d stamp=%s" % [run_b.user_items.size(),
			run_a.user_items.size(), run_a.delivered,
			run_a.user_items[0].SliderContainerId])
	check("H10: and the new run still owns the chat", chat.is_request_active)

	# Run B's own two responses, arriving back to back.
	var b1 = run_b.user_items[0]
	var b2 = run_b.user_items[1]
	_so.cancelled_history_ids.append(chat.HistoryId)
	pane._on_thread_bot_response_arrived(item_script.new(), run_b)
	await process_frame
	check("H11: the new run's response is paired with its OWN user message",
		b1.SliderContainerId == "run-b-user"
			and run_a.user_items[0].SliderContainerId == ""
			and run_a.user_items[1].SliderContainerId == "",
		"b1=%s a=[%s, %s]" % [b1.SliderContainerId,
			run_a.user_items[0].SliderContainerId,
			run_a.user_items[1].SliderContainerId])
	check("H11b: and one response of two does not end the run",
		chat.is_request_active)

	_so.cancelled_history_ids.append(chat.HistoryId)
	pane._on_thread_bot_response_arrived(item_script.new(), run_b)
	await process_frame
	check("H12: the new run ends its own turn on its last response",
		b2.SliderContainerId == "run-b-user" and not chat.is_request_active,
		"b2=%s active=%s" % [b2.SliderContainerId, str(chat.is_request_active)])

	_teardown(pane, [chat])

#endregion


#region I — regeneration is admitted like any other turn

## A regeneration used to claim its turn token only AFTER `await create_prompt`,
## with no busy gate at all: an ordinary send starting inside that await had its
## token replaced, so its own release was refused and the regeneration's release
## drained the queue while that request was still running.
##
## The rule under test: a regeneration is not queueable (the queue carries text
## to send, not a history item to redo), so a busy chat refuses it outright.
func _test_regenerate_waits_for_the_active_turn() -> void:
	var chat = _make_history("Regen")
	var pane = _make_pane([chat])
	var provider = _make_script(FAKE_PROVIDER_SRC).new()
	provider.tree = self
	pane.provider = provider
	# regenerate_response reads history.provider (typed BaseProvider) directly,
	# so it has to be a real one; the generate call itself is the pane's, so
	# this provider is never asked to produce anything.
	var history_provider = load(PLUGIN_PROVIDER_PATH).new()
	pane.add_child(history_provider)
	chat.provider = history_provider
	pane.current_tab = _so.ChatList.find(chat)

	var item_script: = load(CHAT_HISTORY_ITEM_PATH)
	var chi = item_script.new()
	# By the loaded script, never by identifier: naming ChatHistoryItem here
	# would compile it while the autoloads are still unregistered.
	chi.Role = item_script.ChatRole.USER
	chi.Message = "regenerate me"
	chat.HistoryItemList.append(chi)
	chi.rendered_node = chat.VBox.add_history_item(chi)

	pane.execute_regular_chat("A")
	await process_frame
	var token_while_busy: int = chat.request_turn_token
	check("I1: the ordinary send is running", provider.calls.size() == 1
		and chat.is_request_active, str(provider.calls))

	pane.regenerate_response(chi)
	for _i in range(6):
		await process_frame
	check("I2: a regeneration during a live turn starts no second generate",
		pane.regen_calls.is_empty() and provider.calls.size() == 1,
		"%s / %s" % [str(pane.regen_calls), str(provider.calls)])
	check("I3: the active turn keeps its token",
		chat.request_turn_token == token_while_busy,
		"%d -> %d" % [token_while_busy, chat.request_turn_token])
	check("I4: and the chat is still busy with it", chat.is_request_active)

	provider.release("A")
	for _i in range(6):
		await process_frame
	check("I5: the ordinary turn ends normally", not chat.is_request_active)

	pane.regenerate_response(chi)
	for _i in range(8):
		await process_frame
	check("I6: regenerating an idle chat runs", pane.regen_calls.size() == 1,
		str(pane.regen_calls))
	check("I7: and releases its own turn", not chat.is_request_active)

	_teardown(pane, [chat])

#endregion


#region K — a promoted message must really be sent

## The drain records an entry as DISPATCHED the moment it leaves the queue, so an
## executor that declines to send it loses the message AND leaves a receipt
## saying it ran. execute_regular_chat's "the last history item is a user
## message" guard was exactly that: when the previous turn errored or was
## cancelled after its user item landed, a promoted entry hit the guard, released
## the turn and returned without a request — and the release drained the next
## entry into the same guard.
func _test_a_promoted_message_is_sent_past_the_last_user_guard() -> void:
	var chat = _make_history("Orphaned")
	var pane = _make_pane([chat], REAL_TURN_PANE_SRC)
	# The real turn path reads history.provider as a BaseProvider; it is never
	# asked to produce anything, because the pane's generate call is replaced.
	var history_provider = load(PLUGIN_PROVIDER_PATH).new()
	pane.add_child(history_provider)
	chat.provider = history_provider
	pane.current_tab = _so.ChatList.find(chat)

	var item_script: = load(CHAT_HISTORY_ITEM_PATH)
	var orphan = item_script.new()
	orphan.Role = item_script.ChatRole.USER
	orphan.Message = "the turn that never answered"
	chat.HistoryItemList.append(orphan)
	orphan.rendered_node = chat.VBox.add_history_item(orphan)

	# A turn is in flight, so the message queues instead of starting one.
	var token: int = pane._begin_chat_turn(chat)
	pane.execute_regular_chat("promote me")
	await process_frame
	check("K1: the message is queued behind the live turn",
		str(pane._outgoing_queue.pending_texts(chat.HistoryId))
			== str(PackedStringArray(["promote me"])),
		str(pane._outgoing_queue.pending_texts(chat.HistoryId)))
	var entry_id: int = pane._outgoing_queue.newest_id(chat.HistoryId)

	pane._release_chat_turn(chat, token)
	for _i in range(10):
		await process_frame
	check("K2: the promoted message really starts a request",
		str(pane.real_generates) == str(PackedStringArray(["promote me"])),
		str(pane.real_generates))
	check("K3: and the queue's record of it is honest",
		pane._outgoing_queue.outcome_of(entry_id) == ChatOutgoingQueue.Outcome.DISPATCHED,
		str(pane._outgoing_queue.outcome_of(entry_id)))
	check("K4: the chat is busy with that turn, not left idle",
		chat.is_request_active)
	pane.blocked = false
	_teardown(pane, [chat])

	# The guard still protects what it targets: a DIRECT send onto an unanswered
	# user message starts nothing.
	var direct_chat = _make_history("Direct")
	var direct_pane = _make_pane([direct_chat], REAL_TURN_PANE_SRC)
	var direct_provider = load(PLUGIN_PROVIDER_PATH).new()
	direct_pane.add_child(direct_provider)
	direct_chat.provider = direct_provider
	direct_pane.current_tab = _so.ChatList.find(direct_chat)
	var pending = item_script.new()
	pending.Role = item_script.ChatRole.USER
	pending.Message = "the turn that never answered"
	direct_chat.HistoryItemList.append(pending)
	pending.rendered_node = direct_chat.VBox.add_history_item(pending)

	direct_pane.execute_regular_chat("direct send")
	for _i in range(6):
		await process_frame
	check("K5: a direct send onto an unanswered user message still starts nothing",
		direct_pane.real_generates.is_empty(), str(direct_pane.real_generates))
	check("K6: and it releases the turn it claimed",
		not direct_chat.is_request_active)

	direct_pane.blocked = false
	_teardown(direct_pane, [direct_chat])

#endregion


#region L — the promotion exemption must cover every executor the queue promotes into

## The queue promotes into three executors, one per Mode, and each one that
## carries a "last item is a user message" guard needs the same exemption: the
## entry is already recorded as DISPATCHED and its bubble is already gone, so a
## guard bail loses the message behind an honest-looking receipt. This is the
## SEQUENTIAL door onto the same trailing USER item section K uses.
func _test_a_promoted_sequential_message_is_sent_past_the_guard() -> void:
	var chat = _make_history("Orphaned Sequential")
	var pane = _make_pane([chat], REAL_TURN_PANE_SRC)
	var history_provider = load(PLUGIN_PROVIDER_PATH).new()
	pane.add_child(history_provider)
	chat.provider = history_provider
	pane.current_tab = _so.ChatList.find(chat)

	var item_script: = load(CHAT_HISTORY_ITEM_PATH)
	var orphan = item_script.new()
	orphan.Role = item_script.ChatRole.USER
	orphan.Message = "the turn that never answered"
	chat.HistoryItemList.append(orphan)
	orphan.rendered_node = chat.VBox.add_history_item(orphan)

	var token: int = pane._begin_chat_turn(chat)
	check("L1: the sequential message is queued behind the live turn",
		pane._queue_if_busy(chat, "promote me", ChatOutgoingQueue.Mode.SEQUENTIAL))
	var entry_id: int = pane._outgoing_queue.newest_id(chat.HistoryId)

	pane._release_chat_turn(chat, token)
	for _i in range(10):
		await process_frame
	check("L2: the promoted sequential message really starts a request",
		str(pane.real_generates) == str(PackedStringArray(["promote me"])),
		str(pane.real_generates))
	check("L3: and the queue's record of it is honest",
		pane._outgoing_queue.outcome_of(entry_id) == ChatOutgoingQueue.Outcome.DISPATCHED,
		str(pane._outgoing_queue.outcome_of(entry_id)))
	check("L4: the chat is busy with that turn, not left idle",
		chat.is_request_active)

	pane.blocked = false
	_teardown(pane, [chat])

	# And the guard still protects a DIRECT sequential send.
	var direct_chat = _make_history("Direct Sequential")
	var direct_pane = _make_pane([direct_chat], REAL_TURN_PANE_SRC)
	var direct_provider = load(PLUGIN_PROVIDER_PATH).new()
	direct_pane.add_child(direct_provider)
	direct_chat.provider = direct_provider
	direct_pane.current_tab = _so.ChatList.find(direct_chat)
	var pending = item_script.new()
	pending.Role = item_script.ChatRole.USER
	pending.Message = "the turn that never answered"
	direct_chat.HistoryItemList.append(pending)
	pending.rendered_node = direct_chat.VBox.add_history_item(pending)

	direct_pane.execute_sequential_chat("direct send",
		direct_pane._begin_chat_turn(direct_chat))
	for _i in range(6):
		await process_frame
	check("L5: a direct sequential send onto an unanswered user message starts nothing",
		direct_pane.real_generates.is_empty(), str(direct_pane.real_generates))
	check("L6: and it releases the turn it claimed",
		not direct_chat.is_request_active)

	direct_pane.blocked = false
	_teardown(direct_pane, [direct_chat])

#endregion


#region M — a human-provider parallel worker still ends its share of the run

## A human provider answers by hand: the worker has no request to make and no
## bot response to wait for. It still owns one share of the run, so it has to go
## through the same completion accounting as every other worker — a worker that
## returns without delivering leaves `delivered` short of `expected`, the run
## never completes, `_release_chat_turn` never runs, and every later message
## stays queued behind a turn that can never end.
##
## The worker body `create_message_new` is real here; only the network calls and
## the promotion target are replaced, so the branch this measures is the one the
## app runs. The handler's UI half needs the booted scene, so the cancelled-chat
## early return stops it right after the release decision — the decision is the
## whole subject.
func _test_a_human_parallel_worker_ends_its_share_of_the_run() -> void:
	var chat = _make_history("HumanParallel")
	var pane = _make_pane([chat], PARALLEL_WORKER_PANE_SRC)
	var human = load(HUMAN_PROVIDER_PATH).new()
	pane.add_child(human)
	chat.provider = human
	pane.current_tab = _so.ChatList.find(chat)

	var token: int = pane._begin_chat_turn(chat)
	var run = load(PARALLEL_RUN_PATH).new()
	run.history = chat
	run.turn_token = token
	run.inputs.append("what do you think?")
	run.expected = 1
	run.user_slider_uuid = "human-user"
	run.model_slider_uuid = "human-model"
	run.multi_slider_uuid = "human-multi"
	pane._parallel_run = run

	# A second message arrives while the human is still answering.
	pane.execute_regular_chat("queued behind the human")
	check("M1: the later message is queued behind the live run",
		str(pane._outgoing_queue.pending_texts(chat.HistoryId))
			== str(PackedStringArray(["queued behind the human"])),
		str(pane._outgoing_queue.pending_texts(chat.HistoryId)))

	_so.cancelled_history_ids.append(chat.HistoryId)
	pane.create_message_new(0)
	for _i in range(10):
		await process_frame

	check("M2: the human worker issues no provider request",
		pane.real_generates.is_empty(), str(pane.real_generates))
	check("M3: it counts as delivered, so the run completes",
		run.delivered == 1, "delivered=%d expected=%d" % [run.delivered, run.expected])
	check("M4: and the turn is released", not chat.is_request_active)
	check("M5: so the queued message drains",
		str(pane.drained) == str(PackedStringArray(["queued behind the human"])),
		str(pane.drained))

	# The pair the owner types into: the user message and an EMPTY model item.
	var item_script: = load(CHAT_HISTORY_ITEM_PATH)
	check("M6: the worker leaves a user message and an empty model answer",
		chat.HistoryItemList.size() == 2
			and chat.HistoryItemList[0].Role == item_script.ChatRole.USER
			and chat.HistoryItemList[0].Message == "what do you think?"
			and chat.HistoryItemList[1].Role == item_script.ChatRole.MODEL
			and chat.HistoryItemList[1].Message == "",
		"items=%d" % chat.HistoryItemList.size())
	check("M7: the user message carries the human provider, which is what the "
		+ "response handler renders the editable answer by",
		chat.HistoryItemList.size() > 0
			and chat.HistoryItemList[0].provider == human)

	pane.blocked = false
	_teardown(pane, [chat])


## The worker body is real and runs on a real worker thread here, because the
## thread the handler lands on is the whole subject: the handler builds and
## renders message nodes, sets the editable answer bubble and drains the queue
## into the next turn, and none of that may run off the main thread. The human
## branch is the one driven, since it emits with no await in front of it. As in
## section M the chat is marked cancelled, so the handler stops right after the
## release decision instead of reaching UI that needs the booted scene.
func _test_a_worker_delivers_its_response_on_the_main_thread() -> void:
	var chat = _make_history("ThreadedHumanParallel")
	var pane = _make_pane([chat], PARALLEL_WORKER_PANE_SRC)
	var human = load(HUMAN_PROVIDER_PATH).new()
	pane.add_child(human)
	chat.provider = human
	pane.current_tab = _so.ChatList.find(chat)

	var token: int = pane._begin_chat_turn(chat)
	var run = load(PARALLEL_RUN_PATH).new()
	run.history = chat
	run.turn_token = token
	run.inputs.append("answer me by hand")
	run.expected = 1
	run.user_slider_uuid = "thread-user"
	run.model_slider_uuid = "thread-model"
	run.multi_slider_uuid = "thread-multi"
	pane._parallel_run = run

	pane.execute_regular_chat("queued behind the threaded run")
	_so.cancelled_history_ids.append(chat.HistoryId)

	var worker: = Thread.new()
	worker.start(pane.create_message_new.bind(0))
	while worker.is_alive():
		await process_frame
	worker.wait_to_finish()
	for _i in range(10):
		await process_frame

	check("N1: the response handler runs on the main thread",
		pane.handler_thread_id == OS.get_main_thread_id(),
		"handler=%d main=%d worker-side=%s"
			% [pane.handler_thread_id, OS.get_main_thread_id(),
				str(pane.handler_thread_id != -1)])
	check("N2: the worker still delivers its share of the run",
		run.delivered == 1, "delivered=%d" % run.delivered)
	check("N3: and the turn is released", not chat.is_request_active)
	check("N4: so the queued message drains",
		str(pane.drained) == str(PackedStringArray(["queued behind the threaded run"])),
		str(pane.drained))

	pane.blocked = false
	_so.cancelled_history_ids.erase(chat.HistoryId)
	_teardown(pane, [chat])

#endregion

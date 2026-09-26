extends RefCounted
## The world test_terminal_notify.gd and test_trigger_harness_delivery.gd
## share: the real MCPTerminalTools with its terminal listing, watch profiles
## and relay send scripted; chats bound to terminals the way the passthrough
## launch binds them; and a ChatPane whose queue helpers are real and whose
## turn body drives a blocking fake provider.

const CHAT_HISTORY_PATH := "res://Scripts/Models/ChatHistory.gd"
const VBOX_CHAT_PATH := "res://Scripts/UI/Controls/vboxChat.gd"
const PLUGIN_PROVIDER_PATH := "res://Scripts/Services/Providers/PluginProvider.gd"

## Blocking provider stand-in, keyed by chat so two chats can be in flight
## independently and "did this chat's next turn start?" is directly observable.
const FAKE_PROVIDER_SRC := """
extends RefCounted
var tree: SceneTree = null
var calls: Array = []
var _released: Dictionary = {}
var _questions: Dictionary = {}

func release(chat: String, text: String) -> void:
	_released[chat + "|" + text] = true

## Mark the turn this text starts as one that ENDS IN A QUESTION: the harness
## pane then finalizes it with passthrough question options, the way a real
## passthrough turn that hit a chooser does.
func mark_question(chat: String, text: String) -> void:
	_questions[chat + "|" + text] = true

func is_question(chat: String, text: String) -> bool:
	return _questions.get(chat + "|" + text, false)

func texts_for(chat: String) -> PackedStringArray:
	var out: = PackedStringArray()
	for call_entry: Dictionary in calls:
		if str(call_entry["chat"]) == chat:
			out.append(str(call_entry["text"]))
	return out

func generate_content(chat: String, text: String) -> String:
	calls.append({"chat": chat, "text": text})
	while not _released.get(chat + "|" + text, false):
		await tree.process_frame
	return "reply"
"""

## Harness pane: ChatPane's real queue helpers, faked turn body. The UI button
## refreshers are no-ops because their unique-name nodes only exist in the
## booted scene.
const HARNESS_PANE_SRC := """
extends "res://Scripts/UI/Views/ChatPane.gd"

var provider = null

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
	# Stands in for PluginProvider._report_notify: the fake provider IS the
	# harness here, so the turn starting is the harness taking the line.
	load("res://Scripts/Services/Terminal/NotifyDeliveryLedger.gd").shared().note_chat_outcome(
		history.HistoryId, text, "handed")
	var answer = await provider.generate_content(history.HistoryName, text)
	# The real turn finalizes by appending the bot's ChatHistoryItem, carrying
	# the passthrough question options when the turn ended in a question. That
	# item is what ChatHistory.is_awaiting_question_answer() reads, so the
	# harness must produce it too.
	var chi: = ChatHistoryItem.new()
	chi._suppress_save_state = true
	chi.Role = ChatHistoryItem.ChatRole.MODEL
	chi.Message = str(answer)
	if provider.is_question(history.HistoryName, text):
		chi.HcpData = {"passthrough_question_options": [{"label": "Yes", "keystroke": "1"}]}
	history.HistoryItemList.append(chi)
	_release_chat_turn(history, turn_token)
"""

## Module under test with the two environment seams closed: the terminal
## listing and the watch-profile map. Everything else is the real module.
const HARNESS_MODULE_SRC := """
extends "res://Scripts/Services/MCP/Modules/MCPTerminalTools.gd"

var terminals: Array = []
var relay_calls: Array = []
var relay_call_times: Array = []
var relay_reply: Dictionary = {"ok": true, "submit": {"state": "submitted", "evidence": "echo"}}

func _terminal_list(_arguments: Dictionary) -> Dictionary:
	return {"success": true, "terminals": terminals, "count": terminals.size()}
"""

static func make_script(source: String) -> GDScript:
	var script: = GDScript.new()
	script.source_code = source
	script.reload()
	return script


## A chat bound to a terminal exactly the way the passthrough launch path binds
## one: a PluginProvider whose entry_id is "terminal-<id>".
static func make_bound_chat(chat_name: String, terminal_id: String):
	var history = load(CHAT_HISTORY_PATH).new(null)
	history.HistoryName = chat_name
	var provider = load(PLUGIN_PROVIDER_PATH).new()
	provider.configure_from_entry({
		"key": "plugin:agent_relay:terminal-%s" % terminal_id,
		"plugin_id": "agent_relay",
		"entry_id": "terminal-%s" % terminal_id,
		"generate_tool": "minerva_agent_relay_relay_ask",
		"display_name": chat_name,
	})
	history.provider = provider
	return history


## A pane built from `source` holding `chats`, installed as the app's chat
## pane (SingletonObject `so`).
static func make_pane(tree: SceneTree, so: Node, chats: Array, source: String = HARNESS_PANE_SRC) -> Node:
	var pane = make_script(source).new()
	pane.name = "NotifyHarnessChatPane"
	tree.root.add_child(pane)
	for history in chats:
		var scroll: = ScrollContainer.new()
		pane.add_child(scroll)
		var vbox = load(VBOX_CHAT_PATH).new(pane)
		vbox.chat_history = history
		scroll.add_child(vbox)
		history.VBox = vbox
		so.ChatList.append(history)
	so.Chats = pane
	return pane


static func teardown(so: Node, saved_chats, pane: Node, chats: Array) -> void:
	for history in chats:
		so.ChatList.erase(history)
	so.Chats = saved_chats
	pane.queue_free()


## The module under test, listing `terminals` and reporting `profiles`.
static func make_module(terminals: Array, profiles: Dictionary) -> Object:
	var module = make_script(HARNESS_MODULE_SRC).new(null)
	module.terminals = terminals
	module.watch_profile_source = func(_ids: PackedStringArray) -> Dictionary:
		return profiles
	module.relay_send_source = func(args: Dictionary) -> Dictionary:
		module.relay_calls.append(args)
		module.relay_call_times.append(Time.get_ticks_msec())
		return module.relay_reply
	return module

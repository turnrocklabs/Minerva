extends SceneTree
## Plugin chat targeting (work item minerva:01a13284fb6d): host.chat.active,
## the chat.active_changed host event, and host.chat.input.
##
## Run: godot --headless --path src --script test/test_plugin_chat_target.gd
##   or scripts/run-functional-tests.sh --test test/test_plugin_chat_target.gd
## (registered in the runner's non-CI plugin tier).
##
## A real Chat.tscn pane is mounted (as test_chat_groups_integration does) and
## the capabilities go through the live SingletonObject CapabilityBroker, as a
## plugin's minerva/capability request would. The fixture plugin
## (fixtures/chat_target_probe, the host_event_probe script) records the
## chat.active_changed notifications it receives. Chats use the Human provider,
## so a submit posts the user's message without any network request.
##
## Nothing touches a Minerva script before the SingletonObject autoload is up:
## scripts that name it fail to compile earlier and stay broken for the run.
## Scripts are load()ed and their instances left untyped for that reason.

const CHAT_HISTORY_PATH := "res://Scripts/Models/ChatHistory.gd"
const CHAT_HISTORY_ITEM_PATH := "res://Scripts/Models/ChatHistoryItem.gd"
const AUDIO_TO_TEXT_PATH := "res://Scripts/Models/AudioToText.gd"
const CHAT_GROUP_REGISTRY_PATH := "res://Scripts/Models/ChatGroupRegistry.gd"
const TRACKER_PATH := "res://Scripts/Models/ActiveChatTracker.gd"
const SECOND := "chat_target_second"

const PROBE := "chat_target_probe"
const UNGRANTED := "chat_target_ungranted"
const ACTIVE := "host.chat.active"
const INPUT := "host.chat.input"
const ACTIVE_CHANGED := "chat.active_changed"

var _pass := 0
var _fail := 0
var _so: Node = null
var _host_render := preload("res://test/helpers/chat_host_render_fixture.gd").new()
var _pane = null
var _broker = null
var _seen: Array = []
## Refusal messages shown to the user (the chat target's notifier, observed).
var _notices: Array = []
var _ptt_ready := 0
var _ptt_listening := 1


func _init() -> void:
	print("=== Plugin chat target ===\n")
	await _run()
	print("\n=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func check(label: String, ok: bool, detail: String = "") -> void:
	if ok:
		_pass += 1
		print("  PASS: %s" % label)
	else:
		_fail += 1
		printerr("  FAIL: %s%s" % [label, ("  — " + detail) if detail else ""])


func _run() -> void:
	await process_frame
	_so = root.get_node_or_null("SingletonObject")
	check("SingletonObject autoload is live", _so != null)
	if _so == null:
		return
	var deadline: int = Time.get_ticks_msec() + 10000
	while _so.get("plugin_capability_broker") == null and Time.get_ticks_msec() < deadline:
		await create_timer(0.1).timeout
	_broker = _so.get("plugin_capability_broker")
	check("the broker has its chat target", _broker != null and _broker.chat_target != null)
	if _broker == null or _broker.chat_target == null:
		return
	var ptt_states: Dictionary = load(AUDIO_TO_TEXT_PATH).PTTState
	_ptt_ready = ptt_states["READY"]
	_ptt_listening = ptt_states["LISTENING"]
	var show_to_user: Callable = _broker.chat_target._notify
	_broker.chat_target._notify = func(message: String) -> void:
		_notices.append(message)
		show_to_user.call(message)
	if OS.execute("python3", ["--version"], [], true) != OK:
		print("SKIP: python3 not available — skipping the fixture plugin suite")
		return
	_test_tracker()
	var probe_ready: bool = await _start_probe()
	if not probe_ready:
		return
	var chat_scene = await _mount_pane()
	if _pane == null:
		return
	_pane.clear_all_chats()
	_so.ChatList.clear()
	var chat_a = _add_chat("Alpha")
	var chat_b = _add_chat("Beta")
	_show(chat_a)
	await _frames(3)
	await _probe("probe_clear")
	_seen.clear()

	await _test_active_changed(chat_a, chat_b)
	await _test_input(chat_a, chat_b)
	await _test_slow_admission(chat_b)
	await _test_provisional_append_is_not_success()
	await _test_refused_dispatch(chat_b)
	await _test_external_ptt()
	await _test_denied()
	await _test_close_visible(chat_a, chat_b)
	await _test_crash_releases_mic()
	await _test_plugin_stop_releases_mic()

	await _so.plugin_manager.stop_plugin(PROBE)
	await _so.plugin_manager.remove_plugin(PROBE, false)
	for history in [chat_a, chat_b]:
		_so.ChatList.erase(history)
	chat_scene.queue_free()
	await process_frame
	_host_render.restore()


#region Tracker

func _test_tracker() -> void:
	print("\n-- ActiveChatTracker --")
	var tracker = load(TRACKER_PATH).new()
	var none := {"chat_id": null, "name": "", "group_id": "", "group": ""}
	var first := {"chat_id": "a", "name": "A", "group_id": "", "group": ""}
	tracker.request_check()
	check("T1: the first check records the starting chat without reporting it", not tracker.settle(none))
	check("T2: a real change is reported", tracker.request_check() and tracker.settle(first))
	tracker.request_check()
	check("T3: the same payload again is not", not tracker.settle(first.duplicate()))
	check("T4: a second request while one is pending is not scheduled twice",
		tracker.request_check() and not tracker.request_check())
	var renamed := first.duplicate()
	renamed["name"] = "A2"
	check("T5: a renamed chat is a change", tracker.settle(renamed))

#endregion


#region Active chat

func _test_active_changed(chat_a, chat_b) -> void:
	print("\n-- chat.active_changed and host.chat.active --")
	_show(chat_b)
	await _frames(3)
	check("1: a tab switch emits one chat.active_changed naming the new chat",
		_seen.size() == 1 and _seen[0]["chat_id"] == str(chat_b.HistoryId), str(_seen))
	var delivered: Array = await _active_events()
	check("2: the fixture plugin receives exactly one, for the same chat",
		delivered.size() == 1 and delivered[0]["chat_id"] == str(chat_b.HistoryId), str(delivered))

	_show(chat_b)
	_pane.set_active_group(_pane.get_active_group_id())
	_pane._apply_tab_filters()
	await _frames(3)
	check("3: re-selecting the visible chat emits nothing", _seen.size() == 1, str(_seen))

	_show(chat_a)
	_show(chat_b)
	await _frames(3)
	check("4: a switch and restore within one frame emits nothing", _seen.size() == 1, str(_seen))
	check("5: the plugin still has exactly one", (await _active_events()).size() == 1)

	var active: Dictionary = await _broker.dispatch(PROBE, ACTIVE, {})
	var result: Dictionary = active.get("result", {})
	check("6: host.chat.active matches the visible chat",
		active.get("success", false) and result.get("chat_id") == str(chat_b.HistoryId)
			and result.get("name") == "Beta" and result.has("group_id") and result.has("group"),
		str(active))

	var before: int = _seen.size()
	_pane.rename_chat(_so.ChatList.find(chat_b), "Beta renamed")
	await _frames(3)
	check("6b: renaming the visible chat emits one chat.active_changed with the new name",
		_seen.size() == before + 1 and _seen[-1]["name"] == "Beta renamed", str(_seen))

	var Registry = load(CHAT_GROUP_REGISTRY_PATH)
	var tag := str(Time.get_ticks_usec())
	var group_b: String = _so.chat_groups.create_group("Group B " + tag)
	before = _seen.size()
	_pane.set_chat_group(chat_b, group_b)
	await _frames(3)
	check("6c: regrouping the visible chat emits one, naming the group",
		_seen.size() == before + 1 and _seen[-1]["group_id"] == group_b and _seen[-1]["group"] == "Group B " + tag,
		str(_seen))

	var group_a: String = _so.chat_groups.create_group("Group A " + tag)
	_pane.set_chat_group(chat_a, group_a)
	await _frames(3)
	before = _seen.size()
	_pane.set_active_group(group_a)
	await _frames(3)
	check("6d: switching to another group emits one, for the chat it shows",
		_seen.size() == before + 1 and _seen[-1]["chat_id"] == str(chat_a.HistoryId), str(_seen))
	before = _seen.size()
	_pane.set_active_group(Registry.VIEW_ALL)
	await _frames(3)
	check("6e: widening the view while that chat stays on screen emits nothing", _seen.size() == before, str(_seen))
	_pane.set_chat_group(chat_a, "")
	_pane.set_chat_group(chat_b, "")
	for gid in [group_a, group_b]:
		if _so.chat_groups.has_group(gid):
			_pane.delete_group(gid)
	check("6f: the groups this test made are gone",
		not _so.chat_groups.has_group(group_a) and not _so.chat_groups.has_group(group_b))
	_show(chat_b)
	await _frames(3)

#endregion


#region Input

func _test_input(chat_a, chat_b) -> void:
	print("\n-- host.chat.input --")
	await _input({"op": "clear"})
	await _input({"op": "append", "text": "hello "})
	await _input({"op": "append", "text": "world"})
	check("7: append adds to the visible chat's input box", _pane.get_user_input_text() == "hello world",
		_pane.get_user_input_text())
	var before_b: int = chat_b.HistoryItemList.size()
	var sent: Dictionary = await _input({"op": "submit", "expected_chat_id": str(chat_b.HistoryId)})
	await _frames(5)
	check("8: submit to the expected visible chat succeeds", sent.get("success", false), str(sent))
	check("9: the message is posted into that chat and the box is emptied",
		_has_user_message(chat_b, "hello world", before_b) and _pane.get_user_input_text().is_empty(),
		"items %d -> %d" % [before_b, chat_b.HistoryItemList.size()])

	await _input({"op": "append", "text": "stale draft"})
	_show(chat_a)
	await _frames(3)
	var counts := [chat_a.HistoryItemList.size(), chat_b.HistoryItemList.size()]
	var notices_before: int = _notices.size()
	var stale: Dictionary = await _input({"op": "submit", "expected_chat_id": str(chat_b.HistoryId)})
	await _frames(5)
	check("10: a submit after the visible chat changed is refused, and the user is shown why",
		not stale.get("success", true) and stale.get("error_code") == "chat_changed"
			and _notices.size() == notices_before + 1, str(stale))
	check("11: and nothing is posted to either chat; the draft stays",
		[chat_a.HistoryItemList.size(), chat_b.HistoryItemList.size()] == counts
			and _pane.get_user_input_text() == "stale draft")

	await _input({"op": "clear"})
	check("12: clear empties the input box", _pane.get_user_input_text().is_empty())
	notices_before = _notices.size()
	var empty: Dictionary = await _input({"op": "submit", "expected_chat_id": str(chat_a.HistoryId)})
	check("13: an empty input is refused, and the user is shown why",
		not empty.get("success", true) and empty.get("error_code") == "empty_input"
			and _notices.size() == notices_before + 1, str(empty))
	var no_text: Dictionary = await _input({"op": "append"})
	var no_target: Dictionary = await _input({"op": "submit"})
	check("13b: append without text and submit without expected_chat_id are malformed requests",
		no_text.get("error_code") == "schema_validation_failed"
			and no_target.get("error_code") == "schema_validation_failed", "%s %s" % [no_text, no_target])

	_show(chat_b)
	await _frames(3)
	chat_b.is_request_active = true
	await _input({"op": "append", "text": "while busy"})
	var queued: Dictionary = await _input({"op": "submit", "expected_chat_id": str(chat_b.HistoryId)})
	check("13c: a submit to a busy chat is queued behind its turn",
		queued.get("success", false) and queued.get("result", {}).get("queued") == true
			and _pane._outgoing_queue.pending_count(str(chat_b.HistoryId)) == 1, str(queued))
	_pane._clear_outgoing_queue(chat_b)
	chat_b.is_request_active = false
	check("13d: the queued entry is cleaned up", _pane._outgoing_queue.pending_count(str(chat_b.HistoryId)) == 0)

	var chat_c = _add_chat("Gamma", _so.API_MODEL_PROVIDERS.NEMOTRON_NANO)
	var Item = load(CHAT_HISTORY_ITEM_PATH)
	var unanswered = Item.new()
	unanswered.Role = Item.ChatRole.USER
	unanswered.Message = "still waiting"
	chat_c.HistoryItemList.append(unanswered)
	_show(chat_c)
	await _frames(3)
	var items_c: int = chat_c.HistoryItemList.size()
	notices_before = _notices.size()
	await _input({"op": "append", "text": "second question"})
	var dropped: Dictionary = await _input({"op": "submit", "expected_chat_id": str(chat_c.HistoryId)})
	check("13e: a message the chat drops (it is still waiting on a reply) is reported not_sent, loudly",
		dropped.get("error_code") == "not_sent" and dropped.get("reason") == "awaiting_reply"
			and _notices.size() == notices_before + 1 and chat_c.HistoryItemList.size() == items_c, str(dropped))
	_show(chat_b)
	await _frames(3)
	_pane.delete_chat(chat_c)
	await _frames(3)

	var audit = _so.plugin_audit_log
	var leaked := false
	for entry: Dictionary in audit.get_entries(PROBE, "", 200):
		if str(entry.get("detail", {})).contains("hello") or str(entry.get("detail", {})).contains("stale draft"):
			leaked = true
	check("14: input text never reaches the audit log", not leaked)
	_show(chat_b)
	await _frames(3)


func _has_user_message(history, text: String, from_index: int) -> bool:
	var Item = load(CHAT_HISTORY_ITEM_PATH)
	for i in range(from_index, history.HistoryItemList.size()):
		var item = history.HistoryItemList[i]
		if item.Role == Item.ChatRole.USER and item.Message == text:
			return true
	return false

#endregion


#region Submit outcomes

## Notes container whose prompt build waits for the test to open its gate, so a
## Human-provider post lands as late as the test chooses.
const GATED_NOTES_SRC := """
extends "res://Scenes/note/NotesContainer.gd"

var released := false

func to_prompt(provider: BaseProvider, refresh_detached: = false, history_id: String = "") -> Array[Variant]:
	while not released:
		await Engine.get_main_loop().process_frame
	return []
"""

## A pane standing in for the Core (HCP) send: it records the user's message
## provisionally, then takes it back and drops the send, as execute_hcp_chat
## does for a refused or stale prompt. The submit must report not_sent, never
## success on the provisional entry.
const PROVISIONAL_PANE_SRC := """
extends "res://Scripts/UI/Views/ChatPane.gd"

var box_text := ""
var chat: ChatHistory = null

func _ready() -> void:
	pass

func current_chat() -> ChatHistory:
	return chat

func get_user_input_text() -> String:
	return box_text

func set_user_input_text(text: String) -> void:
	box_text = text

func submit_chat(_mode: int = 0) -> int:
	_last_box_send_id += 1
	var send_id := _last_box_send_id
	var history: ChatHistory = current_chat()
	var provisional := ChatHistoryItem.new()
	provisional.Role = ChatHistoryItem.ChatRole.USER
	history.HistoryItemList.append(provisional)
	box_text = ""
	_drop_later(history, provisional, send_id)
	return send_id

func _drop_later(history: ChatHistory, provisional: ChatHistoryItem, send_id: int) -> void:
	for i in 5:
		await get_tree().process_frame
	history.HistoryItemList.erase(provisional)
	_settle_box_send(history, send_id, "prompt_refused")
"""


func _test_slow_admission(chat_b) -> void:
	print("\n-- submit outcomes: slow admission and pending --")
	var real_notes = _so.notes_container
	var gated = _compile(GATED_NOTES_SRC).new()
	_so.notes_container = gated
	_show(chat_b)
	await _frames(3)

	var before: int = chat_b.HistoryItemList.size()
	await _input({"op": "append", "text": "slow notes"})
	create_timer(0.5).timeout.connect(func() -> void: gated.released = true)
	var slow: Dictionary = await _input({"op": "submit", "expected_chat_id": str(chat_b.HistoryId)})
	await _frames(3)
	check("32: a post that waits on slow notes is reported admitted, not a false not_sent",
		slow.get("success", false) and slow.get("result", {}).get("queued") == false
			and _has_user_message(chat_b, "slow notes", before), str(slow))

	gated.released = false
	_broker.chat_target.submit_timeout_ms = 200
	var notices_before: int = _notices.size()
	before = chat_b.HistoryItemList.size()
	await _input({"op": "append", "text": "very slow"})
	var pending: Dictionary = await _input({"op": "submit", "expected_chat_id": str(chat_b.HistoryId)})
	check("33: no outcome before the timeout is pending, with no toast and no not_sent",
		pending.get("success", false) and pending.get("result", {}).get("status") == "pending"
			and _notices.size() == notices_before, str(pending))
	gated.released = true
	await _frames(5)
	check("34: and the message still posts once the chat takes it", _has_user_message(chat_b, "very slow", before))
	_broker.chat_target.submit_timeout_ms = 30000
	_so.notes_container = real_notes
	gated.free()


func _test_provisional_append_is_not_success() -> void:
	print("\n-- submit outcomes: provisional append then drop --")
	var chat = _make_plain_history("Provisional")
	var stand_in = _compile(PROVISIONAL_PANE_SRC).new()
	root.add_child(stand_in)
	stand_in.chat = chat
	var real_pane = _so.Chats
	_so.Chats = stand_in
	stand_in.box_text = "refused text"
	var notices_before: int = _notices.size()
	var refused: Dictionary = await _input({"op": "submit", "expected_chat_id": str(chat.HistoryId)})
	check("35: a provisionally recorded message that is then dropped is not_sent, not success",
		refused.get("error_code") == "not_sent" and refused.get("reason") == "prompt_refused"
			and _notices.size() == notices_before + 1 and chat.HistoryItemList.is_empty(), str(refused))
	_so.Chats = real_pane
	stand_in.queue_free()


## Local provider that counts the requests it is given instead of making them.
const COUNTING_LOCAL_SRC := """
extends "res://Scripts/Services/Providers/LocalProvider.gd"

var calls := 0

func generate_content(prompt: Array[Variant], additional_params: Dictionary={}) -> BotResponse:
	calls += 1
	return BotResponse.new()
"""


## The regular send's dispatch gate (a disabled provider here) refuses after
## the message is recorded; the submit must report that, not admission.
func _test_refused_dispatch(chat_b) -> void:
	print("\n-- submit outcomes: dispatch gate refusal --")
	var provider = _compile(COUNTING_LOCAL_SRC).new()
	var was_enabled: bool = _so.is_provider_enabled(provider.PROVIDER)
	_so.set_provider_enabled(provider.PROVIDER, false)
	var history = load(CHAT_HISTORY_PATH).new(provider)
	history.HistoryName = "Refusing"
	_so.ChatList.append(history)
	_pane.render_history(history)
	_show(history)
	await _frames(3)
	var notices_before: int = _notices.size()
	await _input({"op": "append", "text": "to a disabled provider"})
	var refused: Dictionary = await _input({"op": "submit", "expected_chat_id": str(history.HistoryId)})
	await _frames(5)
	check("36: a send the dispatch gate refuses is not_sent with the gate's reason, loudly, and nothing is dispatched",
		refused.get("error_code") == "not_sent"
			and refused.get("reason") in ["provider_disabled", "system_prompt_unavailable"]
			and _notices.size() == notices_before + 1 and provider.calls == 0, str(refused))
	_so.set_provider_enabled(provider.PROVIDER, was_enabled)
	_show(chat_b)
	await _frames(3)
	_pane.delete_chat(history)
	await _frames(3)


func _make_plain_history(chat_name: String):
	var history = load(CHAT_HISTORY_PATH).new(null)
	history.HistoryName = chat_name
	return history


func _compile(source: String) -> GDScript:
	var script := GDScript.new()
	script.source_code = source
	script.reload()
	return script

#endregion


#region External PTT

func _test_external_ptt() -> void:
	print("\n-- set_external_ptt_state --")
	var mic = _pane.get_mic_button()
	var att = _so.AtT
	check("15: the pane has a mic button and Minerva's recorder is idle",
		mic != null and att != null and att.ptt_state == _ptt_ready and att._active_ptt_req == null)
	if mic == null or att == null:
		return
	var recording: Dictionary = await _input({"op": "set_external_ptt_state", "state": "recording"})
	check("16: recording shows the listening visuals",
		recording.get("success", false) and mic.modulate == Color.LIME_GREEN and not mic.disabled, str(recording))
	check("17: and never starts Minerva's own recording",
		att.ptt_state == _ptt_ready and att._active_ptt_req == null
			and not att.mic_player.playing and not att.effect.is_recording_active())
	await _input({"op": "set_external_ptt_state", "state": "transcribing"})
	check("18: transcribing disables the button", mic.disabled)
	await _input({"op": "set_external_ptt_state", "state": "idle"})
	check("19: idle restores the ready visuals", mic.modulate == Color.WHITE and not mic.disabled)
	att.ptt_state = _ptt_listening
	var look := [mic.modulate, mic.disabled]
	var busy: Dictionary = await _input({"op": "set_external_ptt_state", "state": "transcribing"})
	check("19b: while Minerva's own push-to-talk is in use an external state is refused, button untouched",
		busy.get("error_code") == "minerva_ptt_active" and [mic.modulate, mic.disabled] == look, str(busy))
	att.ptt_state = _ptt_ready
	var bad: Dictionary = await _input({"op": "set_external_ptt_state", "state": "shouting"})
	check("20: an unknown state is refused", not bad.get("success", true), str(bad))
	_so.plugin_policy.grant_capability(SECOND, INPUT)
	await _input({"op": "set_external_ptt_state", "state": "recording"})
	var other: Dictionary = await _broker.dispatch(SECOND, INPUT, {"op": "set_external_ptt_state", "state": "idle"})
	check("20b: another plugin cannot overwrite a state the first plugin is showing",
		other.get("error_code") == "external_ptt_busy" and mic.modulate == Color.LIME_GREEN, str(other))
	var own: Dictionary = await _input({"op": "set_external_ptt_state", "state": "idle"})
	check("20c: the owner can set idle, after which the other plugin may show its state",
		own.get("success", false)
			and (await _broker.dispatch(SECOND, INPUT, {"op": "set_external_ptt_state", "state": "idle"})).get("success", false))
	_so.plugin_policy.revoke_capability(SECOND, INPUT)
	await _input({"op": "set_external_ptt_state", "state": "recording"})
	att.ptt_state = _ptt_listening
	look = [mic.modulate, mic.disabled]
	var released: Dictionary = await _input({"op": "set_external_ptt_state", "state": "idle"})
	check("20d: the owner can finish during local PTT without changing its visuals",
		released.get("success", false) and [mic.modulate, mic.disabled] == look, str(released))
	att.ptt_state = _ptt_ready
	_so.plugin_policy.grant_capability(SECOND, INPUT)
	var next_owner: Dictionary = await _broker.dispatch(SECOND, INPUT,
		{"op": "set_external_ptt_state", "state": "recording"})
	check("20e: another plugin can own the button after that local session",
		next_owner.get("success", false), str(next_owner))
	await _broker.dispatch(SECOND, INPUT, {"op": "set_external_ptt_state", "state": "idle"})
	await _input({"op": "set_external_ptt_state", "state": "transcribing"})
	_so.plugin_policy.revoke_capability(PROBE, INPUT)
	check("20f: revoking the owner's input grant restores the button",
		not mic.disabled and mic.modulate == Color.WHITE)
	var revoked_idle: Dictionary = await _input({"op": "set_external_ptt_state", "state": "idle"})
	check("20g: the revoked plugin remains denied", revoked_idle.get("error_code") == "capability_not_granted")
	var after_revoke: Dictionary = await _broker.dispatch(SECOND, INPUT,
		{"op": "set_external_ptt_state", "state": "recording"})
	check("20h: revocation releases ownership for another granted plugin", after_revoke.get("success", false), str(after_revoke))
	await _broker.dispatch(SECOND, INPUT, {"op": "set_external_ptt_state", "state": "idle"})
	_so.plugin_policy.grant_capability(PROBE, INPUT)
	_so.plugin_policy.revoke_capability(SECOND, INPUT)
	check("21: Minerva's recorder is still idle after all of it",
		att.ptt_state == _ptt_ready and att._active_ptt_req == null
			and not att.mic_player.playing and not att.effect.is_recording_active())

#endregion


## A plugin that crashes while the button shows its state must not leave the
## button frozen there: the probe exits with status 3 on PluginManager's real
## unexpected-exit path.
func _test_crash_releases_mic() -> void:
	print("\n-- plugin crash releases the mic button --")
	var mic = _pane.get_mic_button()
	if mic == null:
		return
	await _input({"op": "set_external_ptt_state", "state": "transcribing"})
	check("29: the button shows the plugin's transcribing state", mic.disabled)
	var crashes: Array = []
	_so.plugin_manager.plugin_crashed.connect(func(id: String) -> void: crashes.append(id))
	await _probe("probe_exit")
	var deadline: int = Time.get_ticks_msec() + 10000
	while not crashes.has(PROBE) and Time.get_ticks_msec() < deadline:
		await process_frame
	check("30: the plugin's exit is reported as a crash", crashes.has(PROBE), str(crashes))
	check("31: and the button is back to ready", not mic.disabled and mic.modulate == Color.WHITE)
	var restarted: Dictionary = await _so.plugin_manager.start_plugin(PROBE)
	check("the probe plugin restarts", restarted.get("ok", false) == true, str(restarted))


## A plugin that stops while the button shows its state must not leave the
## button frozen there.
func _test_plugin_stop_releases_mic() -> void:
	print("\n-- plugin stop releases the mic button --")
	var mic = _pane.get_mic_button()
	if mic == null:
		return
	await _input({"op": "set_external_ptt_state", "state": "transcribing"})
	check("27: the button shows the plugin's transcribing state", mic.disabled)
	await _so.plugin_manager.stop_plugin(PROBE)
	await _frames(2)
	check("28: stopping the plugin returns the button to ready",
		not mic.disabled and mic.modulate == Color.WHITE)


#region Denial

func _test_denied() -> void:
	print("\n-- ungranted plugin --")
	var before: String = _pane.get_user_input_text()
	var denied: Dictionary = await _broker.dispatch(UNGRANTED, INPUT, {"op": "append", "text": "intruder"})
	check("22: an ungranted plugin is denied",
		not denied.get("success", true) and denied.get("error_code") == "capability_not_granted", str(denied))
	check("23: and changes nothing", _pane.get_user_input_text() == before)
	var audited := false
	for entry: Dictionary in _so.plugin_audit_log.get_entries(UNGRANTED, "capability_denied", 50):
		if entry["detail"].get("capability") == INPUT:
			audited = true
	check("24: the denial is in the audit log", audited)
	var active: Dictionary = await _broker.dispatch(UNGRANTED, ACTIVE, {})
	check("25: host.chat.active is denied to it too", not active.get("success", true))

#endregion


#region Closing the visible chat

func _test_close_visible(chat_a, chat_b) -> void:
	print("\n-- closing the visible chat --")
	await _frames(3)
	var before: int = _seen.size()
	_pane.delete_chat(chat_b)
	await _frames(3)
	check("26: closing the visible chat emits one chat.active_changed for the chat now shown",
		_seen.size() == before + 1 and _seen[-1]["chat_id"] == str(chat_a.HistoryId), str(_seen))
	_pane.restore_chat(chat_b)
	await _frames(3)

#endregion


#region Helpers

func _start_probe() -> bool:
	var pm = _so.plugin_manager
	if pm.get_db().get_by_id(PROBE) != null:
		await pm.stop_plugin(PROBE)
		await pm.remove_plugin(PROBE, false)
	var manifest := ProjectSettings.globalize_path("res://test/fixtures").path_join(PROBE).path_join("manifest.json")
	var installed: Dictionary = await pm.install_plugin(manifest, true)
	check("the probe plugin installs", installed.get("ok", false) == true, str(installed))
	var policy = _so.plugin_policy
	check("install grants its declared capabilities and event",
		policy.is_capability_granted(PROBE, ACTIVE) and policy.is_capability_granted(PROBE, INPUT)
			and policy.is_capability_granted(PROBE, "host_event:" + ACTIVE_CHANGED))
	var started: Dictionary = await pm.start_plugin(PROBE)
	check("the probe plugin starts", started.get("ok", false) == true, str(started))
	return pm.get_connection(PROBE) != null


func _mount_pane():
	_host_render.install(_so)
	var chat_scene = load("res://Scenes/Chat.tscn").instantiate()
	root.add_child(chat_scene)
	_pane = chat_scene.find_child("tcChats", true, false)
	if _pane != null:
		_pane.chat_active_changed.connect(func(payload: Dictionary) -> void: _seen.append(payload))
	await _frames(3)
	check("a real chat pane is mounted and is SingletonObject.Chats", _pane != null and _so.Chats == _pane)
	check("0: mounting the pane reports no chat.active_changed (start-up is not a change)",
		_seen.is_empty(), str(_seen))
	return chat_scene


func _add_chat(chat_name: String, provider_key: int = -1):
	var key: int = _so.API_MODEL_PROVIDERS.HUMAN if provider_key < 0 else provider_key
	var history = load(CHAT_HISTORY_PATH).new(_so.API_MODEL_PROVIDER_SCRIPTS[key].new())
	history.HistoryName = chat_name
	_so.ChatList.append(history)
	_pane.render_history(history)
	return history


func _show(history) -> void:
	_pane.current_tab = _so.ChatList.find(history)


func _input(args: Dictionary) -> Dictionary:
	return await _broker.dispatch(PROBE, INPUT, args)


func _frames(count: int) -> void:
	for i in count:
		await process_frame


func _probe(tool_name: String) -> Dictionary:
	var conn = _so.plugin_manager.get_connection(PROBE)
	if conn == null:
		return {}
	var reply = await conn.call_tool(tool_name, {})
	return reply if reply is Dictionary else {}


## Payloads of the chat.active_changed notifications the plugin received.
func _active_events() -> Array:
	var reply: Dictionary = await _probe("probe_events")
	var out: Array = []
	for entry in reply.get("events", []):
		if entry is Dictionary and entry["message"]["params"]["event"] == ACTIVE_CHANGED:
			out.append(entry["message"]["params"]["payload"])
	return out

#endregion

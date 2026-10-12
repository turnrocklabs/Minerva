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

const PROBE := "chat_target_probe"
const UNGRANTED := "chat_target_ungranted"
const ACTIVE := "host.chat.active"
const INPUT := "host.chat.input"
const ACTIVE_CHANGED := "chat.active_changed"

var _pass := 0
var _fail := 0
var _so: Node = null
var _pane = null
var _broker = null
var _seen: Array = []


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
	if OS.execute("python3", ["--version"], [], true) != OK:
		print("SKIP: python3 not available — skipping the fixture plugin suite")
		return
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
	await _test_external_ptt()
	await _test_denied()
	await _test_close_visible(chat_a, chat_b)

	await _so.plugin_manager.stop_plugin(PROBE)
	await _so.plugin_manager.remove_plugin(PROBE, false)
	for history in [chat_a, chat_b]:
		_so.ChatList.erase(history)
	chat_scene.queue_free()


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
	var stale: Dictionary = await _input({"op": "submit", "expected_chat_id": str(chat_b.HistoryId)})
	await _frames(5)
	check("10: a submit after the visible chat changed is refused",
		not stale.get("success", true) and stale.get("error_code") == "chat_changed", str(stale))
	check("11: and nothing is posted to either chat; the draft stays",
		[chat_a.HistoryItemList.size(), chat_b.HistoryItemList.size()] == counts
			and _pane.get_user_input_text() == "stale draft")

	await _input({"op": "clear"})
	check("12: clear empties the input box", _pane.get_user_input_text().is_empty())
	var empty: Dictionary = await _input({"op": "submit", "expected_chat_id": str(chat_a.HistoryId)})
	check("13: an empty input is refused",
		not empty.get("success", true) and empty.get("error_code") == "empty_input", str(empty))

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


#region External PTT

func _test_external_ptt() -> void:
	print("\n-- set_external_ptt_state --")
	var mic = _pane.get_mic_button()
	var att = _so.AtT
	check("15: the pane has a mic button and Minerva's recorder is idle",
		mic != null and att != null and att.ptt_state == 0 and att._active_ptt_req == null)
	if mic == null or att == null:
		return
	var recording: Dictionary = await _input({"op": "set_external_ptt_state", "state": "recording"})
	check("16: recording shows the listening visuals",
		recording.get("success", false) and mic.modulate == Color.LIME_GREEN and not mic.disabled, str(recording))
	check("17: and never starts Minerva's own recording",
		att.ptt_state == 0 and att._active_ptt_req == null and att.mic_player == null)
	await _input({"op": "set_external_ptt_state", "state": "transcribing"})
	check("18: transcribing disables the button", mic.disabled)
	await _input({"op": "set_external_ptt_state", "state": "idle"})
	check("19: idle restores the ready visuals", mic.modulate == Color.WHITE and not mic.disabled)
	var bad: Dictionary = await _input({"op": "set_external_ptt_state", "state": "shouting"})
	check("20: an unknown state is refused", not bad.get("success", true), str(bad))
	check("21: Minerva's recorder is still idle after all of it",
		att.ptt_state == 0 and att._active_ptt_req == null and att.mic_player == null)

#endregion


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
	var notes_script = load("res://Scenes/note/NotesContainer.gd")
	if _so.notes_container == null:
		_so.notes_container = notes_script.new()
	if _so.drawer_notes_container == null:
		_so.drawer_notes_container = notes_script.new()
	var chat_scene = load("res://Scenes/Chat.tscn").instantiate()
	root.add_child(chat_scene)
	await _frames(2)
	_pane = chat_scene.find_child("tcChats", true, false)
	check("a real chat pane is mounted and is SingletonObject.Chats", _pane != null and _so.Chats == _pane)
	if _pane != null:
		_pane.chat_active_changed.connect(func(payload: Dictionary) -> void: _seen.append(payload))
	return chat_scene


func _add_chat(chat_name: String):
	var human = _so.API_MODEL_PROVIDER_SCRIPTS[_so.API_MODEL_PROVIDERS.HUMAN].new()
	var history = load(CHAT_HISTORY_PATH).new(human)
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

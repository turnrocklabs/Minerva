extends SceneTree
## Host → plugin events (DCR minerva:01a12de939dd, work item 01a1322eaead).
##
## Run: godot --headless --path src --script test/test_plugin_host_events.gd
##
## A. PluginHostEventRouter on its own: who receives an event, what is audited,
##    how payload text is bounded, and the refusal of a plugin whose protocol
##    cannot carry host events.
## P. ChatEventPayloads: outcome precedence and payload shape (reply only).
## B. Manifest permissions.host_events: parse, serialize, validate, grant keys.
## C. End to end through the live SingletonObject plugin system and three real
##    fixture plugins (fixtures/host_event_probe*): a message sent with
##    MCPToolUtils.submit_user_message (the minerva_send_message path) to a chat
##    that is NOT on screen reaches the subscribed plugin as exactly one
##    chat.turn_completed; error and cancelled turns likewise; the ungranted and
##    undeclared plugins receive nothing and the denials are audited; a send
##    the real execute_regular_chat refuses emits nothing.
##    ChatPane's real UI turn cannot run headless (see test_chat_outgoing_queue),
##    so the harness pane replaces only execute_regular_chat's body; the turn
##    gate, _release_chat_turn, _cancel_chat_turn and the signal are ChatPane's.
## D. chat.directory_changed from a real Chat.tscn pane: created, renamed,
##    regrouped, closed, restored — each once, and delivered to the plugin.
##
## Scripts are load()ed and their instances left untyped: in --script mode the
## autoloads register after this file compiles, and the plugin scripts reach
## SingletonObject.

const ROUTER_PATH := "res://Scripts/Services/Plugins/PluginHostEventRouter.gd"
const POLICY_PATH := "res://Scripts/Services/Plugins/PluginPolicy.gd"
const AUDIT_PATH := "res://Scripts/Services/Plugins/PluginAuditLog.gd"
const DEFINITION_PATH := "res://Scripts/Services/Plugins/PluginDefinition.gd"
const TOOL_UTILS_PATH := "res://Scripts/Services/MCP/Modules/MCPToolUtils.gd"
const CHAT_HISTORY_PATH := "res://Scripts/Models/ChatHistory.gd"
const VBOX_CHAT_PATH := "res://Scripts/UI/Controls/vboxChat.gd"
const PAYLOADS_PATH := "res://Scripts/Models/ChatEventPayloads.gd"
const CHAT_HISTORY_ITEM_PATH := "res://Scripts/Models/ChatHistoryItem.gd"
const JSON_SERIALIZATION_PATH := "res://Scripts/Services/MCP/MCPJsonSerialization.gd"

const TURN := "chat.turn_completed"
const DIRECTORY := "chat.directory_changed"
const TURN_GRANT := "host_event:chat.turn_completed"
const DIRECTORY_GRANT := "host_event:chat.directory_changed"

const SUBSCRIBER := "host_event_probe"
const UNGRANTED := "host_event_probe_ungranted"
const UNDECLARED := "host_event_probe_undeclared"

## ChatPane with only the turn body replaced. A text in `hold` blocks its turn
## until cleared; a text in `errors` ends with a reply carrying that error.
const HARNESS_PANE_SRC := """
extends "res://Scripts/UI/Views/ChatPane.gd"

var hold: Dictionary = {}
var errors: Dictionary = {}

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
	var user_item := ChatHistoryItem.new()
	user_item._suppress_save_state = true
	user_item.Role = ChatHistoryItem.ChatRole.USER
	user_item.Message = text
	history.HistoryItemList.append(user_item)
	await get_tree().process_frame
	while hold.get(text, false):
		await get_tree().process_frame
	var reply := ChatHistoryItem.new()
	reply._suppress_save_state = true
	reply.Role = ChatHistoryItem.ChatRole.MODEL
	reply.Error = str(errors.get(text, ""))
	reply.Message = "" if errors.has(text) else "reply:" + text
	history.HistoryItemList.append(reply)
	_note_turn_reply(history, turn_token, reply)
	_release_chat_turn(history, turn_token)
"""

## ChatPane whose real execute_regular_chat runs only as far as the sends it
## refuses before a request. Reaching create_prompt means the send was NOT
## refused: that is recorded and the turn is stopped there, so nothing loops
## or reaches a provider.
const REAL_TURN_PANE_SRC := """
extends "res://Scripts/UI/Views/ChatPane.gd"

func _ready() -> void:
	pass

func _update_stop_button() -> void:
	pass

func _update_compact_button() -> void:
	pass

var reached_request := false

func create_prompt(append_item: ChatHistoryItem = null, refresh_detached := true, provider_fallback: BaseProvider = null, predicate: Callable = Callable(), history_override: ChatHistory = null, _turn_token: int = -1) -> Array[Variant]:
	reached_request = true
	push_error("REAL_TURN_PANE: create_prompt reached — the send was not refused")
	_cancel_chat_turn(history_override)
	await get_tree().process_frame
	return []
"""

var _pass := 0
var _fail := 0
var _so: Node = null


func _init() -> void:
	print("=== Plugin host events ===\n")
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
	_test_router()
	_test_payloads()
	_test_manifest()
	await process_frame
	_so = root.get_node_or_null("SingletonObject")
	check("SingletonObject autoload is live", _so != null)
	if _so == null:
		return
	var deadline: int = Time.get_ticks_msec() + 10000
	while _so.get("plugin_host_event_router") == null and Time.get_ticks_msec() < deadline:
		await create_timer(0.1).timeout
	check("the plugin system built its host-event router", _so.get("plugin_host_event_router") != null)
	if _so.get("plugin_host_event_router") == null:
		return
	if OS.execute("python3", ["--version"], [], true) != OK:
		print("SKIP: python3 not available — skipping fixture plugin sections")
		return
	var fixtures_ready: bool = await _start_fixtures()
	if not fixtures_ready:
		return
	await _test_turn_events()
	await _test_refused_send_is_silent()
	await _test_directory_events()
	for id in [SUBSCRIBER, UNGRANTED, UNDECLARED]:
		await _so.plugin_manager.stop_plugin(id)
		await _so.plugin_manager.remove_plugin(id, false)


#region A — router

func _test_router() -> void:
	print("-- A: PluginHostEventRouter --")
	var audit = load(AUDIT_PATH).new()
	var policy = load(POLICY_PATH).new(null, audit, false)
	var subscriber = _definition("sub", [TURN])
	var ungranted = _definition("ungranted", [TURN])
	var undeclared = _definition("undeclared", [])
	var bystander = _definition("bystander", [])
	policy.grant_capability("sub", TURN_GRANT)
	policy.grant_capability("undeclared", TURN_GRANT)
	var sent: Array = []
	var running := func() -> Array:
		return [subscriber, ungranted, undeclared, bystander]
	var send := func(plugin_id: String, event: String, payload: Dictionary) -> Error:
		sent.append({"plugin_id": plugin_id, "event": event, "payload": payload})
		return OK
	var router = load(ROUTER_PATH).new(policy, audit, running, send)

	var payload := {"chat_id": "c1", "message_index": 3, "role": "assistant",
		"text": "hi", "outcome": "ok"}
	var result: Dictionary = router.publish(TURN, payload)
	check("A1: only the declared and granted plugin is delivered to",
		_list(result["delivered"]) == ["sub"] and sent.size() == 1 and sent[0]["plugin_id"] == "sub",
		str(result))
	check("A2: the payload arrives whole with truncated=false",
		sent.size() == 1 and sent[0]["payload"]["text"] == "hi"
			and sent[0]["payload"]["truncated"] == false
			and typeof(sent[0]["payload"]["message_index"]) == TYPE_INT)
	check("A3: the caller's payload is not changed", not payload.has("truncated"))
	check("A4: declared but ungranted and granted but undeclared are denied",
		result["denied"].has("ungranted") and result["denied"].has("undeclared"), str(result))
	check("A5: delivery is audited as capability_dispatched under the grant key",
		_audit_reason(audit, "sub", "capability_dispatched", TURN_GRANT) == "")
	check("A6: the ungranted denial is audited (capability_not_granted)",
		_audit_reason(audit, "ungranted", "capability_denied", TURN_GRANT) == "capability_not_granted")
	check("A7: the ungranted denial is a policy decision the Plugin Manager can grant from",
		audit.get_entries("ungranted", "policy_deny").size() == 1)
	check("A8: the undeclared denial is audited (not_declared)",
		_audit_reason(audit, "undeclared", "capability_denied", TURN_GRANT) == "not_declared")
	check("A9: a plugin that neither declared nor holds the grant leaves no trace",
		audit.get_entries("bystander").is_empty() and not result["denied"].has("bystander"))

	sent.clear()
	router.publish(DIRECTORY, {"chat_id": "c1", "change": "renamed", "name": "n", "group_id": ""})
	check("A10: an event nobody declared is sent to nobody", sent.is_empty())
	router.publish("chat.bogus", {})
	check("A11: an event outside ALLOWED_HOST_EVENTS is refused", sent.is_empty())

	var failing = load(ROUTER_PATH).new(policy, audit, running,
		func(_p: String, _e: String, _d: Dictionary) -> Error: return ERR_UNAVAILABLE)
	var failed: Dictionary = failing.publish(TURN, payload)
	check("A12: a failed send is reported and audited as capability_failed",
		_list(failed["failed"]) == ["sub"] and audit.get_entries("sub", "capability_failed").size() == 1,
		str(failed))

	var Router = load(ROUTER_PATH)
	var long_text := "é".repeat(40000)
	var bounded: Dictionary = Router.bound_payload({"text": long_text})
	var bounded_size: int = Router.encoded_size(bounded)
	check("A13: oversized text is cut to fit the encoded bound, whole characters, flagged",
		bounded["truncated"] == true and bounded_size <= Router.PAYLOAD_MAX_BYTES
			and bounded_size > Router.PAYLOAD_MAX_BYTES - 8
			and long_text.begins_with(str(bounded["text"])),
		"size=%d" % bounded_size)
	check("A14: a payload without text gets no truncated key",
		not Router.bound_payload({"chat_id": "c1"}).has("truncated"))

	sent.clear()
	var escape_heavy := "\"\n".repeat(25000)
	var heavy_payload := {"chat_id": "c1", "message_index": 1, "role": "assistant",
		"text": escape_heavy, "outcome": "ok"}
	check("A15: escape-heavy text is under the raw size yet over the encoded bound",
		escape_heavy.to_utf8_buffer().size() < Router.PAYLOAD_MAX_BYTES
			and Router.encoded_size(heavy_payload) > Router.PAYLOAD_MAX_BYTES)
	var heavy: Dictionary = router.publish(TURN, heavy_payload)
	check("A16: and is still delivered, truncated, within the bound",
		_list(heavy["delivered"]) == ["sub"] and sent.size() == 1
			and sent[0]["payload"]["truncated"] == true
			and Router.encoded_size(sent[0]["payload"]) <= Router.PAYLOAD_MAX_BYTES, str(heavy))

	sent.clear()
	var control_heavy := "\u001b".repeat(40000)
	var control_payload := {"chat_id": "c1", "message_index": 1, "role": "assistant",
		"text": control_heavy, "outcome": "ok"}
	var control: Dictionary = router.publish(TURN, control_payload)
	var wire_size := -1
	if sent.size() == 1:
		var notification := {"jsonrpc": "2.0", "method": "minerva/host_event",
			"params": {"event": TURN, "payload": sent[0]["payload"]}}
		wire_size = str(load(JSON_SERIALIZATION_PATH).encode(notification).raw).to_utf8_buffer().size()
	check("A16b: raw control characters (6 wire bytes each) deliver truncated within the wire limit",
		_list(control["delivered"]) == ["sub"] and sent.size() == 1
			and sent[0]["payload"]["truncated"] == true
			and wire_size > 0 and wire_size <= 64 * 1024, "wire=%d %s" % [wire_size, str(control)])

	var notices: Array = []
	var modern = _definition("modern", [TURN])
	policy.grant_capability("modern", TURN_GRANT)
	var refusing = load(ROUTER_PATH).new(policy, audit, func() -> Array: return [modern], send,
		func(message: String) -> void: notices.append(message))
	refusing.plugin_started(modern, false)
	sent.clear()
	refusing.publish(TURN, payload)
	refusing.publish(TURN, payload)
	check("A17: a plugin whose protocol cannot carry host events is refused once, loudly",
		notices.size() == 1 and _audit_reason(audit, "modern", "capability_denied", "host_events")
			== Router.REASON_PROTOCOL_UNSUPPORTED
			and audit.get_entries("modern", "capability_denied").size() == 1, str(notices))
	check("A18: and is skipped at delivery without further audit",
		sent.is_empty() and audit.get_entries("modern", "capability_failed").is_empty())
	refusing.plugin_started(modern, true)
	refusing.publish(TURN, payload)
	check("A19: a restart on a protocol that carries them clears the refusal", sent.size() == 1)
	refusing.plugin_started(_definition("quiet", []), false)
	check("A20: a plugin that declares no host events is not refused", notices.size() == 1)


func _definition(id: String, events: Array):
	var def = load(DEFINITION_PATH).new(id)
	for event in events:
		def.host_events.append(event)
	return def


## The reason of the newest `event_type` entry for `plugin_id` whose capability
## is `key`: "" for an entry without one, "<none>" when there is no entry.
func _audit_reason(audit, plugin_id: String, event_type: String, key: String) -> String:
	for entry: Dictionary in audit.get_entries(plugin_id, event_type):
		if entry["detail"].get("capability", "") == key:
			return str(entry["detail"].get("reason", ""))
	return "<none>"

#endregion


#region P — turn payloads

func _test_payloads() -> void:
	print("\n-- P: ChatEventPayloads --")
	var Payloads = load(PAYLOADS_PATH)
	var Item = load(CHAT_HISTORY_ITEM_PATH)
	var history = _make_history("Payloads")
	var user_item = _item(Item, Item.ChatRole.USER, "the user's prompt")
	var reply = _item(Item, Item.ChatRole.MODEL, "Checking.\n\n{{TOOL_BLOCK:2}}\n\nDone.")
	var tool_item = _item(Item, Item.ChatRole.TOOL, "raw tool output")
	for entry in [user_item, reply, tool_item]:
		history.HistoryItemList.append(entry)

	var payload: Dictionary = Payloads.turn_completed(history, reply, "error")
	check("P1: with a TOOL item newest, the event carries the reply, not tool content",
		payload["role"] == "assistant" and payload["message_index"] == 1
			and not str(payload["text"]).contains("raw tool output")
			and str(payload["text"]).begins_with("Checking."), str(payload))
	check("P2: tool-block placeholders are not part of the text",
		not str(payload["text"]).contains("TOOL_BLOCK"), str(payload["text"]))
	var none: Dictionary = Payloads.turn_completed(history, null, "cancelled")
	check("P3: a turn with no reply sends no user content: empty text, index -1, role assistant",
		none["text"] == "" and none["message_index"] == -1 and none["role"] == "assistant")

	var errored = _item(Item, Item.ChatRole.MODEL, "")
	errored.Error = "boom"
	check("P4: termination_reason cancelled outranks an errored reply",
		Payloads.resolve_outcome("", "cancelled", errored) == "cancelled")
	check("P5: error and quota_exhausted terminations are errors",
		Payloads.resolve_outcome("", "error", reply) == "error"
			and Payloads.resolve_outcome("", "quota_exhausted", reply) == "error")
	check("P6: an explicit stop outranks every termination reason",
		Payloads.resolve_outcome("cancelled", "error", reply) == "cancelled")
	check("P7: no reply (a null provider response) is an error",
		Payloads.resolve_outcome("", "", null) == "error")
	check("P8: an errored reply is an error; a clean one is ok",
		Payloads.resolve_outcome("", "completed", errored) == "error"
			and Payloads.resolve_outcome("", "completed", reply) == "ok")


func _item(Item, role: int, message: String):
	var item = Item.new()
	item._suppress_save_state = true
	item.Role = role
	item.Message = message
	return item

#endregion


#region B — manifest

func _test_manifest() -> void:
	print("\n-- B: manifest permissions.host_events --")
	var Definition = load(DEFINITION_PATH)
	var manifest := {
		"id": "events_manifest", "name": "Events", "version": "0.1.0",
		"backend": {"transport": "stdio", "entrypoint": "python3", "args": []},
		"permissions": {"host_capabilities": [], "host_events": [TURN, DIRECTORY]},
	}
	var def = Definition.from_dict(manifest)
	check("B1: host_events is parsed", def != null and _list(def.host_events) == [TURN, DIRECTORY])
	check("B2: known events validate", not _has_host_event_error(def.validate()), str(def.validate()))
	check("B3: host_events round-trips through to_dict",
		_list(def.to_dict()["permissions"]["host_events"]) == [TURN, DIRECTORY])
	check("B4: each declared event maps to its grant key",
		_list(def.host_event_grants()) == [TURN_GRANT, DIRECTORY_GRANT])

	manifest["permissions"]["host_events"] = [TURN, "chat.bogus"]
	var bad = Definition.from_dict(manifest)
	var errors: Array = bad.validate()
	check("B5: an unknown event name fails validation", _has_host_event_error(errors, "chat.bogus"), str(errors))


func _has_host_event_error(errors: Array, event: String = "") -> bool:
	for message in errors:
		if str(message).contains("host_event") and str(message).contains(event):
			return true
	return false

#endregion


#region C — turn events end to end

func _start_fixtures() -> bool:
	print("\n-- C: fixture plugins --")
	var pm = _so.plugin_manager
	var policy = _so.plugin_policy
	var fixtures := ProjectSettings.globalize_path("res://test/fixtures")
	for id in [SUBSCRIBER, UNGRANTED, UNDECLARED]:
		if pm.get_db().get_by_id(id) != null:
			await pm.stop_plugin(id)
			await pm.remove_plugin(id, false)
		var installed: Dictionary = await pm.install_plugin(fixtures.path_join(id).path_join("manifest.json"), true)
		check("%s installs" % id, installed.get("ok", false) == true, str(installed))
	check("C0: install grants the declared host events",
		policy.is_capability_granted(SUBSCRIBER, TURN_GRANT)
			and policy.is_capability_granted(SUBSCRIBER, DIRECTORY_GRANT))
	check("C0: the Plugin Manager lists them as requested capabilities",
		policy.get_requested_capabilities(SUBSCRIBER).has(TURN_GRANT))
	policy.revoke_capability(UNGRANTED, TURN_GRANT)
	policy.revoke_capability(UNGRANTED, DIRECTORY_GRANT)
	policy.revoke_capability(UNDECLARED, TURN_GRANT)
	for id in [SUBSCRIBER, UNGRANTED, UNDECLARED]:
		var started: Dictionary = await pm.start_plugin(id)
		check("%s starts" % id, started.get("ok", false) == true, str(started))
		if pm.get_connection(id) == null:
			return false
	return true


func _test_turn_events() -> void:
	print("\n-- C: chat.turn_completed --")
	var visible_chat = _make_history("Visible")
	var target = _make_history("Target")
	var pane = _make_harness_pane([visible_chat, target])
	var previous_chats = _so.Chats
	_so.Chats = pane
	_so._wire_chat_host_events()
	_so.Chats = null
	_so.Chats = pane
	pane.current_tab = 0
	for id in [SUBSCRIBER, UNGRANTED, UNDECLARED]:
		await _probe(id, "probe_clear")
	var audit = _so.plugin_audit_log
	var undeclared_denials_before: int = audit.get_entries(UNDECLARED, "capability_denied", 1000).size()
	var Utils = load(TOOL_UTILS_PATH)

	var receipt: Dictionary = Utils.submit_user_message(target, "hello")
	check("C1: the send to the hidden chat is accepted, not queued",
		receipt.get("success", false) and not receipt.get("queued", true), str(receipt))
	await _until_idle(target)
	check("C2: the visible chat stayed on screen", pane.current_tab == 0)
	var turns: Array = await _events(SUBSCRIBER, TURN)
	check("C3: the subscriber received exactly one chat.turn_completed, though the pane was wired repeatedly",
		turns.size() == 1, str(turns))
	if turns.size() == 1:
		var message: Dictionary = turns[0]["message"]
		var payload: Dictionary = message["params"]["payload"]
		check("C4: it is a minerva/host_event JSON-RPC notification",
			message.get("jsonrpc") == "2.0" and message.get("method") == "minerva/host_event"
				and not message.has("id") and message["params"]["event"] == TURN)
		check("C5: payload names the hidden chat and carries the assistant text",
			payload["chat_id"] == str(target.HistoryId) and payload["text"] == "reply:hello"
				and payload["role"] == "assistant" and payload["outcome"] == "ok"
				and payload["truncated"] == false, str(payload))
		check("C6: payload keys are exactly the contract",
			_sorted_keys(payload) == ["chat_id", "message_index", "outcome", "role", "text", "truncated"],
			str(payload.keys()))
		check("C7: message_index is the reply's index, sent as a JSON integer",
			int(payload["message_index"]) == target.HistoryItemList.size() - 1
				and turns[0]["integer_keys"] == ["message_index"], str(turns[0]))
	check("C8: the ungranted plugin received nothing", (await _events(UNGRANTED, TURN)).is_empty())
	check("C9: its denial is in the audit log",
		_audit_reason(audit, UNGRANTED, "capability_denied", TURN_GRANT) == "capability_not_granted")
	check("C10: the undeclared, ungranted plugin received nothing and is not audited",
		(await _events(UNDECLARED, TURN)).is_empty()
			and audit.get_entries(UNDECLARED, "capability_denied", 1000).size() == undeclared_denials_before)

	_so.plugin_policy.grant_capability(UNDECLARED, TURN_GRANT)
	pane.errors["fail"] = "boom"
	Utils.submit_user_message(target, "fail")
	await _until_idle(target)
	_so.plugin_policy.revoke_capability(UNDECLARED, TURN_GRANT)
	turns = await _events(SUBSCRIBER, TURN)
	check("C11: an error turn emits one event with outcome=error",
		turns.size() == 2 and turns[1]["message"]["params"]["payload"]["outcome"] == "error", str(turns))
	check("C12: a granted but undeclared plugin still receives nothing",
		(await _events(UNDECLARED, TURN)).is_empty())
	check("C13: and that denial is audited as not_declared",
		_audit_reason(audit, UNDECLARED, "capability_denied", TURN_GRANT) == "not_declared")

	pane.hold["slow"] = true
	Utils.submit_user_message(target, "slow")
	await process_frame
	await process_frame
	check("C14: the held turn is in flight", target.is_request_active)
	pane._cancel_chat_turn(target)
	pane.hold.erase("slow")
	for i in 5:
		await process_frame
	turns = await _events(SUBSCRIBER, TURN)
	check("C15: a stopped turn emits exactly one event, outcome=cancelled, and its late release none",
		turns.size() == 3 and turns[2]["message"]["params"]["payload"]["outcome"] == "cancelled",
		str(turns))

	# A stopped turn whose provider resolves after the next turn began writes its
	# termination late; it must not decide the new turn's outcome.
	var outcomes: Array = []
	pane.chat_turn_completed.connect(func(payload: Dictionary) -> void: outcomes.append(payload["outcome"]))
	var token_a: int = pane._begin_chat_turn(target)
	pane._cancel_chat_turn(target)
	var token_b: int = pane._begin_chat_turn(target)
	pane._terminate_turn(target, token_a, "cancelled", "Request cancelled.")
	var Item = load(CHAT_HISTORY_ITEM_PATH)
	var reply_b = _item(Item, Item.ChatRole.MODEL, "reply:b")
	target.HistoryItemList.append(reply_b)
	pane._note_turn_reply(target, token_b, reply_b)
	pane._release_chat_turn(target, token_b)
	check("C19: a stopped turn's late termination does not decide the next turn's outcome",
		outcomes == ["cancelled", "ok"], str(outcomes))

	_so.Chats = previous_chats
	for history in [visible_chat, target]:
		_so.ChatList.erase(history)
	pane.queue_free()


## A send the real execute_regular_chat refuses (the chat already ends on an
## unanswered user message) starts no answer, so it reports no turn.
func _test_refused_send_is_silent() -> void:
	print("\n-- C: refused send --")
	var Item = load(CHAT_HISTORY_ITEM_PATH)
	var chat = _make_history("Refused")
	chat.HistoryItemList.append(_item(Item, Item.ChatRole.USER, "unanswered"))
	var pane = _make_harness_pane([chat], REAL_TURN_PANE_SRC)
	var previous_chats = _so.Chats
	_so.Chats = pane
	pane.current_tab = 0
	var emitted: Array = []
	pane.chat_turn_completed.connect(func(payload: Dictionary) -> void: emitted.append(payload))
	await _probe(SUBSCRIBER, "probe_clear")
	pane.execute_regular_chat("second question")
	await _until_idle(chat)
	check("C16: the send was refused before any request, and released its turn",
		not pane.reached_request and not chat.is_request_active)
	check("C17: and emitted no chat.turn_completed", emitted.is_empty(), str(emitted))
	check("C18: the subscriber received nothing", (await _events(SUBSCRIBER, TURN)).is_empty())
	_so.Chats = previous_chats
	_so.ChatList.erase(chat)
	pane.queue_free()


func _make_history(chat_name: String):
	var history = load(CHAT_HISTORY_PATH).new(null)
	history.HistoryName = chat_name
	return history


func _make_harness_pane(chats: Array, source: String = HARNESS_PANE_SRC):
	var script := GDScript.new()
	script.source_code = source
	script.reload()
	var pane = script.new()
	pane.name = "HostEventHarnessPane"
	root.add_child(pane)
	for history in chats:
		var scroll := ScrollContainer.new()
		pane.add_child(scroll)
		var vbox = load(VBOX_CHAT_PATH).new(pane)
		vbox.chat_history = history
		scroll.add_child(vbox)
		history.VBox = vbox
		_so.ChatList.append(history)
	return pane


func _until_idle(history) -> void:
	var deadline: int = Time.get_ticks_msec() + 5000
	await process_frame
	while history.is_request_active and Time.get_ticks_msec() < deadline:
		await process_frame
	await process_frame

#endregion


#region D — directory events

func _test_directory_events() -> void:
	print("\n-- D: chat.directory_changed --")
	var notes_script = load("res://Scenes/note/NotesContainer.gd")
	var previous_notes = [_so.notes_container, _so.drawer_notes_container]
	_so.notes_container = notes_script.new()
	_so.drawer_notes_container = notes_script.new()
	var chat_scene = load("res://Scenes/Chat.tscn").instantiate()
	root.add_child(chat_scene)
	await process_frame
	await process_frame
	var pane = chat_scene.find_child("tcChats", true, false)
	check("D0: the real chat pane is mounted and is SingletonObject.Chats",
		pane != null and _so.Chats == pane)
	if pane == null:
		return
	var seen: Array = []
	pane.chat_directory_changed.connect(func(payload: Dictionary) -> void: seen.append(payload))
	await _probe(SUBSCRIBER, "probe_clear")

	var history = load(CHAT_HISTORY_PATH).new(_so.API_MODEL_PROVIDER_SCRIPTS[_so.API_MODEL_PROVIDERS.NEMOTRON_NANO].new())
	history.HistoryName = "Directory probe"
	_so.ChatList.append(history)
	pane.render_history(history)
	var index: int = _so.ChatList.find(history)
	check("D1: creating a chat emits one created", _changes(seen) == ["created"], str(seen))

	seen.clear()
	check("D2: rename_chat succeeds", pane.rename_chat(index, "Renamed probe"))
	check("D3: renaming emits one renamed with the new name",
		_changes(seen) == ["renamed"] and seen[0]["name"] == "Renamed probe", str(seen))

	seen.clear()
	var gid: String = _so.chat_groups.create_group("Host events")
	pane.set_chat_group(history, gid)
	check("D4: regrouping emits one regrouped with the new group",
		_changes(seen) == ["regrouped"] and seen[0]["group_id"] == gid, str(seen))
	seen.clear()
	pane.set_chat_group(history, gid)
	check("D5: moving a chat to the group it is in emits nothing", seen.is_empty(), str(seen))

	pane.delete_chat(history)
	pane.restore_chat(history)
	check("D6: closing and restoring emit closed then restored",
		_changes(seen) == ["closed", "restored"] and seen[0]["group_id"] == gid
			and seen[0]["chat_id"] == str(history.HistoryId), str(seen))

	var delivered: Array = await _events(SUBSCRIBER, DIRECTORY)
	var delivered_changes: Array = []
	for entry: Dictionary in delivered:
		delivered_changes.append(entry["message"]["params"]["payload"]["change"])
	check("D7: the subscriber received each change once, in order",
		delivered_changes == ["created", "renamed", "regrouped", "closed", "restored"], str(delivered_changes))
	check("D8: the ungranted plugin received none", (await _events(UNGRANTED, DIRECTORY)).is_empty())

	_so.ChatList.erase(history)
	chat_scene.queue_free()
	_so.notes_container.free()
	_so.drawer_notes_container.free()
	_so.notes_container = previous_notes[0]
	_so.drawer_notes_container = previous_notes[1]


func _changes(payloads: Array) -> Array:
	var out: Array = []
	for payload: Dictionary in payloads:
		out.append(payload["change"])
	return out

#endregion


#region Probe access

func _probe(plugin_id: String, tool_name: String) -> Dictionary:
	var conn = _so.plugin_manager.get_connection(plugin_id)
	if conn == null:
		return {}
	var reply = await conn.call_tool(tool_name, {})
	return reply if reply is Dictionary else {}


## Received notifications of `event`, each {message, integer_keys} where
## integer_keys are the payload keys the plugin decoded as JSON integers.
func _events(plugin_id: String, event: String) -> Array:
	var reply: Dictionary = await _probe(plugin_id, "probe_events")
	var out: Array = []
	for entry in reply.get("events", []):
		if entry is Dictionary and entry["message"]["params"]["event"] == event:
			out.append(entry)
	return out


## An untyped copy, so typed and untyped arrays compare by content.
func _list(values: Array) -> Array:
	var out: Array = []
	out.append_array(values)
	return out


func _sorted_keys(payload: Dictionary) -> Array:
	var keys: Array = payload.keys()
	keys.sort()
	return keys

#endregion

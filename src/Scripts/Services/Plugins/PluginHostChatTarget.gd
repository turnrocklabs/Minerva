class_name PluginHostChatTarget
extends RefCounted
## host.chat.active and host.chat.input: a plugin follows the chat on screen and
## drives its input box the way the Stream Deck does (StreamDeckServer).
##
## Phase-1 surface (DCR minerva:01a12de939dd items 4-5), to be removed once
## plugins keep their own per-chat draft and send with minerva_send_message.
##
## The pane is reached through the injected lookup on each call, since the chat
## pane can be replaced, and only through its public methods. Refusals are also
## shown to the user through `notify`.

const CAPABILITY_ACTIVE := "host.chat.active"
const CAPABILITY_INPUT := "host.chat.input"

const ERROR_NO_CHAT_PANE := "chat_pane_unavailable"
const ERROR_CHAT_CHANGED := "chat_changed"
const ERROR_EMPTY_INPUT := "empty_input"
const ERROR_NOT_SENT := "not_sent"
const ERROR_PTT_BUSY := "minerva_ptt_active"
const ERROR_EXTERNAL_PTT_BUSY := "external_ptt_busy"
const ERROR_NO_MIC_BUTTON := "mic_button_unavailable"

## How long a submit waits for the pane's admit/drop outcome before reporting
## it as pending (still in progress, neither sent nor refused).
var submit_timeout_ms := 30000

## () -> ChatPane: the chat pane, or null.
var _chat_pane: Callable
## (message: String) -> void: shows the user a refusal.
var _notify: Callable
## () -> bool: whether Minerva's own push-to-talk is idle. While it is not,
## the mic button is Minerva's (AudioToTexts._set_ptt_state alone drives it).
var _minerva_ptt_idle: Callable
## () -> void, awaitable: resumes at the next frame.
var _next_frame: Callable
## The plugin whose external state the mic button shows, "" when none: its
## stop or crash must not leave the button frozen in that state, and no other
## plugin may overwrite it meanwhile.
var _external_ptt_owner := ""


func _init(chat_pane: Callable, notify: Callable, minerva_ptt_idle: Callable, next_frame: Callable) -> void:
	_chat_pane = chat_pane
	_notify = notify
	_minerva_ptt_idle = minerva_ptt_idle
	_next_frame = next_frame


func handle(plugin_id: String, capability: String, args: Dictionary) -> Dictionary:
	var pane: ChatPane = _chat_pane.call()
	if pane == null:
		return _error(plugin_id, ERROR_NO_CHAT_PANE, "The chat pane is not available")
	if capability == CAPABILITY_ACTIVE:
		return PluginErrors.success(pane.active_chat_payload())
	match str(args.get("op", "")):
		"append":
			if not (args.get("text") is String):
				return PluginErrors.schema_validation_failed(plugin_id, "append requires a string 'text'")
			return append_transcript(plugin_id, str(args.get("expected_chat_id", active_chat_id())), str(args.text))
		"clear":
			pane.set_user_input_text("")
			return PluginErrors.success({})
		"submit":
			var expected: Variant = args.get("expected_chat_id")
			if not (expected is String) or str(expected).is_empty():
				return PluginErrors.schema_validation_failed(plugin_id, "submit requires a string 'expected_chat_id'")
			return await _submit(plugin_id, pane, str(expected))
		"set_external_ptt_state":
			return _set_external_ptt_state(plugin_id, pane, str(args.get("state", "")))
	return PluginErrors.schema_validation_failed(plugin_id,
		"op must be one of append, clear, submit, set_external_ptt_state")


func active_chat_id() -> String:
	var pane: ChatPane = _chat_pane.call()
	var chat_id: Variant = pane.active_chat_payload().get("chat_id") if pane != null else null
	return chat_id if chat_id is String else ""


func set_external_state(plugin_id: String, state: String) -> Dictionary:
	var pane: ChatPane = _chat_pane.call()
	return _set_external_ptt_state(plugin_id, pane, state) if pane != null else _error(plugin_id, ERROR_NO_CHAT_PANE, "The chat pane is not available")


func append_transcript(plugin_id: String, expected_chat_id: String, text: String) -> Dictionary:
	var pane: ChatPane = _chat_pane.call()
	if pane == null:
		return _error(plugin_id, ERROR_NO_CHAT_PANE, "The chat pane is not available")
	if expected_chat_id.is_empty() or expected_chat_id != active_chat_id():
		return _refuse(plugin_id, ERROR_CHAT_CHANGED, "Not appended: the visible chat changed during microphone input.")
	pane.set_user_input_text(pane.get_user_input_text() + text)
	return PluginErrors.success({"text": text})


## Call when a plugin stops or crashes: a button left showing its state is
## returned to ready.
func plugin_stopped(plugin_id: String) -> void:
	_release_external_ptt(plugin_id)


func capability_revoked(plugin_id: String, capability: String) -> void:
	if capability == CAPABILITY_INPUT:
		_release_external_ptt(plugin_id)


func _release_external_ptt(plugin_id: String) -> void:
	if plugin_id.is_empty() or plugin_id != _external_ptt_owner:
		return
	_external_ptt_owner = ""
	var pane: ChatPane = _chat_pane.call()
	if pane != null and _minerva_ptt_idle.call():
		MicButtonBinding.show_external_state(pane.get_mic_button(), "idle")


## Posts the input box into the visible chat, only when that chat is the one
## the plugin's turn started on: posting into whichever chat the user switched
## to would send the words to the wrong conversation.
func _submit(plugin_id: String, pane: ChatPane, expected_chat_id: String) -> Dictionary:
	var visible: ServiceHistory = pane.current_chat()
	var visible_id := str(visible.HistoryId) if visible != null else ""
	if visible_id != expected_chat_id:
		return _refuse(plugin_id, ERROR_CHAT_CHANGED,
			"Not sent: the visible chat changed since this message was started (plugin '%s')." % plugin_id)
	var text: String = pane.get_user_input_text()
	if text.strip_edges().is_empty():
		return _refuse(plugin_id, ERROR_EMPTY_INPUT,
			"Not sent: the chat input is empty (plugin '%s')." % plugin_id)
	# The pane reports this send's outcome under the id submit_chat returns;
	# outcomes can arrive before it returns, so they are collected from before.
	var outcomes: Dictionary = {}
	var on_admitted := func(_history_id: String, admitted_send_id: int, queued: bool) -> void:
		outcomes[admitted_send_id] = {"queued": queued}
	var on_dropped := func(_history_id: String, dropped_send_id: int, reason: String) -> void:
		outcomes[dropped_send_id] = {"dropped": reason}
	pane.user_message_admitted.connect(on_admitted)
	pane.user_message_dropped.connect(on_dropped)
	var send_id: int = pane.submit_chat(0, plugin_id)
	var deadline: int = Time.get_ticks_msec() + submit_timeout_ms
	while not outcomes.has(send_id) and Time.get_ticks_msec() < deadline and is_instance_valid(pane):
		await _next_frame.call()
	if is_instance_valid(pane):
		pane.user_message_admitted.disconnect(on_admitted)
		pane.user_message_dropped.disconnect(on_dropped)
	if not outcomes.has(send_id):
		return PluginErrors.success({"chat_id": visible_id, "send_id": send_id, "status": "pending"})
	var outcome: Dictionary = outcomes[send_id]
	if outcome.has("dropped"):
		var refused := _refuse(plugin_id, ERROR_NOT_SENT, "Not sent (%s): the chat did not take the message (plugin '%s')." % [
			outcome["dropped"], plugin_id])
		refused["reason"] = outcome["dropped"]
		return refused
	return PluginErrors.success({"chat_id": visible_id, "send_id": send_id, "queued": outcome["queued"]})


func _set_external_ptt_state(plugin_id: String, pane: ChatPane, state: String) -> Dictionary:
	if not MicButtonBinding.EXTERNAL_STATES.has(state):
		return PluginErrors.schema_validation_failed(plugin_id,
			"state must be one of %s" % str(MicButtonBinding.EXTERNAL_STATES.keys()))
	if not _minerva_ptt_idle.call():
		# Finishing an external session releases its ownership even while the
		# local recorder owns the button; its visuals must remain untouched.
		if state == "idle" and _external_ptt_owner == plugin_id:
			_external_ptt_owner = ""
			return PluginErrors.success({"state": state})
		return _error(plugin_id, ERROR_PTT_BUSY,
			"Minerva's own push-to-talk is in use; the mic button shows that session.")
	if not _external_ptt_owner.is_empty() and _external_ptt_owner != plugin_id:
		return _error(plugin_id, ERROR_EXTERNAL_PTT_BUSY,
			"Plugin '%s' is showing its push-to-talk state on the mic button." % _external_ptt_owner)
	if not MicButtonBinding.show_external_state(pane.get_mic_button(), state):
		return _error(plugin_id, ERROR_NO_MIC_BUTTON, "The chat pane has no mic button")
	_external_ptt_owner = "" if state == "idle" else plugin_id
	return PluginErrors.success({"state": state})


func _refuse(plugin_id: String, code: String, message: String) -> Dictionary:
	if _notify.is_valid():
		_notify.call(message)
	return _error(plugin_id, code, message)


static func _error(plugin_id: String, code: String, message: String) -> Dictionary:
	return {"success": false, "error_code": code, "error_message": message, "plugin_id": plugin_id}

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

## () -> ChatPane: the chat pane, or null.
var _chat_pane: Callable
## (message: String) -> void: shows the user a refusal.
var _notify: Callable
## () -> bool: whether Minerva's own push-to-talk is idle. While it is not,
## the mic button is Minerva's (AudioToTexts._set_ptt_state alone drives it).
var _minerva_ptt_idle: Callable
## The plugin whose external state the mic button shows, "" when none: its
## stop or crash must not leave the button frozen in that state.
var _external_ptt_owner := ""


func _init(chat_pane: Callable, notify: Callable, minerva_ptt_idle: Callable) -> void:
	_chat_pane = chat_pane
	_notify = notify
	_minerva_ptt_idle = minerva_ptt_idle


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
			pane.set_user_input_text(pane.get_user_input_text() + str(args["text"]))
			return PluginErrors.success({})
		"clear":
			pane.set_user_input_text("")
			return PluginErrors.success({})
		"submit":
			var expected: Variant = args.get("expected_chat_id")
			if not (expected is String) or str(expected).is_empty():
				return PluginErrors.schema_validation_failed(plugin_id, "submit requires a string 'expected_chat_id'")
			return _submit(plugin_id, pane, str(expected))
		"set_external_ptt_state":
			return _set_external_ptt_state(plugin_id, pane, str(args.get("state", "")))
	return PluginErrors.schema_validation_failed(plugin_id,
		"op must be one of append, clear, submit, set_external_ptt_state")


## Call when a plugin stops or crashes: a button left showing its state is
## returned to ready.
func plugin_stopped(plugin_id: String) -> void:
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
	var was_busy: bool = visible.is_request_active
	pane.submit_chat(0)
	# The pane empties the input box exactly when it takes the message; an early
	# return (an account prompt the user declined, say) leaves it in place.
	if pane.get_user_input_text() == text:
		return _refuse(plugin_id, ERROR_NOT_SENT,
			"Not sent: the chat did not accept the message (plugin '%s')." % plugin_id)
	return PluginErrors.success({"chat_id": visible_id, "queued": was_busy})


func _set_external_ptt_state(plugin_id: String, pane: ChatPane, state: String) -> Dictionary:
	if not MicButtonBinding.EXTERNAL_STATES.has(state):
		return PluginErrors.schema_validation_failed(plugin_id,
			"state must be one of %s" % str(MicButtonBinding.EXTERNAL_STATES.keys()))
	if not _minerva_ptt_idle.call():
		return _error(plugin_id, ERROR_PTT_BUSY,
			"Minerva's own push-to-talk is in use; the mic button shows that session.")
	if not MicButtonBinding.show_external_state(pane.get_mic_button(), state):
		return _error(plugin_id, ERROR_NO_CHAT_PANE, "The chat pane has no mic button")
	_external_ptt_owner = "" if state == "idle" else plugin_id
	return PluginErrors.success({"state": state})


func _refuse(plugin_id: String, code: String, message: String) -> Dictionary:
	if _notify.is_valid():
		_notify.call(message)
	return _error(plugin_id, code, message)


static func _error(plugin_id: String, code: String, message: String) -> Dictionary:
	return {"success": false, "error_code": code, "error_message": message, "plugin_id": plugin_id}

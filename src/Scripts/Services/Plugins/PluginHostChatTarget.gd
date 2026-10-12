class_name PluginHostChatTarget
extends RefCounted
## host.chat.active and host.chat.input: a plugin follows the chat on screen and
## drives its input box the way the Stream Deck does (StreamDeckServer).
##
## Phase-1 surface (DCR minerva:01a12de939dd items 4-5), to be removed once
## plugins keep their own per-chat draft and send with minerva_send_message.
##
## The pane is reached through the injected lookup each call, since the chat
## pane can be replaced; it is used only through its public methods
## (current_chat, active_chat_payload, get/set_user_input_text, submit_chat,
## get_mic_button). Refusals are also shown to the user through `notify`.

const CAPABILITY_ACTIVE := "host.chat.active"
const CAPABILITY_INPUT := "host.chat.input"

const ERROR_NO_CHAT_PANE := "chat_pane_unavailable"
const ERROR_CHAT_CHANGED := "chat_changed"
const ERROR_EMPTY_INPUT := "empty_input"

## () -> ChatPane: the chat pane, or null.
var _chat_pane: Callable
## (message: String) -> void: shows the user a refusal.
var _notify: Callable


func _init(chat_pane: Callable, notify: Callable) -> void:
	_chat_pane = chat_pane
	_notify = notify


func handle(plugin_id: String, capability: String, args: Dictionary) -> Dictionary:
	var pane: ChatPane = _chat_pane.call()
	if pane == null:
		return _error(plugin_id, ERROR_NO_CHAT_PANE, "The chat pane is not available")
	if capability == CAPABILITY_ACTIVE:
		return PluginErrors.success(pane.active_chat_payload())
	match str(args.get("op", "")):
		"append":
			pane.set_user_input_text(pane.get_user_input_text() + str(args.get("text", "")))
			return PluginErrors.success({})
		"clear":
			pane.set_user_input_text("")
			return PluginErrors.success({})
		"submit":
			return _submit(plugin_id, pane, str(args.get("expected_chat_id", "")))
		"set_external_ptt_state":
			var state := str(args.get("state", ""))
			if not MicButtonBinding.show_external_state(pane.get_mic_button(), state):
				return PluginErrors.schema_validation_failed(plugin_id,
					"state must be one of %s (and the mic button must exist)" % str(MicButtonBinding.EXTERNAL_STATES.keys()))
			return PluginErrors.success({"state": state})
	return PluginErrors.schema_validation_failed(plugin_id,
		"op must be one of append, clear, submit, set_external_ptt_state")


## Posts the input box into the visible chat, only when that chat is the one
## the plugin's turn started on: posting into whichever chat the user switched
## to would send the words to the wrong conversation.
func _submit(plugin_id: String, pane: ChatPane, expected_chat_id: String) -> Dictionary:
	var visible: ServiceHistory = pane.current_chat()
	var visible_id := str(visible.HistoryId) if visible != null else ""
	if expected_chat_id.is_empty() or visible_id != expected_chat_id:
		return _refuse(plugin_id, ERROR_CHAT_CHANGED,
			"Not sent: the visible chat changed since this message was started (plugin '%s')." % plugin_id)
	if pane.get_user_input_text().strip_edges().is_empty():
		return _refuse(plugin_id, ERROR_EMPTY_INPUT,
			"Not sent: the chat input is empty (plugin '%s')." % plugin_id)
	pane.submit_chat(0)
	return PluginErrors.success({"chat_id": visible_id})


func _refuse(plugin_id: String, code: String, message: String) -> Dictionary:
	if _notify.is_valid():
		_notify.call(message)
	return _error(plugin_id, code, message)


static func _error(plugin_id: String, code: String, message: String) -> Dictionary:
	return {"success": false, "error_code": code, "error_message": message, "plugin_id": plugin_id}

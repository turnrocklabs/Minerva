class_name ChatEventPayloads
extends RefCounted
## Plain-value payloads for ChatPane's chat_turn_completed,
## chat_directory_changed and chat_active_changed signals. The turn's end
## points decide the outcome and the reply; this class only resolves their
## precedence and shapes the payload.

const OUTCOME_OK := "ok"
const OUTCOME_ERROR := "error"
const OUTCOME_CANCELLED := "cancelled"

const CHANGE_CREATED := "created"
const CHANGE_RENAMED := "renamed"
const CHANGE_REGROUPED := "regrouped"
const CHANGE_CLOSED := "closed"
const CHANGE_RESTORED := "restored"

## termination_reason values that end a turn as a failure.
const ERROR_TERMINATIONS := ["error", "quota_exhausted", "unsupported_operation_loop"]

## The renderer's placeholders for tool-call blocks inside a reply's Message.
static var _tool_block_marker := RegEx.create_from_string(r"\{\{TOOL_BLOCK:\d+\}\}")


## What one in-flight turn will report when it ends. ChatPane records it where
## the turn's reply is produced and consumes it once, at the turn's end.
class TurnReport:
	var token: int
	## The assistant reply this turn produced; null when it produced none.
	var reply: ChatHistoryItem = null
	## Set only by an explicit stop; it outranks everything else.
	var outcome: String = ""
	## This turn's termination_reason, recorded under its own token.
	var termination: String = ""
	## A Human-provider pseudo-turn or a refused send: no event at all.
	var silent: bool = false
	## Captured at submit and carried through the FIFO, never inferred from focus.
	var origin: Dictionary = {}

	func _init(p_token: int) -> void:
		token = p_token


## Precedence: an explicit stop, then the turn's termination_reason, then the
## reply itself (none, or one carrying an error, is a failure).
static func resolve_outcome(noted: String, termination_reason: String, reply: ChatHistoryItem) -> String:
	if not noted.is_empty():
		return noted
	if termination_reason == OUTCOME_CANCELLED:
		return OUTCOME_CANCELLED
	if ERROR_TERMINATIONS.has(termination_reason):
		return OUTCOME_ERROR
	if reply == null or not reply.Error.is_empty():
		return OUTCOME_ERROR
	return OUTCOME_OK


## `reply` is the turn's assistant reply or null; the payload never carries user
## or tool content. message_index is the reply's index in the chat, or -1.
## Core (HCP) replies carry only structured HcpData with no plain-text form, so
## their text is empty.
static func turn_completed(history: ServiceHistory, reply: ChatHistoryItem, outcome: String, origin: Dictionary = {}) -> Dictionary:
	var text := ""
	if reply != null:
		text = _tool_block_marker.sub(reply.Message, "", true).strip_edges()
	return {
		"chat_id": str(history.HistoryId),
		"message_index": history.HistoryItemList.find(reply) if reply != null else -1,
		"role": "assistant",
		"text": text,
		"outcome": outcome,
		"plugin_id": str(origin.get("plugin_id", "")),
		"send_id": int(origin.get("send_id", 0)),
	}


## The visible chat; chat_id is null when none is on screen. `group_id` is the
## chat's effective group ("" when ungrouped) and `group` its name.
static func active_chat(history: ServiceHistory, group_id: String, group_name: String) -> Dictionary:
	if history == null:
		return {"chat_id": null, "name": "", "group_id": "", "group": ""}
	return {
		"chat_id": str(history.HistoryId),
		"name": str(history.HistoryName),
		"group_id": group_id,
		"group": group_name,
	}


## `group_id` is the chat's group membership (a closed chat's is parked in
## PreDeleteGroupId); the caller passes it because ChatPane owns that rule.
static func directory_changed(history: ServiceHistory, change: String, group_id: String) -> Dictionary:
	return {
		"chat_id": str(history.HistoryId),
		"change": change,
		"name": str(history.HistoryName),
		"group_id": group_id,
	}

class_name ChatEventPayloads
extends RefCounted
## Plain-value payloads for ChatPane's chat_turn_completed and
## chat_directory_changed signals.

const OUTCOME_OK := "ok"
const OUTCOME_ERROR := "error"
const OUTCOME_CANCELLED := "cancelled"

const CHANGE_CREATED := "created"
const CHANGE_RENAMED := "renamed"
const CHANGE_REGROUPED := "regrouped"
const CHANGE_CLOSED := "closed"
const CHANGE_RESTORED := "restored"


## The turn that just ended on `history`, read from its newest item. A model
## reply without an error is "ok"; a reply with an error, or a turn that left
## no reply as the newest item (a failed request appends none), is "error";
## `cancelled` overrides both. message_index is -1 for an empty history.
static func turn_completed(history: ChatHistory, cancelled: bool) -> Dictionary:
	var index: int = history.HistoryItemList.size() - 1
	var last: ChatHistoryItem = history.HistoryItemList[index] if index >= 0 else null
	var is_reply: bool = last != null and (last.Role == ChatHistoryItem.ChatRole.MODEL
		or last.Role == ChatHistoryItem.ChatRole.ASSISTANT)
	var outcome := OUTCOME_OK if is_reply and last.Error.is_empty() else OUTCOME_ERROR
	if cancelled:
		outcome = OUTCOME_CANCELLED
	return {
		"chat_id": str(history.HistoryId),
		"message_index": index,
		"role": role_name(last),
		"text": last.Message if last != null else "",
		"outcome": outcome,
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


static func role_name(item: ChatHistoryItem) -> String:
	if item == null:
		return ""
	match item.Role:
		ChatHistoryItem.ChatRole.USER:
			return "user"
		ChatHistoryItem.ChatRole.MODEL, ChatHistoryItem.ChatRole.ASSISTANT:
			return "assistant"
		ChatHistoryItem.ChatRole.SYSTEM:
			return "system"
		ChatHistoryItem.ChatRole.TOOL:
			return "tool"
	return ""

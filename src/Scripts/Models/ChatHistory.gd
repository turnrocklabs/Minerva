class_name ChatHistory
extends ServiceHistory

## Centralized tool token lifecycle manager for this chat.
var tool_memory_manager: ToolMemoryManager

## Initialize with a new HistoryId
func _init(_provider, optional_historyId = null):
	service_type = ServiceType.CHAT
	super._init(_provider, optional_historyId)
	tool_memory_manager = ToolMemoryManager.new(self)


## True while this chat's last turn ended in a QUESTION that nobody has
## answered yet: the newest history item is a bot turn carrying the passthrough
## question options (the clickable card is rendered under it). The terminal
## agent behind the chat is blocked on that answer, and the human's next plain
## message IS the answer — so a background message must not take the chat's
## turn ahead of it. Cleared by the next turn, whatever answers the card.
func is_awaiting_question_answer() -> bool:
	if HistoryItemList.is_empty():
		return false
	var last: ChatHistoryItem = HistoryItemList[HistoryItemList.size() - 1]
	if last == null:
		return false
	if last.Role != ChatHistoryItem.ChatRole.MODEL \
			and last.Role != ChatHistoryItem.ChatRole.ASSISTANT:
		return false
	return last.HcpData.has("passthrough_question_options")

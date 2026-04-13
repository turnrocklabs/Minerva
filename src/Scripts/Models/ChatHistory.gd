class_name ChatHistory
extends ServiceHistory

## Centralized tool token lifecycle manager for this chat.
var tool_memory_manager: ToolMemoryManager

## Initialize with a new HistoryId
func _init(_provider, optional_historyId = null):
	service_type = ServiceType.CHAT
	super._init(_provider, optional_historyId)
	tool_memory_manager = ToolMemoryManager.new(self)

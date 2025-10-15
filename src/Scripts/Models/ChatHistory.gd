class_name ChatHistory
extends ServiceHistory

## Initialize with a new HistoryId
func _init(_provider, optional_historyId = null):
	service_type = ServiceType.CHAT
	super._init(_provider, optional_historyId)

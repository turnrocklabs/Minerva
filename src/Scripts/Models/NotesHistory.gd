class_name NotesServiceHistory
extends ServiceHistory

func _init(_provider, optional_historyId = null):
    service_type = ServiceType.NOTES
    super._init(_provider, optional_historyId)
class_name AutocoderKanbanDropZone
extends VBoxContainer

signal task_dropped(task: AutocoderTask, target_status: AutocoderTask.TaskStatus)
signal note_dropped(note: Note, target_status: AutocoderTask.TaskStatus)

@export var target_status: AutocoderTask.TaskStatus = AutocoderTask.TaskStatus.PLAN

var _is_drag_hovering: bool = false


func _ready():
	mouse_filter = Control.MOUSE_FILTER_PASS
	# Ensure drop zone always has minimum size so it can receive drops even when empty
	custom_minimum_size = Vector2(0, 100)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	# Accept task cards
	if data is Dictionary and data.get("type") == "task_card":
		var task = data.get("task") as AutocoderTask
		if task and task.status != target_status:
			_set_drag_highlight(true)
			return true
	
	# Accept Note objects - Notes return `self` from _get_drag_data
	if _is_note(data):
		_set_drag_highlight(true)
		return true
	
	_set_drag_highlight(false)
	return false


func _is_note(data: Variant) -> bool:
	# Direct class check
	if data is Note:
		return true
	# Duck-type check: Notes have uuid and title properties
	if data is Object and "uuid" in data and "title" in data:
		return true
	return false


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	_set_drag_highlight(false)
	
	# Handle task card drop
	if data is Dictionary and data.get("type") == "task_card":
		var task = data.get("task") as AutocoderTask
		if task:
			task_dropped.emit(task, target_status)
		return
	
	# Handle Note drop
	if _is_note(data):
		note_dropped.emit(data as Note, target_status)


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		_set_drag_highlight(false)


func _set_drag_highlight(highlight: bool):
	if _is_drag_hovering == highlight:
		return
	
	_is_drag_hovering = highlight
	
	# Visual feedback for drop target
	if highlight:
		modulate = Color(1.1, 1.1, 1.2, 1.0)
	else:
		modulate = Color(1.0, 1.0, 1.0, 1.0)

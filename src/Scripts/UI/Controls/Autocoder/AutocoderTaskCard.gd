class_name AutocoderTaskCard
extends PanelContainer

signal task_clicked(task: AutocoderTask)
signal task_move_requested(task: AutocoderTask, new_status: AutocoderTask.TaskStatus)
signal task_edit_requested(task: AutocoderTask)
signal task_delete_requested(task: AutocoderTask)

var task: AutocoderTask

@onready var _title_label: Label = %TitleLabel
@onready var _description_label: Label = %DescriptionLabel
@onready var _status_badge: Label = %StatusBadge
@onready var _model_label: Label = %ModelLabel
@onready var _files_label: Label = %FilesLabel
@onready var _actions_button: Button = %ActionsButton
@onready var _actions_menu: PopupMenu = %ActionsMenu

func _ready():
	if _actions_button:
		_actions_button.pressed.connect(_on_actions_button_pressed)
	if _actions_menu:
		_actions_menu.id_pressed.connect(_on_menu_item_selected)
	
	# Make card clickable
	gui_input.connect(_on_card_clicked)


# Drag and drop support
func _get_drag_data(_at_position: Vector2) -> Variant:
	if not task:
		return null
	
	# Create a preview of the card being dragged
	var preview = Label.new()
	preview.text = task.title
	preview.add_theme_color_override("font_color", Color(0.9, 0.9, 0.95))
	preview.add_theme_font_size_override("font_size", 12)
	
	var preview_panel = PanelContainer.new()
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0.2, 0.2, 0.25, 0.9)
	style.corner_radius_top_left = 6
	style.corner_radius_top_right = 6
	style.corner_radius_bottom_left = 6
	style.corner_radius_bottom_right = 6
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	preview_panel.add_theme_stylebox_override("panel", style)
	preview_panel.add_child(preview)
	
	set_drag_preview(preview_panel)
	
	return {"type": "task_card", "task": task, "source_card": self}

func setup(p_task: AutocoderTask):
	task = p_task
	_update_display()

func _update_display():
	if not task:
		return
	
	if _title_label:
		_title_label.text = task.title
	if _description_label:
		_description_label.text = task.description
	if _status_badge:
		_status_badge.text = task.get_status_name()
		_update_status_badge_color()
	if _model_label:
		if task.assigned_model.is_empty():
			_model_label.visible = false
		else:
			_model_label.visible = true
			_model_label.text = task.assigned_model
	if _files_label:
		if task.related_files.is_empty():
			_files_label.visible = false
		else:
			_files_label.visible = true
			_files_label.text = "%d file(s)" % task.related_files.size()

func _update_status_badge_color():
	if not _status_badge or not task:
		return
	
	var color: Color
	match task.status:
		AutocoderTask.TaskStatus.PLAN:
			color = Color(0.5, 0.7, 1.0)  # Blue
		AutocoderTask.TaskStatus.IN_PROGRESS:
			color = Color(0.95, 0.8, 0.3)  # Yellow
		AutocoderTask.TaskStatus.AI_REVIEW:
			color = Color(0.5, 0.9, 0.7)  # Green
		AutocoderTask.TaskStatus.HUMAN_REVIEW:
			color = Color(0.9, 0.6, 0.3)  # Orange
		AutocoderTask.TaskStatus.DONE:
			color = Color(0.6, 0.6, 0.65)  # Gray
		_:
			color = Color(0.6, 0.6, 0.65)
	
	_status_badge.add_theme_color_override("font_color", color)

func _on_card_clicked(event: InputEvent):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		task_clicked.emit(task)

func _on_actions_button_pressed():
	if not _actions_menu:
		return
	
	_actions_menu.clear()
	
	# Add "Move to..." options directly
	_actions_menu.add_item("Move to Plan", AutocoderTask.TaskStatus.PLAN)
	_actions_menu.add_item("Move to In Progress", AutocoderTask.TaskStatus.IN_PROGRESS)
	_actions_menu.add_item("Move to AI Review", AutocoderTask.TaskStatus.AI_REVIEW)
	_actions_menu.add_item("Move to Human Review", AutocoderTask.TaskStatus.HUMAN_REVIEW)
	_actions_menu.add_item("Move to Done", AutocoderTask.TaskStatus.DONE)
	
	_actions_menu.add_separator()
	_actions_menu.add_item("Edit", 100)
	_actions_menu.add_item("Delete", 101)
	
	# Show menu below button
	var button_rect = _actions_button.get_global_rect()
	var pos = Vector2i(int(button_rect.position.x), int(button_rect.position.y + button_rect.size.y))
	_actions_menu.popup(Rect2i(pos, Vector2i(200, 0)))

func _on_menu_item_selected(id: int):
	# Check if it's a move action (status enum values are 0-4)
	if id >= 0 and id <= 4:
		var new_status = id as AutocoderTask.TaskStatus
		if task and task.status != new_status:
			task_move_requested.emit(task, new_status)
	else:
		match id:
			100:  # Edit
				task_edit_requested.emit(task)
			101:  # Delete
				task_delete_requested.emit(task)

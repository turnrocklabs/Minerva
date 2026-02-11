class_name AutocoderKanbanBoard
extends Control

signal task_clicked(task: AutocoderTask)
signal task_move_requested(task: AutocoderTask, new_status: AutocoderTask.TaskStatus)
signal task_created_from_note(task: AutocoderTask, note: Note)

const TASK_CARD_SCENE = preload("res://Scripts/UI/Controls/Autocoder/AutocoderTaskCard.tscn")

var task_store: AutocoderTaskStore
@warning_ignore("unused_private_class_variable")
@onready var _scroll_container: ScrollContainer = %ScrollContainer
@warning_ignore("unused_private_class_variable")
@onready var _columns_container: HBoxContainer = %ColumnsContainer
@onready var _plan_column: VBoxContainer = %PlanColumn
@onready var _plan_list: AutocoderKanbanDropZone = %PlanList
@onready var _in_progress_column: VBoxContainer = %InProgressColumn
@onready var _in_progress_list: AutocoderKanbanDropZone = %InProgressList
@onready var _ai_review_column: VBoxContainer = %AIReviewColumn
@onready var _ai_review_list: AutocoderKanbanDropZone = %AIReviewList
@onready var _human_review_column: VBoxContainer = %HumanReviewColumn
@onready var _human_review_list: AutocoderKanbanDropZone = %HumanReviewList
@onready var _done_column: VBoxContainer = %DoneColumn
@onready var _done_list: AutocoderKanbanDropZone = %DoneList

func _ready():
	# Create task store if not provided
	if not task_store:
		task_store = AutocoderTaskStore.new()
	
	# Connect signals
	if task_store:
		if not task_store.task_added.is_connected(_on_task_added):
			task_store.task_added.connect(_on_task_added)
		if not task_store.task_updated.is_connected(_on_task_updated):
			task_store.task_updated.connect(_on_task_updated)
		if not task_store.task_moved.is_connected(_on_task_moved):
			task_store.task_moved.connect(_on_task_moved)
		if not task_store.task_deleted.is_connected(_on_task_deleted):
			task_store.task_deleted.connect(_on_task_deleted)
		# Connect store_changed for auto-save
		if not task_store.store_changed.is_connected(_on_store_changed):
			task_store.store_changed.connect(_on_store_changed)
	
	# Connect drop zone signals for drag and drop
	_connect_drop_zones()
	
	# Load saved state if session_id is set
	if task_store and not task_store.session_id.is_empty():
		_load_kanban_state()
	
	# Load initial tasks
	_refresh_all_columns()


func _connect_drop_zones():
	var drop_zones = [_plan_list, _in_progress_list, _ai_review_list, _human_review_list, _done_list]
	for zone in drop_zones:
		if zone:
			if not zone.task_dropped.is_connected(_on_task_dropped):
				zone.task_dropped.connect(_on_task_dropped)
			if not zone.note_dropped.is_connected(_on_note_dropped):
				zone.note_dropped.connect(_on_note_dropped)


func _on_task_dropped(task: AutocoderTask, new_status: AutocoderTask.TaskStatus):
	if task_store:
		task_store.move_task(task.id, new_status)
	task_move_requested.emit(task, new_status)


func _on_note_dropped(note: Note, target_status: AutocoderTask.TaskStatus):
	if not task_store or not note:
		return
	
	# Check if a task already exists for this note
	var existing_task = _find_task_by_note_uuid(note.uuid)
	if existing_task:
		# Ensure note is linked, then move existing task to the new status
		task_store.attach_note_to_task(existing_task.id, note.uuid, note.title, "attached")
		if existing_task.status != target_status:
			task_store.move_task(existing_task.id, target_status)
			print("[KanbanBoard] Moved existing task for note: %s -> %s" % [note.uuid, existing_task.id])
		else:
			print("[KanbanBoard] Task already in target column: %s" % existing_task.id)
		return
	
	# Extract title and content from note
	var title = note.title if note.title and not note.title.is_empty() else "Task from Note"
	var description = ""
	
	# Get text content from note
	var controls = note.get_controls_container()
	if controls and controls is NoteTextControls:
		description = controls.content
	elif controls and "content" in controls:
		description = str(controls.content)
	
	# Truncate description if too long
	if description.length() > 500:
		description = description.substr(0, 500) + "..."
	
	# Create task with source tracking
	var task = task_store.create_task(
		title,
		description,
		target_status,
		"",  # model
		2,   # priority
		AutocoderTask.SourceType.USER_NOTE,
		note.uuid,
		"Note: %s" % title
	)
	task.add_note_link(note.uuid, note.title, "created_from")
	
	task_created_from_note.emit(task, note)
	print("[KanbanBoard] Created task from note: %s -> %s" % [note.uuid, task.id])


func _find_task_by_source_uuid(source_uuid: String) -> AutocoderTask:
	if not task_store or source_uuid.is_empty():
		return null
	
	for task in task_store.get_all_tasks():
		if task.source_uuid == source_uuid:
			return task
	return null


func _find_task_by_note_uuid(note_uuid: String) -> AutocoderTask:
	if not task_store or note_uuid.is_empty():
		return null
	for task in task_store.get_all_tasks():
		if task.has_note_uuid(note_uuid):
			return task
		if task.source_uuid == note_uuid:
			return task
	return null

func set_task_store(store: AutocoderTaskStore):
	# Disconnect from old store
	if task_store:
		if task_store.task_added.is_connected(_on_task_added):
			task_store.task_added.disconnect(_on_task_added)
		if task_store.task_updated.is_connected(_on_task_updated):
			task_store.task_updated.disconnect(_on_task_updated)
		if task_store.task_moved.is_connected(_on_task_moved):
			task_store.task_moved.disconnect(_on_task_moved)
		if task_store.task_deleted.is_connected(_on_task_deleted):
			task_store.task_deleted.disconnect(_on_task_deleted)
		if task_store.store_changed.is_connected(_on_store_changed):
			task_store.store_changed.disconnect(_on_store_changed)
	
	task_store = store
	
	# Connect to new store
	if task_store:
		if not task_store.task_added.is_connected(_on_task_added):
			task_store.task_added.connect(_on_task_added)
		if not task_store.task_updated.is_connected(_on_task_updated):
			task_store.task_updated.connect(_on_task_updated)
		if not task_store.task_moved.is_connected(_on_task_moved):
			task_store.task_moved.connect(_on_task_moved)
		if not task_store.task_deleted.is_connected(_on_task_deleted):
			task_store.task_deleted.connect(_on_task_deleted)
		if not task_store.store_changed.is_connected(_on_store_changed):
			task_store.store_changed.connect(_on_store_changed)
		
		# NOTE: Don't auto-load here - let the caller decide when to load
		# Loading here causes infinite recursion when _load_kanban_state() calls set_task_store()
		
		_refresh_all_columns()

func _refresh_all_columns():
	_clear_all_columns()
	
	if not task_store:
		return
	
	# Load tasks for each column
	_add_tasks_to_column(_plan_list, task_store.get_tasks_by_status(AutocoderTask.TaskStatus.PLAN))
	_add_tasks_to_column(_in_progress_list, task_store.get_tasks_by_status(AutocoderTask.TaskStatus.IN_PROGRESS))
	_add_tasks_to_column(_ai_review_list, task_store.get_tasks_by_status(AutocoderTask.TaskStatus.AI_REVIEW))
	_add_tasks_to_column(_human_review_list, task_store.get_tasks_by_status(AutocoderTask.TaskStatus.HUMAN_REVIEW))
	_add_tasks_to_column(_done_list, task_store.get_tasks_by_status(AutocoderTask.TaskStatus.DONE))
	
	_update_column_counts()

func _clear_all_columns():
	_clear_column(_plan_list)
	_clear_column(_in_progress_list)
	_clear_column(_ai_review_list)
	_clear_column(_human_review_list)
	_clear_column(_done_list)

func _clear_column(column: Control):
	if not column:
		return
	for child in column.get_children():
		child.queue_free()

func _add_tasks_to_column(column: Control, tasks: Array[AutocoderTask]):
	if not column:
		return
	
	for task in tasks:
		var card = TASK_CARD_SCENE.instantiate()
		column.add_child(card)
		card.setup(task)
		card.task_clicked.connect(_on_task_card_clicked)
		card.task_move_requested.connect(_on_task_move_requested)
		card.task_edit_requested.connect(_on_task_edit_requested)
		card.task_delete_requested.connect(_on_task_delete_requested)
		card.note_dropped_on_card.connect(_on_note_dropped_on_card)
		card.note_link_removed.connect(_on_note_link_removed)

func _get_column_for_status(status: AutocoderTask.TaskStatus) -> AutocoderKanbanDropZone:
	match status:
		AutocoderTask.TaskStatus.PLAN:
			return _plan_list
		AutocoderTask.TaskStatus.IN_PROGRESS:
			return _in_progress_list
		AutocoderTask.TaskStatus.AI_REVIEW:
			return _ai_review_list
		AutocoderTask.TaskStatus.HUMAN_REVIEW:
			return _human_review_list
		AutocoderTask.TaskStatus.DONE:
			return _done_list
		_:
			return null

func _update_column_counts():
	# Update count badges in column headers
	_update_column_count(_plan_column, _plan_list, "Plan")
	_update_column_count(_in_progress_column, _in_progress_list, "In Progress")
	_update_column_count(_ai_review_column, _ai_review_list, "AI Review")
	_update_column_count(_human_review_column, _human_review_list, "Human Review")
	_update_column_count(_done_column, _done_list, "Done")

func _update_column_count(column: VBoxContainer, list: Control, _label_text: String):
	if not column or not list:
		return
	
	# Find the column panel and navigate to the count label
	var column_panel = column.get_node_or_null("ColumnPanel")
	if column_panel:
		var column_margin = column_panel.get_node_or_null("ColumnMargin")
		if column_margin:
			var column_content = column_margin.get_node_or_null("ColumnContent")
			if column_content:
				var header = column_content.get_node_or_null("Header")
				if header:
					var count_label = header.get_node_or_null("CountLabel")
					if count_label:
						count_label.text = "(%d)" % list.get_child_count()

func _on_task_added(task: AutocoderTask):
	var column = _get_column_for_status(task.status)
	if column:
		var card = TASK_CARD_SCENE.instantiate()
		column.add_child(card)
		card.setup(task)
		card.task_clicked.connect(_on_task_card_clicked)
		card.task_move_requested.connect(_on_task_move_requested)
		card.task_edit_requested.connect(_on_task_edit_requested)
		card.task_delete_requested.connect(_on_task_delete_requested)
		card.note_dropped_on_card.connect(_on_note_dropped_on_card)
		card.note_link_removed.connect(_on_note_link_removed)
		_update_column_counts()

func _on_task_updated(task: AutocoderTask):
	# Find and update the card
	for column in [_plan_list, _in_progress_list, _ai_review_list, _human_review_list, _done_list]:
		if not column:
			continue
		for child in column.get_children():
			if child is AutocoderTaskCard and child.task and child.task.id == task.id:
				child.setup(task)
				return

func _on_task_moved(task: AutocoderTask, old_status: AutocoderTask.TaskStatus, new_status: AutocoderTask.TaskStatus):
	# Remove from old column
	var old_column = _get_column_for_status(old_status)
	if old_column:
		for child in old_column.get_children():
			if child is AutocoderTaskCard and child.task and child.task.id == task.id:
				old_column.remove_child(child)
				child.queue_free()
				break
	
	# Add to new column
	var new_column = _get_column_for_status(new_status)
	if new_column:
		var card = TASK_CARD_SCENE.instantiate()
		new_column.add_child(card)
		card.setup(task)
		card.task_clicked.connect(_on_task_card_clicked)
		card.task_move_requested.connect(_on_task_move_requested)
		card.task_edit_requested.connect(_on_task_edit_requested)
		card.task_delete_requested.connect(_on_task_delete_requested)
		card.note_dropped_on_card.connect(_on_note_dropped_on_card)
		card.note_link_removed.connect(_on_note_link_removed)
	
	_update_column_counts()

func _on_task_deleted(task_id: String):
	# Find and remove the card from any column
	for column in [_plan_list, _in_progress_list, _ai_review_list, _human_review_list, _done_list]:
		if not column:
			continue
		for child in column.get_children():
			if child is AutocoderTaskCard and child.task and child.task.id == task_id:
				column.remove_child(child)
				child.queue_free()
				_update_column_counts()
				return

func _on_task_card_clicked(task: AutocoderTask):
	task_clicked.emit(task)

func _on_task_move_requested(task: AutocoderTask, new_status: AutocoderTask.TaskStatus):
	if task_store:
		task_store.move_task(task.id, new_status)
	task_move_requested.emit(task, new_status)

func _on_task_edit_requested(task: AutocoderTask):
	if not task:
		return
	
	# Open the Editor with task content
	if not SingletonObject.editor_pane:
		push_error("[KanbanBoard] editor_pane not available")
		return
	
	# Create task content for the editor
	var content = "# %s\n\n" % task.title
	content += "**Status:** %s\n" % task.get_status_name()
	content += "**Priority:** %d\n" % task.priority
	if not task.assigned_model.is_empty():
		content += "**Model:** %s\n" % task.assigned_model
	content += "**Created:** %s\n" % task.created_at
	content += "**Updated:** %s\n\n" % task.updated_at
	content += "## Description\n\n%s\n" % task.description
	
	if task.related_files.size() > 0:
		content += "\n## Related Files\n"
		for file in task.related_files:
			content += "- %s\n" % file
	
	if task.note_links.size() > 0:
		content += "\n## Attached Notes\n"
		for link in task.note_links:
			if link is Dictionary:
				content += "- %s (%s)\n" % [link.get("title", "Untitled"), link.get("relation", "")]
	
	# Create a new text editor with the task content
	var editor: Editor = SingletonObject.editor_pane.add(
		Editor.Type.TEXT,
		null,
		"Task: %s" % task.title.substr(0, 30)
	)
	
	if editor and editor.code_edit:
		editor.code_edit.text = content
		editor.set_meta("task_id", task.id)
		print("[KanbanBoard] Opened editor for task: %s" % task.id)

func _on_task_delete_requested(task: AutocoderTask):
	if task_store:
		task_store.delete_task(task.id)


func _on_note_dropped_on_card(note: Note, card: AutocoderTaskCard) -> void:
	if not task_store or not note or not card or not card.task:
		return
	task_store.attach_note_to_task(card.task.id, note.uuid, note.title, "attached")
	print("[KanbanBoard] Attached note %s to task %s" % [note.uuid, card.task.id])


func _on_note_link_removed(task: AutocoderTask, note_uuid: String) -> void:
	if not task_store or not task:
		return
	# Trigger store change to save the updated task (empty dict just triggers save)
	task_store.update_task(task.id, {"updated_at": Time.get_datetime_string_from_system()})
	print("[KanbanBoard] Removed note link %s from task %s" % [note_uuid, task.id])

# ============================================================================
# Save/Load Functionality
# ============================================================================

func _on_store_changed():
	"""Auto-save when store changes (debounced)"""
	if task_store and not task_store.session_id.is_empty():
		# Debounce saves to avoid excessive disk writes
		_save_kanban_state_debounced()

var _save_timer: Timer = null

func _save_kanban_state_debounced():
	"""Debounced save to avoid excessive writes"""
	if not _save_timer:
		_save_timer = Timer.new()
		_save_timer.wait_time = 1.0  # Wait 1 second after last change
		_save_timer.one_shot = true
		_save_timer.timeout.connect(_save_kanban_state)
		add_child(_save_timer)
	
	_save_timer.stop()
	_save_timer.start()

func _save_kanban_state():
	"""Save kanban board state to disk"""
	if not task_store:
		return
	
	var save_path = _get_save_path()
	#var save_dir = save_path.get_base_dir()
	
	# Ensure directory exists
	var dir = DirAccess.open("user://")
	if not dir:
		push_error("[KanbanBoard] Failed to open user:// directory")
		return
	
	# Create autocoder_kanban directory if it doesn't exist
	var kanban_dir = "user://autocoder_kanban"
	if not dir.dir_exists(kanban_dir):
		var error = dir.make_dir(kanban_dir)
		if error != OK:
			push_error("[KanbanBoard] Failed to create save directory: %d" % error)
			return
	
	# Serialize and save
	var data = task_store.serialize()
	var json_string = JSON.stringify(data, "  ")
	
	var file = FileAccess.open(save_path, FileAccess.WRITE)
	if file:
		file.store_string(json_string)
		file.close()
		print("[KanbanBoard] Saved state to: ", save_path)
	else:
		push_error("[KanbanBoard] Failed to open file for writing: ", save_path)

func _load_kanban_state():
	"""Load kanban board state from disk"""
	if not task_store:
		return
	
	var save_path = _get_save_path()
	if not FileAccess.file_exists(save_path):
		print("[KanbanBoard] No saved state found at: ", save_path)
		return
	
	var file = FileAccess.open(save_path, FileAccess.READ)
	if not file:
		push_error("[KanbanBoard] Failed to open saved state file: ", save_path)
		return
	
	var json_text = file.get_as_text()
	file.close()
	
	var json = JSON.new()
	var parse_result = json.parse(json_text)
	if parse_result != OK:
		push_error("[KanbanBoard] Failed to parse saved state JSON: ", json.get_error_message())
		return
	
	var data = json.get_data()
	if not data is Dictionary:
		push_error("[KanbanBoard] Saved state is not a dictionary")
		return
	
	# Deserialize and restore
	var loaded_store = AutocoderTaskStore.deserialize(data)
	
	# Replace current store (this will trigger _refresh_all_columns)
	set_task_store(loaded_store)
	print("[KanbanBoard] Loaded state from: ", save_path)


func load_saved_state() -> void:
	"""Public helper to load saved state after session_id is assigned"""
	if task_store and task_store.session_id.is_empty():
		return
	_load_kanban_state()
	_refresh_all_columns()

func _get_save_path() -> String:
	"""Get file path for saving kanban state"""
	var session_id = task_store.session_id if task_store else ""
	if session_id.is_empty():
		session_id = "default"
	
	return "user://autocoder_kanban/%s.json" % session_id

func save_kanban_state_now():
	"""Force immediate save (for manual save button or on close)"""
	_save_kanban_state()

class_name AutocoderKanbanBoard
extends Control

signal task_clicked(task: AutocoderTask)
signal task_move_requested(task: AutocoderTask, new_status: AutocoderTask.TaskStatus)

const TASK_CARD_SCENE = preload("res://Scripts/UI/Controls/Autocoder/AutocoderTaskCard.tscn")

var task_store: AutocoderTaskStore

@onready var _scroll_container: ScrollContainer = %ScrollContainer
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
	task_store.task_added.connect(_on_task_added)
	task_store.task_updated.connect(_on_task_updated)
	task_store.task_moved.connect(_on_task_moved)
	task_store.task_deleted.connect(_on_task_deleted)
	
	# Connect drop zone signals for drag and drop
	_connect_drop_zones()
	
	# Load initial tasks
	_refresh_all_columns()


func _connect_drop_zones():
	if _plan_list:
		_plan_list.task_dropped.connect(_on_task_dropped)
	if _in_progress_list:
		_in_progress_list.task_dropped.connect(_on_task_dropped)
	if _ai_review_list:
		_ai_review_list.task_dropped.connect(_on_task_dropped)
	if _human_review_list:
		_human_review_list.task_dropped.connect(_on_task_dropped)
	if _done_list:
		_done_list.task_dropped.connect(_on_task_dropped)


func _on_task_dropped(task: AutocoderTask, new_status: AutocoderTask.TaskStatus):
	if task_store:
		task_store.move_task(task.id, new_status)
	task_move_requested.emit(task, new_status)

func set_task_store(store: AutocoderTaskStore):
	task_store = store
	if task_store:
		task_store.task_added.connect(_on_task_added)
		task_store.task_updated.connect(_on_task_updated)
		task_store.task_moved.connect(_on_task_moved)
		task_store.task_deleted.connect(_on_task_deleted)
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

func _update_column_count(column: VBoxContainer, list: Control, label_text: String):
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
	
	_update_column_counts()

func _on_task_deleted(task_id: String):
	# Find and remove the card from any column
	for column in [_plan_list, _in_progress_list, _ai_review_list, _human_review_list, _done_list]:
		if not column:
			continue
		for child in column.get_children():
			if child is AutocoderTaskCard and child.task and child.task.id == task_id:
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
	# TODO: Show edit dialog
	print("Edit task: ", task.title)

func _on_task_delete_requested(task: AutocoderTask):
	if task_store:
		task_store.delete_task(task.id)

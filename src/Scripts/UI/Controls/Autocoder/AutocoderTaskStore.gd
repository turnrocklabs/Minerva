class_name AutocoderTaskStore
extends RefCounted
## Stores tasks for a single kanban board, associated with a session

signal task_added(task: AutocoderTask)
signal task_updated(task: AutocoderTask)
signal task_moved(task: AutocoderTask, old_status: AutocoderTask.TaskStatus, new_status: AutocoderTask.TaskStatus)
signal task_deleted(task_id: String)
signal store_changed()  ## Emitted when any change occurs (for auto-save)

## Session ID this board is associated with (empty for standalone boards)
var session_id: String = ""

## Board version for sync tracking
var version: int = 1

## Last hash received from backend (for state synchronization)
var last_backend_hash: String = ""

var _tasks: Dictionary = {}  # id -> AutocoderTask
var _next_id: int = 1


func _init(p_session_id: String = ""):
	session_id = p_session_id


## Create a task with full options
func create_task(
	title: String,
	description: String,
	status: AutocoderTask.TaskStatus = AutocoderTask.TaskStatus.PLAN,
	model: String = "",
	priority: int = 2,
	source_type: AutocoderTask.SourceType = AutocoderTask.SourceType.USER_MANUAL,
	source_uuid: String = "",
	source_context: String = ""
) -> AutocoderTask:
	var task = AutocoderTask.new(
		_generate_id(),
		title,
		description,
		status,
		model,
		priority
	)
	task.source_type = source_type
	task.source_uuid = source_uuid
	task.source_context = source_context
	
	_tasks[task.id] = task
	version += 1
	task_added.emit(task)
	store_changed.emit()
	return task


func _generate_id() -> String:
	var id = "task_%d_%d" % [Time.get_ticks_msec(), _next_id]
	_next_id += 1
	return id


func get_tasks_by_status(status: AutocoderTask.TaskStatus) -> Array[AutocoderTask]:
	var result: Array[AutocoderTask] = []
	for task in _tasks.values():
		if task.status == status:
			result.append(task)
	# Sort by priority (1=highest first)
	result.sort_custom(func(a, b): return a.priority < b.priority)
	return result


func get_task(task_id: String) -> AutocoderTask:
	return _tasks.get(task_id)


## Simple add_task for backwards compatibility
func add_task(title: String, description: String, status: AutocoderTask.TaskStatus = AutocoderTask.TaskStatus.PLAN) -> AutocoderTask:
	return create_task(title, description, status)


func update_task(task_id: String, updates: Dictionary) -> bool:
	var task = _tasks.get(task_id)
	if not task:
		return false
	
	var old_status = task.status
	
	if updates.has("title"):
		task.title = updates["title"]
	if updates.has("description"):
		task.description = updates["description"]
	if updates.has("status"):
		task.status = updates["status"]
	if updates.has("priority"):
		task.priority = updates["priority"]
	if updates.has("assigned_model"):
		task.assigned_model = updates["assigned_model"]
	if updates.has("related_files"):
		# Convert to typed array
		var related_files_data = updates["related_files"]
		var typed_related_files: Array[String] = []
		for file in related_files_data:
			typed_related_files.append(str(file))
		task.related_files = typed_related_files
	if updates.has("source_uuid"):
		task.source_uuid = updates["source_uuid"]
	if updates.has("source_type"):
		task.source_type = updates["source_type"]
	if updates.has("source_context"):
		task.source_context = updates["source_context"]
	if updates.has("note_links"):
		task.note_links = updates["note_links"]
	if updates.has("metadata"):
		task.metadata = updates["metadata"]
	
	task.updated_at = Time.get_datetime_string_from_system()
	task.version += 1
	version += 1
	
	if old_status != task.status:
		task_moved.emit(task, old_status, task.status)
	
	task_updated.emit(task)
	store_changed.emit()
	return true


func attach_note_to_task(task_id: String, note_uuid: String, note_title: String, relation: String = "attached") -> bool:
	var task = _tasks.get(task_id)
	if not task:
		return false
	task.add_note_link(note_uuid, note_title, relation)
	task.updated_at = Time.get_datetime_string_from_system()
	task.version += 1
	version += 1
	task_updated.emit(task)
	store_changed.emit()
	return true


func move_task(task_id: String, new_status: AutocoderTask.TaskStatus) -> bool:
	return update_task(task_id, {"status": new_status})


func delete_task(task_id: String) -> bool:
	if not _tasks.has(task_id):
		return false
	
	_tasks.erase(task_id)
	version += 1
	task_deleted.emit(task_id)
	store_changed.emit()
	return true


func get_all_tasks() -> Array[AutocoderTask]:
	var result: Array[AutocoderTask] = []
	result.assign(_tasks.values())
	return result


func get_task_count() -> int:
	return _tasks.size()


func clear() -> void:
	for task_id in _tasks.keys():
		task_deleted.emit(task_id)
	_tasks.clear()
	_next_id = 1
	version += 1
	store_changed.emit()


## Calculate SHA256 hash of current task state for synchronization
func calculate_hash() -> String:
	var serialized = serialize()
	var json_str = JSON.stringify(serialized["tasks"])
	return json_str.sha256_text()


## Serialize the entire store to dictionary
func serialize() -> Dictionary:
	var tasks_array: Array[Dictionary] = []
	for task in _tasks.values():
		tasks_array.append(task.serialize())
	
	return {
		"session_id": session_id,
		"version": version,
		"next_id": _next_id,
		"last_backend_hash": last_backend_hash,
		"tasks": tasks_array,
	}


## Deserialize store from dictionary
static func deserialize(data: Dictionary) -> AutocoderTaskStore:
	var store = AutocoderTaskStore.new(data.get("session_id", ""))
	store.version = data.get("version", 1)
	store._next_id = data.get("next_id", 1)
	store.last_backend_hash = data.get("last_backend_hash", "")
	
	var tasks_array = data.get("tasks", [])
	for task_data in tasks_array:
		var task = AutocoderTask.deserialize(task_data)
		store._tasks[task.id] = task
	
	return store


## Load mock data for testing (call explicitly if needed)
func load_mock_data():
	# Plan tasks
	create_task("Create user authentication system", "Implement login, registration, and session management", AutocoderTask.TaskStatus.PLAN, "", 1, AutocoderTask.SourceType.AUTOCODER)
	create_task("Add database migrations", "Create migration system for schema changes", AutocoderTask.TaskStatus.PLAN, "", 2, AutocoderTask.SourceType.AUTOCODER)
	create_task("Implement API endpoints", "Create REST API for user management", AutocoderTask.TaskStatus.PLAN, "", 2, AutocoderTask.SourceType.AUTOCODER)
	
	# In Progress tasks
	create_task("Refactor authentication middleware", "Update middleware to use new auth system", AutocoderTask.TaskStatus.IN_PROGRESS, "anthropic/claude-sonnet-4", 1, AutocoderTask.SourceType.AUTOCODER)
	create_task("Add password reset functionality", "Implement forgot password flow", AutocoderTask.TaskStatus.IN_PROGRESS, "anthropic/claude-haiku-4.5", 2, AutocoderTask.SourceType.AUTOCODER)
	
	# AI Review tasks
	create_task("Optimize database queries", "Review and optimize slow queries", AutocoderTask.TaskStatus.AI_REVIEW, "general-reviewer", 2, AutocoderTask.SourceType.AUTOCODER)
	
	# Human Review tasks
	create_task("Update documentation", "Document new API endpoints", AutocoderTask.TaskStatus.HUMAN_REVIEW, "", 3, AutocoderTask.SourceType.USER_MANUAL)
	create_task("Add unit tests", "Write tests for authentication system", AutocoderTask.TaskStatus.HUMAN_REVIEW, "", 2, AutocoderTask.SourceType.USER_MANUAL)
	
	# Done tasks
	create_task("Setup project structure", "Initialize project with proper folder structure", AutocoderTask.TaskStatus.DONE, "", 1, AutocoderTask.SourceType.USER_MANUAL)
	create_task("Configure CI/CD pipeline", "Setup GitHub Actions for automated testing", AutocoderTask.TaskStatus.DONE, "", 2, AutocoderTask.SourceType.USER_MANUAL)

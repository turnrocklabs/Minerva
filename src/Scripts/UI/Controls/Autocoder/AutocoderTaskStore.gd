class_name AutocoderTaskStore
extends RefCounted

signal task_added(task: AutocoderTask)
signal task_updated(task: AutocoderTask)
signal task_moved(task: AutocoderTask, old_status: AutocoderTask.TaskStatus, new_status: AutocoderTask.TaskStatus)
signal task_deleted(task_id: String)

var _tasks: Dictionary = {}  # id -> AutocoderTask
var _next_id: int = 1

func _init():
	_load_mock_data()

func _load_mock_data():
	# Plan tasks
	_create_task("Create user authentication system", "Implement login, registration, and session management", AutocoderTask.TaskStatus.PLAN)
	_create_task("Add database migrations", "Create migration system for schema changes", AutocoderTask.TaskStatus.PLAN)
	_create_task("Implement API endpoints", "Create REST API for user management", AutocoderTask.TaskStatus.PLAN)
	
	# In Progress tasks
	_create_task("Refactor authentication middleware", "Update middleware to use new auth system", AutocoderTask.TaskStatus.IN_PROGRESS, "anthropic/claude-sonnet-4")
	_create_task("Add password reset functionality", "Implement forgot password flow", AutocoderTask.TaskStatus.IN_PROGRESS, "anthropic/claude-haiku-4.5")
	
	# AI Review tasks
	_create_task("Optimize database queries", "Review and optimize slow queries", AutocoderTask.TaskStatus.AI_REVIEW, "general-reviewer")
	
	# Human Review tasks
	_create_task("Update documentation", "Document new API endpoints", AutocoderTask.TaskStatus.HUMAN_REVIEW)
	_create_task("Add unit tests", "Write tests for authentication system", AutocoderTask.TaskStatus.HUMAN_REVIEW)
	
	# Done tasks
	_create_task("Setup project structure", "Initialize project with proper folder structure", AutocoderTask.TaskStatus.DONE)
	_create_task("Configure CI/CD pipeline", "Setup GitHub Actions for automated testing", AutocoderTask.TaskStatus.DONE)

func _create_task(title: String, description: String, status: AutocoderTask.TaskStatus, model: String = "") -> AutocoderTask:
	var task = AutocoderTask.new(
		_generate_id(),
		title,
		description,
		status,
		model
	)
	_tasks[task.id] = task
	task_added.emit(task)
	return task

func _generate_id() -> String:
	var id = "task_%d" % _next_id
	_next_id += 1
	return id

func get_tasks_by_status(status: AutocoderTask.TaskStatus) -> Array[AutocoderTask]:
	var result: Array[AutocoderTask] = []
	for task in _tasks.values():
		if task.status == status:
			result.append(task)
	return result

func get_task(task_id: String) -> AutocoderTask:
	return _tasks.get(task_id)

func add_task(title: String, description: String, status: AutocoderTask.TaskStatus = AutocoderTask.TaskStatus.PLAN) -> AutocoderTask:
	return _create_task(title, description, status)

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
	if updates.has("assigned_model"):
		task.assigned_model = updates["assigned_model"]
	if updates.has("related_files"):
		task.related_files = updates["related_files"]
	
	task.updated_at = Time.get_datetime_string_from_system()
	
	if old_status != task.status:
		task_moved.emit(task, old_status, task.status)
	
	task_updated.emit(task)
	return true

func move_task(task_id: String, new_status: AutocoderTask.TaskStatus) -> bool:
	return update_task(task_id, {"status": new_status})

func delete_task(task_id: String) -> bool:
	if not _tasks.has(task_id):
		return false
	
	_tasks.erase(task_id)
	task_deleted.emit(task_id)
	return true

func get_all_tasks() -> Array[AutocoderTask]:
	return _tasks.values()

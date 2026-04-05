class_name MCPKanbanTools
extends MCPToolModule
## MCP tool module for Kanban board domain tools.
## Handles task creation, listing, updating, moving, and deletion on Kanban boards.


func get_tool_names() -> Array[String]:
	return [
		"minerva_kanban_create_task",
		"minerva_kanban_list_boards",
		"minerva_kanban_get_tasks",
		"minerva_kanban_update_task",
		"minerva_kanban_move_task",
		"minerva_kanban_delete_task",
	]


func register_tools() -> void:
	server._register_tool("minerva_kanban_create_task",
		"Create a new task on a Kanban board. The task will be added to the specified board with source tracking showing it was created by an agent.",
		{
			"type": "object",
			"properties": {
				"board_name": {
					"type": "string",
					"description": "Name of the Kanban board editor tab to add the task to"
				},
				"title": {
					"type": "string",
					"description": "Title of the task"
				},
				"description": {
					"type": "string",
					"description": "Detailed description of the task"
				},
				"priority": {
					"type": "integer",
					"description": "Priority 1-5 (1=highest, 5=lowest). Default: 2"
				},
				"status": {
					"type": "string",
					"description": "Initial status: plan, in_progress, ai_review, human_review, done. Default: plan",
					"enum": ["plan", "in_progress", "ai_review", "human_review", "done"]
				}
			},
			"required": ["board_name", "title", "description"]
		}
	, "kanban")

	server._register_tool("minerva_kanban_list_boards",
		"List all open Kanban boards (editor tabs of type KANBAN).",
		{
			"type": "object",
			"properties": {},
			"required": []
		}
	, "kanban")

	server._register_tool("minerva_kanban_get_tasks",
		"Get all tasks from a Kanban board, optionally filtered by status.",
		{
			"type": "object",
			"properties": {
				"board_name": {
					"type": "string",
					"description": "Name of the Kanban board editor tab"
				},
				"status": {
					"type": "string",
					"description": "Optional: Filter by status (plan, in_progress, ai_review, human_review, done)",
					"enum": ["plan", "in_progress", "ai_review", "human_review", "done"]
				}
			},
			"required": ["board_name"]
		}
	, "kanban")

	server._register_tool("minerva_kanban_update_task",
		"Update an existing task on a Kanban board.",
		{
			"type": "object",
			"properties": {
				"board_name": {
					"type": "string",
					"description": "Name of the Kanban board editor tab"
				},
				"task_id": {
					"type": "string",
					"description": "ID of the task to update"
				},
				"title": {
					"type": "string",
					"description": "New title (optional)"
				},
				"description": {
					"type": "string",
					"description": "New description (optional)"
				},
				"priority": {
					"type": "integer",
					"description": "New priority 1-5 (optional)"
				}
			},
			"required": ["board_name", "task_id"]
		}
	, "kanban")

	server._register_tool("minerva_kanban_move_task",
		"Move a task to a different status column on the Kanban board.",
		{
			"type": "object",
			"properties": {
				"board_name": {
					"type": "string",
					"description": "Name of the Kanban board editor tab"
				},
				"task_id": {
					"type": "string",
					"description": "ID of the task to move"
				},
				"new_status": {
					"type": "string",
					"description": "New status: plan, in_progress, ai_review, human_review, done",
					"enum": ["plan", "in_progress", "ai_review", "human_review", "done"]
				}
			},
			"required": ["board_name", "task_id", "new_status"]
		}
	, "kanban")

	server._register_tool("minerva_kanban_delete_task",
		"Delete a task from a Kanban board.",
		{
			"type": "object",
			"properties": {
				"board_name": {
					"type": "string",
					"description": "Name of the Kanban board editor tab"
				},
				"task_id": {
					"type": "string",
					"description": "ID of the task to delete"
				}
			},
			"required": ["board_name", "task_id"]
		}
	, "kanban")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_kanban_create_task": return _kanban_create_task(arguments)
		"minerva_kanban_list_boards": return _kanban_list_boards(arguments)
		"minerva_kanban_get_tasks": return _kanban_get_tasks(arguments)
		"minerva_kanban_update_task": return _kanban_update_task(arguments)
		"minerva_kanban_move_task": return _kanban_move_task(arguments)
		"minerva_kanban_delete_task": return _kanban_delete_task(arguments)
	return MCPToolUtils.error("Unknown tool: %s" % tool_name)


func _get_all_kanban_boards() -> Array[Dictionary]:
	var boards: Array[Dictionary] = []
	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return boards

	for editor in editor_pane.get_open_editors():
		if editor.type == Editor.Type.KANBAN and editor.kanban_board:
			var task_count = 0
			if editor.kanban_board.task_store:
				task_count = editor.kanban_board.task_store.get_task_count()
			boards.append({
				"name": editor.tab_title,
				"session_id": editor.kanban_board.task_store.session_id if editor.kanban_board.task_store else "",
				"task_count": task_count
			})

	return boards


func _status_string_to_enum(status_str: String) -> int:  # Returns AutocoderTask.TaskStatus
	var AutocoderTaskClass = load("res://Scripts/UI/Controls/Autocoder/AutocoderTask.gd")
	match status_str.to_lower():
		"plan":
			return AutocoderTaskClass.TaskStatus.PLAN
		"in_progress":
			return AutocoderTaskClass.TaskStatus.IN_PROGRESS
		"ai_review":
			return AutocoderTaskClass.TaskStatus.AI_REVIEW
		"human_review":
			return AutocoderTaskClass.TaskStatus.HUMAN_REVIEW
		"done":
			return AutocoderTaskClass.TaskStatus.DONE
		_:
			return AutocoderTaskClass.TaskStatus.PLAN


func _kanban_create_task(args: Dictionary) -> Dictionary:
	var board_name: String = str(args.get("board_name", "")).strip_edges()
	var title: String = str(args.get("title", "")).strip_edges()
	var description: String = str(args.get("description", "")).strip_edges()
	var priority: int = MCPToolUtils.coerce_int(args.get("priority", 2))
	var status_str: String = str(args.get("status", "plan")).strip_edges()

	if board_name.is_empty():
		return MCPToolUtils.error("board_name is required")
	if title.is_empty():
		return MCPToolUtils.error("title is required")

	var board = MCPToolUtils.find_kanban(board_name)
	if not board:
		return MCPToolUtils.error("Kanban board not found: %s" % board_name)

	if not board.task_store:
		return MCPToolUtils.error("Kanban board has no task store")

	var status = _status_string_to_enum(status_str)

	# Get context for source tracking
	var source_context = "Agent Tool"
	var chat_pane = SingletonObject.Chats
	if chat_pane and chat_pane.current_tab >= 0 and chat_pane.current_tab < SingletonObject.ChatList.size():
		var current_chat = SingletonObject.ChatList[chat_pane.current_tab]
		source_context = "Agent: %s" % current_chat.HistoryName

	var AutocoderTaskClass = load("res://Scripts/UI/Controls/Autocoder/AutocoderTask.gd")
	var task = board.task_store.create_task(
		title,
		description,
		status,
		"",  # model
		priority,
		AutocoderTaskClass.SourceType.AGENT_TOOL,
		"",  # source_uuid - could track chat ID here
		source_context
	)

	return {
		"success": true,
		"task_id": task.id,
		"title": task.title,
		"status": task.get_status_name(),
		"message": "Task created on board '%s'" % board_name
	}


func _kanban_list_boards(_args: Dictionary) -> Dictionary:
	var boards = _get_all_kanban_boards()

	return {
		"success": true,
		"boards": boards,
		"count": boards.size()
	}


func _kanban_get_tasks(args: Dictionary) -> Dictionary:
	var board_name: String = str(args.get("board_name", "")).strip_edges()
	var status_filter: String = str(args.get("status", "")).strip_edges()

	if board_name.is_empty():
		return MCPToolUtils.error("board_name is required")

	var board = MCPToolUtils.find_kanban(board_name)
	if not board:
		return MCPToolUtils.error("Kanban board not found: %s" % board_name)

	if not board.task_store:
		return MCPToolUtils.error("Kanban board has no task store")

	var tasks: Array  # Array of AutocoderTask
	if status_filter.is_empty():
		tasks = board.task_store.get_all_tasks()
	else:
		var status = _status_string_to_enum(status_filter)
		tasks = board.task_store.get_tasks_by_status(status)

	var tasks_data: Array[Dictionary] = []
	for task in tasks:
		tasks_data.append({
			"task_id": task.id,
			"title": task.title,
			"description": task.description,
			"status": task.get_status_name(),
			"priority": task.priority,
			"source": task.get_source_type_name(),
			"created_at": task.created_at
		})

	return {
		"success": true,
		"board_name": board_name,
		"tasks": tasks_data,
		"count": tasks_data.size()
	}


func _kanban_update_task(args: Dictionary) -> Dictionary:
	var board_name: String = str(args.get("board_name", "")).strip_edges()
	var task_id: String = str(args.get("task_id", "")).strip_edges()

	if board_name.is_empty():
		return MCPToolUtils.error("board_name is required")
	if task_id.is_empty():
		return MCPToolUtils.error("task_id is required")

	var board = MCPToolUtils.find_kanban(board_name)
	if not board:
		return MCPToolUtils.error("Kanban board not found: %s" % board_name)

	if not board.task_store:
		return MCPToolUtils.error("Kanban board has no task store")

	var updates: Dictionary = {}
	if args.has("title"):
		updates["title"] = args["title"]
	if args.has("description"):
		updates["description"] = args["description"]
	if args.has("priority"):
		updates["priority"] = args["priority"]

	if updates.is_empty():
		return MCPToolUtils.error("No updates provided")

	var success = board.task_store.update_task(task_id, updates)
	if not success:
		return MCPToolUtils.error("Task not found: %s" % task_id)

	return {
		"success": true,
		"task_id": task_id,
		"message": "Task updated"
	}


func _kanban_move_task(args: Dictionary) -> Dictionary:
	var board_name: String = str(args.get("board_name", "")).strip_edges()
	var task_id: String = str(args.get("task_id", "")).strip_edges()
	var new_status_str: String = str(args.get("new_status", "")).strip_edges()

	if board_name.is_empty():
		return MCPToolUtils.error("board_name is required")
	if task_id.is_empty():
		return MCPToolUtils.error("task_id is required")
	if new_status_str.is_empty():
		return MCPToolUtils.error("new_status is required")

	var board = MCPToolUtils.find_kanban(board_name)
	if not board:
		return MCPToolUtils.error("Kanban board not found: %s" % board_name)

	if not board.task_store:
		return MCPToolUtils.error("Kanban board has no task store")

	var new_status = _status_string_to_enum(new_status_str)
	var success = board.task_store.move_task(task_id, new_status)
	if not success:
		return MCPToolUtils.error("Task not found: %s" % task_id)

	return {
		"success": true,
		"task_id": task_id,
		"new_status": new_status_str,
		"message": "Task moved to %s" % new_status_str
	}


func _kanban_delete_task(args: Dictionary) -> Dictionary:
	var board_name: String = str(args.get("board_name", "")).strip_edges()
	var task_id: String = str(args.get("task_id", "")).strip_edges()

	if board_name.is_empty():
		return MCPToolUtils.error("board_name is required")
	if task_id.is_empty():
		return MCPToolUtils.error("task_id is required")

	var board = MCPToolUtils.find_kanban(board_name)
	if not board:
		return MCPToolUtils.error("Kanban board not found: %s" % board_name)

	if not board.task_store:
		return MCPToolUtils.error("Kanban board has no task store")

	var success = board.task_store.delete_task(task_id)
	if not success:
		return MCPToolUtils.error("Task not found: %s" % task_id)

	return {
		"success": true,
		"task_id": task_id,
		"message": "Task deleted"
	}

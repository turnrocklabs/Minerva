class_name AutocoderSessionViewManager
extends VBoxContainer

signal session_selected(session_id: String)
signal session_double_clicked(session_id: String)

@onready var _sessions_tree: Tree = $MainMargin/SessionsCard/CardMargin/CardContent/SessionsTree
@onready var _delete_all_button: Button = %DeleteAllButton
@onready var _refresh_button: Button = $MainMargin/SessionsCard/CardMargin/CardContent/Header/RefreshButton

var _sessions: Array[Dictionary] = []


func _ready() -> void:
	_setup_tree()
	# Note: Session loading is now triggered by AutocoderManager calling _load_sessions()
	# after the autocoder_adapter is ready
	
	# Connect tree signals
	if _sessions_tree:
		_sessions_tree.item_selected.connect(_on_tree_item_selected)
		_sessions_tree.item_activated.connect(_on_tree_item_activated)  # Double-click
	
	# Connect button signals
	if _delete_all_button:
		_delete_all_button.pressed.connect(_on_delete_all_button_pressed)
	
	if _refresh_button:
		_refresh_button.pressed.connect(_on_refresh_button_pressed)


func _setup_tree() -> void:
	if not _sessions_tree:
		return
	
	_sessions_tree.clear()
	_sessions_tree.columns = 4
	_sessions_tree.set_column_title(0, "Session Name")
	_sessions_tree.set_column_title(1, "Status")
	_sessions_tree.set_column_title(2, "Created")
	_sessions_tree.set_column_title(3, "Actions")
	_sessions_tree.set_column_expand(0, true)
	_sessions_tree.set_column_expand(1, false)
	_sessions_tree.set_column_expand(2, true)
	_sessions_tree.set_column_expand(3, false)
	_sessions_tree.set_column_custom_minimum_width(1, 100)
	_sessions_tree.set_column_custom_minimum_width(3, 80)
	_sessions_tree.hide_root = true
	
	# Connect tree button signal for delete buttons
	if not _sessions_tree.button_clicked.is_connected(_on_tree_button_clicked):
		_sessions_tree.button_clicked.connect(_on_tree_button_clicked)


func _load_sessions() -> void:
	if not SingletonObject.autocoder_manager or not SingletonObject.autocoder_manager.autocoder_adapter:
		print("[SessionView] Cannot load sessions - autocoder not available")
		return
	
	print("[SessionView] Loading sessions...")
	var sessions = await SingletonObject.autocoder_manager.autocoder_adapter.list_sessions()
	print("[SessionView] Loaded %d sessions" % sessions.size())
	_sessions = sessions
	_populate_tree()


func _populate_tree() -> void:
	if not _sessions_tree:
		return
	
	_sessions_tree.clear()
	var root = _sessions_tree.create_item()
	
	# Sort by created_at (newest first)
	var sorted_sessions = _sessions.duplicate()
	sorted_sessions.sort_custom(func(a, b): return a.get("created_at", "") > b.get("created_at", ""))
	
	print("[SessionView] Populating tree with %d sessions" % sorted_sessions.size())
	
	for session in sorted_sessions:
		if not (session is Dictionary):
			continue
		
		var session_id = str(session.get("session_id", ""))
		if session_id.is_empty():
			continue
		
		var session_name = str(session.get("session_name", session_id.substr(0, 16)))
		var status = str(session.get("status", "unknown"))
		var created_at = str(session.get("created_at", ""))
		
		var item = _sessions_tree.create_item(root)
		item.set_text(0, session_name)
		item.set_text(1, _status_emoji(status) + " " + status)
		item.set_text(2, _format_date(created_at))
		item.set_metadata(0, session_id)
		
		# Add delete button in the actions column
		item.add_button(3, get_theme_icon("Remove", "EditorIcons"), 0, false, "Delete Session")
		
		# Color code by status
		var color = _status_color(status)
		item.set_custom_color(1, color)


func _status_emoji(status: String) -> String:
	match status.to_lower():
		"active": return "🟢"
		"in_review": return "🔍"
		"completed": return "✅"
		"failed": return "❌"
		"cancelled": return "⏸️"
		_: return "⚪"


func _status_color(status: String) -> Color:
	match status.to_lower():
		"active": return Color(0.4, 0.9, 0.4)
		"in_review": return Color(0.9, 0.7, 0.3)
		"completed": return Color(0.6, 0.8, 1.0)
		"failed": return Color(0.9, 0.4, 0.4)
		"cancelled": return Color(0.6, 0.6, 0.6)
		_: return Color(0.7, 0.7, 0.7)


func _format_date(iso_date: String) -> String:
	if iso_date.is_empty():
		return "Unknown"
	
	# Parse ISO date and format nicely
	var parts = iso_date.split("T")
	if parts.size() < 2:
		return iso_date
	
	var date = parts[0]
	var time_part = parts[1].split("+")[0].split(".")[0]  # Remove timezone and milliseconds
	
	return "%s %s" % [date, time_part]


func _on_tree_item_selected() -> void:
	var selected = _sessions_tree.get_selected()
	if not selected:
		return
	
	var session_id = selected.get_metadata(0)
	if session_id:
		session_selected.emit(str(session_id))


func _on_tree_item_activated() -> void:
	var selected = _sessions_tree.get_selected()
	if not selected:
		return
	
	var session_id = selected.get_metadata(0)
	if session_id:
		print("[SessionView] Double-clicked session: %s" % session_id)
		session_double_clicked.emit(str(session_id))


func refresh() -> void:
	"""Public method to refresh sessions"""
	_load_sessions()


func _on_refresh_button_pressed() -> void:
	"""Handle refresh button click"""
	refresh()


func _on_delete_all_button_pressed() -> void:
	"""Handle delete all button click"""
	print("[SessionView] Delete all button pressed!")
	delete_all_sessions()


func delete_all_sessions() -> void:
	"""Delete all sessions (for testing/cleanup)"""
	print("[SessionView] delete_all_sessions() called")
	
	if not SingletonObject.autocoder_manager or not SingletonObject.autocoder_manager.autocoder_adapter:
		print("[SessionView] ERROR: autocoder not available")
		SingletonObject.create_toast_notification(
			"Cannot delete sessions - autocoder not available",
			ToastNotification.Type.ERROR
		)
		return
	
	print("[SessionView] Autocoder available, showing confirmation dialog")
	
	# Show confirmation dialog
	var dialog = ConfirmationDialog.new()
	dialog.dialog_text = "Delete ALL sessions?\n\nThis will delete:\n• All session data from backend\n• All local Kanban boards\n• All artifacts\n\nThis cannot be undone!"
	dialog.ok_button_text = "Delete All"
	dialog.cancel_button_text = "Cancel"
	
	add_child(dialog)
	dialog.popup_centered()
	
	# Wait for user response
	await dialog.confirmed
	dialog.queue_free()
	
	# If we reach here, user clicked OK
	print("[SessionView] Deleting all sessions...")
	SingletonObject.create_toast_notification(
		"Deleting all sessions...",
		ToastNotification.Type.INFO
	)
	
	var result = await SingletonObject.autocoder_manager.autocoder_adapter.delete_all_sessions()
	
	if result.get("success", false):
		SingletonObject.create_toast_notification(
			result.get("message", "All sessions deleted"),
			ToastNotification.Type.SUCCESS
		)
	else:
		SingletonObject.create_toast_notification(
			"Failed to delete some sessions: " + result.get("message", "Unknown error"),
			ToastNotification.Type.ERROR
		)
	
	# Refresh the list
	await _load_sessions()


func _on_tree_button_clicked(item: TreeItem, column: int, id: int, mouse_button_index: int) -> void:
	"""Handle delete button click on individual sessions"""
	print("[SessionView] Tree button clicked - column: %d, id: %d, mouse_button: %d" % [column, id, mouse_button_index])
	
	if column != 3:  # Only handle actions column
		print("[SessionView] Ignoring button click - not in actions column")
		return
	
	var session_id = item.get_metadata(0)
	if not session_id:
		print("[SessionView] No session_id in metadata")
		return
	
	print("[SessionView] Calling _delete_single_session for: %s" % session_id)
	_delete_single_session(str(session_id))


func _delete_single_session(session_id: String) -> void:
	"""Delete a single session with confirmation"""
	print("[SessionView] _delete_single_session() called for: %s" % session_id)
	
	if not SingletonObject.autocoder_manager or not SingletonObject.autocoder_manager.autocoder_adapter:
		print("[SessionView] ERROR: autocoder not available")
		SingletonObject.create_toast_notification(
			"Cannot delete session - autocoder not available",
			ToastNotification.Type.ERROR
		)
		return
	
	print("[SessionView] Showing confirmation dialog for session: %s" % session_id)
	
	# Show confirmation dialog
	var dialog = ConfirmationDialog.new()
	dialog.dialog_text = "Delete session %s?\n\nThis cannot be undone!" % session_id.substr(0, 16)
	dialog.ok_button_text = "Delete"
	dialog.cancel_button_text = "Cancel"
	
	add_child(dialog)
	dialog.popup_centered()
	
	# Wait for user response
	await dialog.confirmed
	dialog.queue_free()
	
	# If we reach here, user clicked OK
	print("[SessionView] Deleting session: %s" % session_id)
	var result = await SingletonObject.autocoder_manager.autocoder_adapter.delete_session(session_id)
	
	if result.get("success", false):
		SingletonObject.create_toast_notification(
			"Session deleted",
			ToastNotification.Type.SUCCESS
		)
		# Refresh the list
		await _load_sessions()
	else:
		SingletonObject.create_toast_notification(
			"Failed to delete: " + result.get("message", "Unknown error"),
			ToastNotification.Type.ERROR
		)

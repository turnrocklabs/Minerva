class_name AutocoderTaskCard
extends PanelContainer

signal task_clicked(task: AutocoderTask)
signal task_move_requested(task: AutocoderTask, new_status: AutocoderTask.TaskStatus)
signal task_edit_requested(task: AutocoderTask)
signal task_delete_requested(task: AutocoderTask)
signal source_clicked(task: AutocoderTask)
signal note_dropped_on_card(note: Note, card: AutocoderTaskCard)
signal note_link_removed(task: AutocoderTask, note_uuid: String)

var task: AutocoderTask

@onready var _title_label: Label = %TitleLabel
@onready var _description_label: Label = %DescriptionLabel
@onready var _status_badge: Label = %StatusBadge
@onready var _model_label: Label = %ModelLabel
@onready var _files_label: Label = %FilesLabel
@onready var _actions_button: Button = %ActionsButton
@onready var _actions_menu: PopupMenu = %ActionsMenu
@onready var _source_button: Button = %SourceButton
@onready var _expand_button: Button = %ExpandButton
@onready var _details_container: VBoxContainer = %DetailsContainer
@onready var _stage_history_list: VBoxContainer = %StageHistoryList
@onready var _activity_indicator: RichTextLabel = %ActivityIndicator
var _source_menu: PopupMenu

var _expanded: bool = false
var _expand_tween: Tween
var _activity_tween: Tween
const EXPAND_DURATION: float = 0.4
const EXPAND_ICON_COLOR: Color = Color(0.16, 1.0, 1.0, 1.0)

func _ready():
	if _actions_button:
		_actions_button.pressed.connect(_on_actions_button_pressed)
	if _actions_menu:
		_actions_menu.id_pressed.connect(_on_menu_item_selected)
	if _source_button:
		_source_button.pressed.connect(_on_source_button_pressed)
		_source_button.gui_input.connect(_on_source_button_gui_input)
	
	# Create popup menu for source button (right-click)
	_source_menu = PopupMenu.new()
	_source_menu.id_pressed.connect(_on_source_menu_item_selected)
	add_child(_source_menu)
	
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


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	# Accept Note drops - forward to parent drop zone
	if _is_note_data(data):
		return true
	return false


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	# Forward Note drops to parent drop zone
	if _is_note_data(data):
		note_dropped_on_card.emit(data as Note, self)


func _is_note_data(data: Variant) -> bool:
	if data is Note:
		return true
	if data is Object and "uuid" in data and "title" in data:
		return true
	return false

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
		_update_model_label()
	if _activity_indicator:
		_update_activity_indicator()
	if _expanded and _stage_history_list:
		_populate_stage_history()
	if _files_label:
		if task.related_files.is_empty():
			_files_label.visible = false
		else:
			_files_label.visible = true
			_files_label.text = "%d file(s)" % task.related_files.size()
	if _source_button:
		_update_source_button()

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

## --- Expand / Collapse ---

func _on_expand_button_pressed() -> void:
	_expanded = not _expanded
	if _expanded:
		_expand_content()
	else:
		_contract_content()


func _expand_content() -> void:
	if not _details_container:
		return
	_populate_stage_history()
	_details_container.visible = true

	# Measure content
	_details_container.custom_minimum_size.y = 0
	await get_tree().process_frame
	var content_size = _details_container.get_combined_minimum_size().y

	if _expand_tween and _expand_tween.is_running():
		_expand_tween.kill()
	_expand_tween = create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_expand_tween.set_parallel(true)
	_details_container.custom_minimum_size.y = 0
	_expand_tween.tween_property(_details_container, "custom_minimum_size:y", content_size, EXPAND_DURATION)
	if _expand_button:
		_expand_tween.tween_property(_expand_button, "rotation", 0.0, EXPAND_DURATION)
		_expand_tween.tween_property(_expand_button, "self_modulate", Color.WHITE, EXPAND_DURATION)


func _contract_content() -> void:
	if not _details_container:
		return
	var content_size = _details_container.get_combined_minimum_size().y

	if _expand_tween and _expand_tween.is_running():
		_expand_tween.kill()
	_expand_tween = create_tween().set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_CUBIC)
	_expand_tween.set_parallel(true)
	_expand_tween.tween_property(_details_container, "custom_minimum_size:y", 0.0, EXPAND_DURATION).from(content_size)
	if _expand_button:
		_expand_tween.tween_property(_expand_button, "rotation", deg_to_rad(-90.0), EXPAND_DURATION)
		_expand_tween.tween_property(_expand_button, "self_modulate", EXPAND_ICON_COLOR, EXPAND_DURATION)
	_expand_tween.set_parallel(false)
	_expand_tween.tween_callback(func(): _details_container.visible = false)


## --- Stage History Rendering ---

func _populate_stage_history() -> void:
	if not _stage_history_list or not task:
		return

	# Clear existing children
	for child in _stage_history_list.get_children():
		child.queue_free()

	var history = task.get_stage_history()
	if history.is_empty():
		var empty_label = Label.new()
		empty_label.text = "No stage history yet"
		empty_label.add_theme_color_override("font_color", Color(0.4, 0.4, 0.45))
		empty_label.add_theme_font_size_override("font_size", 10)
		_stage_history_list.add_child(empty_label)
		return

	for entry in history:
		if not entry is Dictionary:
			continue
		var hbox = HBoxContainer.new()
		hbox.add_theme_constant_override("separation", 6)

		# Stage icon
		var stage_str = str(entry.get("stage", ""))
		var stage_icon = Label.new()
		stage_icon.add_theme_font_size_override("font_size", 10)
		match stage_str:
			"in_progress":
				stage_icon.text = ">"
				stage_icon.add_theme_color_override("font_color", Color(0.95, 0.8, 0.3))
			"ai_review":
				stage_icon.text = "R"
				stage_icon.add_theme_color_override("font_color", Color(0.5, 0.9, 0.7))
			"done":
				stage_icon.text = "D"
				stage_icon.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
			_:
				stage_icon.text = "-"
				stage_icon.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
		hbox.add_child(stage_icon)

		# Model name
		var model_str = str(entry.get("model", ""))
		if not model_str.is_empty():
			var model_label = Label.new()
			model_label.text = AutocoderTask.format_model_name(model_str)
			model_label.add_theme_color_override("font_color", Color(0.4, 0.6, 0.95))
			model_label.add_theme_font_size_override("font_size", 10)
			model_label.tooltip_text = model_str
			hbox.add_child(model_label)

		# Agent name (if present, for review entries)
		var agent_name = str(entry.get("agent_name", ""))
		if not agent_name.is_empty():
			var agent_label = Label.new()
			agent_label.text = agent_name
			agent_label.add_theme_color_override("font_color", Color(0.4, 0.85, 0.5))
			agent_label.add_theme_font_size_override("font_size", 10)
			hbox.add_child(agent_label)

		# Issue count (if present)
		var issues = entry.get("issues", 0)
		if issues is float or issues is int:
			if int(issues) > 0:
				var issue_label = Label.new()
				issue_label.text = "%d issues" % int(issues)
				issue_label.add_theme_color_override("font_color", Color(0.95, 0.8, 0.3))
				issue_label.add_theme_font_size_override("font_size", 10)
				hbox.add_child(issue_label)

		_stage_history_list.add_child(hbox)


## --- Model Label (summary from stage history) ---

func _update_model_label() -> void:
	if not _model_label or not task:
		return

	# Collect all unique models from stage history
	var all_models: Array[String] = []
	for entry in task.get_stage_history():
		if entry is Dictionary:
			var m = str(entry.get("model", ""))
			if not m.is_empty() and not all_models.has(m):
				all_models.append(m)

	# Fall back to assigned_model if no stage history
	if all_models.is_empty():
		if task.assigned_model.is_empty():
			_model_label.visible = false
		else:
			_model_label.visible = true
			_model_label.text = AutocoderTask.format_model_name(task.assigned_model)
			_model_label.tooltip_text = task.assigned_model
		return

	_model_label.visible = true
	if all_models.size() == 1:
		_model_label.text = AutocoderTask.format_model_name(all_models[0])
		_model_label.tooltip_text = all_models[0]
	else:
		_model_label.text = "%s +%d" % [AutocoderTask.format_model_name(all_models[0]), all_models.size() - 1]
		var tooltip_lines: PackedStringArray
		for m in all_models:
			tooltip_lines.append(m)
		_model_label.tooltip_text = "\n".join(tooltip_lines)


## --- Activity Indicator ---

func _update_activity_indicator() -> void:
	if not _activity_indicator or not task:
		return

	var is_active = task.status == AutocoderTask.TaskStatus.IN_PROGRESS or task.status == AutocoderTask.TaskStatus.AI_REVIEW
	_activity_indicator.visible = is_active

	if is_active:
		_start_activity_pulse()
	else:
		_stop_activity_pulse()


func _start_activity_pulse() -> void:
	if _activity_tween and _activity_tween.is_running():
		return  # Already pulsing
	_activity_indicator.text = "..."
	_activity_tween = create_tween().set_loops()
	_activity_tween.tween_property(_activity_indicator, "modulate:a", 0.3, 0.5).set_trans(Tween.TRANS_SINE)
	_activity_tween.tween_property(_activity_indicator, "modulate:a", 1.0, 0.5).set_trans(Tween.TRANS_SINE)


func _stop_activity_pulse() -> void:
	if _activity_tween and _activity_tween.is_running():
		_activity_tween.kill()
		_activity_tween = null
	if _activity_indicator:
		_activity_indicator.modulate.a = 1.0


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


func _update_source_button():
	if not task or not _source_button:
		return
	
	var icon: String
	var label: String
	var note_count = task.note_links.size() if task.note_links is Array else 0
	var has_source = note_count > 0 or not task.source_uuid.is_empty()
	
	if note_count > 0:
		icon = "📝"
		label = "Notes (%d)" % note_count if note_count > 1 else "Note"
	else:
		match task.source_type:
			AutocoderTask.SourceType.AUTOCODER:
				icon = "🤖"
				label = "Autocoder"
			AutocoderTask.SourceType.AGENT_TOOL:
				icon = "🔧"
				label = task.source_context if not task.source_context.is_empty() else "Agent"
			AutocoderTask.SourceType.USER_CHAT:
				icon = "💬"
				label = "Chat"
			AutocoderTask.SourceType.USER_NOTE:
				icon = "📝"
				label = "Note"
			AutocoderTask.SourceType.USER_MANUAL:
				icon = "✏️"
				label = "Manual"
			_:
				icon = "📋"
				label = "Unknown"
	
	_source_button.text = "%s %s" % [icon, label]
	
	# Make button clickable if there's a source UUID or notes
	_source_button.disabled = not has_source
	if has_source:
		_source_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		if note_count > 1:
			_source_button.tooltip_text = "Click to highlight all %d notes. Right-click for options." % note_count
		else:
			_source_button.tooltip_text = "Click to view source. Right-click for options."
	else:
		_source_button.mouse_default_cursor_shape = Control.CURSOR_ARROW
		_source_button.tooltip_text = "Created by: %s" % label


func _on_source_button_pressed():
	if not task:
		return
	
	# Emit signal first so parent can handle it
	source_clicked.emit(task)
	
	# Get all note UUIDs and highlight ALL of them
	var note_uuids = task.get_all_note_uuids()
	if note_uuids.size() > 1:
		SingletonObject.create_toast_notification("Highlighting %d attached notes" % note_uuids.size(), ToastNotification.Type.INFO)
		_focus_all_notes(note_uuids)
	elif note_uuids.size() == 1:
		var source_obj = task.get_source_object()
		if source_obj:
			_navigate_to_source(source_obj)
		else:
			_try_find_note_by_uuid(note_uuids[0])
	else:
		# No note links, try source_uuid
		var source_obj = task.get_source_object()
		if source_obj:
			_navigate_to_source(source_obj)
		else:
			_handle_missing_source()


func _on_source_button_gui_input(event: InputEvent):
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		_show_source_context_menu()


func _show_source_context_menu():
	if not task or not _source_menu:
		return
	
	_source_menu.clear()
	
	var note_uuids = task.get_all_note_uuids()
	if note_uuids.is_empty():
		_source_menu.add_item("No notes attached", -1)
		_source_menu.set_item_disabled(0, true)
	else:
		# Add "View All" option if multiple notes
		if note_uuids.size() > 1:
			_source_menu.add_item("📝 View All Notes (%d)" % note_uuids.size(), 1000)
			_source_menu.add_separator()
		
		# Add each note with remove option
		for i in range(note_uuids.size()):
			var uuid = note_uuids[i]
			var link = task.note_links[i] if i < task.note_links.size() else {}
			var title = str(link.get("title", "Note %d" % (i + 1)))
			if title.length() > 30:
				title = title.substr(0, 27) + "..."
			
			# Store UUID as metadata (index + 2000 for view, index + 3000 for remove)
			_source_menu.add_item("👁️ View: %s" % title, 2000 + i)
			_source_menu.set_item_metadata(_source_menu.get_item_count() - 1, uuid)
			
			_source_menu.add_item("🗑️ Remove: %s" % title, 3000 + i)
			_source_menu.set_item_metadata(_source_menu.get_item_count() - 1, uuid)
	
	# Show menu at mouse position
	var mouse_pos = get_global_mouse_position()
	_source_menu.popup(Rect2i(int(mouse_pos.x), int(mouse_pos.y), 200, 0))


func _on_source_menu_item_selected(id: int):
	if not task:
		return
	
	if id == 1000:
		# View all notes
		var note_uuids = task.get_all_note_uuids()
		_focus_all_notes(note_uuids)
	elif id >= 3000:
		# Remove note link (id 3000+)
		var item_index = _source_menu.get_item_index(id)
		var uuid = _source_menu.get_item_metadata(item_index) as String
		if not uuid.is_empty():
			if task.remove_note_link(uuid):
				note_link_removed.emit(task, uuid)
				_update_display()
				SingletonObject.create_toast_notification("Note link removed", ToastNotification.Type.SUCCESS)
	elif id >= 2000:
		# View single note (id 2000+)
		var item_index = _source_menu.get_item_index(id)
		var uuid = _source_menu.get_item_metadata(item_index) as String
		if not uuid.is_empty():
			_try_find_note_by_uuid(uuid)


func _focus_all_notes(note_uuids: Array[String]):
	"""Focus and highlight all notes with the given UUIDs"""
	var found_count = 0
	var containers = [SingletonObject.notes_container, SingletonObject.drawer_notes_container]
	
	for uuid in note_uuids:
		var note = SingletonObject.get_registered_object(uuid)
		if note is Note:
			_focus_note_without_scroll(note)
			found_count += 1
			continue
		
		# Try to find in containers
		for container in containers:
			if not container:
				continue
			for tab_idx in range(container.get_tab_count()):
				var tab_vbox = container.get_tab_control(tab_idx)
				if not tab_vbox:
					continue
				var found_note = _find_note_by_uuid_recursive(tab_vbox, uuid)
				if found_note:
					_focus_note_without_scroll(found_note)
					found_count += 1
					break
	
	if found_count == 0:
		SingletonObject.create_toast_notification("No notes found - they may have been deleted", ToastNotification.Type.WARNING)
	elif found_count < note_uuids.size():
		SingletonObject.create_toast_notification("Found %d of %d notes" % [found_count, note_uuids.size()], ToastNotification.Type.INFO)


func _focus_note_without_scroll(note: Note):
	"""Focus a note without scrolling - just expand and flash it"""
	if not note:
		return
	
	# Expand the note if collapsed
	if not note.expanded:
		note.expanded = true
	
	# Flash the note to draw attention
	_flash_control(note)


func _navigate_to_source(source_obj: Object):
	# Handle different source types
	if source_obj is Note:
		_focus_note(source_obj)
	elif source_obj.has_method("get") and source_obj.get("HistoryId"):
		# It's a chat history - switch to that chat
		_focus_chat(source_obj.HistoryId)
	else:
		print("[AutocoderTaskCard] Unknown source object type: %s" % source_obj)


func _focus_note(note: Note):
	if not note:
		return
	
	# Find which notes container has this note
	var containers = [SingletonObject.notes_container, SingletonObject.drawer_notes_container]
	
	for container in containers:
		if not container:
			continue
		
		# Check all tabs in the container
		for tab_idx in range(container.get_tab_count()):
			var tab_vbox = container.get_tab_control(tab_idx)
			if not tab_vbox:
				continue
			
			# Check if the note is in this tab
			if note.is_ancestor_of(tab_vbox) or tab_vbox.is_ancestor_of(note):
				# Switch to this tab
				container.current_tab = tab_idx
				
				# Expand the note if collapsed
				if not note.expanded:
					note.expanded = true
				
				# Scroll to make the note visible
				var scroll_container = tab_vbox.get_parent()
				if scroll_container is ScrollContainer:
					# Calculate scroll position to center the note
					var note_pos = note.global_position.y - scroll_container.global_position.y
					scroll_container.scroll_vertical = int(note_pos - scroll_container.size.y / 4)
				
				# Flash the note to draw attention
				_flash_control(note)
				
				print("[AutocoderTaskCard] Focused note: %s" % note.uuid)
				return
	
	# Note not found in containers - it might be detached or deleted
	print("[AutocoderTaskCard] Note not found in containers: %s" % note.uuid)
	SingletonObject.create_toast_notification("Note not found - it may have been deleted", ToastNotification.Type.WARNING)


func _focus_chat(history_id: String):
	var chat_pane = SingletonObject.Chats
	if not chat_pane:
		return
	
	for i in range(SingletonObject.ChatList.size()):
		var history = SingletonObject.ChatList[i]
		if history.HistoryId == history_id:
			chat_pane.current_tab = i
			
			# Flash the chat tab content
			var tab_container = chat_pane.get_node_or_null("%tcChats")
			if tab_container and i < tab_container.get_tab_count():
				var tab_control = tab_container.get_tab_control(i)
				if tab_control:
					_flash_control(tab_control)
			
			print("[AutocoderTaskCard] Switched to chat: %s" % history.HistoryName)
			return
	
	print("[AutocoderTaskCard] Chat not found: %s" % history_id)
	SingletonObject.create_toast_notification("Chat not found - it may have been closed", ToastNotification.Type.WARNING)


func _handle_missing_source():
	# Handle case where source object isn't found
	# Try to find it by UUID in different ways depending on source type
	if not task or task.get_primary_note_uuid().is_empty():
		return
	
	match task.source_type:
		AutocoderTask.SourceType.AGENT_TOOL:
			# For tool-created items, try to find in chat history or notes
			# The source might be a chat message or tool call
			_try_find_tool_source()
		AutocoderTask.SourceType.USER_CHAT:
			# Try to find chat by UUID
			_try_find_chat_by_uuid(task.source_uuid)
		AutocoderTask.SourceType.USER_NOTE:
			# Try to find note by UUID
			_try_find_note_by_uuid(task.get_primary_note_uuid())
		_:
			# For other types, show a message
			var message = "Source not found: %s" % task.source_context if not task.source_context.is_empty() else "Source object not available"
			SingletonObject.create_toast_notification(message, ToastNotification.Type.INFO)
			print("[AutocoderTaskCard] Source object not found for %s: %s" % [task.get_source_type_name(), task.get_primary_note_uuid()])


func _try_find_tool_source():
	# Try to find tool source in chat history
	# Tool-created items might reference a chat message or tool call
	if task.source_uuid.is_empty():
		return
	
	# Try to find in chat history
	var chat_pane = SingletonObject.Chats
	if chat_pane:
		for i in range(SingletonObject.ChatList.size()):
			var history = SingletonObject.ChatList[i]
			# Check if the source UUID matches this chat's history ID
			if history.HistoryId == task.source_uuid:
				chat_pane.current_tab = i
				SingletonObject.create_toast_notification("Opened source chat: %s" % history.HistoryName, ToastNotification.Type.INFO)
				return
	
	# Try to find as a note
	_try_find_note_by_uuid(task.source_uuid)
	
	# If still not found, show info message
	if task.source_context.is_empty():
		SingletonObject.create_toast_notification("Source not found - it may have been deleted", ToastNotification.Type.WARNING)
	else:
		SingletonObject.create_toast_notification("Source: %s (not found)" % task.source_context, ToastNotification.Type.INFO)


func _try_find_chat_by_uuid(uuid: String):
	if uuid.is_empty():
		return
	_focus_chat(uuid)


func _try_find_note_by_uuid(uuid: String):
	if uuid.is_empty():
		return
	
	# Try to find note in registered objects first
	var note = SingletonObject.get_registered_object(uuid)
	if note is Note:
		_focus_note(note)
		return
	
	# Try searching in note containers
	var containers = [SingletonObject.notes_container, SingletonObject.drawer_notes_container]
	for container in containers:
		if not container:
			continue
		
		# Search through all tabs
		for tab_idx in range(container.get_tab_count()):
			var tab_vbox = container.get_tab_control(tab_idx)
			if not tab_vbox:
				continue
			
			# Recursively search for note with matching UUID
			var found_note = _find_note_by_uuid_recursive(tab_vbox, uuid)
			if found_note:
				container.current_tab = tab_idx
				if not found_note.expanded:
					found_note.expanded = true
				_flash_control(found_note)
				return


func _find_note_by_uuid_recursive(parent: Node, uuid: String) -> Note:
	if parent is Note and parent.uuid == uuid:
		return parent
	
	for child in parent.get_children():
		var result = _find_note_by_uuid_recursive(child, uuid)
		if result:
			return result
	
	return null


func _flash_control(control: Control):
	# Visual feedback - quick flash the control
	var tween = control.create_tween()
	tween.tween_property(control, "modulate", Color(1.4, 1.4, 0.7, 1.0), 0.08)
	tween.tween_property(control, "modulate", Color.WHITE, 0.15)

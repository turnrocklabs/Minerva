class_name SessionHistoryBrowser
extends VBoxContainer

@warning_ignore("unused_signal")
signal session_selected(session_data: Dictionary)
signal session_resume_requested(session_id: String)
signal session_view_requested(session_id: String)

var _sessions: Array[Dictionary] = []
var _session_list_container: VBoxContainer
var _empty_label: Label
var _loading_label: Label
var _refresh_button: Button

func _ready() -> void:
	_build_ui()


func _build_ui() -> void:
	add_theme_constant_override("separation", 12)
	
	# Header with refresh button
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	add_child(header)

	var title_label := Label.new()
	title_label.text = "Recent Sessions"
	title_label.add_theme_font_size_override("font_size", 13)
	title_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	title_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(title_label)

	_refresh_button = Button.new()
	_refresh_button.text = "Refresh"
	_refresh_button.flat = true
	_refresh_button.add_theme_font_size_override("font_size", 12)
	_refresh_button.pressed.connect(_on_refresh_pressed)
	header.add_child(_refresh_button)

	# Scroll container for sessions
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 120)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	# Session list container
	_session_list_container = VBoxContainer.new()
	_session_list_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_session_list_container.add_theme_constant_override("separation", 8)
	scroll.add_child(_session_list_container)

	# Loading label
	_loading_label = Label.new()
	_loading_label.text = "Loading sessions..."
	_loading_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_loading_label.add_theme_font_size_override("font_size", 12)
	_loading_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	_loading_label.visible = false
	_session_list_container.add_child(_loading_label)

	# Empty state label
	_empty_label = Label.new()
	_empty_label.text = "No previous sessions found.\nStart a new generation to create your first session."
	_empty_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_label.add_theme_font_size_override("font_size", 12)
	_empty_label.add_theme_color_override("font_color", Color(0.45, 0.45, 0.5))
	_empty_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty_label.visible = false
	_session_list_container.add_child(_empty_label)


func set_sessions(sessions: Array[Dictionary]) -> void:
	print("[SessionHistoryBrowser] set_sessions called with %d sessions" % sessions.size())
	_sessions = sessions.duplicate()
	_refresh_display()


func _refresh_display() -> void:
	print("[SessionHistoryBrowser] _refresh_display called with %d sessions" % _sessions.size())
	# Clear existing session cards (keep loading and empty labels)
	for child in _session_list_container.get_children():
		if child != _loading_label and child != _empty_label:
			child.queue_free()

	if _sessions.is_empty():
		print("[SessionHistoryBrowser] No sessions to display, showing empty label")
		_empty_label.visible = true
		_loading_label.visible = false
		return

	_empty_label.visible = false
	_loading_label.visible = false

	# Sort sessions by created_at (newest first)
	var sorted_sessions = _sessions.duplicate()
	sorted_sessions.sort_custom(func(a, b): return a.get("created_at", "") > b.get("created_at", ""))

	print("[SessionHistoryBrowser] Building cards for %d sessions" % _sessions.size())
	# Create cards for each session
	for session in sorted_sessions:
		var card = _build_session_card(session)
		if card:
			print("[SessionHistoryBrowser] Added session card for: %s" % session.get("session_id", "unknown"))
			_session_list_container.add_child(card)
		else:
			print("[SessionHistoryBrowser] Failed to build card for session: %s" % session.get("session_id", "unknown"))


func _build_session_card(session: Dictionary) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.mouse_filter = Control.MOUSE_FILTER_PASS
	
	# Enable double-click handling
	var session_id = str(session.get("session_id", ""))
	var click_count = [0]  # Use array to capture in closures
	var click_timer = Timer.new()
	click_timer.one_shot = true
	click_timer.wait_time = 0.3
	panel.add_child(click_timer)
	
	panel.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			click_count[0] += 1
			if click_count[0] == 1:
				# Start timer for single click
				click_timer.start()
			elif click_count[0] == 2:
				# Double-click detected
				click_timer.stop()
				click_count[0] = 0
				_on_session_double_clicked(session)
	)
	
	click_timer.timeout.connect(func():
		# Single click timeout - reset
		click_count[0] = 0
	)

	var status = str(session.get("status", "unknown")).to_lower()
	var status_color = _get_status_color(status)

	# Modern card style with subtle left border accent
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.12)
	style.border_color = Color(0.18, 0.18, 0.2)
	style.set_border_width_all(1)
	style.border_width_left = 3
	style.border_color = status_color.darkened(0.3)
	style.set_corner_radius_all(10)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	# Header row: session ID + status badge
	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 10)
	vbox.add_child(header_row)

	var short_id = session_id.substr(0, 18) if session_id.length() > 18 else session_id

	var id_label := Label.new()
	id_label.text = short_id
	id_label.add_theme_font_size_override("font_size", 13)
	id_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.92))
	id_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(id_label)

	# Status badge with modern pill style
	var status_badge := Label.new()
	status_badge.text = _get_status_emoji(status) + " " + status.capitalize()
	status_badge.add_theme_font_size_override("font_size", 10)
	status_badge.add_theme_color_override("font_color", status_color)

	var badge_style := StyleBoxFlat.new()
	badge_style.bg_color = status_color.darkened(0.75)
	badge_style.set_corner_radius_all(10)
	badge_style.content_margin_left = 8
	badge_style.content_margin_right = 8
	badge_style.content_margin_top = 3
	badge_style.content_margin_bottom = 3
	status_badge.add_theme_stylebox_override("normal", badge_style)
	header_row.add_child(status_badge)

	# Prompt preview
	var prompt = str(session.get("prompt", "No prompt"))
	var prompt_preview = prompt.substr(0, 80)
	if prompt.length() > 80:
		prompt_preview += "..."

	var prompt_label := Label.new()
	prompt_label.text = prompt_preview
	prompt_label.add_theme_font_size_override("font_size", 12)
	prompt_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	prompt_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(prompt_label)

	# Footer row: timestamp + actions
	var footer_row := HBoxContainer.new()
	footer_row.add_theme_constant_override("separation", 10)
	vbox.add_child(footer_row)

	# Timestamp
	var created_at = str(session.get("created_at", ""))
	var time_label := Label.new()
	time_label.text = _format_timestamp(created_at)
	time_label.add_theme_font_size_override("font_size", 11)
	time_label.add_theme_color_override("font_color", Color(0.45, 0.45, 0.5))
	time_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer_row.add_child(time_label)

	# Action buttons with modern flat style
	var view_btn := Button.new()
	view_btn.text = "View"
	view_btn.flat = true
	view_btn.add_theme_font_size_override("font_size", 11)
	view_btn.pressed.connect(func(): _on_session_view_clicked(session))
	footer_row.add_child(view_btn)

	# Only show resume button for active sessions
	if status in ["in_review", "processing", "active", "awaiting_user"]:
		var resume_btn := Button.new()
		resume_btn.text = "Resume"
		resume_btn.flat = true
		resume_btn.add_theme_font_size_override("font_size", 11)
		resume_btn.add_theme_color_override("font_color", Color(0.5, 0.9, 0.7))
		resume_btn.pressed.connect(func(): _on_session_resume_clicked(session))
		footer_row.add_child(resume_btn)

	return panel


func _get_status_emoji(status: String) -> String:
	match status.to_lower():
		"complete":
			return "✅"
		"in_review", "awaiting_user":
			return "🔍"
		"processing", "active":
			return "⚡"
		"error":
			return "❌"
		_:
			return "◯"


func _get_status_color(status: String) -> Color:
	match status.to_lower():
		"complete":
			return Color(0.4, 0.9, 0.5)
		"in_review", "awaiting_user":
			return Color(0.95, 0.8, 0.3)
		"processing", "active":
			return Color(0.5, 0.8, 1.0)
		"error":
			return Color(0.95, 0.4, 0.4)
		_:
			return Color(0.55, 0.55, 0.6)


func _format_timestamp(timestamp: String) -> String:
	# Convert ISO timestamp to readable format
	# "2025-11-28T12:00:00Z" -> "Nov 28, 12:00"
	if timestamp.is_empty():
		return "Unknown"

	# Simple parsing for display
	if timestamp.length() >= 16:
		var date_part = timestamp.substr(0, 10)  # "2025-11-28"
		var time_part = timestamp.substr(11, 5)  # "12:00"
		return "%s %s" % [date_part, time_part]

	return timestamp


func _on_session_view_clicked(session: Dictionary) -> void:
	var session_id = str(session.get("session_id", ""))
	if not session_id.is_empty():
		session_view_requested.emit(session_id)


func _on_session_resume_clicked(session: Dictionary) -> void:
	var session_id = str(session.get("session_id", ""))
	if not session_id.is_empty():
		session_resume_requested.emit(session_id)


func _on_session_double_clicked(session: Dictionary) -> void:
	"""Handle double-click on a session card - same as resume"""
	var session_id = str(session.get("session_id", ""))
	if not session_id.is_empty():
		print("[SessionHistoryBrowser] Double-click detected for session: %s" % session_id)
		session_resume_requested.emit(session_id)


func _on_refresh_pressed() -> void:
	_loading_label.visible = true
	_empty_label.visible = false
	_refresh_button.disabled = true

	if not SingletonObject.autocoder_manager or not SingletonObject.autocoder_manager.autocoder_adapter:
		SingletonObject.ErrorDisplay("Can't refresh", "Autocoder not connected")
		_loading_label.visible = false
		_refresh_button.disabled = false
		return

	var sessions = await SingletonObject.autocoder_manager.autocoder_adapter.list_sessions()

	_loading_label.visible = false
	_refresh_button.disabled = false

	set_sessions(sessions)


func show_loading() -> void:
	_loading_label.visible = true
	_empty_label.visible = false


func hide_loading() -> void:
	_loading_label.visible = false

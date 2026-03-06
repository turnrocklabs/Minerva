class_name LedgerBrowserWindow
extends Window

var _entry_list: ItemList
var _detail_scroll: ScrollContainer
var _detail_vbox: VBoxContainer
var _summary_label: RichTextLabel
var _messages_vbox: VBoxContainer
var _filter_button: CheckButton
var _delete_button: Button
var _no_entries_label: Label

var _current_entries: Array[LedgerEntry] = []
var _selected_entry: LedgerEntry = null


func _ready():
	title = "Compaction Ledger"
	size = Vector2i(900, 600)
	initial_position = Window.WINDOW_INITIAL_POSITION_CENTER_SCREEN_WITH_MOUSE_FOCUS
	transient = true
	close_requested.connect(hide)

	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.set_anchor(SIDE_RIGHT, 1.0)
	margin.set_anchor(SIDE_BOTTOM, 1.0)
	margin.offset_left = 0
	margin.offset_top = 0
	margin.offset_right = 0
	margin.offset_bottom = 0
	margin.grow_horizontal = Control.GROW_DIRECTION_BOTH
	margin.grow_vertical = Control.GROW_DIRECTION_BOTH
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 12)
	add_child(margin)

	var main_vbox := VBoxContainer.new()
	main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_theme_constant_override("separation", 8)
	margin.add_child(main_vbox)

	# Header with filter toggle
	var header := HBoxContainer.new()
	main_vbox.add_child(header)

	var title_label := Label.new()
	title_label.text = "Compaction Ledger"
	title_label.add_theme_font_size_override("font_size", 18)
	header.add_child(title_label)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(spacer)

	_filter_button = CheckButton.new()
	_filter_button.text = "Current chat only"
	_filter_button.toggled.connect(_on_filter_toggled)
	header.add_child(_filter_button)

	var sep := HSeparator.new()
	main_vbox.add_child(sep)

	# Split: entry list on left, detail on right
	var hsplit := HSplitContainer.new()
	hsplit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hsplit.size_flags_vertical = Control.SIZE_EXPAND_FILL
	hsplit.split_offset = 300
	main_vbox.add_child(hsplit)

	# Left: entry list
	var left_vbox := VBoxContainer.new()
	left_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left_vbox.custom_minimum_size.x = 250
	hsplit.add_child(left_vbox)

	_entry_list = ItemList.new()
	_entry_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_entry_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_entry_list.item_selected.connect(_on_entry_selected)
	left_vbox.add_child(_entry_list)

	_delete_button = Button.new()
	_delete_button.text = "Delete Entry"
	_delete_button.disabled = true
	_delete_button.pressed.connect(_on_delete_pressed)
	left_vbox.add_child(_delete_button)

	_no_entries_label = Label.new()
	_no_entries_label.text = "No ledger entries found."
	_no_entries_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_no_entries_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_no_entries_label.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_no_entries_label.visible = false
	left_vbox.add_child(_no_entries_label)

	# Right: detail view
	_detail_scroll = ScrollContainer.new()
	_detail_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	hsplit.add_child(_detail_scroll)

	_detail_vbox = VBoxContainer.new()
	_detail_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_detail_vbox.add_theme_constant_override("separation", 8)
	_detail_scroll.add_child(_detail_vbox)

	# Summary section
	var summary_header := Label.new()
	summary_header.text = "Summary"
	summary_header.add_theme_font_size_override("font_size", 14)
	_detail_vbox.add_child(summary_header)

	_summary_label = RichTextLabel.new()
	_summary_label.bbcode_enabled = true
	_summary_label.fit_content = true
	_summary_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_summary_label.custom_minimum_size.y = 80
	_detail_vbox.add_child(_summary_label)

	var msg_sep := HSeparator.new()
	_detail_vbox.add_child(msg_sep)

	var msg_header := Label.new()
	msg_header.text = "Original Messages"
	msg_header.add_theme_font_size_override("font_size", 14)
	_detail_vbox.add_child(msg_header)

	_messages_vbox = VBoxContainer.new()
	_messages_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_messages_vbox.add_theme_constant_override("separation", 4)
	_detail_vbox.add_child(_messages_vbox)

	_clear_detail()


func open(filter_current_chat: bool = false) -> void:
	_filter_button.button_pressed = filter_current_chat
	_refresh_entries()
	popup_centered()


func _refresh_entries() -> void:
	_entry_list.clear()
	_current_entries.clear()
	_selected_entry = null
	_delete_button.disabled = true
	_clear_detail()

	var lm: LedgerManager = SingletonObject.ledger_manager
	if not lm:
		_show_no_entries(true)
		return

	var entries: Array[LedgerEntry]
	if _filter_button.button_pressed and not SingletonObject.ChatList.is_empty():
		var current_chat: ServiceHistory = SingletonObject.ChatList[SingletonObject.Chats.current_tab]
		entries = lm.get_entries_for_chat(current_chat.HistoryId)
	else:
		entries = lm.entries

	_show_no_entries(entries.is_empty())

	# Show newest first
	for i in range(entries.size() - 1, -1, -1):
		var e: LedgerEntry = entries[i]
		_current_entries.append(e)
		var label := "%s\n%s  |  %s" % [e.chat_name, e.timestamp, e.message_range]
		_entry_list.add_item(label)


func _show_no_entries(should_show: bool) -> void:
	_no_entries_label.visible = should_show
	_entry_list.visible = not should_show


func _on_entry_selected(index: int) -> void:
	if index < 0 or index >= _current_entries.size():
		return
	_selected_entry = _current_entries[index]
	_delete_button.disabled = false
	_show_detail(_selected_entry)


func _show_detail(entry: LedgerEntry) -> void:
	_summary_label.text = entry.summary_text if not entry.summary_text.is_empty() else "(no summary)"

	# Clear old messages
	for child in _messages_vbox.get_children():
		child.queue_free()

	if entry.original_messages.is_empty():
		var empty_label := Label.new()
		empty_label.text = "(no original messages stored)"
		_messages_vbox.add_child(empty_label)
		return

	for msg in entry.original_messages:
		var panel := PanelContainer.new()
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var style := StyleBoxFlat.new()
		var role: String = str(msg.get("role", ""))
		if "1" in role or "USER" in role.to_upper():
			style.bg_color = Color(0.15, 0.18, 0.25)
		else:
			style.bg_color = Color(0.12, 0.14, 0.18)
		style.set_corner_radius_all(6)
		style.set_content_margin_all(8)
		panel.add_theme_stylebox_override("panel", style)

		var msg_vbox := VBoxContainer.new()
		panel.add_child(msg_vbox)

		# Role header
		var role_label := Label.new()
		var role_text := _role_display(msg)
		role_label.text = role_text
		role_label.add_theme_font_size_override("font_size", 11)
		role_label.add_theme_color_override("font_color", Color(0.6, 0.65, 0.7))
		msg_vbox.add_child(role_label)

		# Message body
		var body := RichTextLabel.new()
		body.bbcode_enabled = true
		body.fit_content = true
		body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var text: String = msg.get("message", "")
		if text.length() > 2000:
			text = text.substr(0, 2000) + "\n... (truncated)"
		body.text = text
		msg_vbox.add_child(body)

		_messages_vbox.add_child(panel)


func _role_display(msg: Dictionary) -> String:
	var role = msg.get("role", "")
	# ChatHistoryItem.ChatRole enum: 0=USER, 1=ASSISTANT/MODEL, 2=SYSTEM, 3=TOOL
	match str(role):
		"0": return "USER"
		"1": return "ASSISTANT"
		"2": return "SYSTEM"
		"3": return "TOOL" + (" (%s)" % msg.get("tool_name", "") if msg.get("tool_name", "") else "")
		_: return str(role).to_upper()


func _clear_detail() -> void:
	_summary_label.text = "Select an entry to view details."
	for child in _messages_vbox.get_children():
		child.queue_free()


func _on_filter_toggled(_on: bool) -> void:
	_refresh_entries()


func _on_delete_pressed() -> void:
	if not _selected_entry:
		return
	var lm: LedgerManager = SingletonObject.ledger_manager
	if lm and lm.remove_entry(_selected_entry.id):
		SingletonObject.create_toast_notification("Ledger entry deleted")
		_refresh_entries()

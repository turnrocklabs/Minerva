class_name ChatHeader
extends HBoxContainer
## Header control for chat tabs with per-chat agent mode and bulk actions.
## Sits at the top of each chat tab.

signal agent_mode_toggled(enabled: bool)

var agent_mode_toggle: CheckButton
var editor_button: Button
var notes_button: Button

var chat_history  # ChatHistory


## Setup must be called after instantiation
func setup(history) -> void:
	chat_history = history
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_theme_constant_override("separation", 8)

	# Agent indicator label (for triggered agent chats)
	if history.IsAgentChat:
		var agent_label = Label.new()
		agent_label.text = "[Agent]"
		agent_label.add_theme_color_override("font_color", Color(0.3, 0.7, 1.0))
		agent_label.tooltip_text = "Triggered agent chat"
		add_child(agent_label)

	# Agent mode toggle (always interactive — focused chats can turn off agent mode for plain chat)
	agent_mode_toggle = CheckButton.new()
	agent_mode_toggle.text = "Agent"
	agent_mode_toggle.tooltip_text = "Enable Agent Mode for this chat"
	agent_mode_toggle.button_pressed = history.AgentModeEnabled
	var gears_icon = load("res://assets/icons/gear_icons/gears_icon_24_no_bg.png")
	if gears_icon:
		agent_mode_toggle.icon = gears_icon
	agent_mode_toggle.toggled.connect(_on_agent_mode_toggled)
	add_child(agent_mode_toggle)

	# Focused chat indicator (after agent toggle — visually to its right)
	if history.StaticToolMode:
		var focused_label = Label.new()
		focused_label.text = "[Focused: %d tools]" % history.ConfiguredTools.size()
		focused_label.add_theme_color_override("font_color", Color(0.9, 0.7, 0.2))
		if not history.ConfiguredSkills.is_empty():
			focused_label.tooltip_text = "Skills: %s" % ", ".join(history.ConfiguredSkills)
		else:
			focused_label.tooltip_text = "Fixed tool set (no dynamic discovery)"
		add_child(focused_label)

	# Passthrough chat indicator (chat-passthrough W2) — provider is contractually
	# bound to a terminal-backed plugin entry for the chat's life.
	if history.PassthroughMode:
		var passthrough_label = Label.new()
		passthrough_label.text = "[Passthrough: %s]" % history.PassthroughName
		passthrough_label.add_theme_color_override("font_color", Color(0.4, 0.85, 0.6))
		passthrough_label.tooltip_text = "Passthrough chat — provider is fixed for this chat's life"
		add_child(passthrough_label)

	# Spacer
	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(spacer)

	# Editor button
	editor_button = Button.new()
	editor_button.tooltip_text = "Push chat to editor"
	editor_button.flat = true
	var code_icon = load("res://assets/icons/code_syntax/code_syntax_24.png")
	if code_icon:
		editor_button.icon = code_icon
	editor_button.pressed.connect(_on_editor_button_pressed)
	add_child(editor_button)

	# Notes button
	notes_button = Button.new()
	notes_button.tooltip_text = "Create notes from messages"
	notes_button.flat = true
	var pencil_icon = load("res://assets/generated/pencil_icon_24_no_bg.png")
	if pencil_icon:
		notes_button.icon = pencil_icon
	notes_button.pressed.connect(_on_notes_button_pressed)
	add_child(notes_button)


## Handle agent mode toggle
func _on_agent_mode_toggled(toggled_on: bool) -> void:
	print("[ChatHeader] Toggle pressed: %s, chat_history=%s" % [toggled_on, chat_history])
	if chat_history:
		chat_history.AgentModeEnabled = toggled_on
		print("[ChatHeader] Set AgentModeEnabled=%s on history '%s' (id=%s)" % [toggled_on, chat_history.HistoryName, chat_history.HistoryId])
		agent_mode_toggled.emit(toggled_on)

		if toggled_on:
			var mcp = SingletonObject.get_mcp_manager()
			var tools = mcp.get_available_tools()
			print("[Agent Mode] Enabled for '%s' with %d tools" % [chat_history.HistoryName, tools.size()])
		else:
			print("[Agent Mode] Disabled for '%s'" % chat_history.HistoryName)
	else:
		print("[ChatHeader] ERROR: chat_history is null!")


## Push entire chat to code editor
func _on_editor_button_pressed() -> void:
	if not chat_history:
		return

	var content = _format_chat_for_editor()
	var ep = SingletonObject.editor_pane
	var tab = ep.add(Editor.Type.TEXT, null, chat_history.HistoryName, null)  # 0 = Editor.Type.TEXT
	if tab and tab.code_edit:
		tab.code_edit.text = content
	ep.update_tabs_icon()


## Create notes from each message
func _on_notes_button_pressed() -> void:
	if not chat_history:
		return

	var count := 0
	var role_names = ["USER", "ASSISTANT", "SYSTEM", "TOOL_RESULT"]
	for item in chat_history.HistoryItemList:
		if item.Message.is_empty():
			continue

		var role_name = role_names[item.Role] if item.Role < role_names.size() else "UNKNOWN"
		var preview = item.Message.left(30).replace("\n", " ")
		var title = "%s: %s..." % [role_name, preview]
		var note = Note.create_text_note(title, item.Message)
		SingletonObject.notes_container.add_note(note)
		count += 1

	if count > 0:
		SingletonObject.main_ui.set_notes_pane_visible(true)
		print("[ChatHeader] Created %d notes from chat" % count)


## Format chat history as markdown for editor
func _format_chat_for_editor() -> String:
	var parts: PackedStringArray = []
	parts.append("# Chat: %s\n" % chat_history.HistoryName)

	var role_names = ["USER", "ASSISTANT", "SYSTEM", "TOOL_RESULT"]
	for item in chat_history.HistoryItemList:
		if item.Message.is_empty():
			continue

		var role_name = role_names[item.Role] if item.Role < role_names.size() else "UNKNOWN"
		parts.append("## %s\n" % role_name)
		parts.append(item.Message)
		parts.append("\n---\n")

	return "\n".join(parts)

class_name ChatHeader
extends HBoxContainer
## Header control for chat tabs with per-chat agent mode and bulk actions.
## Sits at the top of each chat tab.

signal agent_mode_toggled(enabled: bool)

var agent_mode_toggle: CheckButton
var editor_button: Button
var summarize_button: Button
var notes_button: Button
var tool_sets_button: MenuButton
var _tool_manager: MCPManager
var _tool_set_names: Array[String] = []

var chat_history: ServiceHistory


## Setup must be called after instantiation
func setup(history: ServiceHistory, tool_manager: MCPManager = null, skills: SkillManager = null) -> void:
	if chat_history and chat_history.agent_mode_changed.is_connected(_sync_agent_mode):
		chat_history.agent_mode_changed.disconnect(_sync_agent_mode)
	if chat_history and chat_history.tool_sets_changed.is_connected(_refresh_tool_set_chip):
		chat_history.tool_sets_changed.disconnect(_refresh_tool_set_chip)
	chat_history = history
	_tool_manager = tool_manager
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
	agent_mode_toggle.set_pressed_no_signal(history.AgentModeEnabled)
	history.agent_mode_changed.connect(_sync_agent_mode)
	var gears_icon = load("res://assets/icons/gear_icons/gears_icon_24_no_bg.png")
	if gears_icon:
		agent_mode_toggle.icon = gears_icon
	agent_mode_toggle.toggled.connect(_on_agent_mode_toggled)
	add_child(agent_mode_toggle)

	if _tool_manager != null:
		tool_sets_button = MenuButton.new()
		tool_sets_button.flat = true
		var popup: PopupMenu = tool_sets_button.get_popup()
		popup.hide_on_checkable_item_selection = false
		popup.about_to_popup.connect(_populate_tool_sets)
		popup.id_pressed.connect(_on_tool_set_pressed)
		history.tool_sets_changed.connect(_refresh_tool_set_chip)
		_tool_manager.tools_refreshed.connect(_refresh_tool_set_chip)
		if skills != null:
			skills.active_skills_changed.connect(_refresh_tool_set_chip)
			skills.skills_changed.connect(_refresh_tool_set_chip)
		add_child(tool_sets_button)
		_refresh_tool_set_chip()

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

	# Summarize-to-note button (chat-passthrough W6) — THE deliberate
	# token-spend gesture for passthrough chats (their transport has no LLM).
	# Visible ONLY for passthrough chats; one explicit LLM call per press.
	summarize_button = Button.new()
	summarize_button.tooltip_text = "Summarize to note"
	summarize_button.flat = true
	var summarize_icon = load("res://assets/icons/file/file_24.svg")
	if summarize_icon:
		summarize_button.icon = summarize_icon
	summarize_button.visible = history.PassthroughMode
	summarize_button.pressed.connect(_on_summarize_button_pressed)
	add_child(summarize_button)

	# Notes button
	notes_button = Button.new()
	notes_button.tooltip_text = "Create notes from messages"
	notes_button.flat = true
	var pencil_icon = load("res://assets/generated/pencil_icon_24_no_bg.png")
	if pencil_icon:
		notes_button.icon = pencil_icon
	notes_button.pressed.connect(_on_notes_button_pressed)
	add_child(notes_button)


func _refresh_tool_set_chip() -> void:
	if _tool_manager == null or not is_instance_valid(tool_sets_button):
		return
	var sets: Array[String] = _tool_manager._effective_tool_sets_for_history(chat_history)
	var label: String = "all"
	if sets.size() == 1 and sets[0] == "meta":
		label = "meta only"
	elif not sets.is_empty():
		label = ", ".join(sets) if sets.size() <= 2 else "%d sets" % sets.size()
	tool_sets_button.text = "Tools: %s" % label
	tool_sets_button.tooltip_text = "Agent mode tool sets: %s. Use inherited sets to follow skills and preferences." % (", ".join(sets) if not sets.is_empty() else "all")
	if tool_sets_button.get_popup().visible:
		_populate_tool_sets()


func _populate_tool_sets() -> void:
	var popup: PopupMenu = tool_sets_button.get_popup()
	popup.clear()
	popup.add_check_item("Use inherited sets", 0)
	popup.set_item_checked(0, chat_history.ToolSetOverride.is_empty())
	popup.add_separator()
	_tool_set_names.assign(_tool_manager.get_tool_set_counts().keys())
	_tool_set_names.sort()
	var enabled: Array[String] = _tool_manager._effective_tool_sets_for_history(chat_history)
	for index: int in range(_tool_set_names.size()):
		popup.add_check_item(_tool_set_names[index], 100 + index)
		popup.set_item_checked(popup.get_item_index(100 + index), enabled.is_empty() or _tool_set_names[index] in enabled)


func _on_tool_set_pressed(id: int) -> void:
	if id == 0:
		chat_history.ToolSetOverride = []
	elif id >= 100 and id - 100 < _tool_set_names.size():
		_tool_manager.toggle_tool_set(chat_history, _tool_set_names[id - 100])


## Model updates also arrive for background chats. Rendering must not dispatch
## a user gesture or reconfigure another chat.
func _sync_agent_mode(enabled: bool) -> void:
	if is_instance_valid(agent_mode_toggle):
		agent_mode_toggle.set_pressed_no_signal(enabled)


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


## Summarize the passthrough transcript into a linked note (chat-passthrough W6).
## Delegates to ChatPane's engine (one explicit LLM call on the fixed distill
## model). Button is disabled while the call is in flight — no double-spend.
func _on_summarize_button_pressed() -> void:
	if not chat_history or not chat_history.PassthroughMode:
		return
	var pane = SingletonObject.Chats
	if pane == null or not pane.has_method("summarize_passthrough_to_note"):
		return
	# A press while a summarize is in flight is a no-op — returning here keeps
	# the button disabled (re-enabling is the first flight's job).
	if pane.has_method("is_summarize_in_flight") and pane.is_summarize_in_flight(chat_history):
		return
	summarize_button.disabled = true
	await pane.summarize_passthrough_to_note(chat_history)
	if is_instance_valid(summarize_button):
		summarize_button.disabled = false


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

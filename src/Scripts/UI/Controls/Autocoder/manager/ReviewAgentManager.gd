class_name AutocoderReviewAgentManager
extends VBoxContainer

const DEFAULT_MODEL: String = "anthropic/claude-sonnet-4"

@onready var _refresh_button: Button = %RefreshButton
@onready var _name_line_edit: LineEdit = %NameLineEdit
@onready var _model_line_edit: LineEdit = %ModelLineEdit
@onready var _tools_enabled_check_box: CheckBox = %ToolsEnabledCheckBox
@onready var _prompt_text_edit: TextEdit = %PromptTextEdit
@onready var _setup_commands_text_edit: TextEdit = %SetupCommandsTextEdit
@onready var _save_button: Button = %SaveButton
@onready var _cancel_edit_button: Button = %CancelEditButton
@onready var _clear_button: Button = %ClearButton
@onready var _agents_list: VBoxContainer = %AgentsList
@onready var _loading_label: Label = %LoadingLabel
@onready var _empty_label: Label = %EmptyLabel

var _agents: Array[Dictionary] = []
var _editing_agent_id: String = ""

# Drag and drop state
#var _dragging_card: PanelContainer = null
#var _drag_start_index: int = -1
#var _drag_preview: Control = null


func _ready() -> void:
	_refresh_button.pressed.connect(_on_refresh_pressed)
	_save_button.pressed.connect(_on_save_pressed)
	_cancel_edit_button.pressed.connect(_on_cancel_edit_pressed)
	_clear_button.pressed.connect(_on_clear_pressed)

	_reset_form()
	_refresh_agents.call_deferred()


func _get_adapter() -> AutocoderAdapter:
	if not SingletonObject.autocoder_manager:
		return null
	return SingletonObject.autocoder_manager.autocoder_adapter


func _reset_form() -> void:
	_editing_agent_id = ""
	_name_line_edit.text = ""
	_prompt_text_edit.text = ""
	_setup_commands_text_edit.text = ""
	_model_line_edit.text = DEFAULT_MODEL
	_tools_enabled_check_box.button_pressed = false
	_save_button.text = "Create Agent"
	_cancel_edit_button.visible = false


func _set_edit_mode(agent: Dictionary) -> void:
	_editing_agent_id = str(agent.get("agent_id", ""))
	_name_line_edit.text = str(agent.get("name", ""))
	_prompt_text_edit.text = str(agent.get("prompt", ""))
	_model_line_edit.text = str(agent.get("model", DEFAULT_MODEL))
	_tools_enabled_check_box.button_pressed = bool(agent.get("tools_enabled", false))
	_setup_commands_text_edit.text = _format_setup_commands(agent.get("setup_commands", []))
	_save_button.text = "Update Agent"
	_cancel_edit_button.visible = true


func _refresh_agents() -> void:
	_loading_label.visible = true
	_empty_label.visible = false
	_refresh_button.disabled = true

	var adapter = _get_adapter()
	if not adapter:
		_agents = []
		_refresh_list()
		_loading_label.visible = false
		_refresh_button.disabled = false
		_empty_label.text = "Connect to core to load review agents."
		_empty_label.visible = true
		return

	var agents = await adapter.list_review_agents()
	_agents = agents

	_loading_label.visible = false
	_refresh_button.disabled = false
	_refresh_list()


func _refresh_list() -> void:
	for child in _agents_list.get_children():
		if child == _loading_label or child == _empty_label:
			continue
		child.queue_free()

	if _agents.is_empty():
		_empty_label.text = "No review agents yet. Create one above."
		_empty_label.visible = true
		return

	_empty_label.visible = false

	# Sort by order field (ascending - lower numbers = higher priority)
	var sorted_agents = _agents.duplicate()
	sorted_agents.sort_custom(func(a, b): return int(a.get("order", 999)) < int(b.get("order", 999)))

	for i in range(sorted_agents.size()):
		var agent = sorted_agents[i]
		var card = _build_agent_card(agent, i)
		_agents_list.add_child(card)


func _build_agent_card(agent: Dictionary, index: int) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var tools_enabled = bool(agent.get("tools_enabled", false))
	var border_color = Color(0.25, 0.5, 0.35) if tools_enabled else Color(0.2, 0.2, 0.22)

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.12)
	style.border_color = border_color
	style.set_border_width_all(1)
	style.border_width_left = 3 if tools_enabled else 1
	style.set_corner_radius_all(10)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", style)
	
	# Store agent data and index for drag-drop
	panel.set_meta("agent_id", str(agent.get("agent_id", "")))
	panel.set_meta("agent_data", agent)
	panel.set_meta("index", index)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 8)
	panel.add_child(vbox)

	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	vbox.add_child(header)
	
	# Drag handle
	var drag_handle := Label.new()
	drag_handle.text = "⋮⋮"
	drag_handle.add_theme_font_size_override("font_size", 14)
	drag_handle.add_theme_color_override("font_color", Color(0.4, 0.4, 0.45))
	drag_handle.mouse_filter = Control.MOUSE_FILTER_STOP
	drag_handle.mouse_default_cursor_shape = Control.CURSOR_MOVE
	drag_handle.tooltip_text = "Drag to reorder"
	header.add_child(drag_handle)
	
	# Order indicator
	var order_label := Label.new()
	order_label.text = "#%d" % (index + 1)
	order_label.add_theme_font_size_override("font_size", 11)
	order_label.add_theme_color_override("font_color", Color(0.4, 0.6, 0.8))
	order_label.custom_minimum_size.x = 30
	header.add_child(order_label)

	var name_label := Label.new()
	name_label.text = str(agent.get("name", "Unnamed Agent"))
	name_label.add_theme_font_size_override("font_size", 14)
	name_label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.97))
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(name_label)

	var model_text = str(agent.get("model", ""))
	var model_label := Label.new()
	model_label.text = model_text if not model_text.is_empty() else "default model"
	model_label.add_theme_font_size_override("font_size", 11)
	model_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	header.add_child(model_label)
	
	# Move up/down buttons
	var move_up_button := Button.new()
	move_up_button.text = "▲"
	move_up_button.flat = true
	move_up_button.add_theme_font_size_override("font_size", 10)
	move_up_button.disabled = (index == 0)
	move_up_button.tooltip_text = "Move up"
	move_up_button.pressed.connect(func(): _on_move_agent(str(agent.get("agent_id", "")), -1))
	header.add_child(move_up_button)
	
	var move_down_button := Button.new()
	move_down_button.text = "▼"
	move_down_button.flat = true
	move_down_button.add_theme_font_size_override("font_size", 10)
	move_down_button.disabled = (index >= _agents.size() - 1)
	move_down_button.tooltip_text = "Move down"
	move_down_button.pressed.connect(func(): _on_move_agent(str(agent.get("agent_id", "")), 1))
	header.add_child(move_down_button)

	var prompt_preview := str(agent.get("prompt", ""))
	if prompt_preview.length() > 140:
		prompt_preview = "%s..." % prompt_preview.substr(0, 140)

	var prompt_label := Label.new()
	prompt_label.text = prompt_preview
	prompt_label.add_theme_font_size_override("font_size", 12)
	prompt_label.add_theme_color_override("font_color", Color(0.65, 0.65, 0.7))
	prompt_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(prompt_label)

	var footer := HBoxContainer.new()
	footer.add_theme_constant_override("separation", 12)
	vbox.add_child(footer)

	var setup_count = _get_setup_count(agent.get("setup_commands", []))
	var meta_label := Label.new()
	var tools_text = "🔧 Tools On" if tools_enabled else "Tools Off"
	meta_label.text = "Setup: %d | %s" % [setup_count, tools_text]
	meta_label.add_theme_font_size_override("font_size", 11)
	meta_label.add_theme_color_override("font_color", Color(0.45, 0.45, 0.5))
	meta_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(meta_label)

	var edit_button := Button.new()
	edit_button.text = "Edit"
	edit_button.flat = true
	edit_button.add_theme_font_size_override("font_size", 12)
	edit_button.pressed.connect(func(): _on_edit_agent_pressed(agent))
	footer.add_child(edit_button)

	var delete_button := Button.new()
	delete_button.text = "Delete"
	delete_button.flat = true
	delete_button.add_theme_font_size_override("font_size", 12)
	delete_button.add_theme_color_override("font_color", Color(0.9, 0.5, 0.5))
	delete_button.pressed.connect(func(): _on_delete_agent_pressed(str(agent.get("agent_id", ""))))
	footer.add_child(delete_button)

	return panel


func _format_setup_commands(commands: Variant) -> String:
	if commands is Array:
		var lines: Array[String] = []
		for cmd in commands:
			lines.append(str(cmd))
		return "\n".join(lines)
	return ""


func _parse_setup_commands(text: String) -> Array[String]:
	var commands: Array[String] = []
	for line in text.split("\n"):
		var trimmed = line.strip_edges()
		if not trimmed.is_empty():
			commands.append(trimmed)
	return commands


func _get_setup_count(commands: Variant) -> int:
	if commands is Array:
		return commands.size()
	return 0


func _on_refresh_pressed() -> void:
	await _refresh_agents()


func _on_save_pressed() -> void:
	var name_ = _name_line_edit.text.strip_edges()
	var prompt = _prompt_text_edit.text.strip_edges()

	if name_.is_empty() or prompt.is_empty():
		SingletonObject.ErrorDisplay("Missing Fields", "Name and prompt are required.")
		return

	var adapter = _get_adapter()
	if not adapter:
		SingletonObject.ErrorDisplay("Not Connected", "Please connect to core first.")
		return

	_save_button.disabled = true

	var model = _model_line_edit.text.strip_edges()
	var tools_enabled = _tools_enabled_check_box.button_pressed
	var setup_commands = _parse_setup_commands(_setup_commands_text_edit.text)

	if _editing_agent_id.is_empty():
		var agent_id = await adapter.create_review_agent(name, prompt, setup_commands, model, tools_enabled)
		if agent_id.is_empty():
			_save_button.disabled = false
			return
		SingletonObject.create_toast_notification("Review agent created.", ToastNotification.Type.SUCCESS)
	else:
		var ok = await adapter.update_review_agent(_editing_agent_id, name, prompt, setup_commands, model, tools_enabled)
		if not ok:
			_save_button.disabled = false
			return
		SingletonObject.create_toast_notification("Review agent updated.", ToastNotification.Type.SUCCESS)

	_save_button.disabled = false
	_reset_form()
	await _refresh_agents()


func _on_clear_pressed() -> void:
	_name_line_edit.text = ""
	_prompt_text_edit.text = ""
	_setup_commands_text_edit.text = ""


func _on_cancel_edit_pressed() -> void:
	_reset_form()


func _on_edit_agent_pressed(agent: Dictionary) -> void:
	_set_edit_mode(agent)


func _on_delete_agent_pressed(agent_id: String) -> void:
	if agent_id.is_empty():
		return

	var adapter = _get_adapter()
	if not adapter:
		SingletonObject.ErrorDisplay("Not Connected", "Please connect to core first.")
		return

	var ok = await adapter.delete_review_agent(agent_id)
	if ok:
		if _editing_agent_id == agent_id:
			_reset_form()
		SingletonObject.create_toast_notification("Review agent deleted.", ToastNotification.Type.SUCCESS)
		await _refresh_agents()


func _on_move_agent(agent_id: String, direction: int) -> void:
	"""Move agent up (-1) or down (+1) in the order"""
	if agent_id.is_empty():
		return
	
	var adapter = _get_adapter()
	if not adapter:
		SingletonObject.ErrorDisplay("Not Connected", "Please connect to core first.")
		return
	
	# Find current agent and its index
	var current_idx = -1
	var current_agent: Dictionary = {}
	
	# Sort agents by order to find current position
	var sorted_agents = _agents.duplicate()
	sorted_agents.sort_custom(func(a, b): return int(a.get("order", 999)) < int(b.get("order", 999)))
	
	for i in range(sorted_agents.size()):
		if str(sorted_agents[i].get("agent_id", "")) == agent_id:
			current_idx = i
			current_agent = sorted_agents[i]
			break
	
	if current_idx < 0:
		return
	
	var target_idx = current_idx + direction
	if target_idx < 0 or target_idx >= sorted_agents.size():
		return
	
	# Swap orders with the target agent
	var target_agent = sorted_agents[target_idx]
	var current_order = int(current_agent.get("order", current_idx))
	var target_order = int(target_agent.get("order", target_idx))
	
	# If both have the same order (shouldn't happen, but handle it)
	if current_order == target_order:
		current_order = current_idx
		target_order = target_idx
	
	# Update both agents
	var current_agent_id = str(current_agent.get("agent_id", ""))
	var target_agent_id = str(target_agent.get("agent_id", ""))
	
	# Update current agent with target's order
	var ok1 = await adapter.update_review_agent_order(current_agent_id, target_order)
	# Update target agent with current's order
	var ok2 = await adapter.update_review_agent_order(target_agent_id, current_order)
	
	if ok1 and ok2:
		SingletonObject.create_toast_notification("Agent order updated.", ToastNotification.Type.SUCCESS)
		await _refresh_agents()
	else:
		SingletonObject.ErrorDisplay("Order Update Failed", "Could not update agent order.")

class_name AutocoderReviewAgentManager
extends VBoxContainer

@onready var _refresh_button: Button = %RefreshButton
@onready var _name_line_edit: LineEdit = %NameLineEdit
@onready var _model_option_button: OptionButton = %ModelOptionButton
@onready var _tools_enabled_check_box: CheckBox = %ToolsEnabledCheckBox
@onready var _prompt_text_edit: TextEdit = %PromptTextEdit
@onready var _setup_commands_text_edit: TextEdit = %SetupCommandsTextEdit
@onready var _save_button: Button = %SaveButton
@onready var _cancel_edit_button: Button = %CancelEditButton
@onready var _clear_button: Button = %ClearButton
@onready var _agents_list: VBoxContainer = %AgentsList
@onready var _loading_label: Label = %LoadingLabel
@onready var _empty_label: Label = %EmptyLabel
@onready var _presets_list: VBoxContainer = %PresetsList
@onready var _presets_loading_label: Label = %PresetsLoadingLabel
@onready var _presets_empty_label: Label = %PresetsEmptyLabel
@onready var _refresh_presets_button: Button = %RefreshPresetsButton
@onready var _edit_preset_button: Button = %EditPresetButton
@onready var _create_preset_button: Button = %CreatePresetButton

var _agents: Array[Dictionary] = []
var _editing_agent_id: String = ""
var _presets: Array[Dictionary] = []


func _ready() -> void:
	_refresh_button.pressed.connect(_on_refresh_pressed)
	_save_button.pressed.connect(_on_save_pressed)
	_cancel_edit_button.pressed.connect(_on_cancel_edit_pressed)
	_clear_button.pressed.connect(_on_clear_pressed)

	# Auto-refresh when agents/presets are created/updated/deleted externally (e.g. via MCP)
	var adapter = _get_adapter()
	if adapter:
		adapter.review_agents_changed.connect(_on_review_agents_changed)
		adapter.review_presets_changed.connect(_on_review_presets_changed)

	_refresh_presets_button.pressed.connect(_on_refresh_presets_pressed)
	_edit_preset_button.pressed.connect(_on_edit_preset_button_pressed)
	_create_preset_button.pressed.connect(_on_create_preset_pressed)

	_reset_form()
	# Models are refreshed by AutocoderManager._refresh_child_views() after adapter is ready.
	# Initialize with empty list so the dropdown shows "Auto (server default)".
	_populate_models([])
	_refresh_agents.call_deferred()
	_refresh_presets.call_deferred()


func _get_adapter() -> AutocoderAdapter:
	if not SingletonObject.autocoder_manager:
		return null
	return SingletonObject.autocoder_manager.autocoder_adapter


func _reset_form() -> void:
	_editing_agent_id = ""
	_name_line_edit.text = ""
	_prompt_text_edit.text = ""
	_setup_commands_text_edit.text = ""
	if _model_option_button.item_count > 0:
		_model_option_button.select(0)
	_tools_enabled_check_box.button_pressed = false
	_save_button.text = "Create Agent"
	_cancel_edit_button.visible = false


func _set_edit_mode(agent: Dictionary) -> void:
	_editing_agent_id = str(agent.get("agent_id", ""))
	_name_line_edit.text = str(agent.get("name", ""))
	_prompt_text_edit.text = str(agent.get("prompt", ""))
	_select_model_by_id(str(agent.get("model", "")))
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
	_refresh_presets_list()


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
	drag_handle.add_theme_font_size_override("font_size", 21)
	drag_handle.add_theme_color_override("font_color", Color(0.4, 0.4, 0.45))
	drag_handle.mouse_filter = Control.MOUSE_FILTER_STOP
	drag_handle.mouse_default_cursor_shape = Control.CURSOR_MOVE
	drag_handle.tooltip_text = "Drag to reorder"
	header.add_child(drag_handle)
	
	# Order indicator
	var order_label := Label.new()
	order_label.text = "#%d" % (index + 1)
	order_label.add_theme_font_size_override("font_size", 16)
	order_label.add_theme_color_override("font_color", Color(0.4, 0.6, 0.8))
	order_label.custom_minimum_size.x = 30
	header.add_child(order_label)

	var name_label := Label.new()
	name_label.text = str(agent.get("name", "Unnamed Agent"))
	name_label.add_theme_font_size_override("font_size", 21)
	name_label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.97))
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(name_label)

	var model_text = str(agent.get("model", ""))
	var model_label := Label.new()
	model_label.text = model_text if not model_text.is_empty() else "default model"
	model_label.add_theme_font_size_override("font_size", 16)
	model_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	header.add_child(model_label)
	
	# Move up/down buttons
	var move_up_button := Button.new()
	move_up_button.text = "▲"
	move_up_button.flat = true
	move_up_button.add_theme_font_size_override("font_size", 15)
	move_up_button.disabled = (index == 0)
	move_up_button.tooltip_text = "Move up"
	move_up_button.pressed.connect(func(): _on_move_agent(str(agent.get("agent_id", "")), -1))
	header.add_child(move_up_button)
	
	var move_down_button := Button.new()
	move_down_button.text = "▼"
	move_down_button.flat = true
	move_down_button.add_theme_font_size_override("font_size", 15)
	move_down_button.disabled = (index >= _agents.size() - 1)
	move_down_button.tooltip_text = "Move down"
	move_down_button.pressed.connect(func(): _on_move_agent(str(agent.get("agent_id", "")), 1))
	header.add_child(move_down_button)

	var prompt_preview := str(agent.get("prompt", ""))
	if prompt_preview.length() > 140:
		prompt_preview = "%s..." % prompt_preview.substr(0, 140)

	var prompt_label := Label.new()
	prompt_label.text = prompt_preview
	prompt_label.add_theme_font_size_override("font_size", 18)
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
	meta_label.add_theme_font_size_override("font_size", 16)
	meta_label.add_theme_color_override("font_color", Color(0.45, 0.45, 0.5))
	meta_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	footer.add_child(meta_label)

	var edit_button := Button.new()
	edit_button.text = "Edit"
	edit_button.flat = true
	edit_button.add_theme_font_size_override("font_size", 18)
	edit_button.pressed.connect(func(): _on_edit_agent_pressed(agent))
	footer.add_child(edit_button)

	var delete_button := Button.new()
	delete_button.text = "Delete"
	delete_button.flat = true
	delete_button.add_theme_font_size_override("font_size", 18)
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


# ── Model dropdown ───────────────────────────────────────────────────────────

func _refresh_models() -> void:
	var adapter = _get_adapter()
	if not adapter:
		_populate_models([])
		return

	_model_option_button.disabled = true
	_model_option_button.clear()
	_model_option_button.add_item("Loading models...")

	var models = await adapter.list_generation_models()
	_populate_models(models)


func _populate_models(models: Array[Dictionary]) -> void:
	var previous_id = _get_selected_model_id()

	_model_option_button.clear()
	_model_option_button.add_item("Auto (server default)")
	_model_option_button.set_item_metadata(0, "")

	var selected_index = 0
	var index = 1
	for model_data in models:
		if not (model_data is Dictionary):
			continue
		var model_id = str(model_data.get("id", ""))
		if model_id.is_empty():
			continue
		var model_name = str(model_data.get("name", ""))
		var label = model_name if not model_name.is_empty() else model_id
		if not model_name.is_empty() and model_name != model_id:
			label = "%s (%s)" % [model_name, model_id]
		_model_option_button.add_item(label)
		_model_option_button.set_item_metadata(index, model_id)
		if model_id == previous_id:
			selected_index = index
		index += 1

	_model_option_button.select(selected_index)
	_model_option_button.disabled = false


func _get_selected_model_id() -> String:
	if _model_option_button.item_count == 0:
		return ""
	var idx = _model_option_button.selected
	if idx < 0:
		return ""
	var meta = _model_option_button.get_item_metadata(idx)
	if meta == null:
		return ""
	return str(meta)


func _select_model_by_id(model_id: String) -> void:
	for i in range(_model_option_button.item_count):
		var meta = _model_option_button.get_item_metadata(i)
		if meta != null and str(meta) == model_id:
			_model_option_button.select(i)
			return
	# Fallback to "Auto" if model not found in list
	if _model_option_button.item_count > 0:
		_model_option_button.select(0)


func _on_refresh_pressed() -> void:
	_refresh_models()
	await _refresh_agents()


func _on_review_agents_changed() -> void:
	_refresh_agents.call_deferred()


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

	var model = _get_selected_model_id()
	var tools_enabled = _tools_enabled_check_box.button_pressed
	var setup_commands = _parse_setup_commands(_setup_commands_text_edit.text)

	if _editing_agent_id.is_empty():
		var agent_id = await adapter.create_review_agent(name_, prompt, setup_commands, model, tools_enabled)
		if agent_id.is_empty():
			_save_button.disabled = false
			return
		SingletonObject.create_toast_notification("Review agent created.", ToastNotification.Type.SUCCESS)
	else:
		var ok = await adapter.update_review_agent(_editing_agent_id, name_, prompt, setup_commands, model, tools_enabled)
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
	if _model_option_button.item_count > 0:
		_model_option_button.select(0)


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


# ── Presets ──────────────────────────────────────────────────────────────────

func _on_refresh_presets_pressed() -> void:
	await _refresh_presets()


func _on_review_presets_changed() -> void:
	_refresh_presets.call_deferred()


func _refresh_presets() -> void:
	_presets_loading_label.visible = true
	_presets_empty_label.visible = false

	var adapter = _get_adapter()
	if not adapter:
		_presets = []
		_presets_loading_label.visible = false
		_presets_empty_label.text = "Connect to core to load groups."
		_presets_empty_label.visible = true
		_refresh_presets_list()
		return

	var presets = await adapter.list_review_presets()
	_presets = presets
	_presets_loading_label.visible = false
	_refresh_presets_list()


func _refresh_presets_list() -> void:
	for child in _presets_list.get_children():
		if child == _presets_loading_label or child == _presets_empty_label:
			continue
		child.queue_free()

	if _presets.is_empty():
		_presets_empty_label.text = "No groups yet. Create one to group agents."
		_presets_empty_label.visible = true
		return

	_presets_empty_label.visible = false

	for preset in _presets:
		var card = _build_preset_card(preset)
		_presets_list.add_child(card)


func _build_preset_card(preset: Dictionary) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.1, 0.1, 0.12)
	style.border_color = Color(0.25, 0.35, 0.55)
	style.set_border_width_all(1)
	style.border_width_left = 3
	style.set_corner_radius_all(10)
	style.content_margin_left = 14
	style.content_margin_right = 14
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	panel.add_theme_stylebox_override("panel", style)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	panel.add_child(vbox)

	# Header row: name + edit + delete
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 10)
	vbox.add_child(header)

	var name_label := Label.new()
	name_label.text = str(preset.get("name", "Unnamed Group"))
	name_label.add_theme_font_size_override("font_size", 21)
	name_label.add_theme_color_override("font_color", Color(0.95, 0.95, 0.97))
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(name_label)

	var delete_button := Button.new()
	delete_button.text = "Delete"
	delete_button.flat = true
	delete_button.add_theme_font_size_override("font_size", 18)
	delete_button.add_theme_color_override("font_color", Color(0.9, 0.5, 0.5))
	delete_button.pressed.connect(func(): _on_delete_preset_pressed(str(preset.get("preset_id", ""))))
	header.add_child(delete_button)

	# Body: agent names
	var agent_ids = preset.get("agent_ids", [])
	var agents_text = _resolve_agent_names(agent_ids) if agent_ids is Array else ""
	if agents_text.is_empty():
		agents_text = "(no agents)"

	var body_label := Label.new()
	body_label.text = agents_text
	body_label.add_theme_font_size_override("font_size", 18)
	body_label.add_theme_color_override("font_color", Color(0.55, 0.55, 0.6))
	body_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(body_label)

	return panel


func _resolve_agent_names(agent_ids: Array) -> String:
	var names: Array[String] = []
	for aid in agent_ids:
		var id_str = str(aid)
		var found = false
		for agent in _agents:
			if str(agent.get("agent_id", "")) == id_str:
				names.append(str(agent.get("name", id_str)))
				found = true
				break
		if not found:
			names.append("(unknown)")
	return ", ".join(names)


func _on_create_preset_pressed() -> void:
	_show_preset_dialog(null)


func _on_edit_preset_button_pressed() -> void:
	if _presets.is_empty():
		SingletonObject.create_toast_notification("No groups to edit.", ToastNotification.Type.INFO)
		return

	var dialog := AcceptDialog.new()
	dialog.title = "Select Group to Edit"
	dialog.ok_button_text = "Cancel"
	dialog.min_size = Vector2i(320, 200)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 4)
	dialog.add_child(content)

	var hint := Label.new()
	hint.text = "Choose a group:"
	hint.add_theme_font_size_override("font_size", 18)
	hint.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	content.add_child(hint)

	for preset in _presets:
		var btn := Button.new()
		btn.text = str(preset.get("name", "Unnamed"))
		btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
		btn.add_theme_font_size_override("font_size", 20)
		btn.pressed.connect(func():
			dialog.hide()
			dialog.queue_free()
			_on_edit_preset_pressed(preset)
		)
		content.add_child(btn)

	dialog.canceled.connect(func(): dialog.queue_free())
	dialog.confirmed.connect(func(): dialog.queue_free())
	dialog.visibility_changed.connect(func():
		if not dialog.visible:
			dialog.queue_free()
	)

	add_child(dialog)
	dialog.popup_centered()


func _on_edit_preset_pressed(preset: Dictionary) -> void:
	_show_preset_dialog(preset)


func _on_delete_preset_pressed(preset_id: String) -> void:
	if preset_id.is_empty():
		return

	var adapter = _get_adapter()
	if not adapter:
		SingletonObject.ErrorDisplay("Not Connected", "Please connect to core first.")
		return

	var ok = await adapter.delete_review_preset(preset_id)
	if ok:
		SingletonObject.create_toast_notification("Group deleted.", ToastNotification.Type.SUCCESS)
		await _refresh_presets()


func _show_preset_dialog(preset: Variant) -> void:
	var dialog := AcceptDialog.new()
	dialog.title = "Edit Group" if preset is Dictionary else "New Group"
	dialog.ok_button_text = "Save"
	dialog.min_size = Vector2i(420, 360)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 12)
	dialog.add_child(content)

	# Name field
	var name_section := VBoxContainer.new()
	name_section.add_theme_constant_override("separation", 4)
	content.add_child(name_section)

	var name_label := Label.new()
	name_label.text = "Group Name"
	name_label.add_theme_font_size_override("font_size", 18)
	name_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	name_section.add_child(name_label)

	var name_edit := LineEdit.new()
	name_edit.placeholder_text = "e.g., Full Review Suite"
	if preset is Dictionary:
		name_edit.text = str(preset.get("name", ""))
	name_section.add_child(name_edit)

	# Agents checklist
	var agents_label := Label.new()
	agents_label.text = "Select Agents"
	agents_label.add_theme_font_size_override("font_size", 18)
	agents_label.add_theme_color_override("font_color", Color(0.7, 0.7, 0.75))
	content.add_child(agents_label)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 150)
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_child(scroll)

	var checks_vbox := VBoxContainer.new()
	checks_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	checks_vbox.add_theme_constant_override("separation", 6)
	scroll.add_child(checks_vbox)

	var preset_agent_ids: Array = []
	if preset is Dictionary:
		preset_agent_ids = preset.get("agent_ids", [])
		if not preset_agent_ids is Array:
			preset_agent_ids = []

	var checkboxes: Array[CheckBox] = []
	for agent in _agents:
		var cb := CheckBox.new()
		cb.text = str(agent.get("name", "Unnamed"))
		cb.add_theme_font_size_override("font_size", 20)
		var agent_id_str = str(agent.get("agent_id", ""))
		cb.set_meta("agent_id", agent_id_str)
		# Pre-check if editing and agent is in preset
		for pid in preset_agent_ids:
			if str(pid) == agent_id_str:
				cb.button_pressed = true
				break
		checks_vbox.add_child(cb)
		checkboxes.append(cb)

	if _agents.is_empty():
		var hint := Label.new()
		hint.text = "No agents available. Create agents first."
		hint.add_theme_font_size_override("font_size", 18)
		hint.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
		checks_vbox.add_child(hint)

	dialog.confirmed.connect(func():
		var preset_name = name_edit.text.strip_edges()
		if preset_name.is_empty():
			SingletonObject.ErrorDisplay("Missing Name", "Group name is required.")
			return

		var selected_ids: Array = []
		for cb in checkboxes:
			if cb.button_pressed:
				selected_ids.append(cb.get_meta("agent_id"))

		var adapter = _get_adapter()
		if not adapter:
			SingletonObject.ErrorDisplay("Not Connected", "Please connect to core first.")
			return

		if preset is Dictionary:
			var preset_id = str(preset.get("preset_id", ""))
			var ok = await adapter.update_review_preset(preset_id, preset_name, selected_ids)
			if ok:
				SingletonObject.create_toast_notification("Group updated.", ToastNotification.Type.SUCCESS)
				await _refresh_presets()
		else:
			var new_id = await adapter.create_review_preset(preset_name, selected_ids)
			if not new_id.is_empty():
				SingletonObject.create_toast_notification("Group created.", ToastNotification.Type.SUCCESS)
				await _refresh_presets()
	)

	dialog.canceled.connect(func(): dialog.queue_free())
	dialog.visibility_changed.connect(func():
		if not dialog.visible:
			dialog.queue_free()
	)

	add_child(dialog)
	dialog.popup_centered()

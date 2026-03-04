class_name AgentManagerWindow
extends Window
## Two-tab Window popup for managing agent definitions and triggers.
## Tab 1: Agents (CRUD) - Tab 2: Triggers (CRUD + enable/disable)

#region Agent Tab Controls
var agent_list: ItemList
var agent_name_edit: LineEdit
var agent_provider_dropdown: OptionButton
var agent_model_dropdown: OptionButton
var agent_system_prompt_edit: TextEdit
var agent_temp_spin: SpinBox
var agent_top_p_spin: SpinBox
var agent_freq_penalty_spin: SpinBox
var agent_pres_penalty_spin: SpinBox
var agent_max_rounds_spin: SpinBox
var agent_tools_all_check: CheckButton
var agent_tools_container: VBoxContainer
var agent_tool_add_edit: LineEdit
var agent_memory_tab_edit: LineEdit
var agent_drawer_tab_edit: LineEdit
var agent_new_btn: Button
var agent_save_btn: Button
var agent_delete_btn: Button
var agent_test_btn: Button
var agent_instance_btn: Button
#endregion

#region Trigger Tab Controls
var trigger_list: ItemList
var trigger_name_edit: LineEdit
var trigger_agent_option: OptionButton
var trigger_type_option: OptionButton
var trigger_interval_spin: SpinBox
var trigger_event_option: OptionButton
var trigger_action_type_option: OptionButton
var trigger_watched_label: Label
var trigger_watched_container: VBoxContainer
var trigger_message_edit: TextEdit
var trigger_batch_params_edit: TextEdit
var trigger_batch_label_edit: LineEdit
var trigger_chain_option: OptionButton
var trigger_enabled_check: CheckButton
var trigger_new_btn: Button
var trigger_save_btn: Button
var trigger_delete_btn: Button
#endregion

var _selected_agent_idx: int = -1
var _selected_trigger_idx: int = -1

## Mapping from model dropdown index to model enum id (changes when provider changes)
var _model_id_map: Array[int] = []
## For Core models: parallel array of [Service, Action] pairs (same indices as _model_id_map)
var _core_model_map: Array = []


func _init():
	title = "Agent Manager"
	size = Vector2i(800, 600)
	min_size = Vector2i(650, 450)
	transient = true
	exclusive = false
	wrap_controls = true
	close_requested.connect(hide)


func _ready() -> void:
	content_scale_factor = get_tree().root.content_scale_factor
	_build_ui()
	_refresh_agent_list()
	_refresh_trigger_list()


func _build_ui() -> void:
	var panel = PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(panel)

	var margin = MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(margin)

	var tabs = TabContainer.new()
	tabs.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tabs.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(tabs)

	# Tab 1: Agents
	var agents_tab = _build_agents_tab()
	agents_tab.name = "Agents"
	tabs.add_child(agents_tab)

	# Tab 2: Triggers
	var triggers_tab = _build_triggers_tab()
	triggers_tab.name = "Triggers"
	tabs.add_child(triggers_tab)


#region Agents Tab

func _build_agents_tab() -> Control:
	var hsplit = HSplitContainer.new()
	hsplit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hsplit.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Left: Agent list
	var left_vbox = VBoxContainer.new()
	left_vbox.custom_minimum_size = Vector2(180, 0)
	left_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var list_label = Label.new()
	list_label.text = "Agent Definitions"
	left_vbox.add_child(list_label)

	agent_list = ItemList.new()
	agent_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	agent_list.item_selected.connect(_on_agent_selected)
	left_vbox.add_child(agent_list)

	hsplit.add_child(left_vbox)

	# Right: Editor panel (scrollable)
	var scroll = ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED

	var right_vbox = VBoxContainer.new()
	right_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_vbox.add_theme_constant_override("separation", 6)

	# Name
	right_vbox.add_child(_label("Name:"))
	agent_name_edit = LineEdit.new()
	agent_name_edit.placeholder_text = "Agent name"
	agent_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_vbox.add_child(agent_name_edit)

	# Provider dropdown
	right_vbox.add_child(_label("Provider:"))
	agent_provider_dropdown = OptionButton.new()
	agent_provider_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	agent_provider_dropdown.item_selected.connect(_on_provider_selected)
	_populate_provider_dropdown()
	right_vbox.add_child(agent_provider_dropdown)

	# Model dropdown (populated when provider changes)
	right_vbox.add_child(_label("Model:"))
	agent_model_dropdown = OptionButton.new()
	agent_model_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_vbox.add_child(agent_model_dropdown)

	# Populate models for initially selected provider
	if agent_provider_dropdown.item_count > 0:
		_on_provider_selected(0)

	# System Prompt
	right_vbox.add_child(_label("System Prompt:"))
	agent_system_prompt_edit = TextEdit.new()
	agent_system_prompt_edit.custom_minimum_size = Vector2(0, 120)
	agent_system_prompt_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	agent_system_prompt_edit.placeholder_text = "Instructions for the agent..."
	right_vbox.add_child(agent_system_prompt_edit)

	# Parameters in a grid
	var params_grid = GridContainer.new()
	params_grid.columns = 4
	params_grid.add_theme_constant_override("h_separation", 10)

	params_grid.add_child(_label("Temp:"))
	agent_temp_spin = _spin(0.0, 2.0, 1.0, 0.1)
	params_grid.add_child(agent_temp_spin)

	params_grid.add_child(_label("Top P:"))
	agent_top_p_spin = _spin(0.0, 1.0, 1.0, 0.05)
	params_grid.add_child(agent_top_p_spin)

	params_grid.add_child(_label("Freq Pen:"))
	agent_freq_penalty_spin = _spin(-2.0, 2.0, 0.0, 0.1)
	params_grid.add_child(agent_freq_penalty_spin)

	params_grid.add_child(_label("Pres Pen:"))
	agent_pres_penalty_spin = _spin(-2.0, 2.0, 0.0, 0.1)
	params_grid.add_child(agent_pres_penalty_spin)

	params_grid.add_child(_label("Max Rounds:"))
	agent_max_rounds_spin = _spin(1, 50, 10, 1)
	params_grid.add_child(agent_max_rounds_spin)

	right_vbox.add_child(params_grid)

	# Tools section
	right_vbox.add_child(_label("Tools:"))
	agent_tools_all_check = CheckButton.new()
	agent_tools_all_check.text = "Allow all tools"
	agent_tools_all_check.button_pressed = true
	agent_tools_all_check.toggled.connect(_on_tools_all_toggled)
	right_vbox.add_child(agent_tools_all_check)

	var tools_btn_hbox = HBoxContainer.new()
	tools_btn_hbox.add_theme_constant_override("separation", 4)
	var select_all_btn = Button.new()
	select_all_btn.text = "Select All"
	select_all_btn.pressed.connect(_on_tools_select_all)
	tools_btn_hbox.add_child(select_all_btn)
	var select_none_btn = Button.new()
	select_none_btn.text = "Select None"
	select_none_btn.pressed.connect(_on_tools_select_none)
	tools_btn_hbox.add_child(select_none_btn)
	right_vbox.add_child(tools_btn_hbox)

	agent_tools_container = VBoxContainer.new()
	right_vbox.add_child(agent_tools_container)

	# Manual tool entry
	var tool_add_hbox = HBoxContainer.new()
	tool_add_hbox.add_theme_constant_override("separation", 4)
	agent_tool_add_edit = LineEdit.new()
	agent_tool_add_edit.placeholder_text = "Tool name to add..."
	agent_tool_add_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tool_add_hbox.add_child(agent_tool_add_edit)
	var tool_add_btn = Button.new()
	tool_add_btn.text = "Add"
	tool_add_btn.pressed.connect(_on_add_tool_pressed)
	tool_add_hbox.add_child(tool_add_btn)
	right_vbox.add_child(tool_add_hbox)

	# Memory tabs
	right_vbox.add_child(_label("Memory Tab (project notes):"))
	agent_memory_tab_edit = LineEdit.new()
	agent_memory_tab_edit.placeholder_text = "Leave empty for no project memory tab"
	agent_memory_tab_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_vbox.add_child(agent_memory_tab_edit)

	right_vbox.add_child(_label("Memory Tab (drawer notes):"))
	agent_drawer_tab_edit = LineEdit.new()
	agent_drawer_tab_edit.placeholder_text = "Leave empty for no drawer memory tab"
	agent_drawer_tab_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_vbox.add_child(agent_drawer_tab_edit)

	# Buttons
	var btn_hbox = HBoxContainer.new()
	btn_hbox.add_theme_constant_override("separation", 8)

	agent_new_btn = Button.new()
	agent_new_btn.text = "New"
	agent_new_btn.pressed.connect(_on_agent_new)
	btn_hbox.add_child(agent_new_btn)

	agent_save_btn = Button.new()
	agent_save_btn.text = "Save"
	agent_save_btn.pressed.connect(_on_agent_save)
	btn_hbox.add_child(agent_save_btn)

	agent_delete_btn = Button.new()
	agent_delete_btn.text = "Delete"
	agent_delete_btn.pressed.connect(_on_agent_delete)
	btn_hbox.add_child(agent_delete_btn)

	var spacer = Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn_hbox.add_child(spacer)

	agent_instance_btn = Button.new()
	agent_instance_btn.text = "Instance"
	agent_instance_btn.pressed.connect(_on_agent_instance)
	btn_hbox.add_child(agent_instance_btn)

	agent_test_btn = Button.new()
	agent_test_btn.text = "Test Spawn"
	agent_test_btn.pressed.connect(_on_agent_test_spawn)
	btn_hbox.add_child(agent_test_btn)

	right_vbox.add_child(btn_hbox)

	scroll.add_child(right_vbox)
	hsplit.add_child(scroll)

	return hsplit

#endregion Agents Tab


#region Triggers Tab

func _build_triggers_tab() -> Control:
	var hsplit = HSplitContainer.new()
	hsplit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hsplit.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# Left: Trigger list
	var left_vbox = VBoxContainer.new()
	left_vbox.custom_minimum_size = Vector2(200, 0)
	left_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL

	var list_label = Label.new()
	list_label.text = "Triggers"
	left_vbox.add_child(list_label)

	trigger_list = ItemList.new()
	trigger_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	trigger_list.item_selected.connect(_on_trigger_selected)
	left_vbox.add_child(trigger_list)

	hsplit.add_child(left_vbox)

	# Right: Editor panel
	var right_vbox = VBoxContainer.new()
	right_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_vbox.add_theme_constant_override("separation", 6)

	# Trigger name
	right_vbox.add_child(_label("Name:"))
	trigger_name_edit = LineEdit.new()
	trigger_name_edit.placeholder_text = "e.g. LLM Tweet Scanner"
	trigger_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_vbox.add_child(trigger_name_edit)

	# Agent selection
	right_vbox.add_child(_label("Agent:"))
	trigger_agent_option = OptionButton.new()
	trigger_agent_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_vbox.add_child(trigger_agent_option)

	# Trigger type
	right_vbox.add_child(_label("Trigger Type:"))
	trigger_type_option = OptionButton.new()
	trigger_type_option.add_item("Timer", TriggerDefinition.TriggerType.TIMER)
	trigger_type_option.add_item("Event", TriggerDefinition.TriggerType.EVENT)
	trigger_type_option.item_selected.connect(_on_trigger_type_changed)
	right_vbox.add_child(trigger_type_option)

	# Timer interval
	right_vbox.add_child(_label("Interval (seconds):"))
	trigger_interval_spin = _spin(5, 86400, 300, 10)
	right_vbox.add_child(trigger_interval_spin)

	# Event type
	right_vbox.add_child(_label("Event Type:"))
	trigger_event_option = OptionButton.new()
	trigger_event_option.add_item("Note Created", TriggerDefinition.EventType.NOTE_CREATED)
	trigger_event_option.add_item("Note Changed", TriggerDefinition.EventType.NOTE_CHANGED)
	trigger_event_option.add_item("Chat Completed", TriggerDefinition.EventType.CHAT_COMPLETED)
	trigger_event_option.item_selected.connect(_on_event_type_changed)
	right_vbox.add_child(trigger_event_option)

	# Action type (Spawn New vs Message Existing)
	right_vbox.add_child(_label("Action:"))
	trigger_action_type_option = OptionButton.new()
	trigger_action_type_option.add_item("Spawn New Chat", TriggerDefinition.ActionType.SPAWN_NEW)
	trigger_action_type_option.add_item("Message Existing Chat", TriggerDefinition.ActionType.MESSAGE_EXISTING)
	trigger_action_type_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_vbox.add_child(trigger_action_type_option)

	# Watched agents (visible only for CHAT_COMPLETED)
	trigger_watched_label = _label("Watch Agents (filter):")
	right_vbox.add_child(trigger_watched_label)
	trigger_watched_container = VBoxContainer.new()
	right_vbox.add_child(trigger_watched_container)

	# Initial message
	right_vbox.add_child(_label("Initial Message:"))
	trigger_message_edit = TextEdit.new()
	trigger_message_edit.custom_minimum_size = Vector2(0, 80)
	trigger_message_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	trigger_message_edit.placeholder_text = "Message sent when trigger fires.\nVars: {agent_name}, {last_response}, {history_name}, {param}, {batch_index}, {batch_total}"
	right_vbox.add_child(trigger_message_edit)

	# Batch parameters
	right_vbox.add_child(_label("Batch Parameters (one per line):"))
	trigger_batch_params_edit = TextEdit.new()
	trigger_batch_params_edit.custom_minimum_size = Vector2(0, 60)
	trigger_batch_params_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	trigger_batch_params_edit.placeholder_text = "AAPL\nMSFT\nGOOGL\n(leave empty for single fire)"
	right_vbox.add_child(trigger_batch_params_edit)

	# Parameter label
	right_vbox.add_child(_label("Parameter Label (optional):"))
	trigger_batch_label_edit = LineEdit.new()
	trigger_batch_label_edit.placeholder_text = "e.g. Ticker Symbols"
	trigger_batch_label_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_vbox.add_child(trigger_batch_label_edit)

	# Chain to trigger
	right_vbox.add_child(_label("Chain To (after completion):"))
	trigger_chain_option = OptionButton.new()
	trigger_chain_option.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_vbox.add_child(trigger_chain_option)

	# Enabled toggle
	trigger_enabled_check = CheckButton.new()
	trigger_enabled_check.text = "Enabled"
	right_vbox.add_child(trigger_enabled_check)

	# Buttons
	var btn_hbox = HBoxContainer.new()
	btn_hbox.add_theme_constant_override("separation", 8)

	trigger_new_btn = Button.new()
	trigger_new_btn.text = "New"
	trigger_new_btn.pressed.connect(_on_trigger_new)
	btn_hbox.add_child(trigger_new_btn)

	trigger_save_btn = Button.new()
	trigger_save_btn.text = "Save"
	trigger_save_btn.pressed.connect(_on_trigger_save)
	btn_hbox.add_child(trigger_save_btn)

	trigger_delete_btn = Button.new()
	trigger_delete_btn.text = "Delete"
	trigger_delete_btn.pressed.connect(_on_trigger_delete)
	btn_hbox.add_child(trigger_delete_btn)

	right_vbox.add_child(btn_hbox)

	# Push remaining space down
	var bottom_spacer = Control.new()
	bottom_spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_vbox.add_child(bottom_spacer)

	hsplit.add_child(right_vbox)

	return hsplit

#endregion Triggers Tab


#region Helper Builders

func _label(text: String) -> Label:
	var lbl = Label.new()
	lbl.text = text
	return lbl


func _spin(min_val: float, max_val: float, default_val: float, step: float) -> SpinBox:
	var sb = SpinBox.new()
	sb.min_value = min_val
	sb.max_value = max_val
	sb.value = default_val
	sb.step = step
	sb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return sb


func _populate_provider_dropdown() -> void:
	agent_provider_dropdown.clear()
	# Collect which API_PROVIDER values actually have models registered
	var seen_providers: Array[int] = []
	for model_key in SingletonObject.MODEL_TO_PROVIDER:
		if model_key == SingletonObject.API_MODEL_PROVIDERS.HUMAN:
			continue
		var prov: int = SingletonObject.MODEL_TO_PROVIDER[model_key]
		if prov not in seen_providers and SingletonObject.is_provider_enabled(prov):
			seen_providers.append(prov)

	for prov in seen_providers:
		var display = SingletonObject.PROVIDER_DISPLAY_NAMES.get(prov, "Provider %d" % prov)
		agent_provider_dropdown.add_item(display)
		agent_provider_dropdown.set_item_metadata(agent_provider_dropdown.item_count - 1, prov)


func _on_provider_selected(index: int) -> void:
	if index < 0 or index >= agent_provider_dropdown.item_count:
		return
	var selected_provider: int = agent_provider_dropdown.get_item_metadata(index)
	_populate_model_dropdown(selected_provider)


func _populate_model_dropdown(provider_id: int) -> void:
	agent_model_dropdown.clear()
	_model_id_map.clear()
	_core_model_map.clear()

	# Core/TurnRock: models are runtime-discovered Service/Action pairs
	if provider_id == SingletonObject.API_PROVIDER.TURNROCK:
		_populate_core_models()
		if agent_model_dropdown.item_count > 0:
			agent_model_dropdown.select(0)
		return

	for model_key in SingletonObject.API_MODEL_PROVIDER_SCRIPTS:
		if model_key == SingletonObject.API_MODEL_PROVIDERS.HUMAN:
			continue
		# Skip TURNROCK from standard iteration (handled above)
		if model_key == SingletonObject.API_MODEL_PROVIDERS.TURNROCK:
			continue
		# Only include models belonging to this provider
		var model_provider: int = SingletonObject.MODEL_TO_PROVIDER.get(model_key, -1)
		if model_provider != provider_id:
			continue
		if not SingletonObject.is_model_enabled(model_key):
			continue

		var display_name: String
		if model_key >= SingletonObject.DYNAMIC_MODEL_ID_BASE:
			var config: Dictionary = SingletonObject.openrouter_model_manager.get_model(model_key)
			if not config.is_empty():
				display_name = config.get("display_name", config.get("api_model_id", "OpenRouter %d" % model_key))
			else:
				display_name = "OpenRouter %d" % model_key
		else:
			var instance: BaseProvider = SingletonObject.API_MODEL_PROVIDER_SCRIPTS[model_key].new()
			display_name = instance.display_name if instance else "Model %d" % model_key
		agent_model_dropdown.add_item(display_name)
		_model_id_map.append(model_key)

	if agent_model_dropdown.item_count > 0:
		agent_model_dropdown.select(0)


func _populate_core_models() -> void:
	var core_node = Engine.get_singleton("Core") if Engine.has_singleton("Core") else null
	if not core_node:
		core_node = SingletonObject.get_tree().root.get_node_or_null("Core")
	if not core_node:
		agent_model_dropdown.add_item("(Core not connected)")
		_model_id_map.append(-1)
		return

	var svc_list: Array = core_node.services
	if svc_list.is_empty():
		agent_model_dropdown.add_item("(No Core services discovered)")
		_model_id_map.append(-1)
		return

	for service in svc_list:
		for action in service.actions:
			var display = "%s (%s)" % [service.name, action.name]
			agent_model_dropdown.add_item(display)
			_model_id_map.append(SingletonObject.API_MODEL_PROVIDERS.TURNROCK)
			_core_model_map.append([service, action])


func _populate_agent_options() -> void:
	trigger_agent_option.clear()
	var registry = SingletonObject.agent_registry
	if not registry:
		return
	for agent in registry.agents:
		trigger_agent_option.add_item(agent.name)
		trigger_agent_option.set_item_metadata(trigger_agent_option.item_count - 1, agent.id)


func _populate_tools_checkboxes(enabled_tools: Array[String]) -> void:
	# Clear existing checkboxes
	for child in agent_tools_container.get_children():
		child.queue_free()

	var is_all = enabled_tools.is_empty()
	agent_tools_all_check.button_pressed = is_all

	# Collect all known tool names: MCP tools + saved agent tools
	var known_tools: Array[String] = []

	var mcp = SingletonObject.mcp_manager
	if mcp:
		var tools = mcp.get_available_tools()
		for tool_def in tools:
			var tool_name: String = tool_def.name if tool_def is MCPToolDefinition else str(tool_def)
			if not tool_name.is_empty() and tool_name not in known_tools:
				known_tools.append(tool_name)

	# Include saved tool names not currently in MCP (e.g. from disconnected servers)
	for t in enabled_tools:
		if t not in known_tools:
			known_tools.append(t)

	if known_tools.is_empty():
		var lbl = Label.new()
		lbl.text = "(No tools discovered yet — add manually below)"
		agent_tools_container.add_child(lbl)
	else:
		for tool_name in known_tools:
			var cb = CheckBox.new()
			cb.text = tool_name
			cb.button_pressed = is_all or (tool_name in enabled_tools)
			agent_tools_container.add_child(cb)

	_update_tools_interactive(not is_all)


func _get_selected_tools() -> Array[String]:
	# "Allow all" means empty array (no restrictions)
	if agent_tools_all_check.button_pressed:
		return []

	var result: Array[String] = []
	for child in agent_tools_container.get_children():
		if child is CheckBox and child.button_pressed:
			result.append(child.text)
	return result


func _on_tools_all_toggled(toggled_on: bool) -> void:
	_update_tools_interactive(not toggled_on)


func _on_tools_select_all() -> void:
	if agent_tools_all_check.button_pressed:
		agent_tools_all_check.button_pressed = false
	for child in agent_tools_container.get_children():
		if child is CheckBox:
			child.button_pressed = true


func _on_tools_select_none() -> void:
	if agent_tools_all_check.button_pressed:
		agent_tools_all_check.button_pressed = false
	for child in agent_tools_container.get_children():
		if child is CheckBox:
			child.button_pressed = false


func _update_tools_interactive(interactive: bool) -> void:
	for child in agent_tools_container.get_children():
		if child is CheckBox:
			child.disabled = not interactive
	agent_tool_add_edit.editable = interactive


func _on_add_tool_pressed() -> void:
	var tool_name = agent_tool_add_edit.text.strip_edges()
	if tool_name.is_empty():
		return

	# If "Allow all" is on, turn it off since user is specifying tools
	if agent_tools_all_check.button_pressed:
		agent_tools_all_check.button_pressed = false

	# Check if already exists
	for child in agent_tools_container.get_children():
		if child is CheckBox and child.text == tool_name:
			child.button_pressed = true
			agent_tool_add_edit.text = ""
			return

	# Remove the "(No tools discovered)" label if present
	for child in agent_tools_container.get_children():
		if child is Label:
			child.queue_free()

	# Add new checkbox
	var cb = CheckBox.new()
	cb.text = tool_name
	cb.button_pressed = true
	agent_tools_container.add_child(cb)
	agent_tool_add_edit.text = ""

func _select_agent_by_id(agent_id: String) -> void:
	var registry = SingletonObject.agent_registry
	if not registry:
		return
	for i in registry.agents.size():
		if registry.agents[i].id == agent_id:
			_selected_agent_idx = i
			agent_list.select(i)
			return
	_selected_agent_idx = -1


func _clear_agent_form() -> void:
	agent_name_edit.text = ""
	agent_system_prompt_edit.text = ""
	agent_temp_spin.value = 1.0
	agent_top_p_spin.value = 1.0
	agent_freq_penalty_spin.value = 0.0
	agent_pres_penalty_spin.value = 0.0
	agent_max_rounds_spin.value = 10
	if agent_provider_dropdown.item_count > 0:
		agent_provider_dropdown.select(0)
		_on_provider_selected(0)
	var empty_tools: Array[String] = []
	_populate_tools_checkboxes(empty_tools)
	agent_memory_tab_edit.text = ""
	agent_drawer_tab_edit.text = ""

#endregion Helper Builders


#region Agent Callbacks

func _on_agent_selected(index: int) -> void:
	_selected_agent_idx = index
	var registry = SingletonObject.agent_registry
	if not registry or index < 0 or index >= registry.agents.size():
		return

	var agent = registry.agents[index]
	agent_name_edit.text = agent.name
	agent_system_prompt_edit.text = agent.system_prompt
	agent_temp_spin.value = agent.temperature
	agent_top_p_spin.value = agent.top_p
	agent_freq_penalty_spin.value = agent.frequency_penalty
	agent_pres_penalty_spin.value = agent.presence_penalty
	agent_max_rounds_spin.value = agent.max_tool_call_rounds

	# Select provider dropdown, then populate and select model
	var model_provider: int = SingletonObject.MODEL_TO_PROVIDER.get(agent.provider_enum_id, -1)
	for i in agent_provider_dropdown.item_count:
		if agent_provider_dropdown.get_item_metadata(i) == model_provider:
			agent_provider_dropdown.select(i)
			_populate_model_dropdown(model_provider)
			break
	# Select model in model dropdown
	if agent.provider_enum_id == SingletonObject.API_MODEL_PROVIDERS.TURNROCK:
		# Match Core model by service_id + action_name
		for i in _core_model_map.size():
			var pair = _core_model_map[i]
			if pair[0].client_id == agent.core_service_id and pair[1].name == agent.core_action_name:
				agent_model_dropdown.select(i)
				break
	else:
		for i in _model_id_map.size():
			if _model_id_map[i] == agent.provider_enum_id:
				agent_model_dropdown.select(i)
				break

	_populate_tools_checkboxes(agent.enabled_tools)

	agent_memory_tab_edit.text = agent.memory_tab_name
	agent_drawer_tab_edit.text = agent.drawer_tab_name


func _on_agent_new() -> void:
	_selected_agent_idx = -1
	agent_list.deselect_all()
	_clear_agent_form()
	agent_name_edit.grab_focus()


func _on_agent_save() -> void:
	var registry = SingletonObject.agent_registry
	if not registry:
		return

	if agent_name_edit.text.strip_edges().is_empty():
		SingletonObject.create_toast_notification("Agent name is required", ToastNotification.Type.WARNING)
		return

	var model_idx = agent_model_dropdown.selected
	var provider_enum_id = _model_id_map[model_idx] if model_idx >= 0 and model_idx < _model_id_map.size() else 0

	# Extract Core service/action info if this is a TurnRock model
	var core_svc_id := ""
	var core_act_name := ""
	if provider_enum_id == SingletonObject.API_MODEL_PROVIDERS.TURNROCK and model_idx >= 0 and model_idx < _core_model_map.size():
		var pair = _core_model_map[model_idx]
		core_svc_id = pair[0].client_id
		core_act_name = pair[1].name

	var saved_id: String = ""

	if _selected_agent_idx >= 0 and _selected_agent_idx < registry.agents.size():
		# Update existing
		var agent = registry.agents[_selected_agent_idx]
		saved_id = agent.id
		agent.name = agent_name_edit.text.strip_edges()
		agent.system_prompt = agent_system_prompt_edit.text
		agent.provider_enum_id = provider_enum_id
		agent.core_service_id = core_svc_id
		agent.core_action_name = core_act_name
		agent.temperature = agent_temp_spin.value
		agent.top_p = agent_top_p_spin.value
		agent.frequency_penalty = agent_freq_penalty_spin.value
		agent.presence_penalty = agent_pres_penalty_spin.value
		agent.max_tool_call_rounds = int(agent_max_rounds_spin.value)
		agent.enabled_tools = _get_selected_tools()
		agent.memory_tab_name = agent_memory_tab_edit.text.strip_edges()
		agent.drawer_tab_name = agent_drawer_tab_edit.text.strip_edges()
		registry.update_agent(agent.id, agent)
		SingletonObject.create_toast_notification("Agent updated: %s" % agent.name, ToastNotification.Type.SUCCESS)
	else:
		# Create new
		var agent = AgentDefinition.new()
		saved_id = agent.id
		agent.name = agent_name_edit.text.strip_edges()
		agent.system_prompt = agent_system_prompt_edit.text
		agent.provider_enum_id = provider_enum_id
		agent.core_service_id = core_svc_id
		agent.core_action_name = core_act_name
		agent.temperature = agent_temp_spin.value
		agent.top_p = agent_top_p_spin.value
		agent.frequency_penalty = agent_freq_penalty_spin.value
		agent.presence_penalty = agent_pres_penalty_spin.value
		agent.max_tool_call_rounds = int(agent_max_rounds_spin.value)
		agent.enabled_tools = _get_selected_tools()
		agent.memory_tab_name = agent_memory_tab_edit.text.strip_edges()
		agent.drawer_tab_name = agent_drawer_tab_edit.text.strip_edges()
		registry.add_agent(agent)
		SingletonObject.create_toast_notification("Agent created: %s" % agent.name, ToastNotification.Type.SUCCESS)

	_refresh_agent_list()
	_populate_agent_options()
	# Re-select the saved agent so subsequent saves update rather than duplicate
	_select_agent_by_id(saved_id)


func _on_agent_delete() -> void:
	var registry = SingletonObject.agent_registry
	if not registry or _selected_agent_idx < 0 or _selected_agent_idx >= registry.agents.size():
		SingletonObject.create_toast_notification("Select an agent first", ToastNotification.Type.WARNING)
		return

	var agent = registry.agents[_selected_agent_idx]
	var agent_name = agent.name
	registry.remove_agent(agent.id)
	_selected_agent_idx = -1
	_refresh_agent_list()
	_populate_agent_options()
	_clear_agent_form()
	SingletonObject.create_toast_notification("Agent deleted: %s" % agent_name, ToastNotification.Type.SUCCESS)


func _on_agent_instance() -> void:
	var registry = SingletonObject.agent_registry
	if not registry or _selected_agent_idx < 0 or _selected_agent_idx >= registry.agents.size():
		SingletonObject.create_toast_notification("Select an agent first", ToastNotification.Type.WARNING)
		return

	var agent = registry.agents[_selected_agent_idx]
	AgentSpawner.spawn_agent(agent, "")
	hide()


func _on_agent_test_spawn() -> void:
	var registry = SingletonObject.agent_registry
	if not registry or _selected_agent_idx < 0 or _selected_agent_idx >= registry.agents.size():
		SingletonObject.create_toast_notification("Select an agent first", ToastNotification.Type.WARNING)
		return

	var agent = registry.agents[_selected_agent_idx]
	AgentSpawner.spawn_agent(agent, "Hello, I'm testing your agent configuration.")
	hide()

#endregion Agent Callbacks


#region Trigger Callbacks

func _on_trigger_selected(index: int) -> void:
	_selected_trigger_idx = index
	var tm = SingletonObject.trigger_manager
	if not tm or index < 0 or index >= tm.triggers.size():
		return

	var trig = tm.triggers[index]

	trigger_name_edit.text = trig.name

	# Select agent in option button
	for i in trigger_agent_option.item_count:
		if trigger_agent_option.get_item_metadata(i) == trig.agent_id:
			trigger_agent_option.select(i)
			break

	trigger_type_option.select(trig.trigger_type)
	trigger_interval_spin.value = trig.interval_seconds
	trigger_event_option.select(trig.event_type)
	trigger_action_type_option.select(trig.action_type)
	trigger_message_edit.text = trig.initial_message
	trigger_batch_params_edit.text = "\n".join(trig.batch_params)
	trigger_batch_label_edit.text = trig.batch_label
	_populate_chain_options(trig.id)
	_select_chain_option(trig.chain_trigger_id)
	trigger_enabled_check.button_pressed = trig.enabled
	_on_trigger_type_changed(trig.trigger_type)
	_populate_watched_agents(trig.watched_agent_ids)
	_update_watched_visibility(trig.trigger_type, trig.event_type)


func _on_trigger_type_changed(index: int) -> void:
	var is_timer = (index == TriggerDefinition.TriggerType.TIMER)
	trigger_interval_spin.visible = is_timer
	trigger_event_option.visible = not is_timer
	var event_type = trigger_event_option.get_selected_id() if not is_timer else -1
	_update_watched_visibility(index, event_type)


func _on_event_type_changed(index: int) -> void:
	var trigger_type = trigger_type_option.get_selected_id()
	_update_watched_visibility(trigger_type, index)


func _update_watched_visibility(trigger_type: int, event_type: int) -> void:
	var show_watched = (trigger_type == TriggerDefinition.TriggerType.EVENT \
			and event_type == TriggerDefinition.EventType.CHAT_COMPLETED)
	trigger_watched_label.visible = show_watched
	trigger_watched_container.visible = show_watched


func _populate_watched_agents(selected_ids: Array[String]) -> void:
	for child in trigger_watched_container.get_children():
		child.queue_free()

	var registry = SingletonObject.agent_registry
	if not registry or registry.agents.is_empty():
		var lbl = Label.new()
		lbl.text = "(No agents defined)"
		trigger_watched_container.add_child(lbl)
		return

	var hint_label = Label.new()
	hint_label.text = "Empty = all agent chats"
	hint_label.add_theme_font_size_override("font_size", 11)
	hint_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	trigger_watched_container.add_child(hint_label)

	for agent in registry.agents:
		var cb = CheckBox.new()
		cb.text = agent.name
		cb.set_meta("agent_id", agent.id)
		cb.button_pressed = agent.id in selected_ids
		trigger_watched_container.add_child(cb)


func _get_watched_agent_ids() -> Array[String]:
	var result: Array[String] = []
	for child in trigger_watched_container.get_children():
		if child is CheckBox and child.button_pressed:
			result.append(child.get_meta("agent_id"))
	return result


func _on_trigger_new() -> void:
	_selected_trigger_idx = -1
	trigger_name_edit.text = ""
	if trigger_agent_option.item_count > 0:
		trigger_agent_option.select(0)
	trigger_type_option.select(0)
	trigger_interval_spin.value = 300
	trigger_event_option.select(0)
	trigger_action_type_option.select(0)
	trigger_message_edit.text = ""
	trigger_batch_params_edit.text = ""
	trigger_batch_label_edit.text = ""
	_populate_chain_options("")
	trigger_enabled_check.button_pressed = false
	_on_trigger_type_changed(0)
	var empty_ids: Array[String] = []
	_populate_watched_agents(empty_ids)


func _on_trigger_save() -> void:
	var tm = SingletonObject.trigger_manager
	if not tm:
		return

	if trigger_agent_option.selected < 0:
		SingletonObject.create_toast_notification("Select an agent first", ToastNotification.Type.WARNING)
		return

	var agent_id: String = trigger_agent_option.get_item_metadata(trigger_agent_option.selected)

	if _selected_trigger_idx >= 0 and _selected_trigger_idx < tm.triggers.size():
		# Update existing
		var trig = TriggerDefinition.new(tm.triggers[_selected_trigger_idx].id)
		trig.name = trigger_name_edit.text
		trig.agent_id = agent_id
		trig.trigger_type = trigger_type_option.get_selected_id()
		trig.interval_seconds = trigger_interval_spin.value
		trig.event_type = trigger_event_option.get_selected_id()
		trig.action_type = trigger_action_type_option.get_selected_id()
		trig.watched_agent_ids = _get_watched_agent_ids()
		trig.initial_message = trigger_message_edit.text
		trig.batch_params = _parse_batch_params()
		trig.batch_label = trigger_batch_label_edit.text.strip_edges()
		trig.chain_trigger_id = _get_selected_chain_trigger_id()
		trig.enabled = trigger_enabled_check.button_pressed
		tm.update_trigger(trig.id, trig)
		SingletonObject.create_toast_notification("Trigger updated", ToastNotification.Type.SUCCESS)
	else:
		# Create new
		var trig = TriggerDefinition.new()
		trig.name = trigger_name_edit.text
		trig.agent_id = agent_id
		trig.trigger_type = trigger_type_option.get_selected_id()
		trig.interval_seconds = trigger_interval_spin.value
		trig.event_type = trigger_event_option.get_selected_id()
		trig.action_type = trigger_action_type_option.get_selected_id()
		trig.watched_agent_ids = _get_watched_agent_ids()
		trig.initial_message = trigger_message_edit.text
		trig.batch_params = _parse_batch_params()
		trig.batch_label = trigger_batch_label_edit.text.strip_edges()
		trig.chain_trigger_id = _get_selected_chain_trigger_id()
		trig.enabled = trigger_enabled_check.button_pressed
		tm.add_trigger(trig)
		SingletonObject.create_toast_notification("Trigger created", ToastNotification.Type.SUCCESS)

	_refresh_trigger_list()


func _on_trigger_delete() -> void:
	var tm = SingletonObject.trigger_manager
	if not tm or _selected_trigger_idx < 0 or _selected_trigger_idx >= tm.triggers.size():
		return

	tm.remove_trigger(tm.triggers[_selected_trigger_idx].id)
	_selected_trigger_idx = -1
	_refresh_trigger_list()
	SingletonObject.create_toast_notification("Trigger deleted", ToastNotification.Type.SUCCESS)


func _parse_batch_params() -> Array[String]:
	var result: Array[String] = []
	var lines = trigger_batch_params_edit.text.split("\n")
	for line in lines:
		var trimmed = line.strip_edges()
		if not trimmed.is_empty():
			result.append(trimmed)
	return result


func _populate_chain_options(exclude_trigger_id: String) -> void:
	trigger_chain_option.clear()
	trigger_chain_option.add_item("(None)")
	trigger_chain_option.set_item_metadata(0, "")

	var tm = SingletonObject.trigger_manager
	if not tm:
		return

	for trig in tm.triggers:
		if trig.id == exclude_trigger_id:
			continue
		var display = trig.name if not trig.name.is_empty() else trig.id
		trigger_chain_option.add_item(display)
		trigger_chain_option.set_item_metadata(trigger_chain_option.item_count - 1, trig.id)


func _select_chain_option(chain_id: String) -> void:
	if chain_id.is_empty():
		trigger_chain_option.select(0)
		return
	for i in trigger_chain_option.item_count:
		if trigger_chain_option.get_item_metadata(i) == chain_id:
			trigger_chain_option.select(i)
			return
	trigger_chain_option.select(0)


func _get_selected_chain_trigger_id() -> String:
	if trigger_chain_option.selected < 0:
		return ""
	return trigger_chain_option.get_item_metadata(trigger_chain_option.selected)

#endregion Trigger Callbacks


#region List Refresh

func _refresh_agent_list() -> void:
	agent_list.clear()
	var registry = SingletonObject.agent_registry
	if not registry:
		return

	for agent in registry.agents:
		agent_list.add_item(agent.name)

	# Also refresh trigger agent options
	_populate_agent_options()


func _refresh_trigger_list() -> void:
	trigger_list.clear()
	var tm = SingletonObject.trigger_manager
	if not tm:
		return

	var registry = SingletonObject.agent_registry
	for trig in tm.triggers:
		var agent_name = ""
		if registry:
			var agent = registry.get_agent(trig.agent_id)
			if agent:
				agent_name = agent.name

		var type_str = "Timer" if trig.trigger_type == TriggerDefinition.TriggerType.TIMER else "Event"
		var action_str = " (msg)" if trig.action_type == TriggerDefinition.ActionType.MESSAGE_EXISTING else ""
		var enabled_str = " [ON]" if trig.enabled else " [OFF]"
		var batch_str = " [%d params]" % trig.batch_params.size() if not trig.batch_params.is_empty() else ""
		var chain_str = " -> chain" if not trig.chain_trigger_id.is_empty() else ""
		var display_name = trig.name if not trig.name.is_empty() else agent_name
		trigger_list.add_item("%s%s: %s%s%s%s" % [type_str, action_str, display_name, batch_str, chain_str, enabled_str])

#endregion List Refresh

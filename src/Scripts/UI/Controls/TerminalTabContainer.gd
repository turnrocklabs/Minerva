class_name TerminalTabContainer
extends VBoxContainer
## Manages one or two TerminalTabGroup instances in a vertical split layout.
## Single group by default; split toggle button creates a second group on the right.

var _split_container: HSplitContainer
var _left_group: TerminalTabGroup
var _right_group: TerminalTabGroup  # null when not split
var _active_group: TerminalTabGroup
var _split_button: Button

## Agent terminal registry: agent_id → TerminalNew instance
var _agent_terminals: Dictionary = {}


func _ready():
	# Build split container
	_split_container = HSplitContainer.new()
	_split_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_split_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_split_container)

	# Create left group (always present)
	_left_group = TerminalTabGroup.new()
	_split_container.add_child(_left_group)
	_setup_group(_left_group)
	_active_group = _left_group

	# Add split toggle button to the left group's header
	_split_button = Button.new()
	_split_button.icon = preload("res://assets/icons/terminal_split_24.png")
	_split_button.tooltip_text = "Split terminal"
	_split_button.flat = true
	_split_button.pressed.connect(_on_split_toggle)
	_left_group.add_header_button(_split_button)

	visibility_changed.connect(_on_visibility_changed)

	# Listen for MCP tool calls to route to agent terminals
	SingletonObject.mcp_tool_executed.connect(_on_mcp_tool_executed)


func _setup_group(group: TerminalTabGroup) -> void:
	group.focus_requested.connect(_on_group_focus_requested.bind(group))
	group.became_empty.connect(_on_group_became_empty.bind(group))
	# Forward clicks to focus tracking
	group.gui_input.connect(func(_event): _set_active_group(group))


func _on_split_toggle() -> void:
	if _right_group:
		_close_right_group()
	else:
		_right_group = TerminalTabGroup.new()
		_split_container.add_child(_right_group)
		_setup_group(_right_group)
		_right_group.add_terminal()
		_set_active_group(_right_group)
		_split_button.tooltip_text = "Close split"


func _close_right_group() -> void:
	if not _right_group:
		return
	while _right_group.tab_count() > 0:
		_right_group.close_terminal(0)
	_right_group.queue_free()
	_right_group = null
	_set_active_group(_left_group)
	_split_button.tooltip_text = "Split terminal"


func _on_group_focus_requested(group: TerminalTabGroup) -> void:
	_set_active_group(group)


func _on_group_became_empty(group: TerminalTabGroup) -> void:
	if group == _right_group:
		_close_right_group()


func _set_active_group(group: TerminalTabGroup) -> void:
	if _active_group == group:
		return
	_active_group = group
	# Visual: dim inactive group slightly
	if _left_group:
		_left_group.modulate = Color.WHITE if group == _left_group else Color(0.8, 0.8, 0.85)
	if _right_group:
		_right_group.modulate = Color.WHITE if group == _right_group else Color(0.8, 0.8, 0.85)


func _unhandled_key_input(event: InputEvent) -> void:
	if not visible:
		return
	# Ctrl+\ to toggle focus between split groups
	if _right_group and event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_BACKSLASH and event.ctrl_pressed:
			if _active_group == _left_group:
				_set_active_group(_right_group)
			else:
				_set_active_group(_left_group)
			get_viewport().set_input_as_handled()


# ── Public API ────────────────────────────────────────────────────────

func get_active_terminal() -> TerminalNew:
	if _active_group:
		return _active_group.get_active_terminal()
	return null


# ── Visibility ────────────────────────────────────────────────────────

func _on_visibility_changed() -> void:
	if is_visible_in_tree() and _left_group and _left_group.is_empty():
		_left_group.add_terminal()


# ── Agent Terminal Management ─────────────────────────────────────────

func get_or_create_agent_terminal(agent_id: String) -> TerminalNew:
	## Get or create a terminal tab for the given agent. Empty agent_id = "MCP Activity".
	var display_name: String = "Agent: %s" % agent_id if not agent_id.is_empty() else "MCP Activity"
	var key: String = agent_id if not agent_id.is_empty() else "__mcp_default__"

	# Return existing if still valid
	if _agent_terminals.has(key):
		var existing: TerminalNew = _agent_terminals[key]
		if is_instance_valid(existing):
			return existing
		_agent_terminals.erase(key)  # stale reference

	# Create new agent terminal in the left group
	var term: TerminalNew = _left_group.add_terminal()

	# Rename the tab to show agent identity
	var tab_idx: int = _left_group.tab_count() - 1
	if _left_group._tab_bar and tab_idx >= 0:
		_left_group._tab_bar.set_tab_title(tab_idx, display_name)
		_left_group._tab_bar.set_tab_tooltip(tab_idx, "MCP agent terminal — tool call traceability")

	_agent_terminals[key] = term
	return term


func _on_mcp_tool_executed(tool_name: String, arguments: Dictionary, result: Dictionary, agent_id: String) -> void:
	## Route virtual block to the agent's terminal tab.
	if tool_name in ["minerva_bash", "minerva_cwd"]:
		return

	var term: TerminalNew = get_or_create_agent_terminal(agent_id)
	if not term:
		return

	# Defer write to ensure terminal is fully initialized
	_write_virtual_to_terminal.call_deferred(term, tool_name, arguments, result)


func _write_virtual_to_terminal(term: TerminalNew, tool_name: String, arguments: Dictionary, result: Dictionary) -> void:
	if not term or not is_instance_valid(term):
		return
	if not term.terminal or not term.terminal.has_method("write_to_screen"):
		# Terminal not ready yet — try again next frame
		_write_virtual_to_terminal.call_deferred(term, tool_name, arguments, result)
		return

	var block: TerminalBlock = TerminalBlock.create_virtual(tool_name, arguments, result)
	term._blocks.append(block)

	term._write_virtual_summary(block)

	var cursor = term.terminal.get_cursor() if term.terminal else {"y": 0}
	var viewport_row: int = cursor.get("y", 0)

	var block_idx: int = term._blocks.size() - 1
	var expand_btn := Button.new()
	expand_btn.text = "▶"
	expand_btn.tooltip_text = "Show full tool call details"
	expand_btn.flat = true
	expand_btn.custom_minimum_size = Vector2(28, 24)
	expand_btn.add_theme_font_size_override("font_size", 14)
	expand_btn.position.y = maxi(0, viewport_row - 1) * term.line_height
	expand_btn.position.x = 0
	expand_btn.pressed.connect(term._expand_virtual_block.bind(block_idx, expand_btn))
	term._check_buttons_container.add_child(expand_btn)

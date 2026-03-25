class_name TerminalTabContainer
extends VBoxContainer
## Manages one or two TerminalTabGroup instances in a vertical split layout.
## Single group by default; split toggle button creates a second group on the right.

var _split_container: HSplitContainer
var _left_group: TerminalTabGroup
var _right_group: TerminalTabGroup  # null when not split
var _active_group: TerminalTabGroup
var _split_button: Button


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

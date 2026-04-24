class_name TerminalTabContainer
extends VBoxContainer
## Manages up to three TerminalTabGroup instances in a horizontal split layout.
## Single group by default; split button creates additional groups on the right.

const MAX_GROUPS := 3

var _split_container: HSplitContainer
var _groups: Array[TerminalTabGroup] = []
var _active_group: TerminalTabGroup
var _split_button: Button


func _ready():
	_split_container = HSplitContainer.new()
	_split_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_split_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_split_container)

	var first_group := _create_group()
	_active_group = first_group

	_split_button = Button.new()
	_split_button.icon = preload("res://assets/icons/terminal_split_24.png")
	_split_button.tooltip_text = "Split terminal"
	_split_button.flat = true
	_split_button.pressed.connect(_on_split_toggle)
	_move_split_button_to_rightmost_group()

	visibility_changed.connect(_on_visibility_changed)


func _setup_group(group: TerminalTabGroup) -> void:
	group.focus_requested.connect(_on_group_focus_requested.bind(group))
	group.became_empty.connect(_on_group_became_empty.bind(group))
	# Forward clicks to focus tracking
	group.gui_input.connect(func(_event): _set_active_group(group))


func _create_group(add_initial_terminal: bool = false) -> TerminalTabGroup:
	var group := TerminalTabGroup.new()
	group.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	group.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_setup_group(group)
	_groups.append(group)
	_rebuild_split_layout()
	if add_initial_terminal:
		group.add_terminal()
	return group


func _rebuild_split_layout() -> void:
	_clear_split_children(_split_container)

	if _groups.size() == 0:
		return

	_split_container.add_child(_groups[0])
	if _groups.size() == 2:
		_split_container.add_child(_groups[1])
	elif _groups.size() == 3:
		var nested_split := HSplitContainer.new()
		nested_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nested_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_split_container.add_child(nested_split)
		nested_split.add_child(_groups[1])
		nested_split.add_child(_groups[2])


func _clear_split_children(node: Node) -> void:
	for child in node.get_children():
		if child is TerminalTabGroup:
			node.remove_child(child)
		elif child is HSplitContainer:
			_clear_split_children(child)
			node.remove_child(child)
			child.queue_free()


func _move_split_button_to_rightmost_group() -> void:
	if not _split_button or _groups.is_empty():
		return

	var parent := _split_button.get_parent()
	if parent:
		parent.remove_child(_split_button)

	var rightmost_group := _groups[_groups.size() - 1]
	rightmost_group.add_header_button(_split_button)
	_update_split_button_state()


func _update_split_button_state() -> void:
	if not _split_button:
		return
	var at_limit := _groups.size() >= MAX_GROUPS
	_split_button.disabled = at_limit
	_split_button.tooltip_text = "Maximum 3 terminal splits" if at_limit else "Split terminal"


func _on_split_toggle() -> void:
	if _groups.size() >= MAX_GROUPS:
		return

	var group := _create_group(true)
	_set_active_group(group)
	_move_split_button_to_rightmost_group()


func _remove_group(group: TerminalTabGroup) -> void:
	var group_index := _groups.find(group)
	if group_index <= 0:
		return

	# Closing the final tab emits TerminalTabGroup.became_empty, which routes back
	# here. Remove the group from tracking first so that signal cannot re-enter.
	var group_to_close := group
	_groups.remove_at(group_index)

	if _split_button and _split_button.get_parent():
		_split_button.get_parent().remove_child(_split_button)

	while group_to_close.tab_count() > 0:
		group_to_close.close_terminal(0)
	_rebuild_split_layout()
	group_to_close.queue_free()

	var fallback_index = mini(group_index - 1, _groups.size() - 1)
	_set_active_group(_groups[fallback_index])
	_move_split_button_to_rightmost_group()


func _on_group_focus_requested(group: TerminalTabGroup) -> void:
	_set_active_group(group)


func _on_group_became_empty(group: TerminalTabGroup) -> void:
	if _groups.find(group) > 0:
		_remove_group(group)


func _set_active_group(group: TerminalTabGroup) -> void:
	if _active_group == group:
		return
	_active_group = group
	for terminal_group in _groups:
		terminal_group.modulate = Color.WHITE if group == terminal_group else Color(0.8, 0.8, 0.85)


func _unhandled_key_input(event: InputEvent) -> void:
	if not visible:
		return
	# Ctrl+\ cycles focus between split groups.
	if _groups.size() > 1 and event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_BACKSLASH and event.ctrl_pressed:
			var current_index := _groups.find(_active_group)
			var next_index := (current_index + 1) % _groups.size()
			_set_active_group(_groups[next_index])
			get_viewport().set_input_as_handled()


# ── Public API ────────────────────────────────────────────────────────

func get_active_terminal() -> TerminalNew:
	if _active_group:
		return _active_group.get_active_terminal()
	return null


# ── Visibility ────────────────────────────────────────────────────────

func _on_visibility_changed() -> void:
	if is_visible_in_tree() and not _groups.is_empty() and _groups[0].is_empty():
		_groups[0].add_terminal()

class_name ChatGroupCard
extends PanelContainer
## One card in the chat-group dock (DCR 01a017494904).
##
## 32px tall, a coloured left bar identifying the group, an ellipsised name and
## a live chat count. Clicking selects the group (filtering the tab strip below);
## double-clicking renames it; dropping a chat tab on it moves that chat in.

signal selected(group_id: String)
signal rename_requested(group_id: String)
signal chat_dropped(group_id: String, chat_id: String)
## Right-click. The pane owns the menu, because the actions it offers depend on
## pane state (is there a group delete to undo?) that a card cannot see.
signal context_menu_requested(group_id: String, kind: int)

## ALL / UNGROUPED / DELETED are pseudo-groups: they are views, not storable
## memberships, so they cannot be renamed and are not drop targets (except
## UNGROUPED, which is how a chat leaves a group). Creating a group is NOT a
## card — it lives in the dock header, so it stays reachable when the row
## overflows or the dock is collapsed.
enum Kind { GROUP, ALL, UNGROUPED, DELETED }

const CARD_HEIGHT := 32
const MAX_NAME_WIDTH := 190
const BAR_WIDTH := 4
const DOUBLE_CLICK_WINDOW := 0.4

var kind: int = Kind.GROUP
var group_id: String = ""
var group_name: String = ""
var bar_color: Color = Color("#5f7f8a")
var count: int = 0
var is_active: bool = false

var _name_label: Label = null
var _count_label: Label = null
var _click_timer: float = 0.0
var _awaiting_double: bool = false


func _init() -> void:
	custom_minimum_size = Vector2(0, CARD_HEIGHT)
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


func _ready() -> void:
	_build()


func _build() -> void:
	if _name_label != null:
		return
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)

	_name_label = Label.new()
	_name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name_label.clip_text = true
	_name_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(_name_label)

	_count_label = Label.new()
	_count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_count_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_count_label.add_theme_color_override("font_color", Color("#8fb2bc"))
	row.add_child(_count_label)

	_refresh()


## Populate the card. Safe to call before _ready(); the values are re-applied
## once the child labels exist.
func configure(card_kind: int, id: String, display_name: String, color: Color, chat_count: int, active: bool) -> void:
	kind = card_kind
	group_id = id
	group_name = display_name
	bar_color = color
	count = chat_count
	is_active = active
	_build()
	_refresh()


func _refresh() -> void:
	if _name_label == null:
		return
	_name_label.text = group_name
	# Godot has no max-size on Control, so cap the label's MINIMUM width instead:
	# an HBoxContainer hands a non-expanding child exactly its minimum, so a name
	# wider than the cap gets clamped and the ellipsis behaviour engages.
	var measured := _measure_text(group_name)
	_name_label.custom_minimum_size.x = min(measured, MAX_NAME_WIDTH)

	if kind == Kind.DELETED:
		_count_label.text = str(count)
		tooltip_text = "Deleted chats — select to browse and restore. Nothing is purged automatically."
	else:
		_count_label.text = str(count)
		tooltip_text = "%s — %d chat%s" % [group_name, count, "" if count == 1 else "s"]
		if kind == Kind.GROUP:
			tooltip_text += "\nDouble-click to rename. Drop a chat tab here to move it in."

	add_theme_stylebox_override("panel", _make_stylebox())


func _measure_text(text: String) -> float:
	if text.is_empty():
		return 0.0
	var font := get_theme_default_font()
	if _name_label != null:
		var lbl_font := _name_label.get_theme_font("font")
		if lbl_font != null:
			font = lbl_font
	if font == null:
		# Headless / theme-less: fall back to a conservative per-character width
		# so the cap still applies and tests stay deterministic.
		return float(text.length()) * 8.0
	var font_size := get_theme_default_font_size()
	if _name_label != null:
		var lbl_size := _name_label.get_theme_font_size("font_size")
		if lbl_size > 0:
			font_size = lbl_size
	return font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x


func _make_stylebox() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#1e2024") if not is_active else Color("#252b34")
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	sb.border_width_left = BAR_WIDTH
	sb.border_color = bar_color
	if is_active:
		# The active card is outlined, not just tinted — colour alone is not a
		# reliable selection cue at 32px.
		sb.border_width_top = 1
		sb.border_width_bottom = 1
		sb.border_width_right = 1
	return sb


func _process(delta: float) -> void:
	if not _awaiting_double:
		return
	_click_timer += delta
	if _click_timer >= DOUBLE_CLICK_WINDOW:
		_awaiting_double = false
		set_process(false)
		selected.emit(group_id)


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_RIGHT:
		context_menu_requested.emit(group_id, kind)
		accept_event()
		return
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return
	accept_event()

	# Only real groups can be renamed, so only they need the double-click delay.
	# Everything else selects on the first click with no latency.
	if kind != Kind.GROUP:
		selected.emit(group_id)
		return

	if _awaiting_double:
		_awaiting_double = false
		set_process(false)
		rename_requested.emit(group_id)
	else:
		_awaiting_double = true
		_click_timer = 0.0
		set_process(true)


func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	if not (data is Dictionary):
		return false
	var payload: Dictionary = data
	if str(payload.get("kind", "")) != "chat_tab":
		return false
	# ALL and DELETED are not memberships — dropping there has no meaning.
	# UNGROUPED is, because it is how a chat leaves a group.
	return kind == Kind.GROUP or kind == Kind.UNGROUPED


func _drop_data(_at_position: Vector2, data: Variant) -> void:
	if not (data is Dictionary):
		return
	var payload: Dictionary = data
	chat_dropped.emit(group_id, str(payload.get("chat_id", "")))

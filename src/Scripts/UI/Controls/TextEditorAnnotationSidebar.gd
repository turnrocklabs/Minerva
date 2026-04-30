extends VBoxContainer
## Sidebar for a Type.TEXT Editor: surfaces broken-anchor annotations and the
## Repair UX. Wraps the substrate's AnnotationSidebarModel.
##
## Round 5b.ii: parent Editor calls set_host() once the AnnotationHost exists,
## then refresh() any time annotations / text change. Click Repair → emits
## `repair_requested(id)` so the parent Editor enters retarget mode.

signal repair_requested(annotation_id: String)
signal add_comment_requested(text: String)

const _AnnotationSidebarModelScript = preload("res://Scripts/Services/Annotations/AnnotationSidebarModel.gd")
const _BROKEN_COLOR := Color(1.0, 0.55, 0.05, 1.0)

var _model: RefCounted = null
var _host: RefCounted = null
var _can_add_comment := false

var _header_row: HBoxContainer
var _header: Label
var _add_button: Button
var _filter_button: CheckBox
var _add_row: HBoxContainer
var _comment_input: LineEdit
var _entries_list: VBoxContainer
var _status_label: Label
var _empty_label: Label


func _ready() -> void:
	_model = _AnnotationSidebarModelScript.new()
	_model.retarget_picker_requested.connect(_on_retarget_requested)
	_build_ui()
	refresh()


func set_host(host: RefCounted) -> void:
	_host = host
	refresh()


func set_can_add_comment(value: bool) -> void:
	_can_add_comment = value
	if _add_button != null:
		_add_button.disabled = not value
		_add_button.tooltip_text = "Add comment to selected text" if value else "Select text first"


func begin_add_comment_flow() -> void:
	_show_add_row()


func show_status(message: String) -> void:
	if _status_label != null:
		_status_label.text = message
		_status_label.show()


func enter_retarget_mode(_annotation_id: String) -> void:
	if _status_label != null:
		_status_label.text = "Select new range to re-anchor (Esc to cancel)"
		_status_label.show()


func exit_retarget_mode() -> void:
	if _status_label != null:
		_status_label.text = ""
		_status_label.hide()


## Decorate annotations with current resolved-stale state and push to the model.
func refresh() -> void:
	if _model == null:
		return
	var decorated: Array = []
	if _host != null and _host.has_method("get_annotations"):
		var anns: Array = _host.get_annotations()
		for a in anns:
			if not a is Dictionary:
				continue
			var d: Dictionary = (a as Dictionary).duplicate(true)
			if _host.has_method("resolve_anchor"):
				var resolved: Dictionary = _host.resolve_anchor(d.get("anchor", {}))
				if bool(resolved.get("stale", false)):
					d["stale"] = true
			decorated.append(d)
	_model.set_annotations(decorated)
	_populate_entries()


# ── UI construction ──────────────────────────────────────────────────────────

func _build_ui() -> void:
	add_theme_constant_override("separation", 6)

	_header_row = HBoxContainer.new()
	_header_row.add_theme_constant_override("separation", 6)
	add_child(_header_row)

	_header = Label.new()
	_header.add_theme_font_size_override("font_size", 13)
	_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header_row.add_child(_header)

	_add_button = Button.new()
	_add_button.text = "+"
	_add_button.disabled = true
	_add_button.tooltip_text = "Select text first"
	_add_button.custom_minimum_size = Vector2(28, 24)
	_add_button.focus_mode = Control.FOCUS_NONE
	_add_button.pressed.connect(begin_add_comment_flow)
	_header_row.add_child(_add_button)

	_filter_button = CheckBox.new()
	_filter_button.text = "Show broken only"
	_filter_button.toggled.connect(_on_filter_toggled)
	add_child(_filter_button)

	_add_row = HBoxContainer.new()
	_add_row.add_theme_constant_override("separation", 4)
	_add_row.hide()
	add_child(_add_row)

	_comment_input = LineEdit.new()
	_comment_input.placeholder_text = "Comment"
	_comment_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_comment_input.text_submitted.connect(_on_comment_submitted)
	_add_row.add_child(_comment_input)

	var add_confirm := Button.new()
	add_confirm.text = "Add"
	add_confirm.focus_mode = Control.FOCUS_NONE
	add_confirm.pressed.connect(_commit_add_comment)
	_add_row.add_child(add_confirm)

	var add_cancel := Button.new()
	add_cancel.text = "Cancel"
	add_cancel.focus_mode = Control.FOCUS_NONE
	add_cancel.pressed.connect(_hide_add_row)
	_add_row.add_child(add_cancel)

	_status_label = Label.new()
	_status_label.add_theme_color_override("font_color", _BROKEN_COLOR)
	_status_label.add_theme_font_size_override("font_size", 12)
	_status_label.hide()
	add_child(_status_label)

	_entries_list = VBoxContainer.new()
	_entries_list.add_theme_constant_override("separation", 4)
	add_child(_entries_list)

	_empty_label = Label.new()
	_empty_label.text = "(no broken annotations)"
	_empty_label.add_theme_font_size_override("font_size", 11)
	_empty_label.modulate = Color(1, 1, 1, 0.5)
	add_child(_empty_label)


func _populate_entries() -> void:
	for child in _entries_list.get_children():
		child.queue_free()
	if _model == null:
		return
	var broken_count: int = _model.get_broken_count()
	var visible: Array = _model.get_visible_annotations()
	if _header != null:
		_header.text = "Annotations (%d total, %d broken)" % [visible.size(), broken_count]
		_header.add_theme_color_override("font_color", _BROKEN_COLOR if broken_count > 0 else Color.WHITE)
	if _empty_label != null:
		_empty_label.visible = visible.size() == 0
	# Broken first (with Repair button + warning styling), then healthy.
	for entry in _model.get_broken_entries():
		_entries_list.add_child(_make_broken_row(entry))
	for ann in visible:
		if not ann is Dictionary:
			continue
		var d: Dictionary = ann as Dictionary
		if bool(d.get("stale", false)) or str(d.get("lifecycle", "")) == "stale":
			continue
		_entries_list.add_child(_make_healthy_row(d))


func _make_broken_row(entry: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var label := Label.new()
	var summary: String = str(entry.get("summary", ""))
	label.text = "⚠ %s" % summary
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_color_override("font_color", _BROKEN_COLOR)
	label.tooltip_text = summary
	row.add_child(label)
	var btn := Button.new()
	btn.text = "Repair"
	btn.pressed.connect(_on_repair_pressed.bind(str(entry.get("id", ""))))
	row.add_child(btn)
	return row


func _make_healthy_row(annotation: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var label := Label.new()
	var summary: String = str(annotation.get("summary", ""))
	label.text = "  %s" % summary
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.tooltip_text = summary
	row.add_child(label)
	return row


# ── Signals ──────────────────────────────────────────────────────────────────

func _on_filter_toggled(value: bool) -> void:
	if _model != null:
		_model.set_show_broken_only(value)


func _on_repair_pressed(annotation_id: String) -> void:
	repair_requested.emit(annotation_id)


func _on_retarget_requested(annotation_id: String) -> void:
	repair_requested.emit(annotation_id)


func _show_add_row() -> void:
	if _add_row == null or _comment_input == null:
		return
	_status_label.hide()
	_comment_input.text = ""
	_add_row.show()
	_comment_input.grab_focus()


func _hide_add_row() -> void:
	if _add_row != null:
		_add_row.hide()
	if _comment_input != null:
		_comment_input.text = ""


func _on_comment_submitted(_text: String) -> void:
	_commit_add_comment()


func _commit_add_comment() -> void:
	if _comment_input == null:
		return
	var text := _comment_input.text.strip_edges()
	if text.is_empty():
		show_status("Enter a comment")
		return
	add_comment_requested.emit(text)
	_hide_add_row()

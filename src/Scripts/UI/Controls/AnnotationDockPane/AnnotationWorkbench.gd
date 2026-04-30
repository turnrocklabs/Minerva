class_name AnnotationWorkbench
extends VBoxContainer
## Shared annotation workbench mounted by editor/plugin hosts.
##
## Hosts provide data and capabilities; this control owns the common UI:
## add flow, filter, list rows, lifecycle buttons, repair entry point, and
## selection sync. It intentionally keeps editor-specific picking outside.

signal repair_requested(annotation_id: String)
signal add_comment_requested(text: String)
signal annotation_selected(annotation_id: String)

const _BROKEN_COLOR := Color(1.0, 0.55, 0.05, 1.0)
const _MUTED := Color(1, 1, 1, 0.58)

var _host: RefCounted = null
var _can_add_comment := false
var _filter := "open"

var _header: Label
var _count_label: Label
var _add_button: Button
var _filter_options: OptionButton
var _add_row: HBoxContainer
var _comment_input: LineEdit
var _status_label: Label
var _entries_list: VBoxContainer
var _empty_label: Label


func _ready() -> void:
	_build_ui()
	refresh()


func set_host(host: RefCounted) -> void:
	if _host != null and _host.has_signal("annotations_changed") and _host.is_connected("annotations_changed", Callable(self, "refresh")):
		_host.disconnect("annotations_changed", Callable(self, "refresh"))
	_host = host
	if _host != null and _host.has_signal("annotations_changed") and not _host.is_connected("annotations_changed", Callable(self, "refresh")):
		_host.connect("annotations_changed", Callable(self, "refresh"))
	refresh()


func set_can_add_comment(value: bool) -> void:
	_can_add_comment = value
	if _add_button != null:
		_add_button.disabled = not value
		_add_button.tooltip_text = "Add annotation" if value else "Select text or click a line indicator"


func begin_add_comment_flow() -> void:
	_show_add_row()


func show_status(message: String) -> void:
	if _status_label == null:
		return
	_status_label.text = message
	_status_label.visible = not message.is_empty()


func enter_retarget_mode(_annotation_id: String) -> void:
	show_status("Select new range to re-anchor (Esc to cancel)")


func exit_retarget_mode() -> void:
	show_status("")


func refresh() -> void:
	if _entries_list == null:
		return
	for child in _entries_list.get_children():
		child.queue_free()

	var entries := _decorated_annotations()
	var visible := []
	var broken_count := 0
	for entry in entries:
		if bool(entry.get("stale", false)):
			broken_count += 1
		if _passes_filter(entry):
			visible.append(entry)

	if _header != null:
		_header.text = "Annotations"
	if _count_label != null:
		_count_label.text = "%d open, %d broken" % [_count_lifecycle(entries, "open"), broken_count]
		_count_label.add_theme_color_override("font_color", _BROKEN_COLOR if broken_count > 0 else _MUTED)

	for entry in visible:
		_entries_list.add_child(_make_row(entry))
	if _empty_label != null:
		_empty_label.visible = visible.is_empty()


func _build_ui() -> void:
	add_theme_constant_override("separation", 6)

	var header_row := HBoxContainer.new()
	header_row.add_theme_constant_override("separation", 6)
	add_child(header_row)

	_header = Label.new()
	_header.text = "Annotations"
	_header.add_theme_font_size_override("font_size", 13)
	_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_row.add_child(_header)

	_add_button = Button.new()
	_add_button.text = "+"
	_add_button.tooltip_text = "Select text or click a line indicator"
	_add_button.disabled = true
	_add_button.focus_mode = Control.FOCUS_NONE
	_add_button.custom_minimum_size = Vector2(28, 24)
	_add_button.pressed.connect(begin_add_comment_flow)
	header_row.add_child(_add_button)

	_count_label = Label.new()
	_count_label.text = "0 open, 0 broken"
	_count_label.add_theme_font_size_override("font_size", 11)
	_count_label.add_theme_color_override("font_color", _MUTED)
	add_child(_count_label)

	_filter_options = OptionButton.new()
	for label in ["Open", "All", "Applied", "Resolved", "Broken"]:
		_filter_options.add_item(label)
	_filter_options.item_selected.connect(_on_filter_selected)
	add_child(_filter_options)

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
	_entries_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(_entries_list)

	_empty_label = Label.new()
	_empty_label.text = "(no annotations)"
	_empty_label.add_theme_font_size_override("font_size", 11)
	_empty_label.add_theme_color_override("font_color", _MUTED)
	add_child(_empty_label)


func _decorated_annotations() -> Array:
	var result: Array = []
	if _host == null or not _host.has_method("get_annotations"):
		return result
	for a in _host.get_annotations():
		if not a is Dictionary:
			continue
		var d: Dictionary = (a as Dictionary).duplicate(true)
		if _host.has_method("resolve_anchor"):
			var resolved: Dictionary = _host.resolve_anchor(d.get("anchor", {}))
			if bool(resolved.get("stale", false)):
				d["stale"] = true
		if int(d.get("display_index", 0)) <= 0 and _host.has_method("get_annotation_display_index"):
			d["display_index"] = int(_host.get_annotation_display_index(d))
		d["_anchor_label"] = _annotation_anchor_label(d)
		result.append(d)
	return result


func _passes_filter(annotation: Dictionary) -> bool:
	var stale := bool(annotation.get("stale", false)) or str(annotation.get("lifecycle", "")) == "stale"
	var lifecycle := str(annotation.get("lifecycle", "open"))
	match _filter:
		"all":
			return true
		"broken":
			return stale
		"open":
			return lifecycle == "open" and not stale
		"applied":
			return lifecycle == "applied"
		"resolved":
			return lifecycle == "resolved"
	return true


func _make_row(annotation: Dictionary) -> Control:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.tooltip_text = "%s\n%s" % [str(annotation.get("_anchor_label", "")), str(annotation.get("summary", ""))]

	var select := Button.new()
	select.text = _annotation_prefix(annotation)
	select.focus_mode = Control.FOCUS_NONE
	select.custom_minimum_size = Vector2(44, 24)
	select.pressed.connect(_select_annotation.bind(str(annotation.get("id", ""))))
	row.add_child(select)

	var label := Label.new()
	label.text = _row_text(annotation)
	label.clip_text = true
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if bool(annotation.get("stale", false)):
		label.add_theme_color_override("font_color", _BROKEN_COLOR)
	row.add_child(label)

	var lifecycle := str(annotation.get("lifecycle", "open"))
	if bool(annotation.get("stale", false)):
		row.add_child(_small_button("Repair", _on_repair_pressed.bind(str(annotation.get("id", "")))))
	elif lifecycle == "resolved":
		row.add_child(_small_button("Reopen", _set_lifecycle.bind(str(annotation.get("id", "")), "open")))
	elif lifecycle == "applied":
		row.add_child(_small_button("Resolve", _set_lifecycle.bind(str(annotation.get("id", "")), "resolved")))
	else:
		row.add_child(_small_button("Applied", _set_lifecycle.bind(str(annotation.get("id", "")), "applied")))
		row.add_child(_small_button("Resolve", _set_lifecycle.bind(str(annotation.get("id", "")), "resolved")))
	if _host != null and _host.has_method("remove_annotation"):
		row.add_child(_small_button("Del", _delete_annotation.bind(str(annotation.get("id", "")))))
	return row


func _small_button(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(action)
	return button


func _annotation_prefix(annotation: Dictionary) -> String:
	var index := int(annotation.get("display_index", 0))
	return "#%d" % index if index > 0 else "#?"


func _row_text(annotation: Dictionary) -> String:
	var anchor_label := str(annotation.get("_anchor_label", ""))
	var summary := str(annotation.get("summary", "")).strip_edges()
	if summary.is_empty():
		summary = str(annotation.get("kind", "annotation"))
	if not anchor_label.is_empty():
		return "%s  %s" % [anchor_label, summary]
	return summary


func _annotation_anchor_label(annotation: Dictionary) -> String:
	var anchor: Variant = annotation.get("anchor", {})
	if not anchor is Dictionary:
		return ""
	var snapshot: Variant = (anchor as Dictionary).get("snapshot", {})
	var scope := ""
	var text := ""
	var line_num := -1
	if snapshot is Dictionary:
		var snap: Dictionary = snapshot
		scope = str(snap.get("target_scope", ""))
		text = str(snap.get("text", ""))
		var pos: Variant = snap.get("position", [])
		if pos is Array and (pos as Array).size() >= 1:
			line_num = int(float(pos[0])) + 1
	var payload: Variant = annotation.get("kind_payload", {})
	if payload is Dictionary and scope.is_empty():
		scope = str((payload as Dictionary).get("target_scope", ""))
	if scope == "line" and line_num > 0:
		return "Line %d" % line_num
	if text.is_empty():
		return "Range"
	text = text.replace("\n", " ").strip_edges()
	if text.length() > 32:
		text = text.substr(0, 29) + "..."
	return "\"%s\"" % text


func _count_lifecycle(entries: Array, lifecycle: String) -> int:
	var count := 0
	for entry in entries:
		if entry is Dictionary and str((entry as Dictionary).get("lifecycle", "")) == lifecycle and not bool((entry as Dictionary).get("stale", false)):
			count += 1
	return count


func _on_filter_selected(index: int) -> void:
	var text := _filter_options.get_item_text(index).to_lower()
	_filter = text
	refresh()


func _select_annotation(annotation_id: String) -> void:
	if _host != null and _host.has_method("set_selected_annotation_id"):
		_host.set_selected_annotation_id(annotation_id)
	annotation_selected.emit(annotation_id)


func _on_repair_pressed(annotation_id: String) -> void:
	repair_requested.emit(annotation_id)


func _set_lifecycle(annotation_id: String, lifecycle: String) -> void:
	if _host == null:
		return
	var patch := {}
	if lifecycle == "resolved":
		patch["resolved"] = {"by": {"kind": "human"}}
	elif lifecycle == "applied":
		patch["applied"] = {"by": {"kind": "human"}, "links": []}
	var ok := false
	if _host.has_method("update_annotation_lifecycle"):
		ok = bool(_host.update_annotation_lifecycle(annotation_id, lifecycle, patch).get("ok", false))
	if not ok:
		show_status("Could not update annotation")
	else:
		show_status("")
		refresh()


func _delete_annotation(annotation_id: String) -> void:
	if _host != null and _host.has_method("remove_annotation"):
		_host.remove_annotation(annotation_id)
		refresh()


func _show_add_row() -> void:
	if _add_row == null or _comment_input == null:
		return
	show_status("")
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

extends VBoxContainer
## Sidebar for a Type.TEXT Editor: surfaces broken-anchor annotations and the
## Repair UX. Wraps the substrate's AnnotationSidebarModel.
##
## Round 5b.ii: parent Editor calls set_host() once the AnnotationHost exists,
## then refresh() any time annotations / text change. Click Repair → emits
## `repair_requested(id)` so the parent Editor enters retarget mode.

signal repair_requested(annotation_id: String)

const _AnnotationSidebarModelScript = preload("res://Scripts/Services/Annotations/AnnotationSidebarModel.gd")
const _BROKEN_COLOR := Color(1.0, 0.55, 0.05, 1.0)

var _model: RefCounted = null
var _host: RefCounted = null

var _header: Label
var _filter_button: CheckBox
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

	_header = Label.new()
	_header.add_theme_font_size_override("font_size", 13)
	add_child(_header)

	_filter_button = CheckBox.new()
	_filter_button.text = "Show broken only"
	_filter_button.toggled.connect(_on_filter_toggled)
	add_child(_filter_button)

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

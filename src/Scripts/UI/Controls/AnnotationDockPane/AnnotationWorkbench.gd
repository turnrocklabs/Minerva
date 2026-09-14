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
signal reveal_requested(target: Control, annotation_id: String, host_epoch: int)

const _BROKEN_COLOR := Color(1.0, 0.55, 0.05, 1.0)
const _MUTED := Color(1, 1, 1, 0.58)
const _SELECTED_ROW_COLOR := Color(0.4, 0.55, 0.85, 0.18)

const _AnnotationApplyToolRunnerScript = preload("res://Scripts/Services/Annotations/AnnotationApplyToolRunner.gd")
const _CommentThreadScript = preload("res://Scripts/Services/Annotations/AnnotationCommentThread.gd")

var _host: RefCounted = null
var _can_add_comment := false
var _filter := "open"
var _selected_id: String = ""

## Every selected id (A8u1 multi-select); _selected_id stays the primary, which
## is what the body view and the single-target actions below keep using.
var _selected_ids: PackedStringArray = PackedStringArray()
var _apply_runner: RefCounted = null

var _header: Label
var _count_label: Label
var _header_row: HBoxContainer
var _add_button: Button
var _filter_options: OptionButton
var _add_row: VBoxContainer
var _comment_input: TextEdit
var _status_label: Label
var _entries_list: VBoxContainer
var _body_view_container: PanelContainer
## Horizontal-only viewport for the rows. Vertical scrolling belongs to the
## dock pane's single scroll region — this surface reports its full content
## height and lets the pane's budget decide how much of it is on screen.
var _content_scroll: ScrollContainer = null
var _scroll_body: VBoxContainer = null
var _current_body_view: Control = null
var _empty_label: Label
var _new_comment_draft := ""
var _reply_drafts: Dictionary = {}
var _reply_draft_focus: Dictionary = {}
var _thread_ui_states: Dictionary = {}
var _displayed_host_id := 0
var _displayed_annotation_id := ""
var _host_epoch := 0
## Expanded thread state is explicit so a data refresh cannot reopen a comment
## the reader deliberately collapsed.
var _expanded_comment_id := ""


func _ready() -> void:
	_build_ui()
	refresh()


func set_host(host: RefCounted) -> void:
	_capture_body_draft()
	var changing_host := host != _host
	if changing_host:
		_host_epoch += 1
		_clear_body_view()
	if _host != null and _host.has_signal("annotations_changed") and _host.is_connected("annotations_changed", Callable(self, "_on_annotations_changed")):
		_host.disconnect("annotations_changed", Callable(self, "_on_annotations_changed"))
	if _host != null and _host.has_signal("selection_changed") and _host.is_connected("selection_changed", Callable(self, "_on_selection_changed")):
		_host.disconnect("selection_changed", Callable(self, "_on_selection_changed"))
	if _host != null and _host.has_signal("selection_set_changed") and _host.is_connected("selection_set_changed", Callable(self, "_on_selection_set_changed")):
		_host.disconnect("selection_set_changed", Callable(self, "_on_selection_set_changed"))
	_host = host
	if changing_host:
		_new_comment_draft = ""
		_reply_drafts.clear()
		_reply_draft_focus.clear()
		_thread_ui_states.clear()
		_expanded_comment_id = ""
		if _comment_input != null:
			_comment_input.text = ""
		if _add_row != null:
			_add_row.hide()
	_selected_id = ""
	_selected_ids = PackedStringArray()
	if _host != null and _host.has_signal("annotations_changed") and not _host.is_connected("annotations_changed", Callable(self, "_on_annotations_changed")):
		_host.connect("annotations_changed", Callable(self, "_on_annotations_changed"))
	if _host != null and _host.has_signal("selection_changed") and not _host.is_connected("selection_changed", Callable(self, "_on_selection_changed")):
		_host.connect("selection_changed", Callable(self, "_on_selection_changed"))
	# A8u1: the SET can change with the primary unmoved; selection_changed is
	# silent in that case, so the row highlight needs its own hook.
	if _host != null and _host.has_signal("selection_set_changed") and not _host.is_connected("selection_set_changed", Callable(self, "_on_selection_set_changed")):
		_host.connect("selection_set_changed", Callable(self, "_on_selection_set_changed"))
	if _host != null and _host.has_method("get_selected_annotation_id"):
		_selected_id = _host.get_selected_annotation_id()
	if _is_text_comment_id(_selected_id):
		_expanded_comment_id = _selected_id
	_selected_ids = _read_selected_ids()
	_rebuild_filter_options()
	refresh()
	_refresh_body_view()


func set_can_add_comment(value: bool) -> void:
	_can_add_comment = value
	if _add_button != null:
		_add_button.disabled = not value
		_add_button.tooltip_text = "Add annotation" if value else "Select text or click a line indicator"


func begin_add_comment_flow() -> void:
	_show_add_row()
	_request_reveal(_comment_input, "")


func complete_add_comment(success: bool) -> void:
	if success:
		_new_comment_draft = ""
		_hide_add_row()
	else:
		_new_comment_draft = _comment_input.text if _comment_input != null else _new_comment_draft


func show_status(message: String) -> void:
	if _status_label == null:
		return
	_status_label.text = message
	_status_label.tooltip_text = message
	_status_label.visible = not message.is_empty()


func enter_retarget_mode(_annotation_id: String) -> void:
	show_status("Select new range to re-anchor (Esc to cancel)")


func exit_retarget_mode() -> void:
	show_status("")


func refresh() -> void:
	if _entries_list == null:
		return
	for child in _entries_list.get_children():
		if child == _body_view_container:
			continue
		_entries_list.remove_child(child)
		child.queue_free()

	var entries := _decorated_annotations()
	var visible_entries := []
	var broken_count := 0
	for entry in entries:
		if bool(entry.get("stale", false)):
			broken_count += 1
		if _passes_filter(entry):
			visible_entries.append(entry)

	var comment_context := _is_comment_context()
	_place_filter_for_context(comment_context)
	if _header != null:
		_header.text = "Comments" if comment_context else "Annotations"
	if _count_label != null:
		var open_count := _count_lifecycle(entries, "open", comment_context)
		_count_label.text = "%d open, %d need reattachment" % [open_count, broken_count] \
			if comment_context else "%d open, %d broken" % [open_count, broken_count]
		_count_label.add_theme_color_override("font_color", _BROKEN_COLOR if broken_count > 0 else _MUTED)

	for entry in visible_entries:
		_entries_list.add_child(_make_row(entry))
	_place_body_container()
	if _empty_label != null:
		_empty_label.visible = visible_entries.is_empty()


func _on_annotations_changed() -> void:
	refresh()
	_refresh_body_view()


## True while the row content is wider than the viewport — the state in which
## the horizontal scrollbar is the user's only way to the right-hand controls.
func is_scrolling_horizontally() -> bool:
	if _content_scroll == null:
		return false
	return _content_scroll.get_h_scroll_bar().visible


func _build_ui() -> void:
	add_theme_constant_override("separation", 6)

	_header_row = HBoxContainer.new()
	_header_row.add_theme_constant_override("separation", 6)
	add_child(_header_row)

	_header = Label.new()
	_header.text = "Annotations"
	_header.add_theme_font_size_override("font_size", 13)
	_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header_row.add_child(_header)

	_add_button = Button.new()
	_add_button.text = "+"
	_add_button.tooltip_text = "Select text or click a line indicator"
	_add_button.disabled = true
	_add_button.focus_mode = Control.FOCUS_NONE
	_add_button.custom_minimum_size = Vector2(28, 24)
	_add_button.pressed.connect(begin_add_comment_flow)
	_header_row.add_child(_add_button)

	_count_label = Label.new()
	_count_label.text = "0 open, 0 broken"
	_count_label.add_theme_font_size_override("font_size", 11)
	_count_label.add_theme_color_override("font_color", _MUTED)
	add_child(_count_label)

	_filter_options = OptionButton.new()
	_rebuild_filter_options()
	_filter_options.item_selected.connect(_on_filter_selected)
	add_child(_filter_options)

	_add_row = VBoxContainer.new()
	_add_row.add_theme_constant_override("separation", 4)
	_add_row.hide()
	add_child(_add_row)

	_comment_input = TextEdit.new()
	_comment_input.placeholder_text = "Write a comment…"
	_comment_input.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_comment_input.custom_minimum_size = Vector2(180, 76)
	_comment_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_comment_input.gui_input.connect(_on_comment_input_gui_input)
	_add_row.add_child(_comment_input)

	var add_actions := HBoxContainer.new()
	add_actions.alignment = BoxContainer.ALIGNMENT_END
	_add_row.add_child(add_actions)

	var add_confirm := Button.new()
	add_confirm.text = "Add"
	add_confirm.focus_mode = Control.FOCUS_NONE
	add_confirm.pressed.connect(_commit_add_comment)
	add_actions.add_child(add_confirm)

	var add_cancel := Button.new()
	add_cancel.text = "Cancel"
	add_cancel.focus_mode = Control.FOCUS_NONE
	add_cancel.pressed.connect(_hide_add_row)
	add_actions.add_child(add_cancel)

	_status_label = Label.new()
	_status_label.add_theme_color_override("font_color", _BROKEN_COLOR)
	_status_label.add_theme_font_size_override("font_size", 12)
	# Elide rather than widen: this label sits OUTSIDE the scroll, so a long
	# status would otherwise set the whole dock's minimum width. Full text stays
	# reachable in the tooltip.
	_status_label.clip_text = true
	_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status_label.hide()
	add_child(_status_label)

	# The list + expanded body live inside a ScrollContainer that scrolls
	# SIDEWAYS only. Growing tall is safe now: the dock pane caps its own height
	# and scrolls this whole surface vertically, so a long list can no longer
	# push the pane's collapse chevron off-screen.
	var content_scroll := ScrollContainer.new()
	content_scroll.name = "AnnotationScroll"
	content_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Horizontal AUTO: with horizontal scrolling DISABLED the scroll's own
	# minimum width is the widest row's, so a narrow dock could neither shrink
	# the rows nor reach what hung outside it. AUTO keeps rows shrink-to-fit
	# while they fit (the container only falls back to content width once the
	# row minimum overflows) and shows a scrollbar exactly when it does not —
	# wheel and shift+wheel pan it, which ScrollContainer handles itself.
	# Vertical DISABLED: the dock pane owns the one vertical scroll, so this
	# surface reports its true content height rather than nesting a second
	# wheel target inside the first.
	content_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	content_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(content_scroll)
	_content_scroll = content_scroll

	var scroll_body := VBoxContainer.new()
	scroll_body.name = "ScrollBody"
	scroll_body.add_theme_constant_override("separation", 6)
	scroll_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_scroll.add_child(scroll_body)
	_scroll_body = scroll_body

	_entries_list = VBoxContainer.new()
	_entries_list.name = "EntriesList"
	_entries_list.add_theme_constant_override("separation", 4)
	_entries_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_body.add_child(_entries_list)

	_body_view_container = PanelContainer.new()
	_body_view_container.name = "BodyViewContainer"
	_body_view_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body_view_container.hide()
	scroll_body.add_child(_body_view_container)

	_empty_label = Label.new()
	_empty_label.text = "(no annotations)"
	_empty_label.add_theme_font_size_override("font_size", 11)
	_empty_label.add_theme_color_override("font_color", _MUTED)
	add_child(_empty_label)


func _decorated_annotations() -> Array:
	var result: Array = []
	if _host == null or not _host.has_method("get_annotations"):
		return result
	var registry: AnnotationRegistry = _host.get_registry() if _host.has_method("get_registry") else null
	for a in _host.get_annotations():
		if not a is Dictionary:
			continue
		# Workflow-class kinds (e.g. pcb_route_hint) are working data for a
		# domain loop, not review commentary — the review dock excludes them
		# (pcb-ui-native-cluster §4). They list in WorkflowAnnotationList.
		if _is_workflow_class(a as Dictionary, registry):
			continue
		var d: Dictionary = (a as Dictionary).duplicate(true)
		if _host.has_method("resolve_anchor"):
			var resolved: Dictionary = _host.resolve_anchor(d.get("anchor", {}))
			if bool(resolved.get("stale", false)):
				d["stale"] = true
				d["_anchor_issue"] = str(resolved.get("view_metadata", {}).get("reason", "Needs reattachment"))
		var display_index := int(d.get("display_index", 0))
		if display_index <= 0 and _host.has_method("get_annotation_display_index"):
			display_index = int(_host.get_annotation_display_index(d))
		if display_index <= 0:
			display_index = result.size() + 1
		d["display_index"] = display_index
		d["_anchor_label"] = _annotation_anchor_label(d)
		d["_row_words"] = _annotation_words(d, registry)
		result.append(d)
	return result


## True when the annotation's registered kind declares workflow_class
## (AnnotationKind.workflow_class). Unknown kinds are NOT workflow-class.
func _is_workflow_class(annotation: Dictionary, registry: AnnotationRegistry) -> bool:
	if registry == null:
		return false
	var kind: AnnotationKind = registry.get_annotation_kind(StringName(str(annotation.get("kind", ""))))
	return kind != null and kind.workflow_class


func _passes_filter(annotation: Dictionary) -> bool:
	var stale := bool(annotation.get("stale", false)) or str(annotation.get("lifecycle", "")) == "stale"
	var lifecycle := str(annotation.get("lifecycle", "open"))
	match _filter:
		"all":
			return true
		"broken":
			return stale
		"open":
			return lifecycle == "open" and (not stale or str(annotation.get("kind", "")) == "text_comment")
		"applied":
			return lifecycle == "applied"
		"resolved":
			return lifecycle == "resolved"
	return true


func _make_row(annotation: Dictionary) -> Control:
	var panel := PanelContainer.new()
	panel.set_meta("annotation_id", str(annotation.get("id", "")))
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var row := HBoxContainer.new()
	panel.add_child(row)
	row.add_theme_constant_override("separation", 6)
	row.tooltip_text = "%s\n%s" % [str(annotation.get("_anchor_label", "")), str(annotation.get("summary", ""))]
	if _selected_ids.has(str(annotation.get("id", ""))):
		var style := StyleBoxFlat.new()
		style.bg_color = _SELECTED_ROW_COLOR
		panel.add_theme_stylebox_override("panel", style)

	var is_comment_thread := str(annotation.get("kind", "")) == "text_comment"
	var select: BaseButton
	if is_comment_thread:
		var jump_link := LinkButton.new()
		jump_link.text = _annotation_prefix(annotation)
		jump_link.underline = LinkButton.UNDERLINE_MODE_ON_HOVER
		jump_link.tooltip_text = "Jump to comment %s" % jump_link.text
		select = jump_link
	else:
		var annotation_button := Button.new()
		annotation_button.text = _annotation_prefix(annotation)
		annotation_button.focus_mode = Control.FOCUS_NONE
		annotation_button.custom_minimum_size = Vector2(44, 24)
		select = annotation_button
	select.pressed.connect(_select_annotation.bind(str(annotation.get("id", ""))))
	row.add_child(select)

	var label := Label.new()
	label.text = _row_text(annotation)
	# Clip + ellipsis drops the label's minimum width to nothing, so the row
	# shrinks to the dock instead of the dock stretching to the summary — and
	# the lifecycle buttons after it stay pinned at the right edge.
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if bool(annotation.get("stale", false)):
		label.add_theme_color_override("font_color", _BROKEN_COLOR)
	row.add_child(label)

	var lifecycle := str(annotation.get("lifecycle", "open"))
	if bool(annotation.get("stale", false)) and _capability_lifecycle_enabled("repair"):
		row.add_child(_small_icon_button("res://assets/icons/reload-icons/reload-16.svg", "Repair anchor", _on_repair_pressed.bind(str(annotation.get("id", "")))) if is_comment_thread else _small_button("Repair", _on_repair_pressed.bind(str(annotation.get("id", "")))))
	elif lifecycle == "resolved" and _capability_lifecycle_enabled("reopen"):
		row.add_child(_small_icon_button("res://assets/icons/reload-icons/reload-16.svg", "Reopen thread", _set_lifecycle.bind(str(annotation.get("id", "")), "open")) if is_comment_thread else _small_button("Reopen", _set_lifecycle.bind(str(annotation.get("id", "")), "open")))
	elif lifecycle == "applied" and _capability_lifecycle_enabled("resolve"):
		row.add_child(_small_icon_button("res://assets/icons/checkmark16.svg", "Resolve thread", _set_lifecycle.bind(str(annotation.get("id", "")), "resolved")) if is_comment_thread else _small_button("Resolve", _set_lifecycle.bind(str(annotation.get("id", "")), "resolved")))
	else:
		if not is_comment_thread and _capability_lifecycle_enabled("apply"):
			row.add_child(_small_button("Applied", _set_lifecycle.bind(str(annotation.get("id", "")), "applied")))
		if _capability_lifecycle_enabled("resolve"):
			row.add_child(_small_icon_button("res://assets/icons/checkmark16.svg", "Resolve thread", _set_lifecycle.bind(str(annotation.get("id", "")), "resolved")) if is_comment_thread else _small_button("Resolve", _set_lifecycle.bind(str(annotation.get("id", "")), "resolved")))
	if _host != null and _host.has_method("remove_annotation") and _capability_lifecycle_enabled("delete"):
		if is_comment_thread:
			row.add_child(_small_icon_button("res://assets/icons/delete_selection.svg", "Delete thread", _confirm_delete_annotation.bind(str(annotation.get("id", "")))))
		else:
			row.add_child(_small_button("Del", _delete_annotation.bind(str(annotation.get("id", "")))))
	var kind_actions := _row_actions(annotation)
	for action in kind_actions:
		if not action is Dictionary:
			continue
		var action_id := str((action as Dictionary).get("id", ""))
		var action_label := str((action as Dictionary).get("label", action_id))
		if action_id.is_empty():
			continue
		row.add_child(_small_button(action_label, _run_action.bind(str(annotation.get("id", "")), action_id)))
	return panel


func _small_button(text: String, action: Callable) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.pressed.connect(action)
	return button


func _small_icon_button(icon_path: String, tooltip: String, action: Callable) -> Button:
	var button := Button.new()
	button.icon = load(icon_path) as Texture2D
	button.tooltip_text = tooltip
	button.focus_mode = Control.FOCUS_ALL
	button.custom_minimum_size = Vector2(28, 24)
	button.pressed.connect(action)
	return button


func _host_capabilities() -> Dictionary:
	if _host == null:
		return {}
	if _host.has_method("get_annotation_capabilities"):
		return _host.get_annotation_capabilities()
	if _host.has_method("get_capabilities"):
		return _host.get_capabilities()
	return {}


func _capability_lifecycle_enabled(action: String) -> bool:
	var lifecycle: Variant = _host_capabilities().get("lifecycle", {})
	if lifecycle is Dictionary:
		return bool((lifecycle as Dictionary).get(action, false))
	return false


func _annotation_prefix(annotation: Dictionary) -> String:
	var index := int(annotation.get("display_index", 0))
	return "#%d" % index if index > 0 else "#?"


## The row is the HUMAN'S words — the caption, the comment, the text — and
## nothing else. Geometry and the resolved anchor are the envelope's `summary`
## and `anchored_to`; agents read those as structured fields from
## minerva_annotations_list, and a person gets them in the row's tooltip.
## An annotation with no words shows its kind's name.
func _row_text(annotation: Dictionary) -> String:
	var words := str(annotation.get("_row_words", "")).strip_edges()
	if words.is_empty():
		words = str(annotation.get("kind", "annotation")).capitalize()
	var anchor_label := str(annotation.get("_anchor_label", ""))
	var anchor_issue := str(annotation.get("_anchor_issue", ""))
	if not anchor_issue.is_empty():
		words = "%s · %s" % [anchor_issue, words]
	if not anchor_label.is_empty():
		return "%s  %s" % [anchor_label, words]
	return words


## The kind's own reading of the annotation's free text (AnnotationKind
## .text_content) — "" for a kind with no words or one the registry does not
## know.
func _annotation_words(annotation: Dictionary, registry) -> String:
	if registry == null:
		return ""
	var kind = registry.get_annotation_kind(StringName(str(annotation.get("kind", ""))))
	if kind == null:
		return ""
	return str(kind.text_content(annotation)).replace("\n", " ").strip_edges()


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
	# No snapshot text means the anchor is a point or region on a canvas, and a
	# label saying so ("Range") tells the reader nothing the row needs.
	if text.is_empty():
		return ""
	text = text.replace("\n", " ").strip_edges()
	if text.length() > 32:
		text = text.substr(0, 29) + "..."
	return "\"%s\"" % text


func _count_lifecycle(entries: Array, lifecycle: String, include_detached: bool = false) -> int:
	var count := 0
	for entry in entries:
		if entry is Dictionary and str((entry as Dictionary).get("lifecycle", "")) == lifecycle \
				and (include_detached or not bool((entry as Dictionary).get("stale", false))):
			count += 1
	return count


func _is_comment_context() -> bool:
	var filters: Array = _host_capabilities().get("filters", [])
	return filters == ["open", "resolved", "all"]


func _place_filter_for_context(comment_context: bool) -> void:
	if _filter_options == null or _header_row == null:
		return
	if comment_context:
		_filter_options.size_flags_horizontal = Control.SIZE_SHRINK_END
		if _filter_options.get_parent() != _header_row:
			_filter_options.reparent(_header_row)
		# Keep the compact state selector next to the add action while the title
		# consumes the remaining header width.
		var filter_index := _header.get_index() + 1
		if _filter_options.get_index() != filter_index:
			_header_row.move_child(_filter_options, filter_index)
	else:
		_filter_options.size_flags_horizontal = Control.SIZE_FILL
		if _filter_options.get_parent() != self:
			_filter_options.reparent(self)
			move_child(_filter_options, _count_label.get_index() + 1)


func _on_filter_selected(index: int) -> void:
	var text := _filter_options.get_item_text(index).to_lower()
	_filter = text
	refresh()


func _select_annotation(annotation_id: String) -> void:
	if _is_text_comment_id(annotation_id) and _expanded_comment_id == annotation_id:
		_collapse_comment(annotation_id)
		return
	if _is_text_comment_id(annotation_id):
		_expanded_comment_id = annotation_id
	# A list click REPLACES the selection — see WorkflowAnnotationList for why
	# the multi API is preferred when the host has it.
	if _host != null and _host.has_method("set_selected_annotation_ids"):
		_host.set_selected_annotation_ids(PackedStringArray([annotation_id]), annotation_id)
	elif _host != null and _host.has_method("set_selected_annotation_id"):
		_host.set_selected_annotation_id(annotation_id)
	annotation_selected.emit(annotation_id)
	if _is_text_comment_id(annotation_id) and _expanded_comment_id == annotation_id:
		_request_reveal(_body_view_container, annotation_id)


func _on_selection_changed(annotation_id: String) -> void:
	_capture_body_draft()
	_selected_id = annotation_id
	_expanded_comment_id = annotation_id if _is_text_comment_id(annotation_id) else ""
	_selected_ids = _read_selected_ids()
	refresh()
	_refresh_body_view()


func _on_selection_set_changed(annotation_ids: PackedStringArray) -> void:
	_selected_ids = annotation_ids.duplicate()
	refresh()


## Every selected id. See AnnotationHost.selected_ids_for for the single-id
## fallback shared with the overlay and the author tools.
func _read_selected_ids() -> PackedStringArray:
	return AnnotationHost.selected_ids_for(_host)


func _refresh_body_view() -> void:
	if _body_view_container == null:
		return
	_capture_body_draft()
	if _selected_id.is_empty() or _host == null:
		_clear_body_view()
		_body_view_container.hide()
		return
	var annotation: Dictionary = {}
	for a in _host.get_annotations():
		if a is Dictionary and str((a as Dictionary).get("id", "")) == _selected_id:
			annotation = (a as Dictionary).duplicate(true)
			break
	if annotation.is_empty():
		_clear_body_view()
		_body_view_container.hide()
		return
	var registry: AnnotationRegistry = _host.get_registry()
	if registry == null:
		_clear_body_view()
		_body_view_container.hide()
		return
	var kind: AnnotationKind = registry.get_annotation_kind(StringName(annotation.get("kind", "")))
	if kind == null:
		_clear_body_view()
		_body_view_container.hide()
		return
	if str(annotation.get("kind", "")) == "text_comment" and _expanded_comment_id != _selected_id:
		_clear_body_view()
		_body_view_container.hide()
		return
	var host_id := _host.get_instance_id()
	if _current_body_view != null and _displayed_host_id == host_id \
			and _displayed_annotation_id == _selected_id \
			and _current_body_view.has_method("update_annotation"):
		_current_body_view.call("update_annotation", annotation)
		_body_view_container.show()
		_place_body_container()
		return
	_clear_body_view()
	var annotation_id: String = _selected_id
	var host_epoch := _host_epoch
	var emit := func(patch: Dictionary) -> bool:
		if _host == null or _host_epoch != host_epoch or _host.get_instance_id() != host_id:
			return false
		return _apply_body_patch(annotation_id, patch)
	var view: Variant = kind.body_view_factory(annotation, emit)
	if view == null or not view is Control:
		_body_view_container.hide()
		return
	_current_body_view = view as Control
	_displayed_host_id = host_id
	_displayed_annotation_id = annotation_id
	_body_view_container.add_child(_current_body_view)
	if _current_body_view.has_signal("collapse_requested"):
		_current_body_view.connect("collapse_requested", _collapse_comment.bind(annotation_id))
	if _current_body_view.has_signal("reveal_requested"):
		_current_body_view.connect("reveal_requested", func(target: Control) -> void:
			_request_reveal(target, annotation_id, host_epoch)
		)
	_body_view_container.show()
	_place_body_container()
	if _current_body_view.has_method("restore_draft"):
		if _current_body_view.has_method("restore_ui_state") and _thread_ui_states.has(annotation_id):
			_current_body_view.call("restore_ui_state", _thread_ui_states[annotation_id])
		else:
			_current_body_view.call("restore_draft", str(_reply_drafts.get(annotation_id, "")),
				bool(_reply_draft_focus.get(annotation_id, false)))


func _is_text_comment_id(annotation_id: String) -> bool:
	if annotation_id.is_empty():
		return false
	return str(_annotation_by_id(annotation_id).get("kind", "")) == "text_comment"


func _collapse_comment(annotation_id: String) -> void:
	if annotation_id != _expanded_comment_id:
		return
	_capture_body_draft()
	_expanded_comment_id = ""
	if _host != null and _host.has_method("set_selected_annotation_ids"):
		_host.set_selected_annotation_ids(PackedStringArray(), "")
	elif _host != null and _host.has_method("set_selected_annotation_id"):
		_host.set_selected_annotation_id("")
	# Hosts normally signal synchronously. Keep the view correct for a minimal
	# host whose setter does not, without reopening the collapsed thread.
	if _selected_id == annotation_id:
		_selected_id = ""
		_selected_ids = PackedStringArray()
		refresh()
		_refresh_body_view()


func _request_reveal(target: Control, annotation_id: String, epoch: int = -1) -> void:
	if target == null:
		return
	reveal_requested.emit(target, annotation_id, _host_epoch if epoch < 0 else epoch)


func is_reveal_target_current(target: Control, annotation_id: String, epoch: int) -> bool:
	if epoch != _host_epoch or target == null or not is_instance_valid(target) \
			or not target.is_inside_tree() or not target.is_visible_in_tree():
		return false
	if annotation_id.is_empty():
		return _add_row != null and _add_row.visible \
			and (target == _add_row or _add_row.is_ancestor_of(target))
	return annotation_id == _expanded_comment_id and annotation_id == _displayed_annotation_id \
		and _body_view_container != null and _body_view_container.visible \
		and (target == _body_view_container or _body_view_container.is_ancestor_of(target))


func _park_body_container() -> void:
	if _body_view_container == null or _scroll_body == null:
		return
	if _body_view_container.get_parent() != _scroll_body:
		_body_view_container.reparent(_scroll_body)
	_scroll_body.move_child(_body_view_container, _entries_list.get_index() + 1)


func _place_body_container() -> void:
	if _body_view_container == null or _entries_list == null or _scroll_body == null:
		return
	if not _expanded_comment_id.is_empty() and _current_body_view != null:
		var target_row: Control = null
		for child in _entries_list.get_children():
			if child != _body_view_container and str(child.get_meta("annotation_id", "")) == _expanded_comment_id:
				target_row = child as Control
				break
		if target_row != null:
			_body_view_container.show()
			if _body_view_container.get_parent() != _entries_list:
				_body_view_container.reparent(_entries_list)
			var target_index := target_row.get_index()
			var body_index := _body_view_container.get_index()
			# If the body currently precedes the row, removing it shifts the row
			# left by one; account for that so the final order is always row/body.
			var desired_index := target_index if body_index < target_index else target_index + 1
			if _body_view_container.get_index() != desired_index:
				_entries_list.move_child(_body_view_container, desired_index)
			return
		# A lifecycle filter can temporarily remove the active row. Retain the
		# owned view and draft, but never show an unattached thread in the list.
		_body_view_container.hide()
		_park_body_container()
		return
	# Generic annotation details retain their historical below-list placement.
	_park_body_container()


func _apply_body_patch(annotation_id: String, patch: Dictionary) -> bool:
	if _host == null or not _host.has_method("update_annotation"):
		return false
	var current := _annotation_by_id(annotation_id)
	if current.is_empty():
		return false
	var command := str(patch.get("_thread_command", ""))
	if command == "edit_root":
		var updated := current.duplicate(true)
		var payload_v: Variant = updated.get("kind_payload", {})
		var payload: Dictionary = (payload_v as Dictionary).duplicate(true) if payload_v is Dictionary else {}
		var text := str(patch.get("text", "")).strip_edges()
		if text.is_empty():
			show_status("Comment text is required")
			return false
		payload["text"] = text
		updated["kind_payload"] = payload
		updated["summary"] = text
		var stored := bool(_host.update_annotation(annotation_id, updated))
		if stored:
			show_status("")
		return stored
	if command in ["add_reply", "edit_reply", "delete_reply"]:
		var result: Dictionary
		if command == "add_reply" and _host.has_method("add_comment_reply"):
			result = _host.call("add_comment_reply", annotation_id, str(patch.get("text", "")), {"kind": "human"})
		elif command == "edit_reply" and _host.has_method("edit_comment_reply"):
			result = _host.call("edit_comment_reply", annotation_id, str(patch.get("reply_id", "")), str(patch.get("text", "")))
		elif command == "delete_reply" and _host.has_method("delete_comment_reply"):
			result = _host.call("delete_comment_reply", annotation_id, str(patch.get("reply_id", "")))
		elif command == "add_reply":
			result = _CommentThreadScript.add_reply(current, str(patch.get("text", "")), {"kind": "human"})
		elif command == "edit_reply":
			result = _CommentThreadScript.edit_reply(current, str(patch.get("reply_id", "")), str(patch.get("text", "")))
		else:
			result = _CommentThreadScript.delete_reply(current, str(patch.get("reply_id", "")))
		if not bool(result.get("ok", false)):
			show_status(str(result.get("error", "Could not add reply")))
			return false
		var stored := bool(result.get("ok", false))
		if not (_host.has_method("add_comment_reply") and command == "add_reply") \
				and not (_host.has_method("edit_comment_reply") and command == "edit_reply") \
				and not (_host.has_method("delete_comment_reply") and command == "delete_reply"):
			stored = bool(_host.update_annotation(annotation_id, result.get("annotation", {})))
		if stored and command == "add_reply":
			_reply_drafts.erase(annotation_id)
			_thread_ui_states.erase(annotation_id)
			if _current_body_view != null and _current_body_view.has_method("clear_draft"):
				_current_body_view.call("clear_draft")
		if stored:
			show_status("")
		return stored
	var merged := current.duplicate(true)
	merged.merge(patch, true)
	return bool(_host.update_annotation(annotation_id, merged))


func _annotation_by_id(annotation_id: String) -> Dictionary:
	if _host != null and _host.has_method("get_by_id"):
		return _host.get_by_id(annotation_id)
	if _host != null and _host.has_method("get_annotations"):
		for value in _host.get_annotations():
			if value is Dictionary and str((value as Dictionary).get("id", "")) == annotation_id:
				return (value as Dictionary).duplicate(true)
	return {}


func _capture_body_draft() -> void:
	if _current_body_view == null or _displayed_annotation_id.is_empty():
		return
	if _current_body_view.has_method("draft_text"):
		_reply_drafts[_displayed_annotation_id] = str(_current_body_view.call("draft_text"))
	if _current_body_view.has_method("composer_has_focus"):
		_reply_draft_focus[_displayed_annotation_id] = bool(_current_body_view.call("composer_has_focus"))
	if _current_body_view.has_method("capture_ui_state"):
		_thread_ui_states[_displayed_annotation_id] = _current_body_view.call("capture_ui_state")


func _clear_body_view() -> void:
	if _current_body_view != null:
		if _current_body_view.get_parent() == _body_view_container:
			_body_view_container.remove_child(_current_body_view)
		_current_body_view.queue_free()
	_current_body_view = null
	_displayed_host_id = 0
	_displayed_annotation_id = ""


func _rebuild_filter_options() -> void:
	if _filter_options == null:
		return
	var allowed: Array = _host_capabilities().get("filters", [])
	if allowed.is_empty():
		allowed = ["all", "open", "applied", "resolved", "broken"]
	_filter_options.clear()
	for value in allowed:
		_filter_options.add_item(str(value).capitalize())
	var selected := allowed.find(_filter)
	if selected < 0:
		_filter = "open" if allowed.has("open") else str(allowed[0])
		selected = allowed.find(_filter)
	_filter_options.select(selected)


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


func _ensure_apply_runner() -> RefCounted:
	if _apply_runner == null:
		_apply_runner = _AnnotationApplyToolRunnerScript.new()
	return _apply_runner


func _row_actions(annotation: Dictionary) -> Array:
	if _host == null:
		return []
	var registry: AnnotationRegistry = null
	if _host.has_method("get_registry"):
		registry = _host.get_registry()
	if registry == null:
		return []
	var kind: AnnotationKind = registry.get_annotation_kind(StringName(annotation.get("kind", "")))
	if kind == null:
		return []
	var raw: Array = kind.actions(annotation)
	var lifecycle := str(annotation.get("lifecycle", "open"))
	var visible_actions: Array = []
	for entry in raw:
		if not entry is Dictionary:
			continue
		var requires: Variant = (entry as Dictionary).get("requires_lifecycle", [])
		if requires is Array and not (requires as Array).is_empty() and not (lifecycle in requires):
			continue
		visible_actions.append(entry)
	return visible_actions


func _run_action(annotation_id: String, action_id: String) -> void:
	if _host == null:
		return
	var registry: AnnotationRegistry = null
	if _host.has_method("get_registry"):
		registry = _host.get_registry()
	if registry == null:
		return
	var annotation: Dictionary = {}
	for a in _host.get_annotations():
		if a is Dictionary and str((a as Dictionary).get("id", "")) == annotation_id:
			annotation = a as Dictionary
			break
	if annotation.is_empty():
		return
	var kind: AnnotationKind = registry.get_annotation_kind(StringName(annotation.get("kind", "")))
	if kind == null:
		return
	# Single-element Array wrapper so the closure can write the commit-phase result
	# back to the enclosing scope; ApplyToolRunner.apply() returns bare {ok: true}.
	var commit_result: Array = [{}]
	var hook := func(ann_id: String, phase: String) -> Dictionary:
		var ann: Dictionary = {}
		for a in _host.get_annotations():
			if a is Dictionary and str((a as Dictionary).get("id", "")) == ann_id:
				ann = a as Dictionary
				break
		var hook_result: Dictionary = kind.run_action(action_id, ann, phase, _host as AnnotationHost)
		if phase == "commit":
			commit_result[0] = hook_result
		return hook_result
	var result: Dictionary = _ensure_apply_runner().apply(action_id, annotation_id, hook, _host)
	if not bool(result.get("ok", false)):
		show_status(str(result.get("error", "Action failed")))
		return
	var next_lifecycle := str((commit_result[0] as Dictionary).get("lifecycle", ""))
	if not next_lifecycle.is_empty() and _host.has_method("update_annotation_lifecycle"):
		_host.update_annotation_lifecycle(annotation_id, next_lifecycle, {})
	show_status("")
	refresh()


func _delete_annotation(annotation_id: String) -> void:
	if _host != null and _host.has_method("remove_annotation"):
		_host.remove_annotation(annotation_id)
		refresh()


func _confirm_delete_annotation(annotation_id: String) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Delete comment thread?"
	dialog.dialog_text = "The comment and all replies will be removed."
	dialog.confirmed.connect(_delete_annotation.bind(annotation_id))
	dialog.canceled.connect(dialog.queue_free)
	dialog.confirmed.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()


func _show_add_row() -> void:
	if _add_row == null or _comment_input == null:
		return
	show_status("")
	_comment_input.text = _new_comment_draft
	_add_row.show()
	_comment_input.grab_focus()


func _hide_add_row() -> void:
	if _add_row != null:
		_add_row.hide()
	if _comment_input != null:
		_new_comment_draft = ""
		_comment_input.text = ""


func _on_comment_input_gui_input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var key := event as InputEventKey
	if not key.pressed or key.is_echo():
		return
	if key.keycode == KEY_ESCAPE:
		_comment_input.accept_event()
		_hide_add_row()
	elif key.keycode in [KEY_ENTER, KEY_KP_ENTER] and (key.ctrl_pressed or key.meta_pressed):
		_comment_input.accept_event()
		_commit_add_comment()


func _commit_add_comment() -> void:
	if _comment_input == null:
		return
	var text := _comment_input.text.strip_edges()
	if text.is_empty():
		show_status("Enter a comment")
		return
	_new_comment_draft = _comment_input.text
	add_comment_requested.emit(text)

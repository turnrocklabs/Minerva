class_name AnnotationCommentThreadView
extends VBoxContainer
## Selected-card view for a local text-comment thread. Mutations are commands,
## so AnnotationWorkbench can apply them to the latest host copy atomically.

signal collapse_requested
signal reveal_requested(target: Control)

var _annotation_id := ""
var _emit_command: Callable
var _reply_edit: TextEdit
var _messages: VBoxContainer
var _annotation: Dictionary = {}
var _active_edit_id := ""
var _active_edit: TextEdit
var _composer_open := false


func _ready() -> void:
	_messages = get_node("Messages") as VBoxContainer
	_reply_edit = get_node("ReplyComposer") as TextEdit
	if not _reply_edit.gui_input.is_connected(_on_reply_gui_input):
		_reply_edit.gui_input.connect(_on_reply_gui_input)
	var cancel := get_node("ReplyActions/CancelReply") as Button
	var post := get_node("ReplyActions/PostReply") as Button
	var reply := get_node("ThreadHeader/Reply") as Button
	var collapse := get_node("ThreadHeader/Collapse") as Button
	if not cancel.pressed.is_connected(_cancel_reply):
		cancel.pressed.connect(_cancel_reply)
	if not post.pressed.is_connected(_submit_reply):
		post.pressed.connect(_submit_reply)
	if not reply.pressed.is_connected(_open_reply):
		reply.pressed.connect(_open_reply)
	if not collapse.pressed.is_connected(_request_collapse):
		collapse.pressed.connect(_request_collapse)
	_set_composer_visible(_composer_open)
	_populate_messages()


func setup(annotation: Dictionary, emit_command: Callable) -> void:
	_annotation = annotation.duplicate(true)
	_annotation_id = str(annotation.get("id", ""))
	_emit_command = emit_command
	_messages = get_node_or_null("Messages") as VBoxContainer
	_reply_edit = get_node_or_null("ReplyComposer") as TextEdit
	_update_selection_context()
	_populate_messages()


func update_annotation(annotation: Dictionary) -> void:
	# Message updates leave the composer node untouched, preserving its native
	# caret, selection, scroll, and undo stack during document/MCP refreshes.
	var state := capture_ui_state()
	_annotation = annotation.duplicate(true)
	_update_selection_context()
	_populate_messages()
	if not str(state.get("edit_id", "")).is_empty():
		_begin_edit_reply_id(str(state.get("edit_id", "")), state)


func _update_selection_context() -> void:
	var status := get_node_or_null("SelectionStatus") as Label
	var quote := get_node_or_null("SelectedQuote") as Label
	if status == null or quote == null:
		return
	var tracking := str(_annotation.get("tracking_state", ""))
	var stale := bool(_annotation.get("stale", false)) or str(_annotation.get("lifecycle", "")) == "stale"
	status.text = "Text removed · Needs reattachment" if tracking == "text_removed" \
		else ("Needs reattachment" if stale or not tracking.is_empty() else "Selected text")
	var snapshot: Dictionary = _annotation.get("anchor", {}).get("snapshot", {})
	var selected := str(snapshot.get("text", "")).strip_edges()
	quote.text = "“%s”" % selected if not selected.is_empty() else "No selected text"
	quote.tooltip_text = selected


func _populate_messages() -> void:
	if _messages == null:
		return
	_active_edit_id = ""
	_active_edit = null
	for child in _messages.get_children():
		_messages.remove_child(child)
		child.queue_free()
	var annotation := _annotation
	var payload_v: Variant = annotation.get("kind_payload", {})
	var payload: Dictionary = payload_v as Dictionary if payload_v is Dictionary else {}
	_add_message(str(payload.get("text", "")), annotation.get("author", {}),
		int(annotation.get("created_at", 0)), true, "")
	var thread_script = load("res://Scripts/Services/Annotations/AnnotationCommentThread.gd")
	for reply in thread_script.replies(annotation):
		_add_message(str((reply as Dictionary).get("text", "")),
			(reply as Dictionary).get("author", {}), int((reply as Dictionary).get("created_at", 0)),
			false, str((reply as Dictionary).get("id", "")))


func draft_text() -> String:
	return _reply_edit.text if _reply_edit != null else ""


func restore_draft(text: String, focus_composer: bool = false) -> void:
	if _reply_edit == null:
		return
	_reply_edit.text = text
	if not text.is_empty() or focus_composer:
		_set_composer_visible(true)
	if focus_composer and is_inside_tree():
		_reply_edit.grab_focus()


func capture_ui_state() -> Dictionary:
	var state := {"draft": draft_text(), "composer_focus": composer_has_focus(),
		"composer_open": _composer_open}
	if _reply_edit != null:
		state["composer_line"] = _reply_edit.get_caret_line()
		state["composer_column"] = _reply_edit.get_caret_column()
		state["composer_scroll"] = _reply_edit.scroll_vertical
	if _active_edit != null and is_instance_valid(_active_edit):
		state["edit_id"] = _active_edit_id
		state["edit_text"] = _active_edit.text
		state["edit_line"] = _active_edit.get_caret_line()
		state["edit_column"] = _active_edit.get_caret_column()
		state["edit_scroll"] = _active_edit.scroll_vertical
		state["edit_focus"] = _active_edit.has_focus()
	return state


func restore_ui_state(state: Dictionary) -> void:
	var draft := str(state.get("draft", ""))
	_set_composer_visible(bool(state.get("composer_open", false)) or not draft.is_empty())
	restore_draft(draft, false)
	if _reply_edit != null:
		_reply_edit.set_caret_line(int(state.get("composer_line", 0)))
		_reply_edit.set_caret_column(int(state.get("composer_column", 0)))
		_reply_edit.scroll_vertical = float(state.get("composer_scroll", 0.0))
	if not str(state.get("edit_id", "")).is_empty():
		_begin_edit_reply_id(str(state.get("edit_id", "")), state)
	elif bool(state.get("composer_focus", false)) and _reply_edit != null and is_inside_tree():
		_reply_edit.grab_focus()


func composer_has_focus() -> bool:
	return _reply_edit != null and _reply_edit.has_focus()


func clear_draft() -> void:
	if _reply_edit != null:
		_reply_edit.text = ""


func _open_reply() -> void:
	_set_composer_visible(true)
	if _reply_edit != null:
		_reply_edit.grab_focus()
		reveal_requested.emit(_reply_edit)


func _set_composer_visible(value: bool) -> void:
	_composer_open = value
	var reply_button := get_node_or_null("ThreadHeader/Reply") as Button
	if reply_button != null:
		reply_button.visible = not value
	for path in ["ReplyLabel", "ReplyComposer", "ReplyActions"]:
		var control := get_node_or_null(path) as Control
		if control != null:
			control.visible = value


func _request_collapse() -> void:
	collapse_requested.emit()


func _add_message(text: String, author: Variant, created_at: int, root_message: bool,
		reply_id: String) -> void:
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var body_column := VBoxContainer.new()
	card.add_child(body_column)
	var body := Label.new()
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(180, 0)
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.text = text
	body_column.add_child(body)
	var meta := Label.new()
	var actor := _author_label(author)
	var timestamp := Time.get_datetime_string_from_unix_time(created_at, true) if created_at > 0 else ""
	meta.text = "%s%s" % [actor,
		" · %s" % timestamp if not timestamp.is_empty() else ""]
	meta.tooltip_text = "Original comment" if root_message else "Reply"
	meta.modulate = Color(1, 1, 1, 0.58)
	body_column.add_child(meta)
	if AnnotationAuthor.kind_of(author) == "human":
		var actions := HBoxContainer.new()
		actions.alignment = BoxContainer.ALIGNMENT_END
		var message_id := "__root__" if root_message else reply_id
		actions.set_meta("reply_id", message_id)
		actions.add_child(_icon_button("res://assets/icons/edit_icons/edit.svg",
			"Edit comment" if root_message else "Edit reply",
			_begin_edit_reply.bind(body_column, body, actions, message_id, {})))
		if not root_message:
			actions.add_child(_icon_button("res://assets/icons/delete_selection.svg", "Delete reply", _confirm_delete_reply.bind(reply_id)))
		body_column.add_child(actions)
	_messages.add_child(card)


func _author_label(author: Variant) -> String:
	if author is Dictionary:
		var details := author as Dictionary
		for key in ["name", "id", "model"]:
			var value := str(details.get(key, "")).strip_edges()
			if not value.is_empty():
				return value
	var kind := AnnotationAuthor.kind_of(author)
	return kind if not kind.is_empty() else "unknown"


func _begin_edit_reply(column: VBoxContainer, body: Label, actions: HBoxContainer,
		reply_id: String, state: Dictionary) -> void:
	if _active_edit != null and is_instance_valid(_active_edit):
		return
	var editor := TextEdit.new()
	editor.text = str(state.get("edit_text", body.text))
	editor.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	editor.custom_minimum_size = Vector2(180, 72)
	var body_index := body.get_index()
	body.hide()
	actions.hide()
	column.add_child(editor)
	column.move_child(editor, body_index)
	var save := _icon_button("res://assets/icons/checkmark16.svg",
		"Save comment" if reply_id == "__root__" else "Save reply", func() -> void:
		var clean := editor.text.strip_edges()
		if not clean.is_empty() and _emit_command.is_valid():
			var command := "edit_root" if reply_id == "__root__" else "edit_reply"
			var persisted := bool(_emit_command.call({"_thread_command": command, "reply_id": reply_id, "text": clean}))
			if persisted:
				_finish_edit_after_save(reply_id)
	)
	column.add_child(save)
	var cancel := _icon_button("res://assets/icons/close.svg", "Cancel editing", Callable())
	cancel.pressed.connect(_cancel_edit_reply.bind(editor, save, cancel, body, actions))
	column.add_child(cancel)
	_active_edit_id = reply_id
	_active_edit = editor
	# A nonempty state means a passive refresh is restoring an existing editor;
	# only a person's fresh Edit action should move the enclosing dock.
	if state.is_empty():
		reveal_requested.emit(editor)
	editor.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventKey and event.pressed and not event.is_echo() and event.keycode == KEY_ESCAPE:
			cancel.pressed.emit()
	)
	editor.set_caret_line(int(state.get("edit_line", editor.get_line_count() - 1)))
	editor.set_caret_column(int(state.get("edit_column", editor.get_line(editor.get_caret_line()).length())))
	editor.scroll_vertical = float(state.get("edit_scroll", 0.0))
	if bool(state.get("edit_focus", true)):
		editor.grab_focus()


func _cancel_edit_reply(editor: TextEdit, save: Button, cancel: Button, body: Label,
		actions: HBoxContainer) -> void:
	_active_edit_id = ""
	_active_edit = null
	# Detach the transient controls synchronously so another action in this frame
	# cannot find and invoke the just-closed editor's queued buttons.
	_detach_for_free(editor)
	_detach_for_free(save)
	_detach_for_free(cancel)
	body.show()
	actions.show()


func _detach_for_free(control: Control) -> void:
	control.hide()
	if control.get_parent() != null:
		control.get_parent().remove_child(control)
	control.queue_free()


func _finish_edit_after_save(reply_id: String) -> void:
	# A synchronous host update rebuilds this card before the command returns.
	# Close the rebuilt editor only after persistence confirms success.
	if _active_edit_id != reply_id or _active_edit == null:
		return
	var editor := _active_edit
	var column := editor.get_parent() as VBoxContainer
	var body: Label = null
	var actions: HBoxContainer = null
	var save: Button = null
	var cancel: Button = null
	for child in column.get_children():
		if child is Label and body == null:
			body = child as Label
		elif child is HBoxContainer:
			actions = child as HBoxContainer
		elif child is Button and (child as Button).tooltip_text in ["Save reply", "Save comment"]:
			save = child as Button
		elif child is Button and (child as Button).tooltip_text == "Cancel editing":
			cancel = child as Button
	if body != null and actions != null and save != null and cancel != null:
		_cancel_edit_reply(editor, save, cancel, body, actions)


func _begin_edit_reply_id(reply_id: String, state: Dictionary) -> void:
	for card in _messages.get_children():
		var column := card.get_child(0) as VBoxContainer
		var body := column.get_child(0) as Label
		var actions := column.get_child(column.get_child_count() - 1) as HBoxContainer
		if actions != null and actions.get_meta("reply_id", "") == reply_id:
			_begin_edit_reply(column, body, actions, reply_id, state)
			return


func _confirm_delete_reply(reply_id: String) -> void:
	var dialog := ConfirmationDialog.new()
	dialog.title = "Delete reply?"
	dialog.dialog_text = "This reply will be removed from the thread."
	dialog.confirmed.connect(func() -> void:
		if _emit_command.is_valid():
			_emit_command.call({"_thread_command": "delete_reply", "reply_id": reply_id})
	)
	dialog.canceled.connect(dialog.queue_free)
	dialog.confirmed.connect(dialog.queue_free)
	add_child(dialog)
	dialog.popup_centered()


func _icon_button(icon_path: String, tooltip: String, action: Callable) -> Button:
	var button := Button.new()
	button.icon = load(icon_path) as Texture2D
	button.tooltip_text = tooltip
	button.focus_mode = Control.FOCUS_ALL
	button.custom_minimum_size = Vector2(30, 26)
	if action.is_valid():
		button.pressed.connect(action)
	return button


func _submit_reply() -> void:
	if _reply_edit == null:
		return
	var body := _reply_edit.text.strip_edges()
	if body.is_empty() or not _emit_command.is_valid():
		return
	var persisted := bool(_emit_command.call({"_thread_command": "add_reply", "text": body}))
	if persisted:
		clear_draft()
		_set_composer_visible(false)
		if _messages != null and _messages.get_child_count() > 0:
			reveal_requested.emit(_messages.get_child(_messages.get_child_count() - 1) as Control)


func _cancel_reply() -> void:
	if _reply_edit != null:
		_reply_edit.text = ""
	_set_composer_visible(false)


func _on_reply_gui_input(event: InputEvent) -> void:
	if not event is InputEventKey:
		return
	var key := event as InputEventKey
	if not key.pressed or key.is_echo():
		return
	if key.keycode == KEY_ESCAPE:
		_reply_edit.accept_event()
		_cancel_reply()
	elif key.keycode in [KEY_ENTER, KEY_KP_ENTER] and (key.ctrl_pressed or key.meta_pressed):
		_reply_edit.accept_event()
		_submit_reply()

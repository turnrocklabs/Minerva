extends SceneTree
## Tests for AnnotationWorkbench ↔ host selection_changed wiring (T4).
## State-and-signal only — no draw-frame tests.

const AnnotationWorkbenchScript = preload("res://Scripts/UI/Controls/AnnotationDockPane/AnnotationWorkbench.gd")
const AnnotationHostScript = preload("res://Scripts/Services/Annotations/AnnotationHost.gd")
const AnnotationTextCommentScript = preload("res://Scripts/Services/Annotations/kinds/AnnotationTextComment.gd")

var _pass_count := 0
var _fail_count := 0


func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	print("[tags: unit,ux,selection]")
	print("=== test_workbench_selection_sync ===\n")
	test_set_host_connects_selection_changed()
	test_set_host_seeds_selected_id_from_existing_selection()
	test_set_host_disconnects_from_old_host()
	test_set_host_null_is_safe()
	test_select_annotation_calls_host_and_emits_signal()
	test_remove_annotation_clears_workbench_selected_id()
	test_reply_draft_survives_refresh_and_merges_external_reply()
	test_thread_drafts_follow_displayed_thread_and_host()
	test_comment_threads_expand_collapse_and_dismiss_reply_composer()
	test_multiline_comment_draft_waits_for_confirmed_write()
	test_exit_texture_cleanup_accepts_link_and_icon_buttons()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


# ── Test 1: set_host connects selection_changed ───────────────────────────────

func test_set_host_connects_selection_changed() -> void:
	var workbench = AnnotationWorkbenchScript.new()
	root.add_child(workbench)

	var host := _TestHost.new()
	workbench.set_host(host)

	host.set_selected_annotation_id("ann_abc")
	check("emitting selection_changed updates _selected_id", workbench._selected_id == "ann_abc")

	host.set_selected_annotation_id("")
	check("emitting selection_changed with empty clears _selected_id", workbench._selected_id == "")

	root.remove_child(workbench)
	workbench.queue_free()


# ── Test 2: set_host seeds _selected_id from pre-existing selection ───────────

func test_set_host_seeds_selected_id_from_existing_selection() -> void:
	var workbench = AnnotationWorkbenchScript.new()
	root.add_child(workbench)

	var host := _TestHost.new()
	host._selected_id = "ann_pre"

	workbench.set_host(host)
	check("set_host seeds _selected_id from existing host selection", workbench._selected_id == "ann_pre")

	root.remove_child(workbench)
	workbench.queue_free()


# ── Test 3: set_host disconnects from old host ────────────────────────────────

func test_set_host_disconnects_from_old_host() -> void:
	var workbench = AnnotationWorkbenchScript.new()
	root.add_child(workbench)

	var old_host := _TestHost.new()
	workbench.set_host(old_host)
	old_host.set_selected_annotation_id("ann_old")
	check("old host selection sets _selected_id before rebind", workbench._selected_id == "ann_old")

	var new_host := _TestHost.new()
	workbench.set_host(new_host)
	check("after rebind _selected_id is cleared (new host has no selection)", workbench._selected_id == "")

	# Emitting on old host must NOT update workbench anymore.
	old_host.set_selected_annotation_id("ann_should_not_propagate")
	check("old host signal no longer updates workbench after rebind", workbench._selected_id == "")

	root.remove_child(workbench)
	workbench.queue_free()


# ── Test 4: set_host(null) is safe ────────────────────────────────────────────
# Choice: _selected_id is cleared to "" on null bind (safe default).

func test_set_host_null_is_safe() -> void:
	var workbench = AnnotationWorkbenchScript.new()
	root.add_child(workbench)

	var host := _TestHost.new()
	workbench.set_host(host)
	host.set_selected_annotation_id("ann_before_null")

	# Bind to null — must not crash, _selected_id is cleared.
	workbench.set_host(null)
	check("set_host(null) does not crash", true)
	check("set_host(null) clears _selected_id", workbench._selected_id == "")

	root.remove_child(workbench)
	workbench.queue_free()


# ── Test 5: _select_annotation calls host + emits annotation_selected ─────────

func test_select_annotation_calls_host_and_emits_signal() -> void:
	var workbench = AnnotationWorkbenchScript.new()
	root.add_child(workbench)

	var host := _TestHost.new()
	workbench.set_host(host)

	var captured := {"id": ""}
	workbench.annotation_selected.connect(func(id: String) -> void: captured["id"] = id)

	workbench._select_annotation("ann_xyz")
	check("_select_annotation calls host.set_selected_annotation_id", host.get_selected_annotation_id() == "ann_xyz")
	check("_select_annotation emits annotation_selected signal", str(captured.get("id", "")) == "ann_xyz")

	root.remove_child(workbench)
	workbench.queue_free()


# ── Test 6: remove_annotation clearing selection propagates to workbench ───────

func test_remove_annotation_clears_workbench_selected_id() -> void:
	var workbench = AnnotationWorkbenchScript.new()
	root.add_child(workbench)

	var host := _TestHost.new()
	host._annotations = [
		{"id": "ann_del", "kind": "callout", "lifecycle": "open", "summary": "to remove"},
	]
	workbench.set_host(host)
	host.set_selected_annotation_id("ann_del")
	check("selection set before remove", workbench._selected_id == "ann_del")

	host.remove_annotation("ann_del")
	check("after host removes selected annotation, workbench _selected_id is cleared", workbench._selected_id == "")

	root.remove_child(workbench)
	workbench.queue_free()


func test_reply_draft_survives_refresh_and_merges_external_reply() -> void:
	var workbench = AnnotationWorkbenchScript.new()
	root.add_child(workbench)
	var host := _TestHost.new()
	host._annotations = [{
		"id": "ann_thread", "kind": "text_comment", "schema_version": 2,
		"kind_payload": {"text": "Root"}, "lifecycle": "open",
		"author": {"kind": "human"}, "created_at": 1,
	}]
	workbench.set_host(host)
	host.set_selected_annotation_id("ann_thread")
	var view: Control = workbench._current_body_view
	view.restore_draft("local draft", true)
	host.annotations_changed.emit()
	view = workbench._current_body_view
	check("host refresh rebuilds current content while preserving reply draft and focus",
		view.draft_text() == "local draft" and view.composer_has_focus())

	var external := host.get_by_id("ann_thread")
	var payload: Dictionary = external.get("kind_payload", {}).duplicate(true)
	payload["replies"] = [{"id": "reply_external", "parent_id": "", "text": "External",
		"author": {"kind": "human", "id": "reviewer"}, "created_at": 2, "updated_at": 2}]
	external["kind_payload"] = payload
	host.update_annotation("ann_thread", external)
	view = workbench._current_body_view
	check("external reply does not erase the active local draft", view.draft_text() == "local draft")
	check("thread card shows available author identity instead of only its kind",
		_has_label_prefix(view, "reviewer"))
	_button_with_tooltip(view, "Edit comment").pressed.emit()
	view._active_edit.text = "Edited root"
	_button_with_tooltip(view, "Save comment").pressed.emit()
	view = workbench._current_body_view
	check("root comment edit preserves the existing reply thread",
		host.get_by_id("ann_thread").get("kind_payload", {}).get("text") == "Edited root"
		and (host.get_by_id("ann_thread").get("kind_payload", {}).get("replies", []) as Array).size() == 1)
	var post := _button_with_tooltip(view, "Post reply (Ctrl+Enter)")
	post.pressed.emit()
	var final_payload: Dictionary = host.get_by_id("ann_thread").get("kind_payload", {})
	check("Post button applies to latest host copy and preserves concurrent reply",
		(final_payload.get("replies", []) as Array).size() == 2)
	view = workbench._current_body_view
	var edit := _button_with_tooltip(view, "Edit reply")
	edit.pressed.emit()
	view._active_edit.text = "Unsaved edit"
	view._active_edit.set_caret_line(0)
	view._active_edit.set_caret_column(5)
	host.annotations_changed.emit()
	view = workbench._current_body_view
	check("active reply edit text, caret, and focus survive a thread refresh",
		view._active_edit != null and view._active_edit.text == "Unsaved edit"
		and view._active_edit.get_caret_column() == 5 and view._active_edit.has_focus())
	host.fail_updates = true
	_button_with_tooltip(view, "Save reply").pressed.emit()
	check("failed reply edit stays open with its draft", view._active_edit != null
		and view._active_edit.text == "Unsaved edit")
	host.fail_updates = false
	_button_with_tooltip(view, "Save reply").pressed.emit()
	view = workbench._current_body_view
	var restored_edit := _button_with_tooltip(view, "Edit reply")
	check("successful reply edit exits editing and restores row actions",
		view._active_edit == null and restored_edit != null and restored_edit.is_visible_in_tree())
	restored_edit.pressed.emit()
	view._active_edit.text = "Canceled second edit"
	var cancel_edit := _button_with_tooltip(view, "Cancel editing")
	cancel_edit.pressed.emit()
	check("reply edit Cancel keeps persisted text", host.get_by_id("ann_thread").get("kind_payload", {}).get("replies", [])[0].get("text") == "Unsaved edit")
	_button_with_tooltip(view, "Edit reply").pressed.emit()
	view._active_edit.text = "Edited externally-added reply"
	_button_with_tooltip(view, "Save reply").pressed.emit()
	check("reply edit button persists the addressed reply", host.get_by_id("ann_thread").get("kind_payload", {}).get("replies", [])[0].get("text") == "Edited externally-added reply")
	view = workbench._current_body_view
	_button_with_tooltip(view, "Delete reply").pressed.emit()
	var dialog := _first_confirmation_dialog(view)
	dialog.confirmed.emit()
	check("reply delete confirmation removes only the addressed reply",
		(host.get_by_id("ann_thread").get("kind_payload", {}).get("replies", []) as Array).size() == 1)

	root.remove_child(workbench)
	workbench.queue_free()


func test_thread_drafts_follow_displayed_thread_and_host() -> void:
	var workbench = AnnotationWorkbenchScript.new()
	root.add_child(workbench)
	var host_a := _TestHost.new()
	host_a._annotations = [_thread("ann_a", "A"), _thread("ann_b", "B")]
	host_a._annotations[0]["kind_payload"]["replies"] = [{"id": "reply_a", "parent_id": "ann_a",
		"text": "Reply A", "author": {"kind": "human"}, "created_at": 1, "updated_at": 1}]
	workbench.set_host(host_a)
	host_a.set_selected_annotation_id("ann_a")
	workbench._current_body_view.restore_draft("draft A")
	_button_with_tooltip(workbench._current_body_view, "Edit reply").pressed.emit()
	workbench._current_body_view._active_edit.text = "editing A"
	workbench._current_body_view._active_edit.set_caret_column(4)
	host_a.set_selected_annotation_id("ann_b")
	workbench._current_body_view.restore_draft("draft B")
	host_a.set_selected_annotation_id("ann_a")
	check("selection changes keep each draft with its displayed thread",
		workbench._current_body_view.draft_text() == "draft A")
	check("selection changes restore the active reply edit and caret",
		workbench._current_body_view._active_edit != null
		and workbench._current_body_view._active_edit.text == "editing A"
		and workbench._current_body_view._active_edit.get_caret_column() == 4)
	var stale_view: Control = workbench._current_body_view
	workbench.begin_add_comment_flow()
	workbench._comment_input.text = "old host draft"
	var host_b := _TestHost.new()
	host_b._annotations = [_thread("ann_a", "Other host")]
	host_b._selected_id = "ann_a"
	workbench.set_host(host_b)
	check("same annotation id on a new host does not inherit the old host draft",
		workbench._current_body_view.draft_text().is_empty())
	check("changing host clears and closes the old new-comment composer",
		workbench._comment_input.text.is_empty() and not workbench._add_row.visible)
	check("a stale old-host thread callback cannot mutate the replacement host",
		not bool(stale_view._emit_command.call({"_thread_command": "add_reply", "text": "stale"}))
		and (host_b.get_by_id("ann_a").get("kind_payload", {}).get("replies", []) as Array).is_empty())
	check("Open keeps a detached text thread visible for reattachment",
		workbench._passes_filter({"kind": "text_comment", "lifecycle": "open", "stale": true}))
	check("detached thread rows explain that their text was removed",
		workbench._row_text({"kind": "text_comment", "_row_words": "Other host",
			"_anchor_issue": "Text removed"}).contains("Text removed"))
	var detached: Dictionary = host_b.get_by_id("ann_a")
	detached["tracking_state"] = "text_removed"
	detached["stale"] = true
	detached["anchor"] = {"snapshot": {"text": "A readable selected quotation that remains fully visible"}}
	host_b.update_annotation("ann_a", detached)
	host_b.set_selected_annotation_id("ann_a")
	var detail: Control = workbench._current_body_view
	check("selected thread shows a wrapped full quote and reattachment status",
		(detail.get_node("SelectedQuote") as Label).text.contains("readable selected quotation")
		and (detail.get_node("SelectionStatus") as Label).text.contains("Text removed"))
	check("text host uses Comments heading and counts detached open threads",
		workbench._header.text == "Comments" and workbench._count_label.text.begins_with("1 open"))
	var selected_panel: PanelContainer = null
	for child in workbench._entries_list.get_children():
		if str(child.get_meta("annotation_id", "")) == "ann_a":
			selected_panel = child as PanelContainer
			break
	check("selected row highlight is applied to a drawable panel",
		selected_panel != null and selected_panel.has_theme_stylebox_override("panel"))
	root.remove_child(workbench)
	workbench.queue_free()


func test_comment_threads_expand_collapse_and_dismiss_reply_composer() -> void:
	var workbench = AnnotationWorkbenchScript.new()
	root.add_child(workbench)
	var host := _TestHost.new()
	host._annotations = [_thread("ann_a", "A"), _thread("ann_b", "B")]
	workbench.set_host(host)
	host.set_selected_annotation_id("ann_a")
	var view: Control = workbench._current_body_view
	_button_with_tooltip(view, "Reply").pressed.emit()
	view._reply_edit.text = "draft A"
	_button_with_tooltip(view, "Collapse comment").pressed.emit()
	check("collapse clears the active comment and hides its expanded thread",
		host.get_selected_annotation_id().is_empty() and not workbench._body_view_container.visible)
	host.annotations_changed.emit()
	check("a data refresh does not reopen a deliberately collapsed thread",
		workbench._expanded_comment_id.is_empty() and not workbench._body_view_container.visible)

	workbench._select_annotation("ann_b")
	check("selecting another comment expands only that thread",
		workbench._displayed_annotation_id == "ann_b" and workbench._expanded_comment_id == "ann_b"
		and workbench._body_view_container.get_parent() == workbench._entries_list)
	host.annotations_changed.emit()
	var active_row_index := -1
	for index in range(workbench._entries_list.get_child_count()):
		if str(workbench._entries_list.get_child(index).get_meta("annotation_id", "")) == "ann_b":
			active_row_index = index
	check("refresh replaces old rows and keeps the expanded body directly after its live row",
		active_row_index >= 0 and workbench._body_view_container.get_index() == active_row_index + 1)
	workbench._select_annotation("ann_a")
	view = workbench._current_body_view
	check("returning to a collapsed comment restores its unsent reply draft",
		view.draft_text() == "draft A" and view._composer_open)
	var resolved: Dictionary = host.get_by_id("ann_a")
	resolved["lifecycle"] = "resolved"
	host.update_annotation("ann_a", resolved)
	check("filtering out the active row parks its thread without losing the draft",
		not workbench._body_view_container.visible
		and workbench._body_view_container.get_parent() == workbench._scroll_body
		and workbench._current_body_view.draft_text() == "draft A")
	workbench._filter = "all"
	workbench.refresh()
	check("showing the active row again restores its inline thread and draft",
		workbench._body_view_container.visible
		and workbench._body_view_container.get_parent() == workbench._entries_list
		and workbench._current_body_view.draft_text() == "draft A")
	resolved["lifecycle"] = "open"
	host.update_annotation("ann_a", resolved)
	workbench._filter = "open"
	workbench.refresh()
	_button_with_tooltip(view, "Cancel reply").pressed.emit()
	check("Cancel discards and dismisses the reply composer",
		view.draft_text().is_empty() and not view._composer_open)

	_button_with_tooltip(view, "Reply").pressed.emit()
	view._reply_edit.text = "Posted reply"
	_button_with_tooltip(view, "Post reply (Ctrl+Enter)").pressed.emit()
	view = workbench._current_body_view
	check("successful Post dismisses the composer",
		not view._composer_open and (host.get_by_id("ann_a").get("kind_payload", {}).get("replies", []) as Array).size() == 1)
	_button_with_tooltip(view, "Reply").pressed.emit()
	view._reply_edit.text = "discard with escape"
	var escape := InputEventKey.new()
	escape.pressed = true
	escape.keycode = KEY_ESCAPE
	view._on_reply_gui_input(escape)
	check("Escape discards and dismisses the reply composer",
		view.draft_text().is_empty() and not view._composer_open)
	workbench._select_annotation("ann_a")
	check("clicking the active comment deactivates it",
		host.get_selected_annotation_id().is_empty() and workbench._expanded_comment_id.is_empty())
	root.remove_child(workbench)
	workbench.queue_free()


func test_multiline_comment_draft_waits_for_confirmed_write() -> void:
	var workbench = AnnotationWorkbenchScript.new()
	root.add_child(workbench)
	workbench.set_can_add_comment(true)
	workbench.begin_add_comment_flow()
	workbench._comment_input.text = "First line\nSecond line"
	var submitted := {"text": ""}
	workbench.add_comment_requested.connect(func(text: String) -> void: submitted["text"] = text)
	workbench._commit_add_comment()
	check("multiline creation submits the complete draft", submitted["text"] == "First line\nSecond line")
	check("draft remains visible until the editor confirms persistence",
		workbench._add_row.visible and workbench._comment_input.text == "First line\nSecond line")
	workbench.complete_add_comment(false)
	check("failed persistence keeps the creation draft", workbench._comment_input.text == "First line\nSecond line")
	workbench.complete_add_comment(true)
	check("confirmed persistence clears and closes the creation composer",
		not workbench._add_row.visible and workbench._comment_input.text.is_empty())
	root.remove_child(workbench)
	workbench.queue_free()


func test_exit_texture_cleanup_accepts_link_and_icon_buttons() -> void:
	var singleton := root.get_node_or_null("SingletonObject")
	check("SingletonObject is available for exit texture cleanup coverage", singleton != null)
	if singleton == null:
		return
	var holder := VBoxContainer.new()
	var link := LinkButton.new()
	link.text = "#1"
	holder.add_child(link)
	var icon_button := Button.new()
	icon_button.icon = load("res://assets/icons/checkmark16.svg") as Texture2D
	holder.add_child(icon_button)
	singleton.call("_release_textures_recursive", holder)
	check("exit cleanup traverses LinkButton and releases Button icons safely",
		is_instance_valid(link) and icon_button.icon == null)
	holder.free()


func _thread(annotation_id: String, text: String) -> Dictionary:
	return {"id": annotation_id, "kind": "text_comment", "schema_version": 2,
		"kind_payload": {"text": text}, "lifecycle": "open", "author": {"kind": "human"}}


func _button_with_tooltip(node: Node, tooltip: String) -> Button:
	if node is Button and (node as Button).tooltip_text == tooltip:
		return node as Button
	for child in node.get_children():
		var found := _button_with_tooltip(child, tooltip)
		if found != null:
			return found
	return null


func _first_confirmation_dialog(node: Node) -> ConfirmationDialog:
	if node is ConfirmationDialog:
		return node as ConfirmationDialog
	for child in node.get_children():
		var found := _first_confirmation_dialog(child)
		if found != null:
			return found
	return null


func _has_label_prefix(node: Node, prefix: String) -> bool:
	if node is Label and (node as Label).text.begins_with(prefix):
		return true
	for child in node.get_children():
		if _has_label_prefix(child, prefix):
			return true
	return false


# ── Minimal test host ─────────────────────────────────────────────────────────

class _TestHost extends AnnotationHost:
	signal annotations_changed()

	var _annotations: Array = []
	var _selected_id: String = ""
	var _registry := AnnotationRegistry.new()
	var fail_updates := false

	func _init() -> void:
		super()
		_registry.register_annotation_kind(AnnotationTextCommentScript.new())

	func get_registry() -> AnnotationRegistry:
		return _registry

	func get_annotation_capabilities() -> Dictionary:
		return {"filters": ["open", "resolved", "all"], "body_views": true,
			"lifecycle": {"resolve": true, "reopen": true, "delete": true, "repair": true}}

	func get_annotations() -> Array:
		return _annotations.duplicate()

	func get_by_id(annotation_id: String) -> Dictionary:
		for value in _annotations:
			if value is Dictionary and str((value as Dictionary).get("id", "")) == annotation_id:
				return (value as Dictionary).duplicate(true)
		return {}

	func update_annotation(annotation_id: String, annotation: Dictionary) -> bool:
		if fail_updates:
			return false
		for i in range(_annotations.size()):
			if str((_annotations[i] as Dictionary).get("id", "")) == annotation_id:
				_annotations[i] = annotation.duplicate(true)
				annotations_changed.emit()
				return true
		return false

	func set_selected_annotation_id(annotation_id: String) -> void:
		if _selected_id == annotation_id:
			return
		_selected_id = annotation_id
		selection_changed.emit(_selected_id)

	func get_selected_annotation_id() -> String:
		return _selected_id

	func remove_annotation(annotation_id: String) -> bool:
		for i in range(_annotations.size()):
			var entry: Dictionary = _annotations[i] as Dictionary
			if str(entry.get("id", "")) == annotation_id:
				_annotations.remove_at(i)
				if _selected_id == annotation_id:
					_selected_id = ""
					selection_changed.emit("")
				annotations_changed.emit()
				return true
		return false

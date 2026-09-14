extends SceneTree
## Real CodeEdit coverage for edit-following comment anchors and its native
## undo/redo grouping. This intentionally tests the public host boundary.

const _HostScript = preload("res://Scripts/Services/Annotations/TextEditorAnnotationHost.gd")
const _CodeEditScript = preload("res://Scripts/UI/Controls/EditorCodeEdit.gd")

var _passed := 0
var _failed := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	await _test_edit_following_and_undo()
	await _test_boundary_and_partial_edits()
	await _test_separated_multicaret_edit()
	await _test_grouped_typing_endpoint()
	await _test_new_and_retargeted_anchor_generations()
	await _test_programmatic_text_assignment_is_undoable()
	await _test_stale_anchor_is_not_silently_healed()
	await _test_large_distant_edits_preserve_middle()
	print("=== Results: %d passed, %d failed ===" % [_passed, _failed])
	quit(1 if _failed > 0 else 0)


func _fixture(text: String) -> Dictionary:
	var code = _CodeEditScript.new()
	root.add_child(code)
	code.text = text
	code.clear_undo_history()
	var host = _HostScript.new()
	host.set_code_edit(code)
	code.text_changed.connect(func() -> void:
		host.track_text_change(code.text, code.get_version())
	)
	return {"code": code, "host": host}


func _test_edit_following_and_undo() -> void:
	var fixture := _fixture("alpha beta gamma")
	var code: CodeEdit = fixture.code
	var host: RefCounted = fixture.host
	var annotation_id: String = host.add_comment_at(6, 10, "Review beta")
	code.set_caret_line(0)
	code.set_caret_column(0)
	code.insert_text_at_caret("X ")
	await process_frame
	check("insert before selection moves the linked range", _range(host, annotation_id) == Vector2i(8, 12))
	code.set_caret_column(10)
	code.insert_text_at_caret("+")
	await process_frame
	check("typing inside selection expands the linked range", _range(host, annotation_id) == Vector2i(8, 13))
	code.undo()
	await process_frame
	check("Undo restores the exact prior anchor checkpoint", _range(host, annotation_id) == Vector2i(8, 12))
	code.redo()
	await process_frame
	check("Redo restores the expanded anchor checkpoint", _range(host, annotation_id) == Vector2i(8, 13))
	code.select(0, 8, 0, 13)
	code.delete_selection()
	await process_frame
	var removed: Dictionary = host.get_by_id(annotation_id)
	check("deleting the complete target creates a Text removed tombstone",
		str(removed.get("anchor", {}).get("snapshot", {}).get("tracking_state", "")) == "text_removed"
		and bool(host.resolve_anchor(removed.get("anchor", {})).get("stale", false)))
	code.undo()
	await process_frame
	var restored: Dictionary = host.get_by_id(annotation_id)
	check("Undo restores a fully deleted target and its association",
		_range(host, annotation_id) == Vector2i(8, 13)
		and not bool(host.resolve_anchor(restored.get("anchor", {})).get("stale", true)))
	code.redo()
	await process_frame
	check("Redo restores the deletion tombstone", str(host.get_by_id(annotation_id)
		.get("anchor", {}).get("snapshot", {}).get("tracking_state", "")) == "text_removed")
	code.undo()
	await process_frame
	code.set_caret_column(code.text.length())
	code.insert_text_at_caret("!")
	await process_frame
	check("a divergent edit after Undo keeps the restored anchor attached",
		not bool(host.resolve_anchor(host.get_by_id(annotation_id).get("anchor", {})).get("stale", true)))
	code.queue_free()


func _test_separated_multicaret_edit() -> void:
	var fixture := _fixture("aa XX bb YY cc")
	var code: CodeEdit = fixture.code
	var host: RefCounted = fixture.host
	var annotation_id: String = host.add_comment_at(6, 8, "middle")
	code.set_caret_column(0)
	code.add_caret(0, code.text.length())
	code.insert_text_at_caret("!")
	await process_frame
	check("separated multicaret edits preserve the untouched middle anchor",
		_range(host, annotation_id) == Vector2i(7, 9)
		and str(host.get_by_id(annotation_id).get("anchor", {}).get("snapshot", {}).get("text", "")) == "bb")
	code.undo()
	await process_frame
	check("one grouped Undo restores both multicaret edits and the anchor",
		code.text == "aa XX bb YY cc" and _range(host, annotation_id) == Vector2i(6, 8))
	code.queue_free()


func _test_boundary_and_partial_edits() -> void:
	var fixture := _fixture("abcdef")
	var code: CodeEdit = fixture.code
	var host: RefCounted = fixture.host
	var annotation_id: String = host.add_comment_at(1, 4, "bcd")
	code.set_caret_column(1)
	code.insert_text_at_caret("X")
	await process_frame
	check("typing at the start boundary stays outside and shifts the range",
		_range(host, annotation_id) == Vector2i(2, 5))
	code.set_caret_column(5)
	code.insert_text_at_caret("Y")
	await process_frame
	check("typing at the end boundary stays outside the range",
		_range(host, annotation_id) == Vector2i(2, 5))
	code.select(0, 2, 0, 3)
	code.delete_selection()
	await process_frame
	check("a partial target deletion keeps the surviving text attached",
		_range(host, annotation_id) == Vector2i(2, 4)
		and str(host.get_by_id(annotation_id).get("anchor", {}).get("snapshot", {}).get("text", "")) == "cd")
	code.undo()
	await process_frame
	check("Undo restores the complete range after partial deletion",
		_range(host, annotation_id) == Vector2i(2, 5))
	code.queue_free()


func _test_grouped_typing_endpoint() -> void:
	var fixture := _fixture("abc")
	var code: CodeEdit = fixture.code
	var host: RefCounted = fixture.host
	var annotation_id: String = host.add_comment_at(1, 2, "b")
	code.set_caret_column(0)
	code.begin_complex_operation()
	code.insert_text_at_caret("X")
	code.insert_text_at_caret("Y")
	code.end_complex_operation()
	await process_frame
	check("grouped typing reaches one tracked endpoint", code.text == "XYabc"
		and _range(host, annotation_id) == Vector2i(3, 4))
	code.undo()
	await process_frame
	check("one Undo restores the grouped typing endpoint and anchor",
		code.text == "abc" and _range(host, annotation_id) == Vector2i(1, 2))
	code.queue_free()


func _test_new_and_retargeted_anchor_generations() -> void:
	var fixture := _fixture("hello world")
	var code: CodeEdit = fixture.code
	var host: RefCounted = fixture.host
	code.set_caret_column(0)
	code.insert_text_at_caret("X")
	await process_frame
	var new_id: String = host.add_comment_at(7, 12, "new after edit")
	host.add_comment_reply(new_id, "Keep this reply", {"kind": "human"})
	host.update_annotation_lifecycle(new_id, "resolved", {"resolved": {"by": {"kind": "human"}}})
	code.undo()
	await process_frame
	check("an annotation created after an edit maps backward instead of disappearing",
		not host.get_by_id(new_id).is_empty() and _range(host, new_id) == Vector2i(6, 11))
	code.redo()
	await process_frame
	host.retarget_annotation(new_id, 1, 6)
	host.update_annotation_lifecycle(new_id, "resolved", {"resolved": {"by": {"kind": "human"}}})
	code.undo()
	await process_frame
	var after_undo: Dictionary = host.get_by_id(new_id)
	check("text Undo maps the explicit retarget instead of restoring its obsolete generation",
		_range(host, new_id) == Vector2i(0, 5))
	check("text Undo preserves thread replies and lifecycle",
		after_undo.get("lifecycle", "") == "resolved"
		and (after_undo.get("kind_payload", {}).get("replies", []) as Array).size() == 1)
	host.remove_annotation(new_id)
	code.redo()
	await process_frame
	check("text Redo never resurrects a deleted annotation", host.get_by_id(new_id).is_empty())
	code.queue_free()


func _test_programmatic_text_assignment_is_undoable() -> void:
	var fixture := _fixture("one two three")
	var code: CodeEdit = fixture.code
	var host: RefCounted = fixture.host
	var annotation_id: String = host.add_comment_at(4, 7, "two")
	code.text = "prefix one two three"
	# Editor's buffer pull emits this signal explicitly after assigning `.text`.
	code.text_changed.emit()
	await process_frame
	check("programmatic buffer text assignment moves its linked range",
		_range(host, annotation_id) == Vector2i(11, 14))
	code.undo()
	await process_frame
	check("native Undo restores anchors after a programmatic buffer assignment",
		code.text == "one two three" and _range(host, annotation_id) == Vector2i(4, 7))
	code.queue_free()


func _test_stale_anchor_is_not_silently_healed() -> void:
	var fixture := _fixture("abc")
	var code: CodeEdit = fixture.code
	var host: RefCounted = fixture.host
	var annotation_id: String = host.add_comment_at(1, 2, "stale")
	var annotation: Dictionary = host.get_by_id(annotation_id)
	annotation["anchor"]["snapshot"]["text"] = "wrong"
	host.update_annotation(annotation_id, annotation)
	code.set_caret_column(0)
	code.insert_text_at_caret("X")
	await process_frame
	var after: Dictionary = host.get_by_id(annotation_id)
	check("an already-stale anchor is not moved or silently healed by later edits",
		_range(host, annotation_id) == Vector2i(1, 2)
		and after.get("anchor", {}).get("snapshot", {}).get("text") == "wrong")
	code.undo()
	await process_frame
	check("Undo does not restore a checkpoint over an excluded stale anchor",
		_range(host, annotation_id) == Vector2i(1, 2)
		and host.get_by_id(annotation_id).get("anchor", {}).get("snapshot", {}).get("text") == "wrong")
	code.queue_free()


func _test_large_distant_edits_preserve_middle() -> void:
	var left := "x".repeat(9000)
	var right := "y".repeat(9000)
	var fixture := _fixture(left + "MIDDLE" + right)
	var code: CodeEdit = fixture.code
	var host: RefCounted = fixture.host
	var annotation_id: String = host.add_comment_at(left.length(), left.length() + 6, "middle")
	code.set_caret_column(0)
	code.add_caret(0, code.text.length())
	code.insert_text_at_caret("!")
	await process_frame
	check("distant edits in a large document preserve an untouched middle anchor",
		_range(host, annotation_id) == Vector2i(left.length() + 1, left.length() + 7)
		and str(host.get_by_id(annotation_id).get("anchor", {}).get("snapshot", {}).get("tracking_state", "")).is_empty())
	code.queue_free()


func _range(host: RefCounted, annotation_id: String) -> Vector2i:
	var anchor: Dictionary = host.get_by_id(annotation_id).get("anchor", {})
	var identifier: Dictionary = anchor.get("id", {})
	return Vector2i(int(identifier.get("start", -1)), int(identifier.get("end", -1)))


func check(label: String, condition: bool) -> void:
	if condition:
		_passed += 1
		print("  PASS: %s" % label)
	else:
		_failed += 1
		printerr("  FAIL: %s" % label)

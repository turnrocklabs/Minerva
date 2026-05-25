extends SceneTree
## Regression test for bug 019e5bc8 — ChatPane zombie coroutine using freed
## model_msg_node after stop+redispatch.
##
## Run: godot --headless --path src --script test/test_chatpane_freed_node_guard.gd
##
## Layer-1 structural + behavioral checks:
##   T1: ChatPane.gd loads without parse errors
##   T2: static helper _are_ui_args_valid exists on ChatPane
##   T3: _are_ui_args_valid returns true when all 3 args are live Objects
##   T4: _are_ui_args_valid returns false after model_msg_node is freed
##   T5: _are_ui_args_valid returns false after user_msg_node is freed
##   T6: _are_ui_args_valid returns false after user_history_item is freed (null)
##   T7: ChatPane source references bug ID 019e5bc8 at the guard sites

const CHATPANE_GD := "res://Scripts/UI/Views/ChatPane.gd"

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== ChatPane freed-node guard regression test (bug 019e5bc8) ===\n")
	await _run_tests()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func _run_tests() -> void:
	await process_frame

	# T1: load ChatPane.gd
	var script: GDScript = load(CHATPANE_GD)
	check("T1: ChatPane.gd loads without parse errors",
		script != null,
		"load() returned null — check parse errors above")
	if script == null:
		for _i in range(6):
			_fail_count += 1
		return

	# T2: static helper presence
	var has_helper := false
	for m: Dictionary in script.get_script_method_list():
		if m.get("name", "") == "_are_ui_args_valid":
			has_helper = true
			break
	check("T2: static helper _are_ui_args_valid exists on ChatPane",
		has_helper,
		"method not found in get_script_method_list()")

	if not has_helper:
		for _i in range(4):
			_fail_count += 1
		return

	# Build live arg fixtures. _are_ui_args_valid only checks is_instance_valid,
	# so any RefCounted stands in for ChatHistoryItem here — avoids class_name
	# lookup issues in SceneTree-extending headless test scripts.
	var item := RefCounted.new()
	var user_node := Control.new()
	var model_node := Control.new()
	# Parent into the root so they live in the scene tree; queue_free runs in
	# the next frame, matching the production path where _on_audio_stop_1_pressed
	# detaches + queue_frees loading MessageMarkdown nodes.
	root.add_child(user_node)
	root.add_child(model_node)
	await process_frame

	# T3: all three live → valid
	var t3_ok: bool = script.call("_are_ui_args_valid", item, user_node, model_node)
	check("T3: all-live args → _are_ui_args_valid returns true",
		t3_ok,
		"expected true with live ChatHistoryItem + 2 Control nodes")

	# T4: free model_node, give Godot a frame to clear it
	model_node.queue_free()
	await process_frame
	await process_frame
	var t4_ok: bool = not script.call("_are_ui_args_valid", item, user_node, model_node)
	check("T4: freed model_msg_node → _are_ui_args_valid returns false",
		t4_ok,
		"expected false after queue_free + 2 process frames")

	# T5: free user_node, leaving model_node already freed
	user_node.queue_free()
	await process_frame
	await process_frame
	var t5_ok: bool = not script.call("_are_ui_args_valid", item, user_node, model_node)
	check("T5: freed user_msg_node → _are_ui_args_valid returns false",
		t5_ok,
		"expected false after user_node also freed")

	# T6: null user_history_item — Resource is RefCounted; simulate by passing null
	var t6_ok: bool = not script.call("_are_ui_args_valid", null, Control.new(), Control.new())
	check("T6: null user_history_item → _are_ui_args_valid returns false",
		t6_ok,
		"expected false when user_history_item is null")

	# T7: source references the bug ID at the guard sites
	var f := FileAccess.open(CHATPANE_GD, FileAccess.READ)
	if f == null:
		_fail_count += 1
		printerr("  FAIL: T7 — could not open ChatPane.gd for source inspection")
		return
	var src := f.get_as_text()
	f.close()
	var bug_id_count := src.count("019e5bc8")
	check("T7: ChatPane.gd references bug ID 019e5bc8 at least 3 times (helper + 3 call sites)",
		bug_id_count >= 3,
		"found %d occurrences; expected ≥3 (1 helper + ≥2 guards)" % bug_id_count)


func check(description: String, condition: bool, detail: String = "") -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		if detail != "":
			printerr("  FAIL: %s — %s" % [description, detail])
		else:
			printerr("  FAIL: %s" % description)

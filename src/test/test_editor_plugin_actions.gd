extends SceneTree
## Editor plugin-actions chrome API smoke test — T7 R7 substrate.
##
## Run: godot --headless --path src --script test/test_editor_plugin_actions.gd
##
## Verifies:
##   A1. Editor.gd script loads without parse errors
##   A2. Editor.gd has method '_apply_plugin_chrome_actions'
##   A3. Editor.gd has method '_apply_plugin_chrome_visibility'
##   A4. Editor.gd has member '_plugin_contributed_actions'
##   A5. Editor.tscn loads (PackedScene non-null)
##   A6. Editor.tscn instantiates (root node non-null)
##   A7. Instantiated editor has VBoxContainer/ButtonsHBoxContainer
##   A8. ButtonsHBoxContainer has at least one default child (Save All button)
##   A9. Editor has method '_exit_tree'
##   A10. _plugin_contributed_actions starts empty

const EDITOR_TSCN := "res://Scenes/Editor.tscn"
const EDITOR_GD   := "res://Scripts/UI/Controls/Editor.gd"

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== Editor Plugin-Actions Chrome API Test (T7 R7) ===\n")
	await _run_tests()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func _run_tests() -> void:
	await process_frame

	# -----------------------------------------------------------------------
	# Group A: Editor.gd script-level checks
	# -----------------------------------------------------------------------
	print("\n-- A: Editor.gd script + Editor.tscn --")

	var editor_script = load(EDITOR_GD)
	check("A1: Editor.gd loads without parse errors (non-null)",
		editor_script != null,
		"load() returned null — check parse errors above")

	if editor_script == null:
		for _i in range(9):
			_fail_count += 1
		print("  SKIP A2-A10: editor script null")
		return

	# Check method presence via Script.get_script_method_list().
	var method_names: Array[String] = []
	for m: Dictionary in editor_script.get_script_method_list():
		method_names.append(m.get("name", ""))

	check("A2: Editor.gd has method '_apply_plugin_chrome_actions'",
		method_names.has("_apply_plugin_chrome_actions"),
		"method not found in script method list")

	check("A3: Editor.gd has method '_apply_plugin_chrome_visibility'",
		method_names.has("_apply_plugin_chrome_visibility"),
		"method not found in script method list")

	# Check member variable via Script.get_script_property_list().
	var prop_names: Array[String] = []
	for p: Dictionary in editor_script.get_script_property_list():
		prop_names.append(p.get("name", ""))

	check("A4: Editor.gd has member '_plugin_contributed_actions'",
		prop_names.has("_plugin_contributed_actions"),
		"property not found in script property list")

	# -----------------------------------------------------------------------
	# Editor.tscn instantiation checks
	# -----------------------------------------------------------------------
	var packed = load(EDITOR_TSCN)
	check("A5: Editor.tscn loads (PackedScene non-null)",
		packed != null,
		"load() returned null")

	if packed == null:
		for _i in range(5):
			_fail_count += 1
		print("  SKIP A6-A10: packed scene null")
		return

	var editor_instance = packed.instantiate()
	check("A6: Editor.tscn instantiates (root node non-null)",
		editor_instance != null,
		"instantiate() returned null")

	if editor_instance == null:
		for _i in range(4):
			_fail_count += 1
		print("  SKIP A7-A10: editor_instance null")
		return

	# ButtonsHBoxContainer existence check (no scene tree needed — node is in scene).
	var buttons_row: Node = editor_instance.get_node_or_null("VBoxContainer/ButtonsHBoxContainer")
	check("A7: VBoxContainer/ButtonsHBoxContainer exists in Editor.tscn",
		buttons_row != null,
		"get_node_or_null returned null")

	if buttons_row != null:
		check("A8: ButtonsHBoxContainer has at least one default child",
			buttons_row.get_child_count() > 0,
			"child count: %d" % buttons_row.get_child_count())
	else:
		_fail_count += 1
		printerr("  FAIL A8: buttons_row null — skip child count check")

	check("A9: editor instance has method '_exit_tree'",
		editor_instance.has_method("_exit_tree"))

	# _plugin_contributed_actions must start empty.
	var contrib = editor_instance.get("_plugin_contributed_actions")
	check("A10: _plugin_contributed_actions starts empty",
		contrib != null and contrib is Array and (contrib as Array).size() == 0,
		"got: %s" % str(contrib))

	if is_instance_valid(editor_instance):
		editor_instance.free()


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

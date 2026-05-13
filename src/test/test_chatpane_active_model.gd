extends SceneTree
## Structural smoke test for ChatPane.get_active_model_descriptor() — T7 R8.
##
## Run: godot --headless --path src --script test/test_chatpane_active_model.gd
##
## Layer-1 checks (no display required):
##   1.  ChatPane.gd loads without parse errors
##   2.  ChatPane script is non-null
##   3.  ChatPane has method 'get_active_model_descriptor'
##   4.  get_active_model_descriptor return type annotation is Dictionary
##   5.  Method is present on a fresh script instance check (has_method)

const CHATPANE_GD := "res://Scripts/UI/Views/ChatPane.gd"

var _pass_count: int = 0
var _fail_count: int = 0


func _init() -> void:
	print("=== ChatPane active-model accessor smoke test (T7 R8) ===\n")
	await _run_tests()
	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func _run_tests() -> void:
	await process_frame

	# T1: load the script
	var script = load(CHATPANE_GD)
	check("T1: ChatPane.gd loads without parse errors (non-null)",
		script != null,
		"load() returned null — check parse errors above")

	if script == null:
		for _i in range(4):
			_fail_count += 1
		print("  SKIP T2-T5: script null")
		return

	# T2: script non-null
	check("T2: ChatPane script is non-null", script != null)

	# T3: method presence via script method list
	var method_found := false
	for m: Dictionary in script.get_script_method_list():
		if m.get("name", "") == "get_active_model_descriptor":
			method_found = true
			break
	check("T3: get_active_model_descriptor is declared in ChatPane",
		method_found,
		"method not found in get_script_method_list()")

	# T4: return type is Dictionary (type hint 27 = TYPE_DICTIONARY in GDScript)
	var return_type_ok := false
	for m: Dictionary in script.get_script_method_list():
		if m.get("name", "") == "get_active_model_descriptor":
			# return_type 27 = TYPE_DICTIONARY
			return_type_ok = (m.get("return", {}).get("type", -1) == TYPE_DICTIONARY)
			break
	check("T4: get_active_model_descriptor return type is Dictionary",
		return_type_ok,
		"return type mismatch — check annotation")

	# T5: has_method guard (won't instantiate full ChatPane — needs scene tree)
	#     Verify via method list that has_method would return true.
	check("T5: method list confirms has_method('get_active_model_descriptor') would pass",
		method_found,
		"method absent from list — has_method() would return false")


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

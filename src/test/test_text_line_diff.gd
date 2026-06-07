extends SceneTree
## Unit tests for TextLineDiff (work item 019ea01719a2 — change-journal backbone).
## Run: godot --headless --path src --script test/test_text_line_diff.gd

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== TextLineDiff tests ===")

	test_no_change()
	test_append()
	test_delete()
	test_modify()
	test_prefix_suffix_trim()
	test_empty_before()

	print("=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _eq(desc: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s — expected %s, got %s" % [desc, str(expected), str(actual)])


func test_no_change() -> void:
	print("test_no_change:")
	var d := TextLineDiff.diff("a\nb\nc", "a\nb\nc")
	_eq("no adds", d["adds"], 0)
	_eq("no dels", d["dels"], 0)


func test_append() -> void:
	print("test_append:")
	var d := TextLineDiff.diff("a\nb\nc", "a\nb\nc\nd\ne")
	_eq("two adds", d["adds"], 2)
	_eq("no dels", d["dels"], 0)
	_eq("added indices are the new tail lines", Array(d["added"]), [3, 4])


func test_delete() -> void:
	print("test_delete:")
	var d := TextLineDiff.diff("a\nb\nc", "a\nc")
	_eq("one del", d["dels"], 1)
	_eq("no adds", d["adds"], 0)
	_eq("removed line text", str((d["removed"][0] as Dictionary)["text"]), "b")
	_eq("removed ghost sits at after-index 1", int((d["removed"][0] as Dictionary)["after_index"]), 1)


func test_modify() -> void:
	print("test_modify:")
	var d := TextLineDiff.diff("a\nb\nc", "a\nB\nc")
	_eq("one add (B)", d["adds"], 1)
	_eq("one del (b)", d["dels"], 1)
	_eq("added at index 1", Array(d["added"]), [1])
	_eq("removed b", str((d["removed"][0] as Dictionary)["text"]), "b")


func test_prefix_suffix_trim() -> void:
	print("test_prefix_suffix_trim:")
	# common prefix "x", common suffix "z\nw"; middle y -> Y1,Y2
	var d := TextLineDiff.diff("x\ny\nz\nw", "x\nY1\nY2\nz\nw")
	_eq("two adds", d["adds"], 2)
	_eq("one del", d["dels"], 1)
	_eq("added at the middle after-indices", Array(d["added"]), [1, 2])
	_eq("removed y sits at after-index 1", int((d["removed"][0] as Dictionary)["after_index"]), 1)


func test_empty_before() -> void:
	print("test_empty_before:")
	# Whole-file addition: every after line is new (one spurious empty-line del is
	# acceptable since "".split("\n") == [""]).
	var d := TextLineDiff.diff("", "alpha\nbeta")
	_eq("adds both lines", d["adds"], 2)

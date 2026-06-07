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

	test_aligned_equal()
	test_aligned_append()
	test_aligned_delete()
	test_aligned_modify()

	test_char_ranges()

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


# ── aligned_rows (side-by-side) ───────────────────────────────────────────────

func test_aligned_equal() -> void:
	print("test_aligned_equal:")
	var r := TextLineDiff.aligned_rows("a\nb", "a\nb")
	_eq("2 rows", r.size(), 2)
	_eq("all equal", _ops(r), ["equal", "equal"])


func test_aligned_append() -> void:
	print("test_aligned_append:")
	var r := TextLineDiff.aligned_rows("a\nb", "a\nb\nc")
	_eq("ops", _ops(r), ["equal", "equal", "add"])
	var last: Dictionary = r[2]
	_eq("add row: left is a gap", last["left_line"], -1)
	_eq("add row: right text", last["right_text"], "c")


func test_aligned_delete() -> void:
	print("test_aligned_delete:")
	var r := TextLineDiff.aligned_rows("a\nb\nc", "a\nc")
	_eq("ops", _ops(r), ["equal", "del", "equal"])
	var d: Dictionary = r[1]
	_eq("del row: left text", d["left_text"], "b")
	_eq("del row: right is a gap", d["right_line"], -1)


func test_aligned_modify() -> void:
	print("test_aligned_modify:")
	var r := TextLineDiff.aligned_rows("a\nB\nc", "a\nX\nc")
	_eq("ops", _ops(r), ["equal", "modify", "equal"])
	var m: Dictionary = r[1]
	_eq("modify row: left=before", m["left_text"], "B")
	_eq("modify row: right=after", m["right_text"], "X")


func test_char_ranges() -> void:
	print("test_char_ranges:")
	var cr := TextLineDiff.char_ranges("return 42", "return 84")
	_eq("left changed span = the digits", cr["left"], [[7, 9]])
	_eq("right changed span = the digits", cr["right"], [[7, 9]])
	var same := TextLineDiff.char_ranges("abc", "abc")
	_eq("identical: no left span", same["left"], [])
	_eq("identical: no right span", same["right"], [])
	var ins := TextLineDiff.char_ranges("ac", "abc")
	_eq("insertion: nothing on left", ins["left"], [])
	_eq("insertion: 'b' span on right", ins["right"], [[1, 2]])


func _ops(rows: Array) -> Array:
	var out: Array = []
	for row in rows:
		out.append(str((row as Dictionary)["op"]))
	return out

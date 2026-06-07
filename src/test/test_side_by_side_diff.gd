extends SceneTree
## Render-mapping test for SideBySideDiff (work item 019ea06a1413). The visual
## bits (scroll/tints/comment dialog) are HITL; this locks the row→line mapping.
## Deferred to first frame so autoloads register before the widget script (which
## references SingletonObject for review comments) is loaded.
## Run: godot --headless --path src --script test/test_side_by_side_diff.gd

var _pass := 0
var _fail := 0


func _init() -> void:
	process_frame.connect(_run, CONNECT_ONE_SHOT)


func _run() -> void:
	print("=== SideBySideDiff render tests ===")
	var WidgetScript = load("res://Scripts/UI/Controls/SideBySideDiff.gd")
	var w = WidgetScript.new()
	w.render_rows([
		{"op": "equal", "left_text": "a", "right_text": "a"},
		{"op": "add", "left_line": -1, "left_text": "", "right_text": "b"},
		{"op": "del", "left_text": "c", "right_line": -1, "right_text": ""},
		{"op": "modify", "left_text": "D", "right_text": "X"},
	])
	_eq("left pane: del line present, add is a gap", w._left.text, "a\n\nc\nD")
	_eq("right pane: add line present, del is a gap", w._right.text, "a\nb\n\nX")
	_eq("both panes have equal line counts (rows align)", w._left.get_line_count(), w._right.get_line_count())
	w.free()

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

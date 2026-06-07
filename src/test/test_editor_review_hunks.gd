extends SceneTree
## Unit test for EditorCodeEdit review hunk grouping (DCR 019e9f602391 P5b).
## review_hunk_starts() groups contiguous highlighted lines into hunk start lines.
## Run: godot --headless --path src --script test/test_editor_review_hunks.gd

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=== EditorCodeEdit review-hunk tests ===")
	var ce := EditorCodeEdit.new()

	ce._preview_highlighted = [3, 4, 5, 10, 11, 20]
	_check_eq("contiguous runs -> hunk starts", ce.review_hunk_starts(), [3, 10, 20])
	_check_eq("change count = number of hunks", ce.review_change_count(), 3)

	# Out-of-order input is sorted first.
	ce._preview_highlighted = [20, 4, 3, 11, 5, 10]
	_check_eq("unsorted input still groups correctly", ce.review_hunk_starts(), [3, 10, 20])

	ce._preview_highlighted = []
	_check_eq("no changes -> 0", ce.review_change_count(), 0)
	_check_eq("no changes -> empty starts", ce.review_hunk_starts(), [])

	ce._preview_highlighted = [7]
	_check_eq("single changed line -> one hunk", ce.review_hunk_starts(), [7])

	ce.free()
	print("=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _check_eq(desc: String, actual: Variant, expected: Variant) -> void:
	if actual == expected:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s — expected %s, got %s" % [desc, str(expected), str(actual)])

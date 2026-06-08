extends SceneTree
## Headless tests for TextEditorAnnotationCanvas._wrap_segments (bug 019ea4d3c94d):
## the column-partition logic that splits an annotated char range into per-visual-row
## segments so a soft-wrapped line gets one underline per row instead of a single
## segment that collapses at the first wrap. The pixel/draw + caret-pos side is HITL.
## Also a cheap compile check that both edited scripts parse.
##
## Run: godot --headless --path src --script test/test_annotation_wrap_segments.gd

var _pass := 0
var _fail := 0


class StubCode:
	var rows: PackedStringArray
	func _init(r: PackedStringArray) -> void:
		rows = r
	func get_line_wrap_count(_line: int) -> int:
		return maxi(0, rows.size() - 1)
	func get_line_wrapped_text(_line: int) -> PackedStringArray:
		return rows


class StubNoWrap:
	func get_line_wrap_count(_line: int) -> int:
		return 0
	func get_line_wrapped_text(_line: int) -> PackedStringArray:
		return PackedStringArray(["whatever"])


func _init() -> void:
	print("=== annotation wrap-segments tests ===")
	var S: Variant = load("res://Scripts/UI/Controls/TextEditorAnnotationCanvas.gd")
	_check("canvas script compiles", S != null)
	_check("editor script compiles", load("res://Scripts/UI/Controls/Editor.gd") != null)

	test_no_wrap_single_segment(S)
	test_full_span_splits_per_row(S)
	test_partial_span_clamped(S)
	test_missing_api_falls_back(S)

	print("=== Results: %d passed, %d failed ===" % [_pass, _fail])
	if _fail > 0:
		printerr("FAILURES: %d" % _fail)
	quit(1 if _fail > 0 else 0)


func _check(desc: String, cond: bool) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % desc)
	else:
		_fail += 1
		printerr("  FAIL: %s" % desc)


func _eq(desc: String, actual: Variant, expected: Variant) -> void:
	_check("%s (got %s, want %s)" % [desc, str(actual), str(expected)], str(actual) == str(expected))


func test_no_wrap_single_segment(S: Variant) -> void:
	print("test_no_wrap_single_segment:")
	var code := StubNoWrap.new()
	_eq("one segment when not wrapped", S._wrap_segments(code, 0, 2, 10), [[2, 10]])


func test_full_span_splits_per_row(S: Variant) -> void:
	print("test_full_span_splits_per_row:")
	# rows of length 10,10,5 -> boundaries [0,10),[10,20),[20,25)
	var code := StubCode.new(PackedStringArray(["0123456789", "abcdefghij", "klmno"]))
	_eq("three row segments", S._wrap_segments(code, 0, 0, 25), [[0, 10], [10, 20], [20, 25]])


func test_partial_span_clamped(S: Variant) -> void:
	print("test_partial_span_clamped:")
	var code := StubCode.new(PackedStringArray(["0123456789", "abcdefghij", "klmno"]))
	# annotated span chars 5..22 -> [5,10],[10,20],[20,22]
	_eq("partial span clamped to rows", S._wrap_segments(code, 0, 5, 22), [[5, 10], [10, 20], [20, 22]])


func test_missing_api_falls_back(S: Variant) -> void:
	print("test_missing_api_falls_back:")
	var code := RefCounted.new()  # no wrap methods
	_eq("fallback single segment", S._wrap_segments(code, 0, 1, 7), [[1, 7]])

extends SceneTree
## Tests for EditTool, GrepTool, and BashTool.
## Run: godot --headless --script test/test_codetools_edit_grep_bash.gd

var _pass_count: int = 0
var _fail_count: int = 0

func _init():
	print("=== CodeTools Edit/Grep/Bash Tests ===\n")

	test_edit_basic()
	test_edit_not_found()
	test_edit_ambiguous()
	test_edit_replace_all()
	test_grep_basic()
	test_grep_no_match()
	test_grep_ignore_case()
	test_grep_type_filter()
	test_bash_basic()
	test_bash_exit_code()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	quit(1 if _fail_count > 0 else 0)


func check(desc: String, cond: bool) -> void:
	if cond:
		_pass_count += 1
		print("  PASS: %s" % desc)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % desc)


# ── Edit Tests ────────────────────────────────────────────────────────

func test_edit_basic():
	print("test_edit_basic:")
	var path := "/tmp/test_edit_basic.txt"
	_write_tmp(path, "hello world\nfoo bar\n")
	var r := EditTool.edit_file(path, "foo", "baz")
	check("success", r["success"] == true)
	check("1 replacement", r["replacements"] == 1)
	check("content updated", FileAccess.open(path, FileAccess.READ).get_as_text() == "hello world\nbaz bar\n")

func test_edit_not_found():
	print("test_edit_not_found:")
	var path := "/tmp/test_edit_notfound.txt"
	_write_tmp(path, "hello world\n")
	var r := EditTool.edit_file(path, "xyz", "abc")
	check("fails", r["success"] == false)
	check("error mentions not found", "not found" in r["error"].to_lower())

func test_edit_ambiguous():
	print("test_edit_ambiguous:")
	var path := "/tmp/test_edit_ambig.txt"
	_write_tmp(path, "aaa bbb aaa\n")
	var r := EditTool.edit_file(path, "aaa", "ccc")
	check("fails on ambiguous", r["success"] == false)
	check("error mentions occurrences", "occurrences" in r["error"].to_lower())

func test_edit_replace_all():
	print("test_edit_replace_all:")
	var path := "/tmp/test_edit_replall.txt"
	_write_tmp(path, "aaa bbb aaa\n")
	var r := EditTool.edit_file(path, "aaa", "ccc", true)
	check("success", r["success"] == true)
	check("2 replacements", r["replacements"] == 2)
	check("content updated", FileAccess.open(path, FileAccess.READ).get_as_text() == "ccc bbb ccc\n")

# ── Grep Tests ────────────────────────────────────────────────────────

func test_grep_basic():
	print("test_grep_basic:")
	var path := "/tmp/test_grep_basic.txt"
	_write_tmp(path, "line one\nline two\nthree four\n")
	var r := GrepTool.grep_files("line", path)
	check("success", r["success"] == true)
	check("2 matches", r["total_matches"] == 2)

func test_grep_no_match():
	print("test_grep_no_match:")
	var path := "/tmp/test_grep_nomatch.txt"
	_write_tmp(path, "hello world\n")
	var r := GrepTool.grep_files("xyz123", path)
	check("success", r["success"] == true)
	check("0 matches", r["total_matches"] == 0)

func test_grep_ignore_case():
	print("test_grep_ignore_case:")
	var path := "/tmp/test_grep_icase.txt"
	_write_tmp(path, "Hello World\nhello world\nHELLO\n")
	var r := GrepTool.grep_files("hello", path, "", "", true)
	check("success", r["success"] == true)
	check("3 case-insensitive matches", r["total_matches"] == 3)

func test_grep_type_filter():
	print("test_grep_type_filter:")
	# Search Minerva src for a known pattern in .gd files
	var r := GrepTool.grep_files("class_name", "res://Scripts/Services/CodeTools/", "", "gd")
	check("success", r["success"] == true)
	check("found matches in .gd files", r["total_matches"] > 0)

# ── Bash Tests ────────────────────────────────────────────────────────

func test_bash_basic():
	print("test_bash_basic:")
	var r := BashTool.run_command("echo hello")
	check("exit code 0", r["exit_code"] == 0)
	check("stdout contains hello", "hello" in r["stdout"])

func test_bash_exit_code():
	print("test_bash_exit_code:")
	var r := BashTool.run_command("false")
	check("exit code non-zero", r["exit_code"] != 0)


# ── Helpers ───────────────────────────────────────────────────────────

func _write_tmp(path: String, content: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(content)
	f.close()

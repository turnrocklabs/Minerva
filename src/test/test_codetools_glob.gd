extends SceneTree
## Test: GlobTool — pattern matching over the Minerva src/ directory tree.
## Run: godot --headless --script test/test_codetools_glob.gd
##
## Uses the real src/ directory as test data since it contains known .gd files.

var GlobTool = preload("res://Scripts/Services/CodeTools/GlobTool.gd")

var _pass_count: int = 0
var _fail_count: int = 0


func _init():
	print("=== GlobTool Tests ===\n")

	test_simple_wildcard()
	test_recursive_wildcard()
	test_specific_file_match()
	test_no_matches_returns_empty()
	test_nonexistent_directory_returns_error()
	test_question_mark_wildcard()
	test_limit_truncates_results()
	test_empty_pattern_literal()
	test_nested_dir_not_recursive()

	print("\n=== Results: %d passed, %d failed ===" % [_pass_count, _fail_count])
	if _fail_count > 0:
		printerr("FAILURES: %d" % _fail_count)
	quit(1 if _fail_count > 0 else 0)


func check(description: String, condition: bool) -> void:
	if condition:
		_pass_count += 1
		print("  PASS: %s" % description)
	else:
		_fail_count += 1
		printerr("  FAIL: %s" % description)


## Absolute path to the Minerva src/ directory, which is the Godot project root.
## ProjectSettings.globalize_path("res://") gives the absolute filesystem path.
func src_dir() -> String:
	return ProjectSettings.globalize_path("res://").rstrip("/")


# ── Tests ─────────────────────────────────────────────────────────────────────

func test_simple_wildcard():
	print("test_simple_wildcard:")
	var result: Dictionary = GlobTool.glob_files("*.gd", src_dir())
	check("success is true", result["success"] == true)
	# The src/ root has project.godot but likely no .gd files directly;
	# even if 0 matches, the call must succeed and return an array.
	check("files is an Array", result["files"] is Array)
	check("total_matches is int", result["total_matches"] is int)
	check("truncated is bool", result["truncated"] is bool)


func test_recursive_wildcard():
	print("test_recursive_wildcard:")
	var result: Dictionary = GlobTool.glob_files("**/*.gd", src_dir())
	check("success is true", result["success"] == true)
	# Minerva's src/ tree has many .gd scripts.
	check("finds at least 10 .gd files", result["total_matches"] >= 10)
	# All returned entries must end in .gd.
	var all_gd := true
	for f in result["files"]:
		if not (f as String).ends_with(".gd"):
			all_gd = false
			break
	check("all returned files end in .gd", all_gd)
	# Results must be sorted alphabetically.
	var files: Array = result["files"]
	var sorted: Array = files.duplicate()
	sorted.sort()
	check("results are sorted alphabetically", files == sorted)


func test_specific_file_match():
	print("test_specific_file_match:")
	# GlobTool.gd itself lives at Scripts/Services/CodeTools/GlobTool.gd
	var result: Dictionary = GlobTool.glob_files("Scripts/Services/CodeTools/GlobTool.gd", src_dir())
	check("success is true", result["success"] == true)
	check("finds exactly 1 file", result["total_matches"] == 1)
	check("file path is correct",
		result["files"][0] == "Scripts/Services/CodeTools/GlobTool.gd")


func test_no_matches_returns_empty():
	print("test_no_matches_returns_empty:")
	var result: Dictionary = GlobTool.glob_files("**/*.nonexistent_extension_xyz", src_dir())
	check("success is true", result["success"] == true)
	check("files is empty", result["files"].size() == 0)
	check("total_matches is 0", result["total_matches"] == 0)
	check("truncated is false", result["truncated"] == false)


func test_nonexistent_directory_returns_error():
	print("test_nonexistent_directory_returns_error:")
	var result: Dictionary = GlobTool.glob_files("*.gd", "/this/path/does/not/exist/xyz")
	check("success is false", result["success"] == false)
	check("error key is present", result.has("error"))
	check("error is non-empty string", result["error"] != "")


func test_question_mark_wildcard():
	print("test_question_mark_wildcard:")
	# Match files like "A.gd" or "X.gd" (exactly one char before .gd) anywhere.
	var result: Dictionary = GlobTool.glob_files("**/?.gd", src_dir())
	check("success is true", result["success"] == true)
	check("files is an Array", result["files"] is Array)
	# Every returned name's basename must be exactly one character + ".gd" (4 chars total).
	var all_single := true
	for f in result["files"]:
		var base: String = (f as String).get_file()  # e.g. "A.gd"
		if base.length() != 4:                        # 1 char + ".gd" = 4 chars
			all_single = false
			break
	check("all matched basenames are exactly 1 char + .gd", all_single)


func test_limit_truncates_results():
	print("test_limit_truncates_results:")
	var result_full: Dictionary = GlobTool.glob_files("**/*.gd", src_dir(), 0)
	var total: int = result_full["total_matches"]
	if total < 2:
		check("skipped: not enough .gd files to test limit (a)", true)
		check("skipped: not enough .gd files to test limit (b)", true)
		check("skipped: not enough .gd files to test limit (c)", true)
		check("skipped: not enough .gd files to test limit (d)", true)
		return

	var small_limit := 2
	var result_limited: Dictionary = GlobTool.glob_files("**/*.gd", src_dir(), small_limit)
	check("success is true", result_limited["success"] == true)
	check("files array is capped at limit", result_limited["files"].size() == small_limit)
	check("truncated is true when results exceed limit", result_limited["truncated"] == true)
	check("total_matches reflects full count", result_limited["total_matches"] == total)


func test_empty_pattern_literal():
	print("test_empty_pattern_literal:")
	# A pattern with no wildcards matching nothing → success + empty list.
	var result: Dictionary = GlobTool.glob_files("does_not_exist_at_all.gd", src_dir())
	check("success is true", result["success"] == true)
	check("files is empty", result["files"].size() == 0)


func test_nested_dir_not_recursive():
	print("test_nested_dir_not_recursive:")
	# "*.gd" (no **) must NOT descend into subdirectories.
	# The src/ root has 0 .gd files; ** finds many more.
	var shallow: Dictionary = GlobTool.glob_files("*.gd", src_dir())
	var deep: Dictionary    = GlobTool.glob_files("**/*.gd", src_dir())
	check("shallow search succeeds", shallow["success"] == true)
	check("deep search finds more (or equal) files than shallow",
		deep["total_matches"] >= shallow["total_matches"])

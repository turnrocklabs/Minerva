extends SceneTree
## Test: CodeTools CwdTool and WriteTool functionality
## Run: godot --headless --path <minerva/src> --main-loop res://test/test_codetools_cwd_write.gd

var _pass_count: int = 0
var _fail_count: int = 0
var _test_dir: String = "/tmp/minerva_codetools_test"
var _cwd_tool: CwdTool
var _write_tool: WriteTool


func _initialize():
	print("=== CodeTools CwdTool and WriteTool Tests ===\n")

	_cwd_tool = CwdTool.new()
	_write_tool = WriteTool.new(_cwd_tool)

	setup_test_directory()

	test_cwd_get_default()
	test_cwd_set_valid_directory()
	test_cwd_set_invalid_directory()
	test_cwd_set_tilde_expansion()
	test_write_file_simple()
	test_write_file_nested_directory()
	test_write_file_empty_content()
	test_write_file_overwrites_existing()
	test_write_file_with_relative_path()

	cleanup_test_directory()

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


func setup_test_directory() -> void:
	# Create test directory
	DirAccess.make_dir_recursive_absolute(_test_dir)


func cleanup_test_directory() -> void:
	# Clean up test directory
	var dir = DirAccess.open(_test_dir)
	if dir:
		dir.list_dir_begin()
		var file = dir.get_next()
		while file != "":
			if not file.begins_with("."):
				var file_path = _test_dir.path_join(file)
				if dir.current_is_dir():
					# Recursively delete subdirectories
					var sub_dir = DirAccess.open(file_path)
					if sub_dir:
						sub_dir.list_dir_begin()
						var sub_file = sub_dir.get_next()
						while sub_file != "":
							if not sub_file.begins_with("."):
								DirAccess.remove_absolute(file_path.path_join(sub_file))
							sub_file = sub_dir.get_next()
				else:
					DirAccess.remove_absolute(file_path)
			file = dir.get_next()
		DirAccess.remove_absolute(_test_dir)


# ── CwdTool Tests ─────────────────────────────────────────────────────────

func test_cwd_get_default():
	print("test_cwd_get_default:")
	var cwd = _cwd_tool.get_cwd()
	check("get_cwd returns a string", cwd is String)
	check("get_cwd returns non-empty string", not cwd.is_empty())
	check("get_cwd returns absolute path", cwd.begins_with("/"))


func test_cwd_set_valid_directory():
	print("test_cwd_set_valid_directory:")
	var result = _cwd_tool.set_cwd(_test_dir)
	check("set_cwd succeeds for valid directory", result.get("success", false) == true)
	check("result contains 'directory' key", result.has("directory"))
	check("result contains 'action' key", result.has("action"))
	check("action is 'change'", result.get("action") == "change")
	check("returned directory is normalized", result.get("directory") == _test_dir)

	# Verify it was actually set
	var cwd = _cwd_tool.get_cwd()
	check("get_cwd returns the set directory", cwd == _test_dir)


func test_cwd_set_invalid_directory():
	print("test_cwd_set_invalid_directory:")
	var result = _cwd_tool.set_cwd("/nonexistent/path/that/does/not/exist")
	check("set_cwd fails for nonexistent directory", result.get("success", false) == false)
	check("result contains 'error' key", result.has("error"))
	check("error message mentions directory", "Directory does not exist" in result.get("error", ""))


func test_cwd_set_tilde_expansion():
	print("test_cwd_set_tilde_expansion:")
	var home_dir = OS.get_environment("HOME")
	if not home_dir.is_empty():
		# Create a temporary test directory in home
		var test_home_dir = home_dir.path_join(".minerva_test_cwd")
		DirAccess.make_dir_recursive_absolute(test_home_dir)

		var result = _cwd_tool.set_cwd("~/.minerva_test_cwd")
		check("set_cwd expands ~ to home directory", result.get("success", false) == true)

		# Clean up
		DirAccess.remove_absolute(test_home_dir)
	else:
		print("  SKIP: HOME environment variable not set")


func test_write_file_simple():
	print("test_write_file_simple:")
	_cwd_tool.set_cwd(_test_dir)
	var test_file = "test_simple.txt"
	var content = "Hello, World!"

	var result = _write_tool.write_file(test_file, content)
	check("write_file succeeds", result.get("success", false) == true)
	check("result contains 'path' key", result.has("path"))
	check("result contains 'bytes_written' key", result.has("bytes_written"))
	check("bytes_written matches content length", result.get("bytes_written") == content.length())

	# Verify file was actually written
	var file_access = FileAccess.open(result.get("path"), FileAccess.READ)
	check("file can be read", file_access != null)
	if file_access:
		var read_content = file_access.get_as_text()
		check("file content matches written content", read_content == content)


func test_write_file_nested_directory():
	print("test_write_file_nested_directory:")
	_cwd_tool.set_cwd(_test_dir)
	var test_file = "nested/dir/test_file.txt"
	var content = "Nested content"

	var result = _write_tool.write_file(test_file, content)
	check("write_file succeeds for nested path", result.get("success", false) == true)

	# Verify file was actually written
	var file_access = FileAccess.open(result.get("path"), FileAccess.READ)
	check("nested file can be read", file_access != null)
	if file_access:
		var read_content = file_access.get_as_text()
		check("nested file content matches", read_content == content)


func test_write_file_empty_content():
	print("test_write_file_empty_content:")
	_cwd_tool.set_cwd(_test_dir)
	var test_file = "empty.txt"
	var content = ""

	var result = _write_tool.write_file(test_file, content)
	check("write_file succeeds for empty content", result.get("success", false) == true)
	check("bytes_written is 0 for empty content", result.get("bytes_written") == 0)

	# Verify file exists and is empty
	var file_access = FileAccess.open(result.get("path"), FileAccess.READ)
	check("empty file can be read", file_access != null)
	if file_access:
		var read_content = file_access.get_as_text()
		check("empty file content is empty", read_content.is_empty())


func test_write_file_overwrites_existing():
	print("test_write_file_overwrites_existing:")
	_cwd_tool.set_cwd(_test_dir)
	var test_file = "overwrite_test.txt"
	var original_content = "Original content"
	var new_content = "New content"

	# Write original
	var result1 = _write_tool.write_file(test_file, original_content)
	check("first write succeeds", result1.get("success", false) == true)

	# Overwrite
	var result2 = _write_tool.write_file(test_file, new_content)
	check("second write succeeds", result2.get("success", false) == true)

	# Verify file contains new content
	var file_access = FileAccess.open(result2.get("path"), FileAccess.READ)
	check("file can be read after overwrite", file_access != null)
	if file_access:
		var read_content = file_access.get_as_text()
		check("file content is new content after overwrite", read_content == new_content)


func test_write_file_with_relative_path():
	print("test_write_file_with_relative_path:")
	_cwd_tool.set_cwd(_test_dir)
	var test_file = "relative_test.txt"
	var content = "Relative path content"

	var result = _write_tool.write_file(test_file, content)
	check("write_file succeeds with relative path", result.get("success", false) == true)

	# Verify the path was resolved relative to cwd
	var expected_path = _test_dir.path_join(test_file)
	check("path is resolved relative to cwd", result.get("path") == expected_path)

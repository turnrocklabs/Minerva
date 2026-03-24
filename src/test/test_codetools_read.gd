extends SceneTree
## Test: CodeTools ReadTool.gd - file reading with offset and limit.
## Run: godot --headless --script src/test/test_codetools_read.gd

# ReadTool is available globally via class_name

var _pass_count: int = 0
var _fail_count: int = 0

# Paths for temporary test files
var _temp_dir: String = "/tmp/codetools_read_test"
var _test_file: String = ""
var _test_multiline: String = ""
var _test_empty: String = ""
var _test_binary: String = ""


func _init():
	print("=== CodeTools ReadTool Tests ===\n")

	_setup_temp_files()

	test_read_existing_file()
	test_read_with_offset()
	test_read_with_limit()
	test_read_with_offset_and_limit()
	test_read_nonexistent_file()
	test_read_empty_file()
	test_read_binary_file()
	test_read_file_with_long_lines()
	test_line_numbers_and_format()

	_cleanup_temp_files()

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


func _setup_temp_files() -> void:
	# Create temp directory
	var dir := DirAccess.open("/tmp")
	if dir:
		dir.make_dir_absolute(_temp_dir)

	# Create a simple test file (5 lines)
	_test_file = _temp_dir + "/test_file.txt"
	var file := FileAccess.open(_test_file, FileAccess.WRITE)
	file.store_string("Line 1\nLine 2\nLine 3\nLine 4\nLine 5")
	file = null

	# Create a multiline test file (10 lines)
	_test_multiline = _temp_dir + "/test_multiline.txt"
	file = FileAccess.open(_test_multiline, FileAccess.WRITE)
	var lines_content := ""
	for i in range(1, 11):
		lines_content += "Line number %d\n" % i
	file.store_string(lines_content)
	file = null

	# Create an empty file
	_test_empty = _temp_dir + "/test_empty.txt"
	file = FileAccess.open(_test_empty, FileAccess.WRITE)
	file.store_string("")
	file = null

	# Create a binary-like file (contains null bytes)
	_test_binary = _temp_dir + "/test_binary.bin"
	file = FileAccess.open(_test_binary, FileAccess.WRITE)
	var binary_data := PackedByteArray([0x00, 0x01, 0x02, 0xFF, 0xFE])
	file.store_buffer(binary_data)
	file = null


func _cleanup_temp_files() -> void:
	var dir := DirAccess.open(_temp_dir)
	if dir:
		for file_name in dir.get_files():
			dir.remove(_temp_dir + "/" + file_name)
		DirAccess.remove_absolute(_temp_dir)


# ── Tests ─────────────────────────────────────────────────────────────

func test_read_existing_file() -> void:
	print("test_read_existing_file:")
	var result: Dictionary = ReadTool.read_file(_test_file)
	check("success is true", result.success == true)
	check("content is not empty", result.content.length() > 0)
	check("total_lines is 5", result.total_lines == 5)
	check("lines_read is 5", result.lines_read == 5)
	check("truncated is false", result.truncated == false)
	check("binary is false", result.binary == false)


func test_read_with_offset() -> void:
	print("test_read_with_offset:")
	# Read starting from line 2 (0-based offset=1)
	var result: Dictionary = ReadTool.read_file(_test_file, 1)
	check("success is true", result.success == true)
	check("lines_read is 4", result.lines_read == 4)
	check("content contains 'Line 2'", "Line 2" in result.content)
	check("content does not contain 'Line 1'", "Line 1" not in result.content)


func test_read_with_limit() -> void:
	print("test_read_with_limit:")
	# Read only 2 lines
	var result: Dictionary = ReadTool.read_file(_test_file, 0, 2)
	check("success is true", result.success == true)
	check("lines_read is 2", result.lines_read == 2)
	check("truncated is true", result.truncated == true)
	check("content contains 'Line 1'", "Line 1" in result.content)
	check("content contains 'Line 2'", "Line 2" in result.content)
	check("content does not contain 'Line 3'", "Line 3" not in result.content)


func test_read_with_offset_and_limit() -> void:
	print("test_read_with_offset_and_limit:")
	# Read 2 lines starting from line 2 (offset=1, limit=2)
	var result: Dictionary = ReadTool.read_file(_test_file, 1, 2)
	check("success is true", result.success == true)
	check("lines_read is 2", result.lines_read == 2)
	check("content contains 'Line 2'", "Line 2" in result.content)
	check("content contains 'Line 3'", "Line 3" in result.content)
	check("content does not contain 'Line 1'", "Line 1" not in result.content)
	check("content does not contain 'Line 4'", "Line 4" not in result.content)


func test_read_nonexistent_file() -> void:
	print("test_read_nonexistent_file:")
	var result: Dictionary = ReadTool.read_file("/tmp/nonexistent_file_xyz.txt")
	check("success is false", result.success == false)
	check("error message present", result.error != "")
	check("error contains 'not found'", "not found" in result.error.to_lower())


func test_read_empty_file() -> void:
	print("test_read_empty_file:")
	var result: Dictionary = ReadTool.read_file(_test_empty)
	check("success is true", result.success == true)
	check("content is empty", result.content == "")
	check("total_lines is 0", result.total_lines == 0)
	check("lines_read is 0", result.lines_read == 0)


func test_read_binary_file() -> void:
	print("test_read_binary_file:")
	var result: Dictionary = ReadTool.read_file(_test_binary)
	check("success is true", result.success == true)
	check("binary is true", result.binary == true)
	check("content contains 'Binary file'", "Binary file" in result.content)
	check("content contains byte count", "5 bytes" in result.content)


func test_read_file_with_long_lines() -> void:
	print("test_read_file_with_long_lines:")
	# Create a file with a very long line
	var long_line_file: String = _temp_dir + "/test_long_line.txt"
	var file: FileAccess = FileAccess.open(long_line_file, FileAccess.WRITE)
	var long_line: String = "".repeat(2500)
	for _i in range(2500):
		long_line = long_line + "x"
	file.store_string(long_line + "\nNormal line")
	file = null

	var result: Dictionary = ReadTool.read_file(long_line_file)
	check("success is true", result.success == true)
	check("content contains truncation marker", "[truncated]" in result.content)
	var check_str: String = "".repeat(2000)
	for _i in range(2000):
		check_str = check_str + "x"
	check("long line is truncated to 2000", result.content.contains(check_str))

	# Cleanup
	DirAccess.remove_absolute(long_line_file)


func test_line_numbers_and_format() -> void:
	print("test_line_numbers_and_format:")
	var result: Dictionary = ReadTool.read_file(_test_multiline)
	check("success is true", result.success == true)

	# Lines should be formatted as "  1\tLine number 1"
	var lines: PackedStringArray = result.content.split("\n")
	check("first line contains tab", "\t" in lines[0])
	check("first line starts with line number", lines[0].begins_with(" "))

	# Check that we can see line 10 (should be properly padded)
	check("line 10 is present", "10\t" in result.content or "10\t" in result.content)

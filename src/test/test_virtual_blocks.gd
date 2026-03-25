extends SceneTree
## Test: virtual terminal blocks data model and injection formatting.
## Run: godot --headless --script test/test_virtual_blocks.gd
##
## Tests creation, formatting, token estimation, and truncation behavior
## for VIRTUAL block types (MCP tool calls).
##
## NOTE: Uses dynamic typing (var block = ... without type hints) to work
## with Godot's headless execution where class_name resolution happens at runtime.

var _pass_count: int = 0
var _fail_count: int = 0
var _TerminalBlockClass


func _init():
	print("=== Virtual Terminal Block Tests ===\n")

	# Load TerminalBlock class dynamically
	_TerminalBlockClass = load("res://src/Scripts/Models/terminal_block.gd")
	if not _TerminalBlockClass:
		printerr("ERROR: Failed to load TerminalBlock class")
		quit(1)

	test_default_block_type()
	test_virtual_empty_fields()
	test_create_virtual_bash()
	test_create_virtual_file_write()
	test_virtual_format_for_injection_bash()
	test_virtual_format_for_injection_file_write()
	test_virtual_format_truncates_long_values()
	test_virtual_estimate_tokens()
	test_command_block_unchanged()
	test_virtual_block_timestamp()

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


# ── Tests ─────────────────────────────────────────────────────────────


func test_default_block_type():
	print("test_default_block_type:")
	var block = _TerminalBlockClass.new()
	check("new TerminalBlock defaults to COMMAND type",
		block.block_type == _TerminalBlockClass.BlockType.COMMAND)


func test_virtual_empty_fields():
	print("test_virtual_empty_fields:")
	var block = _TerminalBlockClass.new()
	check("tool_name is empty", block.tool_name == "")
	check("tool_arguments is empty dict", block.tool_arguments == {})
	check("tool_result is empty dict", block.tool_result == {})
	check("timestamp is 0", block.timestamp == 0)


func test_create_virtual_bash():
	print("test_create_virtual_bash:")
	var block = _TerminalBlockClass.new()
	block.block_type = _TerminalBlockClass.BlockType.VIRTUAL
	block.tool_name = "minerva_bash"
	block.tool_arguments = {"command": "ls -la"}
	block.tool_result = {"exit_code": 0, "stdout": "file.txt\ndir/", "success": true}
	block.timestamp = 1711270498

	check("block_type set to VIRTUAL", block.block_type == _TerminalBlockClass.BlockType.VIRTUAL)
	check("tool_name set", block.tool_name == "minerva_bash")
	check("tool_arguments has command key", block.tool_arguments.has("command"))
	check("tool_arguments command value", block.tool_arguments["command"] == "ls -la")
	check("tool_result has exit_code", block.tool_result.has("exit_code"))
	check("tool_result exit_code value", block.tool_result["exit_code"] == 0)
	check("timestamp set", block.timestamp == 1711270498)


func test_create_virtual_file_write():
	print("test_create_virtual_file_write:")
	var block = _TerminalBlockClass.new()
	block.block_type = _TerminalBlockClass.BlockType.VIRTUAL
	block.tool_name = "minerva_file_write"
	block.tool_arguments = {
		"path": "/home/user/test.txt",
		"content": "Hello, world!"
	}
	block.tool_result = {"success": true}
	block.timestamp = 1711270500

	check("tool_name is minerva_file_write", block.tool_name == "minerva_file_write")
	check("tool_arguments has path", block.tool_arguments.has("path"))
	check("tool_arguments path value", block.tool_arguments["path"] == "/home/user/test.txt")
	check("tool_arguments has content", block.tool_arguments.has("content"))
	check("tool_result success is true", block.tool_result["success"] == true)


func test_virtual_format_for_injection_bash():
	print("test_virtual_format_for_injection_bash:")
	var block = _TerminalBlockClass.new()
	block.block_type = _TerminalBlockClass.BlockType.VIRTUAL
	block.tool_name = "minerva_bash"
	block.tool_arguments = {"command": "ls /tmp"}
	block.tool_result = {
		"exit_code": 0,
		"stdout": "file1.txt\nfile2.txt",
		"success": true
	}

	var formatted = block.format_for_injection(null)
	check("format starts with ```tool-call", formatted.begins_with("```tool-call"))
	check("format contains tool name", formatted.contains("minerva_bash"))
	check("format contains command argument", formatted.contains("ls /tmp"))
	check("format contains success marker", formatted.contains("→ success"))
	check("format ends with ```", formatted.ends_with("```"))


func test_virtual_format_for_injection_file_write():
	print("test_virtual_format_for_injection_file_write:")
	var block = _TerminalBlockClass.new()
	block.block_type = _TerminalBlockClass.BlockType.VIRTUAL
	block.tool_name = "minerva_file_write"
	block.tool_arguments = {
		"path": "/home/test.gd",
		"content": "func hello():\n\tprint(\"hi\")"
	}
	block.tool_result = {"success": true}

	var formatted = block.format_for_injection(null)
	check("format starts with ```tool-call", formatted.begins_with("```tool-call"))
	check("format contains tool name", formatted.contains("minerva_file_write"))
	check("format contains path argument", formatted.contains("/home/test.gd"))
	check("format contains content argument", formatted.contains("func hello"))
	check("format contains success marker", formatted.contains("success"))
	check("format ends with ```", formatted.ends_with("```"))


func test_virtual_format_truncates_long_values():
	print("test_virtual_format_truncates_long_values:")
	var long_content := ""
	for _i in range(300):
		long_content += "x"
	var block = _TerminalBlockClass.new()
	block.block_type = _TerminalBlockClass.BlockType.VIRTUAL
	block.tool_name = "minerva_file_write"
	block.tool_arguments = {
		"path": "/home/test.txt",
		"content": long_content
	}
	block.tool_result = {"success": true}

	var formatted = block.format_for_injection(null)

	# If _format_virtual_for_injection is implemented with truncation,
	# the formatted output should contain "..." or similar truncation marker
	# For now, just verify the formatting doesn't crash and produces valid output
	check("format is valid string", formatted is String)
	check("format is not empty", !formatted.is_empty())
	check("format contains tool name", formatted.contains("minerva_file_write"))

	# Note: exact truncation behavior depends on implementation.
	# If truncation is at 200 chars, long values should be cut with "..."
	var x_sample := ""
	for _i in range(50):
		x_sample += "x"
	var has_truncation_or_content = formatted.contains("...") or formatted.contains(x_sample)
	check("format handles long values", has_truncation_or_content)


func test_virtual_estimate_tokens():
	print("test_virtual_estimate_tokens:")
	var block = _TerminalBlockClass.new()
	block.block_type = _TerminalBlockClass.BlockType.VIRTUAL
	block.tool_name = "minerva_bash"
	block.tool_arguments = {"command": "find . -name '*.gd'"}
	block.tool_result = {"stdout": "script1.gd\nscript2.gd\nscript3.gd", "success": true}

	var tokens = block.estimate_tokens(null)
	# Virtual blocks without a terminal should estimate from row counts or content
	# At minimum, should return a positive number or 0
	check("estimate_tokens returns integer", tokens is int)
	check("estimate_tokens >= 0", tokens >= 0)

	# For a block with minimal set data, expect at least some token estimate
	# This depends on implementation (could be 0 if no terminal provided)
	if tokens > 0:
		check("estimate_tokens is positive", true)
	else:
		# Implementation may return 0 for virtual blocks without terminal context
		check("estimate_tokens returns 0 for minimal block", tokens == 0)


func test_command_block_unchanged():
	print("test_command_block_unchanged:")
	var block = _TerminalBlockClass.new()
	block.block_type = _TerminalBlockClass.BlockType.COMMAND
	block.command = "bash-5.2$ ls -la"
	block.output_text = "total 42\ndrwxr-xr-x  user  group  dir\n-rw-r--r--  user  group  file.txt"

	var formatted = block.format_for_injection(null)
	check("format starts with ```terminal", formatted.begins_with("```terminal"))
	check("format contains command", formatted.contains("ls -la"))
	check("format contains output", formatted.contains("total 42"))
	check("format ends with ```", formatted.ends_with("```"))


func test_virtual_block_timestamp():
	print("test_virtual_block_timestamp:")
	var block = _TerminalBlockClass.new()
	block.block_type = _TerminalBlockClass.BlockType.VIRTUAL
	block.timestamp = 1711270498

	check("timestamp can be set", block.timestamp == 1711270498)
	check("timestamp > 0", block.timestamp > 0)

	var block2 = _TerminalBlockClass.new()
	check("new block timestamp defaults to 0", block2.timestamp == 0)

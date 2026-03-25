extends RefCounted
class_name TerminalBlock
## A terminal block: one command + its output, bounded by shell prompts.

## The command line text (e.g. "find . -name '*.gd'")
var command: String = ""

## Stored output text (captured at finalization before scrollback loses it)
var output_text: String = ""

## Screen-absolute row where this block's prompt appeared (stable across scrolling)
var screen_row: int = 0

## Viewport row where this block's prompt appeared (for gutter button positioning)
var prompt_row: int = 0

## Screen-absolute row where this block's output ends (set when next prompt arrives)
var end_row: int = -1  # -1 = block still active (no next prompt yet)

## Whether this block is checked for injection
var checked: bool = false

## Marked ranges for partial injection (Array of Dictionary: {start_row, end_row})
var marked_ranges: Array[Dictionary] = []

## Reference to the gutter CheckButton (for cleanup)
var button: CheckButton = null

## Reference to the per-block send button (for cleanup)
var send_button: Button = null

## Note.Proxy for detached note injection into chat (set when checked)
var proxy: RefCounted = null  # Note.Proxy

## Block type: COMMAND = real PTY command+output, VIRTUAL = MCP tool call
enum BlockType { COMMAND, VIRTUAL }
var block_type: BlockType = BlockType.COMMAND

## Virtual block fields (only used when block_type == VIRTUAL)
var tool_name: String = ""
var tool_arguments: Dictionary = {}
var tool_result: Dictionary = {}
var timestamp: int = 0  # Unix time


func is_active() -> bool:
	return end_row == -1


func row_count() -> int:
	if end_row == -1:
		return 0  # unknown until finalized
	return maxi(0, end_row - prompt_row)


func get_text(terminal_node) -> String:
	## Extract block text from terminal cells.
	## If marked_ranges exist, only include those rows.
	## terminal_node must have .terminal with .get_cell(col, row)
	if not terminal_node or not terminal_node.terminal:
		return ""

	var rows_to_extract: Array[Dictionary] = []
	if marked_ranges.size() > 0:
		rows_to_extract = marked_ranges.duplicate()
	else:
		var last = end_row if end_row >= 0 else prompt_row + 1
		rows_to_extract = [{"start_row": prompt_row, "end_row": last}]

	var parts: PackedStringArray = []
	var prev_end: int = -1

	for range_dict in rows_to_extract:
		var sr: int = range_dict.get("start_row", 0)
		var er: int = range_dict.get("end_row", sr)

		# Add omission marker between non-contiguous ranges
		if prev_end >= 0 and sr > prev_end + 1:
			var omitted: int = sr - prev_end - 1
			parts.append("[... %d lines omitted ...]" % omitted)

		for row in range(sr, er + 1):
			var line: String = ""
			for col in range(terminal_node._cols):
				var cell: Dictionary = terminal_node.terminal.get_cell(col, row)
				if cell.is_empty():
					break
				var cp: int = cell.get("codepoint", 0)
				if cp == 0:
					break
				elif cp >= 32:
					line += char(cp)
			parts.append(line.rstrip(" "))

		prev_end = er

	return "\n".join(parts)


func format_for_injection(_terminal_node) -> String:
	## Format this block as a terminal code fence for chat injection.
	## Uses stored command and output_text (captured before scrollback).
	if block_type == BlockType.VIRTUAL:
		return _format_virtual_for_injection()
	var result: PackedStringArray = ["```terminal"]

	# 1. Command line — always first
	if not command.is_empty():
		# Strip shell prompt prefix (e.g., "bash-5.2$ ls -l" → "ls -l")
		var cmd := _strip_prompt_prefix(command)
		result.append("$ " + cmd)

	# 2. Output — stored at finalization time
	if not output_text.is_empty():
		result.append(output_text)

	result.append("```")
	return "\n".join(result)


static func _strip_prompt_prefix(raw_command: String) -> String:
	## Strip shell prompt prefix from a captured command line.
	## "bash-5.2$ ls -l" → "ls -l"
	## "user@host ~/dir % pwd" → "pwd"
	## ">>> print('hi')" → "print('hi')"
	for sep in ["% ", "$ ", "> ", "# "]:
		var idx := raw_command.rfind(sep)
		if idx >= 0:
			return raw_command.substr(idx + sep.length())
	return raw_command


func _format_virtual_for_injection() -> String:
	var result: PackedStringArray = ["```tool-call"]
	result.append(tool_name)

	# Format key arguments (skip very long values)
	for key in tool_arguments:
		var val = tool_arguments[key]
		var val_str: String = str(val)
		if val_str.length() > 200:
			val_str = val_str.substr(0, 197) + "..."
		result.append("%s: %s" % [key, val_str])

	# Format result summary
	if not tool_result.is_empty():
		var success = tool_result.get("success", null)
		if success != null:
			var summary: String = "→ %s" % ("success" if success else "failed")
			# Add key result metrics
			for key in ["replacements", "bytes_written", "total_matches", "lines_read", "exit_code", "cwd"]:
				if tool_result.has(key):
					summary += ", %s: %s" % [key, str(tool_result[key])]
			if tool_result.has("error"):
				summary += ", error: %s" % tool_result["error"]
			result.append(summary)

	result.append("```")
	return "\n".join(result)


static func create_virtual(p_tool_name: String, p_arguments: Dictionary, p_result: Dictionary) -> TerminalBlock:
	var block := TerminalBlock.new()
	block.block_type = BlockType.VIRTUAL
	block.tool_name = p_tool_name
	block.tool_arguments = p_arguments
	block.tool_result = p_result
	block.timestamp = int(Time.get_unix_time_from_system())
	return block


func estimate_tokens(terminal_node = null) -> int:
	## Token estimate: chars / 4 when terminal available, else row-based fallback.
	if block_type == BlockType.VIRTUAL:
		var text := _format_virtual_for_injection()
		return maxi(1, text.length() / 4)
	if terminal_node:
		var text := get_text(terminal_node)
		if not text.is_empty():
			return maxi(1, text.length() / 4)
	# Fallback: estimate ~40 chars per row average, / 4 tokens per char
	var rows := row_count()
	if rows <= 0:
		return 0
	return rows * 10


func estimate_tokens_for_ranges(terminal_node) -> int:
	## Estimate tokens only for the marked ranges (partial injection).
	## If no marked ranges, returns 0.
	if marked_ranges.is_empty():
		return 0
	if not terminal_node or not terminal_node.terminal:
		# Fallback: estimate from range row counts
		var total_rows: int = 0
		for range_dict in marked_ranges:
			var sr: int = range_dict.get("start_row", 0)
			var er: int = range_dict.get("end_row", sr)
			total_rows += maxi(0, er - sr + 1)
		return total_rows * 10

	# Extract text only for the marked ranges
	var parts: PackedStringArray = []
	for range_dict in marked_ranges:
		var sr: int = range_dict.get("start_row", 0)
		var er: int = range_dict.get("end_row", sr)
		for row in range(sr, er + 1):
			var line: String = ""
			for col in range(terminal_node._cols):
				var cell: Dictionary = terminal_node.terminal.get_cell(col, row)
				if cell.is_empty():
					break
				var cp: int = cell.get("codepoint", 0)
				if cp == 0:
					break
				elif cp >= 32:
					line += char(cp)
			parts.append(line.rstrip(" "))
	var text := "\n".join(parts)
	if text.is_empty():
		return 0
	return maxi(1, text.length() / 4)

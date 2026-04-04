class_name MCPCodeTools
extends MCPToolModule
## MCP tool module for file system and bash code tools.
## Handles file read/write/edit/glob/grep, bash execution, and cwd management.


var _cwd_tool: CwdTool = CwdTool.new()
var _write_tool: WriteTool
## Agent ID for signal emission (set externally by MCPServer for HTTP requests)
var _current_agent_id: String = ""


func _init(mcp_server = null) -> void:
	super._init(mcp_server)
	_write_tool = WriteTool.new(_cwd_tool)


func get_tool_names() -> Array[String]:
	return [
		"minerva_file_read",
		"minerva_file_write",
		"minerva_file_edit",
		"minerva_file_glob",
		"minerva_file_grep",
		"minerva_bash",
		"minerva_cwd",
	]


func register_tools() -> void:
	server._register_tool("minerva_file_read",
		"Read file contents with optional line offset and limit. Returns numbered lines.",
		{"type": "object", "properties": {
			"path": {"type": "string", "description": "Absolute file path"},
			"offset": {"type": "integer", "description": "Start line (0-based, default 0)"},
			"limit": {"type": "integer", "description": "Max lines to read (default 2000)"},
		}, "required": ["path"]}, "codetools")

	server._register_tool("minerva_file_write",
		"Write content to a file. Creates parent directories if needed.",
		{"type": "object", "properties": {
			"path": {"type": "string", "description": "File path (absolute or relative to cwd)"},
			"content": {"type": "string", "description": "Content to write"},
		}, "required": ["path", "content"]}, "codetools")

	server._register_tool("minerva_file_edit",
		"Make targeted string replacements in a file. old_string must be unique unless replace_all is true.",
		{"type": "object", "properties": {
			"path": {"type": "string", "description": "File path"},
			"old_string": {"type": "string", "description": "String to find"},
			"new_string": {"type": "string", "description": "Replacement string"},
			"replace_all": {"type": "boolean", "description": "Replace all occurrences (default false)"},
		}, "required": ["path", "old_string", "new_string"]}, "codetools")

	server._register_tool("minerva_file_glob",
		"Find files matching a glob pattern. Supports *, **, and ? wildcards.",
		{"type": "object", "properties": {
			"pattern": {"type": "string", "description": "Glob pattern (e.g., **/*.gd)"},
			"path": {"type": "string", "description": "Base directory (default: cwd)"},
			"limit": {"type": "integer", "description": "Max results (default 100)"},
		}, "required": ["pattern"]}, "codetools")

	server._register_tool("minerva_file_grep",
		"Search file contents using regex patterns.",
		{"type": "object", "properties": {
			"pattern": {"type": "string", "description": "Regex pattern"},
			"path": {"type": "string", "description": "File or directory to search (default: cwd)"},
			"glob": {"type": "string", "description": "Filter files by glob pattern"},
			"type": {"type": "string", "description": "Filter by file type (py, gd, js, ts, etc.)"},
			"ignore_case": {"type": "boolean", "description": "Case-insensitive search"},
			"context_lines": {"type": "integer", "description": "Lines of context around match"},
			"limit": {"type": "integer", "description": "Max matches (default 100)"},
		}, "required": ["pattern"]}, "codetools")

	server._register_tool("minerva_bash",
		"Execute a shell command and return its output. Runs in the visible terminal PTY if available (command appears in terminal UI), otherwise headless. Use this for normal commands like 'ls', 'echo hi', 'git status'. For interactive programs that need ongoing input (like launching 'claude'), use minerva_terminal_write instead.",
		{"type": "object", "properties": {
			"command": {"type": "string", "description": "Shell command to execute (Enter is handled automatically)"},
			"working_dir": {"type": "string", "description": "Working directory (default: cwd)"},
			"timeout": {"type": "integer", "description": "Timeout in ms (default 120000, max 600000)"},
		}, "required": ["command"]}, "codetools")

	server._register_tool("minerva_cwd",
		"Get or set the working directory.",
		{"type": "object", "properties": {
			"path": {"type": "string", "description": "New directory (omit to just get current)"},
		}}, "codetools")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_file_read": return _codetools_read(arguments)
		"minerva_file_write": return _codetools_write(arguments)
		"minerva_file_edit": return _codetools_edit(arguments)
		"minerva_file_glob": return _codetools_glob(arguments)
		"minerva_file_grep": return _codetools_grep(arguments)
		"minerva_bash": return await _codetools_bash(arguments)
		"minerva_cwd": return _codetools_cwd(arguments)
	return MCPToolUtils.error("Unknown tool: %s" % tool_name)


func _codetools_read(arguments: Dictionary) -> Dictionary:
	var path: String = arguments.get("path", "")
	if path.is_empty():
		return {"success": false, "error": "path is required"}
	if not path.is_absolute_path():
		path = _cwd_tool.get_cwd().path_join(path)
	var offset: int = MCPToolUtils.coerce_int(arguments.get("offset", 0))
	var limit: int = MCPToolUtils.coerce_int(arguments.get("limit", 0))
	var result := ReadTool.read_file(path, offset, limit)
	SingletonObject.mcp_tool_executed.emit("minerva_file_read", arguments, result, _current_agent_id)
	return result


func _codetools_write(arguments: Dictionary) -> Dictionary:
	var path: String = arguments.get("path", "")
	var content: String = arguments.get("content", "")
	if path.is_empty():
		return {"success": false, "error": "path is required"}
	if not path.is_absolute_path():
		path = _cwd_tool.get_cwd().path_join(path)
	var result := _write_tool.write_file(path, content)
	SingletonObject.mcp_tool_executed.emit("minerva_file_write", arguments, result, _current_agent_id)
	return result


func _codetools_edit(arguments: Dictionary) -> Dictionary:
	var path: String = arguments.get("path", "")
	if path.is_empty():
		return MCPToolUtils.error("path is required")
	if not path.is_absolute_path():
		path = _cwd_tool.get_cwd().path_join(path)
	var result := EditTool.edit_file(
		path,
		arguments.get("old_string", ""),
		arguments.get("new_string", ""),
		arguments.get("replace_all", false),
	)
	SingletonObject.mcp_tool_executed.emit("minerva_file_edit", arguments, result, _current_agent_id)
	return result


func _codetools_glob(arguments: Dictionary) -> Dictionary:
	var pattern: String = arguments.get("pattern", "")
	var base_dir: String = arguments.get("path", _cwd_tool.get_cwd())
	var limit: int = MCPToolUtils.coerce_int(arguments.get("limit", 100))
	var result := GlobTool.glob_files(pattern, base_dir, limit)
	SingletonObject.mcp_tool_executed.emit("minerva_file_glob", arguments, result, _current_agent_id)
	return result


func _codetools_grep(arguments: Dictionary) -> Dictionary:
	var path: String = arguments.get("path", _cwd_tool.get_cwd())
	if not path.is_absolute_path():
		path = _cwd_tool.get_cwd().path_join(path)
	var result := GrepTool.grep_files(
		arguments.get("pattern", ""),
		path,
		arguments.get("glob", ""),
		arguments.get("type", ""),
		arguments.get("ignore_case", false),
		MCPToolUtils.coerce_int(arguments.get("context_lines", 0)),
		MCPToolUtils.coerce_int(arguments.get("limit", 100)),
	)
	SingletonObject.mcp_tool_executed.emit("minerva_file_grep", arguments, result, _current_agent_id)
	return result


func _codetools_bash(arguments: Dictionary) -> Dictionary:
	var command: String = arguments.get("command", "")
	if command.is_empty():
		return {"success": false, "error": "command is required"}

	# Policy check first
	var policy_error: String = CodeToolsPolicy.get_instance().check_bash_command(command)
	if not policy_error.is_empty():
		var result: Dictionary = {"success": false, "error": policy_error, "exit_code": -1}
		SingletonObject.mcp_tool_executed.emit("minerva_bash", arguments, result, _current_agent_id)
		return result

	# Try to route through a visible terminal PTY
	var term: TerminalNew = _find_active_terminal()
	if term:
		var working_dir: String = arguments.get("working_dir", "")
		var full_command: String = command
		if not working_dir.is_empty() and working_dir != _cwd_tool.get_cwd():
			full_command = "cd %s && %s" % [working_dir, command]

		var result: Dictionary = await term.execute_command(full_command)
		SingletonObject.mcp_tool_executed.emit("minerva_bash", arguments, result, _current_agent_id)
		return result

	# Fallback: headless execution if no terminal available
	var working_dir: String = arguments.get("working_dir", _cwd_tool.get_cwd())
	if not working_dir.is_absolute_path():
		working_dir = _cwd_tool.get_cwd().path_join(working_dir)
	var timeout_ms: int = MCPToolUtils.coerce_int(arguments.get("timeout", BashTool.DEFAULT_TIMEOUT_MS))
	var result: Dictionary = BashTool.run_command(command, working_dir, timeout_ms)
	result["success"] = result["exit_code"] == 0
	SingletonObject.mcp_tool_executed.emit("minerva_bash", arguments, result, _current_agent_id)
	return result


func _find_active_terminal() -> TerminalNew:
	## Find the active visible terminal for PTY command execution.
	var terminals: Array = SingletonObject.get_tree().get_nodes_in_group("terminal_pane")
	for term in terminals:
		if term is TerminalNew and term.is_visible_in_tree() and term._terminal_available:
			return term
	return null


func _codetools_cwd(arguments: Dictionary) -> Dictionary:
	var path: String = arguments.get("path", "")
	if path.is_empty():
		var result := {"success": true, "cwd": _cwd_tool.get_cwd()}
		SingletonObject.mcp_tool_executed.emit("minerva_cwd", arguments, result, _current_agent_id)
		return result
	var result := _cwd_tool.set_cwd(path)
	SingletonObject.mcp_tool_executed.emit("minerva_cwd", arguments, result, _current_agent_id)
	return result

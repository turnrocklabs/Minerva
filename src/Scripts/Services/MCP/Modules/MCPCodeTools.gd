class_name MCPCodeTools
extends MCPToolModule
## MCP tool module for filesystem search and bash execution.
## Handles file glob/grep, bash, and cwd management. Read/write/edit moved to
## minerva_doc_* (path-canonical, buffer-routed) per buffer-canonical DCR T8.


var _cwd_tool: CwdTool = CwdTool.new()
var _write_tool: WriteTool
## Agent ID for signal emission (set externally by MCPServer for HTTP requests)
var _current_agent_id: String = ""


func _init(mcp_server = null) -> void:
	super._init(mcp_server)
	_write_tool = WriteTool.new(_cwd_tool)


func get_tool_names() -> Array[String]:
	return [
		"minerva_file_glob",
		"minerva_file_grep",
		"minerva_bash",
		"minerva_cwd",
	]


func register_tools() -> void:
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
		"minerva_file_glob": return _codetools_glob(arguments)
		"minerva_file_grep": return _codetools_grep(arguments)
		"minerva_bash": return await _codetools_bash(arguments)
		"minerva_cwd": return _codetools_cwd(arguments)
	return MCPToolUtils.error("Unknown tool: %s" % tool_name)


## Emit the activity-log signal via runtime autoload lookup. Bare `SingletonObject.X`
## references at parse time poison `--script` headless tests (the parser can't resolve
## autoload identifiers, body-level use makes the script uninstantiable). Looking the
## node up by string keeps the parser happy while preserving production behavior.
static func _emit_tool_executed(tool_name: String, arguments: Dictionary, result: Dictionary, agent_id: String) -> void:
	var ml := Engine.get_main_loop()
	if not (ml is SceneTree):
		return
	var so := (ml as SceneTree).root.get_node_or_null("SingletonObject")
	if so and so.has_method("emit_mcp_tool_executed"):
		so.emit_mcp_tool_executed(tool_name, arguments, result, agent_id)


## Expand Godot virtual paths (`res://`, `user://`) to absolute OS paths so the
## underlying CodeTools (which use OS FileAccess, DirAccess) can resolve them.
static func _resolve_virtual_path(path: String) -> String:
	if path.begins_with("user://") or path.begins_with("res://"):
		return ProjectSettings.globalize_path(path)
	return path


func _codetools_glob(arguments: Dictionary) -> Dictionary:
	var pattern: String = arguments.get("pattern", "")
	var base_dir: String = arguments.get("path", _cwd_tool.get_cwd())
	base_dir = _resolve_virtual_path(base_dir)
	var limit: int = MCPToolUtils.coerce_int(arguments.get("limit", 100))
	var result := GlobTool.glob_files(pattern, base_dir, limit)
	_emit_tool_executed("minerva_file_glob", arguments, result, _current_agent_id)
	return result


func _codetools_grep(arguments: Dictionary) -> Dictionary:
	var path: String = arguments.get("path", _cwd_tool.get_cwd())
	path = _resolve_virtual_path(path)
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
	_emit_tool_executed("minerva_file_grep", arguments, result, _current_agent_id)
	return result


func _codetools_bash(arguments: Dictionary) -> Dictionary:
	var command: String = arguments.get("command", "")
	if command.is_empty():
		return {"success": false, "error": "command is required"}

	# Policy check first
	var policy_error: String = CodeToolsPolicy.get_instance().check_bash_command(command)
	if not policy_error.is_empty():
		var policy_result: Dictionary = {"success": false, "error": policy_error, "exit_code": -1}
		_emit_tool_executed("minerva_bash", arguments, policy_result, _current_agent_id)
		return policy_result

	# Try to route through a visible terminal PTY
	var term: TerminalNew = _find_active_terminal()
	if term:
		var terminal_working_dir: String = arguments.get("working_dir", "")
		var full_command: String = command
		if not terminal_working_dir.is_empty() and terminal_working_dir != _cwd_tool.get_cwd():
			full_command = "cd %s && %s" % [terminal_working_dir, command]

		var terminal_result: Dictionary = await term.execute_command(full_command)
		_emit_tool_executed("minerva_bash", arguments, terminal_result, _current_agent_id)
		return terminal_result

	# Fallback: headless execution if no terminal available
	var resolved_working_dir: String = arguments.get("working_dir", _cwd_tool.get_cwd())
	if not resolved_working_dir.is_absolute_path():
		resolved_working_dir = _cwd_tool.get_cwd().path_join(resolved_working_dir)
	var timeout_ms: int = MCPToolUtils.coerce_int(arguments.get("timeout", BashTool.DEFAULT_TIMEOUT_MS))
	var command_result: Dictionary = BashTool.run_command(command, resolved_working_dir, timeout_ms)
	command_result["success"] = command_result["exit_code"] == 0
	_emit_tool_executed("minerva_bash", arguments, command_result, _current_agent_id)
	return command_result


func _find_active_terminal() -> TerminalNew:
	## Find the active visible terminal for PTY command execution.
	var ml := Engine.get_main_loop()
	if not (ml is SceneTree):
		return null
	var terminals: Array = (ml as SceneTree).get_nodes_in_group("terminal_pane")
	for term in terminals:
		if term is TerminalNew and term.is_visible_in_tree() and term._terminal_available:
			return term
	return null


func _codetools_cwd(arguments: Dictionary) -> Dictionary:
	var path: String = arguments.get("path", "")
	var cwd_result: Dictionary
	if path.is_empty():
		cwd_result = {"success": true, "cwd": _cwd_tool.get_cwd()}
	else:
		cwd_result = _cwd_tool.set_cwd(path)
	_emit_tool_executed("minerva_cwd", arguments, cwd_result, _current_agent_id)
	return cwd_result

class_name MCPTerminalTools
extends MCPToolModule
## MCP tool module for Terminal PTY tools.
## Handles listing, creating, closing, reading, writing, and waiting on terminal tabs.


func get_tool_names() -> Array[String]:
	return [
		"minerva_terminal_list",
		"minerva_terminal_create",
		"minerva_terminal_close",
		"minerva_terminal_read",
		"minerva_terminal_write",
		"minerva_terminal_wait",
	]


func register_tools() -> void:
	server._register_tool("minerva_terminal_list",
		"List all open terminal tabs with their IDs, names, and dimensions.",
		{"type": "object", "properties": {}}, "terminal")

	server._register_tool("minerva_terminal_write",
		"Send text/keystrokes to a terminal PTY. Non-blocking. IMPORTANT: Use \\r for Enter (not \\n). Common escapes: \\r=Enter, \\t=Tab, \\x03=Ctrl+C. Example: 'ls -la\\r' to run a command.",
		{"type": "object", "properties": {
			"text": {"type": "string", "description": "Text to send. Use \\r at end to submit commands (Enter key). Example: 'echo hello\\r'"},
			"terminal_id": {"type": "string", "description": "Terminal ID (from terminal_list). Empty = active terminal."},
		}, "required": ["text"]}, "terminal")

	server._register_tool("minerva_terminal_read",
		"Read terminal screen content as plain text. Returns the visible viewport or a specific row range from scrollback.",
		{"type": "object", "properties": {
			"terminal_id": {"type": "string", "description": "Terminal ID (from terminal_list). Empty = active terminal."},
			"start_row": {"type": "integer", "description": "Start row in scrollback (0 = top of history). Omit for visible viewport."},
			"end_row": {"type": "integer", "description": "End row in scrollback. Omit for visible viewport."},
		}}, "terminal")

	server._register_tool("minerva_terminal_create",
		"Create a new terminal tab. Returns its ID. Next steps: use minerva_terminal_write to send commands (use \\r for Enter), minerva_terminal_read to see output.",
		{"type": "object", "properties": {
			"name": {"type": "string", "description": "Tab name (optional)"},
		}}, "terminal")

	server._register_tool("minerva_terminal_close",
		"Close a terminal tab by ID.",
		{"type": "object", "properties": {
			"terminal_id": {"type": "string", "description": "Terminal ID to close"},
		}, "required": ["terminal_id"]}, "terminal")

	server._register_tool("minerva_terminal_wait",
		"Wait for new output on a terminal, then return the screen content. Waits until output settles (no new data for settle_ms) or timeout.",
		{"type": "object", "properties": {
			"terminal_id": {"type": "string", "description": "Terminal ID. Empty = active terminal."},
			"timeout_ms": {"type": "integer", "description": "Max wait time in ms (default 30000)"},
			"settle_ms": {"type": "integer", "description": "Wait for output to stop for this long before returning (default 500)"},
		}}, "terminal")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_terminal_list": return _terminal_list(arguments)
		"minerva_terminal_create": return _terminal_create(arguments)
		"minerva_terminal_close": return _terminal_close(arguments)
		"minerva_terminal_read": return _terminal_read(arguments)
		"minerva_terminal_write": return _terminal_write(arguments)
		"minerva_terminal_wait": return await _terminal_wait(arguments)
	return MCPToolUtils.error("Unknown tool: %s" % tool_name)


func _find_terminal_by_id(terminal_id: String = "") -> TerminalNew:
	var terminals: Array = SingletonObject.get_tree().get_nodes_in_group("terminal_pane")
	if terminal_id.is_empty():
		# Return first visible terminal
		for term in terminals:
			if term is TerminalNew and term.is_visible_in_tree() and term._terminal_available:
				return term
		# Return any available terminal
		for term in terminals:
			if term is TerminalNew and term._terminal_available:
				return term
		return null
	# Find by instance ID
	var target_id: int = int(terminal_id)
	for term in terminals:
		if term is TerminalNew and term.get_instance_id() == target_id:
			return term
	return null


func _find_active_terminal() -> TerminalNew:
	var terminals: Array = SingletonObject.get_tree().get_nodes_in_group("terminal_pane")
	for term in terminals:
		if term is TerminalNew and term.is_visible_in_tree() and term._terminal_available:
			return term
	return null


func _terminal_list(_arguments: Dictionary) -> Dictionary:
	var terminals: Array = SingletonObject.get_tree().get_nodes_in_group("terminal_pane")
	var result: Array = []
	for term in terminals:
		if term is TerminalNew and term._terminal_available:
			result.append({
				"id": str(term.get_instance_id()),
				"name": term.name,
				"visible": term.is_visible_in_tree(),
				"cols": term._cols,
				"rows": term._rows,
			})
	return {"success": true, "terminals": result, "count": result.size()}


func _terminal_write(arguments: Dictionary) -> Dictionary:
	var text: String = arguments.get("text", "")
	if text.is_empty():
		return {"success": false, "error": "text is required"}
	var term: TerminalNew = _find_terminal_by_id(arguments.get("terminal_id", ""))
	if not term:
		return {"success": false, "error": "No terminal found"}
	# Process escape sequences so \r, \n, \t, \x03 etc. become real control chars
	text = text.c_unescape()
	term.terminal.write_input(text)
	return {"success": true, "bytes_sent": text.length()}


func _terminal_read(arguments: Dictionary) -> Dictionary:
	var term: TerminalNew = _find_terminal_by_id(arguments.get("terminal_id", ""))
	if not term:
		return {"success": false, "error": "No terminal found"}
	if not term.terminal or not term._terminal_available:
		return {"success": false, "error": "Terminal not initialized"}

	var has_range: bool = arguments.has("start_row") or arguments.has("end_row")

	if has_range:
		# Read specific row range from scrollback (screen-absolute)
		var start_row: int = int(arguments.get("start_row", 0))
		var end_row: int = int(arguments.get("end_row", start_row))
		var lines: PackedStringArray = []
		for row in range(start_row, end_row + 1):
			lines.append(term._extract_row_text_screen(row))
		return {
			"success": true,
			"content": "\n".join(lines),
			"rows": lines.size(),
			"start_row": start_row,
			"end_row": end_row,
		}
	else:
		# Read visible viewport
		var info: Dictionary = term.terminal.get_scroll_info()
		var total_rows: int = info.get("total_rows", 0)
		var viewport_rows: int = info.get("viewport_rows", term._rows)

		# Viewport starts at total_rows - viewport_rows (when scrolled to bottom)
		var viewport_start: int = maxi(0, total_rows - viewport_rows)

		var lines: PackedStringArray = []
		for row in range(viewport_start, total_rows):
			lines.append(term._extract_row_text_screen(row))

		# Trim trailing empty lines
		while lines.size() > 0 and lines[lines.size() - 1].strip_edges().is_empty():
			lines.remove_at(lines.size() - 1)

		return {
			"success": true,
			"content": "\n".join(lines),
			"rows": lines.size(),
			"cols": term._cols,
			"total_scrollback_rows": total_rows,
			"viewport_rows": viewport_rows,
		}


func _terminal_create(arguments: Dictionary) -> Dictionary:
	# Find a TerminalTabGroup to add to
	var terminals: Array = SingletonObject.get_tree().get_nodes_in_group("terminal_pane")

	# Find the TerminalTabGroup parent of any existing terminal
	var tab_group: TerminalTabGroup = null
	for term in terminals:
		if term is TerminalNew:
			var parent = term.get_parent()
			while parent:
				if parent is TerminalTabGroup:
					tab_group = parent
					break
				parent = parent.get_parent()
			if tab_group:
				break

	if not tab_group:
		return {"success": false, "error": "No terminal tab group found. Is the terminal panel open?"}

	var new_term: TerminalNew = tab_group.add_terminal()
	var tab_name: String = arguments.get("name", "")
	if not tab_name.is_empty() and tab_group._tab_bar:
		var idx: int = tab_group.tab_count() - 1
		tab_group._tab_bar.set_tab_title(idx, tab_name)

	return {"success": true, "id": str(new_term.get_instance_id()), "name": new_term.name}


func _terminal_close(arguments: Dictionary) -> Dictionary:
	var terminal_id: String = arguments.get("terminal_id", "")
	if terminal_id.is_empty():
		return {"success": false, "error": "terminal_id is required"}

	var target_id: int = int(terminal_id)
	var terminals: Array = SingletonObject.get_tree().get_nodes_in_group("terminal_pane")
	for term in terminals:
		if term is TerminalNew and term.get_instance_id() == target_id:
			# Find parent TabGroup and close
			var parent = term.get_parent()
			while parent:
				if parent is TerminalTabGroup:
					# Find tab index
					for i in range(parent._tab_bar.tab_count):
						if parent._tab_bar.get_tab_metadata(i) == term:
							parent.close_terminal(i)
							return {"success": true, "message": "Terminal closed"}
					break
				parent = parent.get_parent()
			return {"success": false, "error": "Could not find terminal's tab group"}

	return {"success": false, "error": "Terminal not found: %s" % terminal_id}


func _terminal_wait(arguments: Dictionary) -> Dictionary:
	var term: TerminalNew = _find_terminal_by_id(arguments.get("terminal_id", ""))
	if not term:
		return {"success": false, "error": "No terminal found"}
	if not term.terminal or not term._terminal_available:
		return {"success": false, "error": "Terminal not initialized"}

	var timeout_ms: int = int(arguments.get("timeout_ms", 30000))
	var settle_ms: int = int(arguments.get("settle_ms", 500))

	# Wait for output to appear and settle
	var timed_out: bool = false
	var got_output: bool = false

	# Use a simple polling approach: check for vt_state_changed via a flag
	var output_changed: bool = false
	var on_change := func():
		output_changed = true

	term.terminal.vt_state_changed.connect(on_change)

	var start_time: int = Time.get_ticks_msec()
	var last_change_time: int = 0

	# Poll loop
	while true:
		var elapsed: int = Time.get_ticks_msec() - start_time
		if elapsed >= timeout_ms:
			timed_out = true
			break

		if output_changed:
			output_changed = false
			got_output = true
			last_change_time = Time.get_ticks_msec()

		# If we got output and it's been quiet for settle_ms, we're done
		if got_output and (Time.get_ticks_msec() - last_change_time) >= settle_ms:
			break

		# Yield to let the engine process
		await term.get_tree().process_frame

	term.terminal.vt_state_changed.disconnect(on_change)

	# Read the screen content
	var read_result: Dictionary = _terminal_read({"terminal_id": arguments.get("terminal_id", "")})

	read_result["timed_out"] = timed_out
	read_result["waited_ms"] = Time.get_ticks_msec() - start_time
	return read_result

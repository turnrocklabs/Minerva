class_name MCPTerminalTools
extends MCPToolModule
## MCP tool module for Terminal PTY tools.
## Handles listing, creating, closing, reading, writing, waiting on, and
## promoting/demoting terminal sessions.
##
## chat-passthrough T2: terminal LOOKUP routes through the
## TerminalSessionRegistry (not the UI tree), so read/write/wait/close work for
## BACKGROUND sessions that have no TerminalNew view. Only tab/view concerns
## (visible create, promote, demote, close-of-a-tab) touch the UI tree.
## Sessions/registry are duck-typed (no TerminalSession type annotations) so
## this file parses in isolated --script harnesses.


func get_tool_names() -> Array[String]:
	return [
		"minerva_terminal_list",
		"minerva_terminal_create",
		"minerva_terminal_close",
		"minerva_terminal_read",
		"minerva_terminal_write",
		"minerva_terminal_wait",
		"minerva_terminal_promote",
		"minerva_terminal_demote",
	]


func register_tools() -> void:
	server._register_tool("minerva_terminal_list",
		"List all terminal sessions with their IDs, names, and dimensions. Includes background sessions: visible=false means no UI tab (use minerva_terminal_promote to show it). alive=false means the shell has exited (scrollback still readable).",
		{"type": "object", "properties": {}}, "terminal")

	server._register_tool("minerva_terminal_write",
		"Send text/keystrokes to a terminal PTY. Non-blocking. IMPORTANT: Use \\r for Enter (not \\n). Common escapes: \\r=Enter, \\t=Tab, \\x03=Ctrl+C. Example: 'ls -la\\r' to run a command.",
		{"type": "object", "properties": {
			"text": {"type": "string", "description": "Text to send. Use \\r at end to submit commands (Enter key). Example: 'echo hello\\r'"},
			"terminal_id": {"type": "string", "description": "Terminal ID (from terminal_list). Empty = active terminal."},
			"raw": {"type": "boolean", "description": "Send text byte-for-byte without unescaping \\r/\\n/\\t etc. Use when the text already contains real control characters (default false)."},
		}, "required": ["text"]}, "terminal")

	server._register_tool("minerva_terminal_read",
		"Read terminal screen content as plain text. Returns the visible viewport or a specific row range from scrollback. Works on background (no-tab) sessions too.",
		{"type": "object", "properties": {
			"terminal_id": {"type": "string", "description": "Terminal ID (from terminal_list). Empty = active terminal."},
			"start_row": {"type": "integer", "description": "Start row in scrollback (0 = top of history). Omit for visible viewport."},
			"end_row": {"type": "integer", "description": "End row in scrollback. Omit for visible viewport."},
		}}, "terminal")

	server._register_tool("minerva_terminal_create",
		"Create a new terminal. Returns its ID. By default opens a visible tab (requires the terminal panel). With background=true the session runs headless with no tab — works even when the terminal panel is closed; promote it later to show it. Next steps: minerva_terminal_write to send commands (use \\r for Enter), minerva_terminal_read to see output.",
		{"type": "object", "properties": {
			"name": {"type": "string", "description": "Tab/session name (optional)"},
			"background": {"type": "boolean", "description": "Create a headless background session with no UI tab (default false)"},
		}}, "terminal")

	server._register_tool("minerva_terminal_close",
		"Close a terminal by ID. Closes the tab (if any) AND terminates the session/PTY.",
		{"type": "object", "properties": {
			"terminal_id": {"type": "string", "description": "Terminal ID to close"},
		}, "required": ["terminal_id"]}, "terminal")

	server._register_tool("minerva_terminal_wait",
		"Wait for new output on a terminal, then return the screen content. Waits until output settles (no new data for settle_ms) or timeout. Result includes bell_rung (a standalone BEL arrived during the wait) and, if the shell died, shell_exited + shell_exit_code. Works on background sessions.",
		{"type": "object", "properties": {
			"terminal_id": {"type": "string", "description": "Terminal ID. Empty = active terminal."},
			"timeout_ms": {"type": "integer", "description": "Max wait time in ms (default 30000)"},
			"settle_ms": {"type": "integer", "description": "Wait for output to stop for this long before returning (default 500)"},
		}}, "terminal")

	server._register_tool("minerva_terminal_promote",
		"Show a background terminal session in the UI: attaches it to a visible tab (scrollback intact) and opens the terminal panel if it is closed. No-op success if it already has a tab.",
		{"type": "object", "properties": {
			"terminal_id": {"type": "string", "description": "Terminal ID (from terminal_list)"},
		}, "required": ["terminal_id"]}, "terminal")

	server._register_tool("minerva_terminal_demote",
		"Hide a terminal: removes its UI tab WITHOUT terminating the session — the shell keeps running in the background and read/write/wait still work. No-op success if it is already background.",
		{"type": "object", "properties": {
			"terminal_id": {"type": "string", "description": "Terminal ID (from terminal_list)"},
		}, "required": ["terminal_id"]}, "terminal")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_terminal_list": return _terminal_list(arguments)
		"minerva_terminal_create": return _terminal_create(arguments)
		"minerva_terminal_close": return _terminal_close(arguments)
		"minerva_terminal_read": return _terminal_read(arguments)
		"minerva_terminal_write": return _terminal_write(arguments)
		"minerva_terminal_wait": return await _terminal_wait(arguments)
		"minerva_terminal_promote": return _terminal_promote(arguments)
		"minerva_terminal_demote": return _terminal_demote(arguments)
	return MCPToolUtils.error("Unknown tool: %s" % tool_name)


# ── Lookup (registry-first; UI tree only for view concerns) ────────────

func _get_registry():
	return SingletonObject.get_terminal_session_registry()


## Resolve a terminal id to a TerminalSession (duck-typed).
## Empty id = "active terminal": the session behind the first visible attached
## view (today's semantics), else the first alive session, else any session.
## Non-empty id: registry lookup, with a view-instance-id fallback for callers
## holding a pre-T2 id.
func _resolve_session(terminal_id: String = ""):
	var registry = _get_registry()
	if terminal_id.is_empty():
		var view := _find_active_view()
		if view and view.get_session():
			return view.get_session()
		if registry:
			var sessions: Array = registry.list_sessions()
			for session in sessions:
				if session.is_alive():
					return session
			if sessions.size() > 0:
				return sessions[0]
		return null
	if registry and registry.has_session(terminal_id):
		return registry.get_session(terminal_id)
	# Back-compat: ids used to be TerminalNew view instance ids.
	var target_id: int = int(terminal_id)
	for term in SingletonObject.get_tree().get_nodes_in_group("terminal_pane"):
		if term is TerminalNew and term.get_instance_id() == target_id:
			return term.get_session()
	return null


## Shared lookup for CapabilityBroker's host.terminal.exec (chat-passthrough
## T3): resolve where a one-shot command should run via the SAME registry path
## as read/write/wait — the broker must not duplicate resolution logic.
## Returns {"session": ..., "view": ...}; either value may be null.
##   - Named id: registry lookup (incl. the stale view-id fallback) + the view
##     currently attached to that session (null for background sessions).
##   - Empty id: exec's historical preference — the visible UI terminal, else
##     any available attached view. NEVER an unnamed background session: a
##     one-shot exec must not type into an agent-owned background terminal the
##     caller didn't name (and the subprocess fallback gives a real exit code).
func resolve_exec_target(terminal_id: String) -> Dictionary:
	if not terminal_id.is_empty():
		var session = _resolve_session(terminal_id)
		return {"session": session, "view": _find_view_for_session(session)}
	var view := _find_active_view()
	if view == null:
		for term in SingletonObject.get_tree().get_nodes_in_group("terminal_pane"):
			if term is TerminalNew and term._terminal_available:
				view = term
				break
	if view == null:
		return {"session": null, "view": null}
	return {"session": view.get_session(), "view": view}


func _find_active_view() -> TerminalNew:
	for term in SingletonObject.get_tree().get_nodes_in_group("terminal_pane"):
		if term is TerminalNew and term.is_visible_in_tree() and term._terminal_available:
			return term
	return null


## The TerminalNew view currently attached to this session, or null if the
## session is background. "Visible" in terminal_list == this returns non-null.
func _find_view_for_session(session) -> TerminalNew:
	if session == null:
		return null
	for term in SingletonObject.get_tree().get_nodes_in_group("terminal_pane"):
		if term is TerminalNew and term.is_inside_tree() and term.get_session() == session:
			return term
	return null


## First TerminalTabGroup in the tree (group-registered in _ready; legacy
## parent-walk fallback for groups created before that registration runs).
func _find_tab_group() -> TerminalTabGroup:
	var tree := SingletonObject.get_tree()
	for g in tree.get_nodes_in_group("terminal_tab_group"):
		if g is TerminalTabGroup:
			return g
	for term in tree.get_nodes_in_group("terminal_pane"):
		if term is TerminalNew:
			var parent = term.get_parent()
			while parent:
				if parent is TerminalTabGroup:
					return parent
				parent = parent.get_parent()
	return null


## The tab group + tab index hosting this view: {group, tab}. group is null when
## the view is not under a TerminalTabGroup; tab is -1 when not in its TabBar.
func _locate_view_tab(view: TerminalNew) -> Dictionary:
	var parent = view.get_parent()
	while parent:
		if parent is TerminalTabGroup:
			for i in range(parent._tab_bar.tab_count):
				if parent._tab_bar.get_tab_metadata(i) == view:
					return {"group": parent, "tab": i}
			return {"group": parent, "tab": -1}
		parent = parent.get_parent()
	return {"group": null, "tab": -1}


## Open the terminal pane so the user sees it (promote = "show me this
## terminal"). Reuses MainUI.set_terminal_pane_visible — the same path the
## View menu uses. No-op headless / before MainScene exists.
func _show_terminal_pane() -> void:
	var main_ui = SingletonObject.get("main_ui")
	if main_ui != null and main_ui.has_method("set_terminal_pane_visible"):
		main_ui.set_terminal_pane_visible(true)


# ── Tool implementations ───────────────────────────────────────────────

func _terminal_list(_arguments: Dictionary) -> Dictionary:
	var result: Array = []
	var registry = _get_registry()
	if registry:
		for session in registry.list_sessions():
			if not session.terminal_available:
				continue
			result.append({
				"id": session.terminal_id,
				"name": session.session_name,
				"visible": _find_view_for_session(session) != null,
				"alive": session.is_alive(),
				"cols": session.get_cols(),
				"rows": session.get_rows(),
			})
	return {"success": true, "terminals": result, "count": result.size()}


func _terminal_write(arguments: Dictionary) -> Dictionary:
	var text: String = arguments.get("text", "")
	if text.is_empty():
		return {"success": false, "error": "text is required"}
	var session = _resolve_session(str(arguments.get("terminal_id", "")))
	if session == null:
		return {"success": false, "error": "No terminal found"}
	if not session.terminal_available:
		return {"success": false, "error": "Terminal not initialized"}
	# Process escape sequences so \r, \n, \t, \x03 etc. become real control
	# chars — unless the caller already sends real bytes (raw=true, used by
	# host.terminal.write where c_unescape would mangle literal backslashes).
	if not arguments.get("raw", false):
		text = text.c_unescape()
	session.write_input(text)
	return {"success": true, "bytes_sent": text.length()}


func _terminal_read(arguments: Dictionary) -> Dictionary:
	var session = _resolve_session(str(arguments.get("terminal_id", "")))
	if session == null:
		return {"success": false, "error": "No terminal found"}
	if not session.terminal_available:
		return {"success": false, "error": "Terminal not initialized"}

	var has_range: bool = arguments.has("start_row") or arguments.has("end_row")

	if has_range:
		# Read specific row range from scrollback (screen-absolute)
		var start_row: int = MCPToolUtils.coerce_int(arguments.get("start_row", 0))
		var end_row: int = MCPToolUtils.coerce_int(arguments.get("end_row", start_row))
		var lines: PackedStringArray = []
		for row in range(start_row, end_row + 1):
			lines.append(session.extract_row_text_screen(row))
		return {
			"success": true,
			"content": "\n".join(lines),
			"rows": lines.size(),
			"start_row": start_row,
			"end_row": end_row,
		}
	else:
		# Read visible viewport
		var info: Dictionary = session.get_scroll_info()
		var total_rows: int = info.get("total_rows", 0)
		var viewport_rows: int = info.get("viewport_rows", session.get_rows())

		# Viewport starts at total_rows - viewport_rows (when scrolled to bottom)
		var viewport_start: int = maxi(0, total_rows - viewport_rows)

		var lines: PackedStringArray = []
		for row in range(viewport_start, total_rows):
			lines.append(session.extract_row_text_screen(row))

		# Trim trailing empty lines
		while lines.size() > 0 and lines[lines.size() - 1].strip_edges().is_empty():
			lines.remove_at(lines.size() - 1)

		return {
			"success": true,
			"content": "\n".join(lines),
			"rows": lines.size(),
			"cols": session.get_cols(),
			"total_scrollback_rows": total_rows,
			"viewport_rows": viewport_rows,
		}


func _terminal_create(arguments: Dictionary) -> Dictionary:
	var tab_name: String = str(arguments.get("name", ""))
	var background: bool = bool(arguments.get("background", false))

	if background:
		# Headless session straight from the registry — no tab, no pane needed.
		var registry = _get_registry()
		if registry == null:
			return {"success": false, "error": "Terminal session registry unavailable"}
		var session = registry.create_session(
			tab_name if not tab_name.is_empty() else "Terminal", 80, 24)
		if not session.terminal_available or not session.started:
			registry.close_session(session.terminal_id)
			return {"success": false, "error": "Failed to start background terminal (extension unavailable or forkpty failed)"}
		return {"success": true, "id": session.terminal_id, "name": session.session_name, "visible": false}

	# Visible path — unchanged behaviour: requires an existing tab group.
	var tab_group: TerminalTabGroup = _find_tab_group()
	if not tab_group:
		return {"success": false, "error": "No terminal tab group found. Is the terminal panel open? (Pass background: true to create a headless terminal instead.)"}

	var new_term: TerminalNew = tab_group.add_terminal()
	if not tab_name.is_empty() and tab_group._tab_bar:
		var idx: int = tab_group.tab_count() - 1
		tab_group._tab_bar.set_tab_title(idx, tab_name)

	var session = new_term.get_session()
	var display_name: String = tab_name if not tab_name.is_empty() else str(new_term.name)
	if session:
		session.session_name = display_name
		return {"success": true, "id": session.terminal_id, "name": display_name, "visible": true}
	# Extension unavailable — keep the legacy (view-instance-id) reply.
	return {"success": true, "id": str(new_term.get_instance_id()), "name": display_name, "visible": true}


func _terminal_close(arguments: Dictionary) -> Dictionary:
	var terminal_id: String = str(arguments.get("terminal_id", ""))
	if terminal_id.is_empty():
		return {"success": false, "error": "terminal_id is required"}
	var session = _resolve_session(terminal_id)
	if session == null:
		return {"success": false, "error": "Terminal not found: %s" % terminal_id}

	var view := _find_view_for_session(session)
	if view:
		var located := _locate_view_tab(view)
		if located.group != null and located.tab >= 0:
			# Tab close = session close (close_terminal handles both).
			located.group.close_terminal(located.tab)
			return {"success": true, "message": "Terminal closed"}
		# View exists outside a tab group (test harness / direct embed):
		# detach it so it never dereferences a freed session, then fall through.
		view.detach_session()

	var registry = _get_registry()
	if registry:
		registry.close_session(session.terminal_id)
	return {"success": true, "message": "Terminal closed"}


func _terminal_promote(arguments: Dictionary) -> Dictionary:
	var terminal_id: String = str(arguments.get("terminal_id", ""))
	if terminal_id.is_empty():
		return {"success": false, "error": "terminal_id is required"}
	var session = _resolve_session(terminal_id)
	if session == null:
		return {"success": false, "error": "Terminal not found: %s" % terminal_id}

	var view := _find_view_for_session(session)
	if view:
		# Already has a tab — just surface it (select tab, open the pane).
		var located := _locate_view_tab(view)
		if located.group != null and located.tab >= 0:
			located.group._tab_bar.current_tab = located.tab
		_show_terminal_pane()
		return {"success": true, "id": session.terminal_id, "visible": true, "already_visible": true}

	var tab_group: TerminalTabGroup = _find_tab_group()
	if tab_group == null:
		# Pane may simply be closed — open it, then re-scan.
		_show_terminal_pane()
		tab_group = _find_tab_group()
	if tab_group == null:
		return {"success": false, "error": "No terminal tab group found — the terminal panel is not available in this context"}

	# Attach the session to a new tab FIRST, then show the pane: a hidden empty
	# group auto-creates a fresh terminal on becoming visible, which would race
	# us into a spurious extra shell.
	tab_group.add_terminal(session)
	if tab_group._tab_bar:
		tab_group._tab_bar.set_tab_title(tab_group.tab_count() - 1, session.session_name)
	_show_terminal_pane()
	return {"success": true, "id": session.terminal_id, "visible": true}


func _terminal_demote(arguments: Dictionary) -> Dictionary:
	var terminal_id: String = str(arguments.get("terminal_id", ""))
	if terminal_id.is_empty():
		return {"success": false, "error": "terminal_id is required"}
	var session = _resolve_session(terminal_id)
	if session == null:
		return {"success": false, "error": "Terminal not found: %s" % terminal_id}

	var view := _find_view_for_session(session)
	if view == null:
		# Already background — no-op success.
		return {"success": true, "id": session.terminal_id, "visible": false, "already_background": true}

	var located := _locate_view_tab(view)
	if located.group != null and located.tab >= 0:
		located.group.detach_terminal(located.tab)
	else:
		# View not hosted in a tab group (direct embed) — detach + free it.
		view.detach_session()
		view.queue_free()
	return {"success": true, "id": session.terminal_id, "visible": false}


func _terminal_wait(arguments: Dictionary) -> Dictionary:
	var session = _resolve_session(str(arguments.get("terminal_id", "")))
	if session == null:
		return {"success": false, "error": "No terminal found"}
	if not session.terminal_available:
		return {"success": false, "error": "Terminal not initialized"}

	var timeout_ms: int = MCPToolUtils.coerce_int(arguments.get("timeout_ms", 30000))
	var settle_ms: int = MCPToolUtils.coerce_int(arguments.get("settle_ms", 500))

	# Wait for output to appear and settle
	var timed_out: bool = false
	var got_output: bool = false
	var bell_serial_start: int = session.bell_serial

	# Use a simple polling approach: check for vt_state_changed via a flag.
	# The session re-emits the extension node's signal, so this works with no view.
	var output_state := {"changed": false}
	var on_change := func():
		output_state["changed"] = true

	session.vt_state_changed.connect(on_change)

	var start_time: int = Time.get_ticks_msec()
	var last_change_time: int = 0

	# Poll loop
	while true:
		var elapsed: int = Time.get_ticks_msec() - start_time
		if elapsed >= timeout_ms:
			timed_out = true
			break

		if output_state["changed"]:
			output_state["changed"] = false
			got_output = true
			last_change_time = Time.get_ticks_msec()

		# If we got output and it's been quiet for settle_ms, we're done
		if got_output and (Time.get_ticks_msec() - last_change_time) >= settle_ms:
			break

		# Shell died — nothing further will arrive
		if session.shell_exit_code != null:
			break

		# Yield to let the engine process
		await session.get_tree().process_frame

	session.vt_state_changed.disconnect(on_change)

	# Read the screen content
	var read_result: Dictionary = _terminal_read({"terminal_id": session.terminal_id})

	read_result["timed_out"] = timed_out
	read_result["waited_ms"] = Time.get_ticks_msec() - start_time
	# Bells that rang during the wait (e.g. an agent CLI signalling turn end).
	read_result["bell_rung"] = session.bell_serial > bell_serial_start
	if session.shell_exit_code != null:
		read_result["shell_exited"] = true
		read_result["shell_exit_code"] = session.shell_exit_code
	return read_result

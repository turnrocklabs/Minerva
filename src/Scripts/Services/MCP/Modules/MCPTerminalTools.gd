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
##
## minerva_terminal_notify delivers ONE line from one harness to another. It
## owns no delivery code: it resolves the target terminal, finds the
## passthrough chat bound to it, and submits an enveloped user message through
## the same path the send button uses — so the line inherits the per-chat
## outgoing queue and then the relay's own hold, lock and confirmation.


## The envelope every notification is delivered inside. Shared by convention
## with the agent-relay plugin's NOTIFY_ENVELOPE_PREFIX (src/plugins/agent-relay
## /src/main.rs): the relay recognises this prefix and refuses to type such a
## line into a question card as its answer. Change one and change the other.
const NOTIFY_ENVELOPE_PREFIX := "[MINERVA NOTIFY from "
## One line, pointer not payload: a notification says "come look", it does not
## carry the work. Newlines would break the single-line envelope contract.
const NOTIFY_MAX_TEXT_LENGTH := 400
const NOTIFY_MAX_FROM_LENGTH := 64
const NOTIFY_MAX_WAIT_MS := 20000

## Entry id the agent-relay provider registers per watched terminal — the ONLY
## binding between a passthrough chat and its terminal.
const PASSTHROUGH_ENTRY_PREFIX := "terminal-"
const AGENT_RELAY_WATCH_STATUS_TOOL := "minerva_agent_relay_watch_status"

## Injectable seam: Callable(PackedStringArray) -> Dictionary of
## terminal_id -> watch profile id. Empty Callable uses the agent-relay plugin
## (see _watch_profiles). Tests inject a stub so profile addressing is
## exercisable without the plugin running.
var watch_profile_source: Callable = Callable()


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
		"minerva_terminal_notify",
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

	server._register_tool("minerva_terminal_notify",
		"Deliver ONE line to the agent running in another Minerva terminal. The line is posted as a user message in that terminal's passthrough chat, so the human sees it and the normal relay rules (hold, lock, submit confirmation) apply. Pointer, not payload: say what happened and where to look, in one line. Errors (never a guess) when 'to' matches no terminal, matches more than one, or the terminal has no passthrough chat bound to it.",
		{"type": "object", "properties": {
			"to": {"type": "string", "description": "Target terminal: its tab name, its watch profile ('claude' / 'codex') when exactly one such terminal is watched, or its terminal id."},
			"text": {"type": "string", "description": "The notification, ONE line, at most %d characters. No newlines." % NOTIFY_MAX_TEXT_LENGTH},
			"from": {"type": "string", "description": "Who this is from, self-declared. Recipients are told to trust the envelope Minerva builds, not the name inside it."},
			"wait_ms": {"type": "integer", "description": "Block up to this long (0-%d, default 0) for a QUEUED line to be dispatched. The receipt returns either way, with status 'queued', 'dispatched', 'dropped' (the line was cancelled before it ran) or 'unknown' (it left the queue but its outcome is no longer on record)." % NOTIFY_MAX_WAIT_MS},
		}, "required": ["to", "text", "from"]}, "terminal")


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
		"minerva_terminal_notify": return await _terminal_notify(arguments)
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
			var entry: Dictionary = {
				"id": session.terminal_id,
				"name": session.session_name,
				"visible": _find_view_for_session(session) != null,
				"alive": session.is_alive(),
				"cols": session.get_cols(),
				"rows": session.get_rows(),
				"created_at_ms": session.created_at_ms,
			}
			# cwd is absent, never guessed: a session started without one runs
			# in Minerva's own working directory, which the host cannot report
			# as the child's launch directory.
			if not session.launch_cwd.is_empty():
				entry["cwd"] = session.launch_cwd
			result.append(entry)
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
		var bg_session = registry.create_session(
			tab_name if not tab_name.is_empty() else "Terminal", 80, 24)
		if not bg_session.terminal_available or not bg_session.started:
			registry.close_session(bg_session.terminal_id)
			return {"success": false, "error": "Failed to start background terminal (extension unavailable or forkpty failed)"}
		return {"success": true, "id": bg_session.terminal_id, "name": bg_session.session_name, "visible": false}

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


# ── minerva_terminal_notify ────────────────────────────────────────────

## One line from one harness to another. The host resolves the target, finds
## the passthrough chat bound to it, and submits the envelope as a user turn;
## everything after that (queue, relay hold, lock, submit confirmation) is
## existing machinery.
func _terminal_notify(arguments: Dictionary) -> Dictionary:
	var to: String = str(arguments.get("to", "")).strip_edges()
	var text: String = str(arguments.get("text", "")).strip_edges()
	var from: String = str(arguments.get("from", "")).strip_edges()

	if to.is_empty():
		return MCPToolUtils.error("to is required: a terminal tab name, a watch profile (claude/codex), or a terminal id")
	if from.is_empty():
		return MCPToolUtils.error("from is required: the name this notification is delivered under")
	var invalid: String = _validate_notify_line(text, from)
	if not invalid.is_empty():
		return MCPToolUtils.error(invalid)

	var target: Dictionary = await _resolve_notify_target(to)
	if not target.get("success", false):
		return target

	var history = target["history"]
	# The envelope, not the name inside it, is what recipients are told to
	# trust: only the host writes this prefix.
	var envelope: String = "%s%s] %s" % [NOTIFY_ENVELOPE_PREFIX, from, text]
	# A notification is never urgent enough to take a turn the chat's agent is
	# blocked on: while a question card is unanswered this queues (deferred)
	# rather than starting a generate, so the human's answer goes first.
	var submitted: Dictionary = MCPToolUtils.submit_user_message(history, envelope, {}, true)
	if not submitted.get("success", false):
		return submitted

	# The receipt follows the QUEUE ENTRY, not the text: two identical
	# notifications are two entries, and an entry that vanishes from the queue
	# may have been cancelled rather than run.
	var entry_id: int = MCPToolUtils.coerce_int(submitted.get("entry_id", 0))
	var position: int = MCPToolUtils.outgoing_queue_position(entry_id)
	var wait_ms: int = clampi(
		MCPToolUtils.coerce_int(arguments.get("wait_ms", 0)), 0, NOTIFY_MAX_WAIT_MS)
	if position > 0 and wait_ms > 0:
		position = await _await_notify_dispatch(entry_id, wait_ms)

	return {
		"success": true,
		"target": {
			"terminal_id": str(target["terminal_id"]),
			"name": str(target["name"]),
			"chat_id": str(history.HistoryId),
		},
		"status": _notify_status(entry_id, position),
		"queue_position": position,
		"entry_id": entry_id,
	}


## Empty string when the line is deliverable, else why it is not.
func _validate_notify_line(text: String, from: String) -> String:
	if text.is_empty():
		return "text is required"
	if text.contains("\n") or text.contains("\r"):
		return "text must be ONE line — a notification is a pointer, not a payload. Put the detail where the line points."
	if _first_control_char(text) >= 0:
		return "text contains a control character (0x%02X) — the envelope is typed into a terminal, where control bytes are keystrokes, not text" % _first_control_char(text)
	if text.length() > NOTIFY_MAX_TEXT_LENGTH:
		return "text is %d characters; the cap is %d. A notification is a pointer, not a payload." % [
			text.length(), NOTIFY_MAX_TEXT_LENGTH]
	if from.contains("\n") or from.contains("\r") or from.contains("]"):
		return "from must be a single line and must not contain ']' — it goes inside the notify envelope"
	if _first_control_char(from) >= 0:
		return "from contains a control character (0x%02X) — the envelope is typed into a terminal, where control bytes are keystrokes, not text" % _first_control_char(from)
	if from.length() > NOTIFY_MAX_FROM_LENGTH:
		return "from is %d characters; the cap is %d" % [from.length(), NOTIFY_MAX_FROM_LENGTH]
	return ""


## Code point of the first C0 control character or DEL in `line`, or -1 when
## the line is all printable. The envelope ends up as keystrokes in someone's
## terminal, so ESC and its neighbours would be read as an escape sequence
## rather than shown. Tabs are in the rejected set too: they have no use in a
## one-line pointer, so admitting them would only widen what can be injected.
func _first_control_char(line: String) -> int:
	for i: int in range(line.length()):
		var code: int = line.unicode_at(i)
		if code < 0x20 or code == 0x7F:
			return code
	return -1


## Resolve `to` to EXACTLY ONE terminal and its bound passthrough chat.
## Matching is the union of three axes — terminal id, tab name
## (case-insensitive) and watch profile — deduplicated by terminal id. No match
## or more than one is an error that lists the candidates: an ambiguous
## notification must never be guessed at.
## Returns {success, terminal_id, name, history} or an error Dictionary.
func _resolve_notify_target(to: String) -> Dictionary:
	var listing: Dictionary = _terminal_list({})
	var terminals: Array = listing.get("terminals", [])
	if terminals.is_empty():
		return MCPToolUtils.error("No terminals exist, so '%s' cannot be delivered to" % to)

	var ids: PackedStringArray = PackedStringArray()
	for entry: Dictionary in terminals:
		ids.append(str(entry.get("id", "")))
	var profiles: Dictionary = await _watch_profiles(ids)

	var needle: String = to.to_lower()
	var matches: Array[Dictionary] = []
	var described: PackedStringArray = PackedStringArray()
	for entry: Dictionary in terminals:
		var tid: String = str(entry.get("id", ""))
		var tname: String = str(entry.get("name", ""))
		var profile: String = str(profiles.get(tid, ""))
		described.append("%s (id %s%s)" % [
			tname, tid, (", profile %s" % profile) if not profile.is_empty() else ""])
		if tid == to or tname.to_lower() == needle \
				or (not profile.is_empty() and profile.to_lower() == needle):
			matches.append({"terminal_id": tid, "name": tname})

	if matches.is_empty():
		return MCPToolUtils.error("No terminal matches '%s'. Terminals: %s" % [
			to, ", ".join(described)])
	if matches.size() > 1:
		var ambiguous: PackedStringArray = PackedStringArray()
		for m: Dictionary in matches:
			ambiguous.append("%s (id %s)" % [str(m["name"]), str(m["terminal_id"])])
		return MCPToolUtils.error("'%s' matches %d terminals: %s. Name one by its terminal id." % [
			to, matches.size(), ", ".join(ambiguous)])

	var terminal_id: String = str(matches[0]["terminal_id"])
	var history = _find_passthrough_chat(terminal_id)
	if history == null:
		return MCPToolUtils.error("Terminal '%s' (id %s) has no passthrough chat bound to it. A notification the human cannot see in a chat is not delivered — bind a passthrough chat to that terminal first." % [
			str(matches[0]["name"]), terminal_id])
	return {
		"success": true,
		"terminal_id": terminal_id,
		"name": str(matches[0]["name"]),
		"history": history,
	}


## The chat whose provider is bound to this terminal. The binding IS the
## provider's entry_id ("terminal-<id>"); nothing else ties a chat to a PTY.
func _find_passthrough_chat(terminal_id: String):
	var entry_id: String = PASSTHROUGH_ENTRY_PREFIX + terminal_id
	for history in SingletonObject.ChatList:
		var provider = history.provider
		if provider is PluginProvider and provider.entry_id == entry_id:
			return history
	return null


## terminal_id -> watch profile id, as the agent-relay plugin knows it.
## Default implementation dispatches the plugin's watch_status tool through
## PluginToolRegistry — the same internal path MCP dispatch uses. An unwatched
## terminal (or an unreachable plugin) simply has no profile, which makes it
## unaddressable BY profile and addressable by name or id as before.
func _watch_profiles(terminal_ids: PackedStringArray) -> Dictionary:
	if watch_profile_source.is_valid():
		var injected = await watch_profile_source.call(terminal_ids)
		return injected if injected is Dictionary else {}
	var registry = SingletonObject.plugin_tool_registry if "plugin_tool_registry" in SingletonObject else null
	if registry == null or not registry.has_method("handle_tool_call"):
		return {}
	var profiles: Dictionary = {}
	for terminal_id in terminal_ids:
		var raw = await registry.handle_tool_call(
			AGENT_RELAY_WATCH_STATUS_TOOL, {"terminal_id": terminal_id})
		if not (raw is Dictionary):
			continue
		# Same unwrap/classify the passthrough launch dialog uses for this
		# plugin's replies (envelope stripping + isError/success handling).
		var classified: Dictionary = PassthroughLaunchDialog._classify_watch_result(raw)
		if not classified.get("ok", false):
			continue
		var status = (classified.get("result", {}) as Dictionary).get("status", null)
		if status is Dictionary:
			var profile_id: String = str(status.get("profile_id", ""))
			if not profile_id.is_empty():
				profiles[terminal_id] = profile_id
	return profiles


## 1-based place of this envelope in the chat's outgoing queue, or 0 when it is
## not queued (the turn started immediately, or it has already been promoted).
## What the receipt says happened, from the queue's own record:
##   queued     — still waiting, position says where
##   dispatched — promoted to a turn (or started straight away: no entry)
##   dropped    — removed or discarded before it ran (a cancel, a closed bubble)
##   unknown    — the entry left the queue but its outcome is no longer on
##                record: the outcome ring is finite, so a burst evicts older
##                entries. "dispatched" is the one answer that must never be
##                guessed, so only a recorded DISPATCHED earns it.
func _notify_status(entry_id: int, position: int) -> String:
	if position > 0:
		return "queued"
	# No entry at all means no queue was involved: the turn started on the spot.
	if entry_id <= 0:
		return "dispatched"
	match MCPToolUtils.outgoing_queue_outcome(entry_id):
		ChatOutgoingQueue.Outcome.DROPPED:
			return "dropped"
		ChatOutgoingQueue.Outcome.DISPATCHED:
			return "dispatched"
		_:
			return "unknown"


## Poll until this entry leaves the queue or the budget lapses, then report its
## position either way — the receipt never lies about what happened.
func _await_notify_dispatch(entry_id: int, wait_ms: int) -> int:
	var deadline: int = Time.get_ticks_msec() + wait_ms
	var position: int = MCPToolUtils.outgoing_queue_position(entry_id)
	var tree: SceneTree = SingletonObject.get_tree()
	if tree == null:
		return position
	while position > 0 and Time.get_ticks_msec() < deadline:
		await tree.process_frame
		position = MCPToolUtils.outgoing_queue_position(entry_id)
	return position

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
## owns no delivery code: it resolves the target terminal and then either
## submits an enveloped user message to the passthrough chat bound to it (the
## same path the send button uses, so the line inherits the per-chat outgoing
## queue) or, when no chat is bound, asks the agent-relay plugin to type it —
## either way the relay's own hold, lock and confirmation apply.
##
## Through the MCP tool, a notification that cannot be delivered yet is KEPT:
## NotifyDeliveryLedger records it and looks again until the harness takes it
## or it fails, and its receipt carries the delivery id
## minerva_terminal_notify_status reads. Host callers (notify()) retry on their
## own, so on the direct path they get the one-look receipt as before.


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
## A keystroke this recent means a person is mid-sentence in the target: the
## notification would submit their half-typed line along with itself.
const NOTIFY_HUMAN_TYPING_MS := 5000
## Pause between looks while a direct delivery waits out a hold.
const NOTIFY_RETRY_INTERVAL_S := 0.25

## Entry id the agent-relay provider registers per watched terminal — the ONLY
## binding between a passthrough chat and its terminal.
const PASSTHROUGH_ENTRY_PREFIX := "terminal-"
const AGENT_RELAY_WATCH_STATUS_TOOL := "minerva_agent_relay_watch_status"
const AGENT_RELAY_SEND_TOOL := "minerva_agent_relay_send"
const AGENT_RELAY_PLUGIN_ID := "agent_relay"

## Preloaded (not class_name) for the harness-check constants a write receipt
## reports, so this module still parses in isolated --script harnesses.
const TerminalInputArbiter := preload("res://Scripts/Services/Terminal/TerminalInputArbiter.gd")
const NotifyDeliveryLedger := preload("res://Scripts/Services/Terminal/NotifyDeliveryLedger.gd")

## The hint each harness shows while a turn runs: the host-side twin of the
## relay's spinner_glyphs (agent-relay profiles.rs). Change one and change the
## other. Both harnesses draw it on their status row while working.
const BUSY_MARKERS := {
	"claude": ["esc to interrupt"],
	"codex": ["esc to interrupt"],
}

## How far up from the last drawn row the busy hint is looked for.
const BUSY_WINDOW_ROWS := 12

## What a kept notification's receipt tells its sender.
const RETAINED_NOTE := "Minerva keeps this notification and delivers it when that clears; do not send it again. minerva_terminal_notify_status with this delivery_id shows where it stands."

## Injectable seam: Callable(PackedStringArray) -> Dictionary of
## terminal_id -> watch profile id. Empty Callable uses the agent-relay plugin
## (see _watch_profiles). Tests inject a stub so profile addressing is
## exercisable without the plugin running.
var watch_profile_source: Callable = Callable()
## Injectable seam: Callable(Dictionary args) -> the relay send tool's raw
## reply. Empty Callable dispatches to the plugin (see _relay_send).
var relay_send_source: Callable = Callable()


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
		"minerva_terminal_notify_status",
	]


func register_tools() -> void:
	server._register_tool("minerva_terminal_list",
		"List all terminal sessions with their IDs, names, and dimensions. name is the current tab name (the address for notify); launch_name appears only when the tab was renamed after its shell started and the program inside still sees the old MINERVA_TERMINAL_NAME (notify accepts either name). Includes background sessions. visible=true means a person can see this terminal right now: it is has_view AND pane_shown AND selected, reported separately — has_view=false means no UI tab at all (use minerva_terminal_promote to show it), while pane_shown=false or selected=false means the tab exists but nobody is looking at it. alive=false means the shell has exited (scrollback still readable).",
		{"type": "object", "properties": {}}, "terminal")

	server._register_tool("minerva_terminal_write",
		"Send text/keystrokes to a terminal PTY. Non-blocking. IMPORTANT: Use \\r for Enter (not \\n). Common escapes: \\r=Enter, \\t=Tab, \\x03=Ctrl+C. Example: 'ls -la\\r' to run a command. To send a line to a program that needs the text settled before it is submitted, pass then_enter_after_ms instead of a trailing \\r: the text and the Enter then go out as one transaction that nothing else can get between.",
		{"type": "object", "properties": {
			"text": {"type": "string", "description": "Text to send. Use \\r at end to submit commands (Enter key). Example: 'echo hello\\r'"},
			"terminal_id": {"type": "string", "description": "Terminal ID (from terminal_list). Empty = active terminal."},
			"raw": {"type": "boolean", "description": "Send text byte-for-byte without unescaping \\r/\\n/\\t etc. Use when the text already contains real control characters (default false)."},
			"unless_typed_within_ms": {"type": "integer", "description": "Refuse (held) when a person typed in this terminal within this many milliseconds. Also refuse (held) while an agent container reports its tmux pane in scrollback or another mode; a container that does not report it is written to, and the receipt's pane_mode_check says 'unknown'. 0 = neither guard."},
			"expect_harness": {"type": "string", "description": "Refuse (held) unless this harness (claude/codex) is the terminal's foreground process at the moment of the write. The receipt's harness_check says whether the check ran ('checked'), was skipped because this platform cannot read the foreground ('skipped'), or was not asked for ('not_requested')."},
			"expect_process": {"type": "integer", "description": "Refuse (held) unless the terminal's foreground process group is this one at the moment of the write (a harness restarted there has another)."},
			"write_ticket": {"type": "string", "description": "Refuse unless this host write ticket is still issued; its issuer revokes it to withdraw a write it handed on."},
			"unless_composer_holds_text": {"type": "boolean", "description": "Refuse (held) when the harness's input box already holds a line a person typed and did not submit — writing would staple your text to theirs and submit both. The receipt's composer_check says whether the check ran ('checked'), was skipped because no composer could be located for whatever is in front ('skipped'), or was not asked for ('not_requested')."},
			"then_enter_after_ms": {"type": "integer", "description": "Send Enter this many ms after the text, as ONE guarded transaction: the terminal is held between the two, so a keystroke can never be submitted along with your line. Use instead of a trailing \\r. The receipt carries txn_id, harness_check and composer_check."},
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
		"Deliver ONE line to the agent harness running in another Minerva terminal, foreground or background, passthrough or not. When the terminal has a passthrough chat the line is posted there as a user message; otherwise it is typed into the harness by the relay. Either way nothing is written while a dialog or menu owns the keyboard, while a person is typing there or has a draft in the harness's input box, or (typed path) while the harness is busy with a turn. Such a line is KEPT and delivered when that clears: its receipt says 'held' with retained=true and a delivery_id — do not send it again. Receipt status: 'handed_to_harness' (the harness took it), 'queued' (waiting in its chat's queue), 'held' (kept, hold_reason says why), 'sending' (offered, no answer yet), 'unconfirmed' (typed, but nothing confirmed the harness took it; never retyped), 'failed' or 'dropped'. Taking the line is not reading it: no receipt claims the recipient read it. Pointer, not payload: say what happened and where to look, in one line. Errors (never a guess) when 'to' matches no terminal, matches more than one, or no harness is in the foreground.",
		{"type": "object", "properties": {
			"to": {"type": "string", "description": "Target terminal: its terminal id, its tab name, 'harness@tab name', or a bare harness ('claude' / 'codex') when exactly one terminal runs it."},
			"text": {"type": "string", "description": "The notification, ONE line, at most %d characters. No newlines." % NOTIFY_MAX_TEXT_LENGTH},
			"from": {"type": "string", "description": "Who this is from, self-declared: your harness name, plus '@' and your tab name when you are inside Minerva ($MINERVA_TERMINAL_NAME). Recipients are told to trust the envelope Minerva builds, not the name inside it."},
			"reply_to": {"type": "string", "description": "Your own terminal id ($MINERVA_TERMINAL_ID) when you are inside Minerva. It is written into the envelope so the recipient can answer you, not a look-alike instance. Omit from a host terminal."},
			"wait_ms": {"type": "integer", "description": "Block up to this long (0-%d, default 0) for the harness to take the line before the receipt returns; a line not taken by then is kept either way." % NOTIFY_MAX_WAIT_MS},
		}, "required": ["to", "text", "from"]}, "terminal")

	server._register_tool("minerva_terminal_notify_status",
		"Where kept notifications stand: one by the delivery_id its minerva_terminal_notify receipt carried, or every one addressed to a terminal (all when terminal_id is omitted). Each record has state (queued, held, sending, handed_to_harness, unconfirmed, failed, dropped), hold_reason, reason, attempts and its state history. A failed one stays readable here.",
		{"type": "object", "properties": {
			"delivery_id": {"type": "string", "description": "The delivery_id from a notify receipt."},
			"terminal_id": {"type": "string", "description": "List the notifications addressed to this terminal."},
			"open_only": {"type": "boolean", "description": "Leave out the ones that are settled (handed_to_harness, unconfirmed, failed, dropped)."},
		}}, "terminal")


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
		"minerva_terminal_notify": return await _notify_tool(arguments)
		"minerva_terminal_notify_status": return _notify_status_tool(arguments)
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
## session is background. This is terminal_list's has_view; `visible` needs the
## pane and the tab selection on top of it (see _view_visibility).
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
## Takes a Node, not a TerminalNew: only the parent chain and the tab metadata
## are read, so this works for any view a tab group hosts.
func _locate_view_tab(view: Node) -> Dictionary:
	var parent = view.get_parent()
	while parent:
		if parent is TerminalTabGroup:
			for i in range(parent._tab_bar.tab_count):
				if parent._tab_bar.get_tab_metadata(i) == view:
					return {"group": parent, "tab": i}
			return {"group": parent, "tab": -1}
		parent = parent.get_parent()
	return {"group": null, "tab": -1}


## What a person can actually see of this session, as three separate facts plus
## their conjunction:
##   has_view   — a view is attached (a tab exists for it at all)
##   pane_shown — the pane hosting that tab group is shown on screen
##   selected   — that tab is the current tab of its group
##   visible    — all three: someone is looking at this terminal right now
## A caller that wants "is there a tab" reads has_view; one that wants "is a
## person watching" reads visible.
func _session_visibility(session) -> Dictionary:
	return _view_visibility(_find_view_for_session(session))


## The same facts read off a view; null (a background session, or one whose
## view was detached by demote) is all-false.
## pane_shown comes from the tab GROUP's is_visible_in_tree because hiding the
## terminal pane hides the group with it, while selecting another tab only
## hides the view — reading the view alone could not tell the two apart.
func _view_visibility(view: Node) -> Dictionary:
	var facts: Dictionary = {
		"has_view": view != null,
		"pane_shown": false,
		"selected": false,
		"visible": false,
	}
	if view == null:
		return facts
	var located: Dictionary = _locate_view_tab(view)
	var group = located.get("group")
	var tab: int = int(located.get("tab", -1))
	if group != null:
		facts["pane_shown"] = group.is_visible_in_tree()
		facts["selected"] = tab >= 0 and group._tab_bar.current_tab == tab
	else:
		# Direct embed (test harness or a one-off host): the view's own
		# visibility is the whole story and there is no tab bar it could be
		# unselected in.
		facts["pane_shown"] = view.is_visible_in_tree()
		facts["selected"] = true
	facts["visible"] = bool(facts["pane_shown"]) and bool(facts["selected"])
	return facts


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
			# visible answers "can a person see this right now", which needs all
			# three facts; each is reported too, so a caller can tell a
			# background session from a tab hidden behind another tab or a
			# closed pane.
			var seen: Dictionary = _session_visibility(session)
			var entry: Dictionary = {
				"id": session.terminal_id,
				"name": session.session_name,
				"visible": seen["visible"],
				"has_view": seen["has_view"],
				"pane_shown": seen["pane_shown"],
				"selected": seen["selected"],
				"alive": session.is_alive(),
				"cols": session.get_cols(),
				"rows": session.get_rows(),
				"created_at_ms": session.created_at_ms,
				"last_input_ms": session.last_input_ms,
			}
			# `name` is the address the tab answers to now. A renamed tab also
			# carries launch_name: the name the child was spawned with and still
			# sees in MINERVA_TERMINAL_NAME, which no rename can update.
			entry.merge(session.name_fields(), true)
			# Who is in the foreground: the program (empty when the query
			# failed just now), and the harness when it is one. The key is
			# present whenever the platform can answer, so its absence means
			# "cannot know", not "nobody". The program, not the thread name:
			# an npm-installed harness renames its main thread (node's is
			# "MainThread"), which names nothing a caller can act on.
			if session.foreground_supported():
				var foreground: Dictionary = session.get_foreground_process()
				entry["foreground_process"] = session.program_of(foreground)
				var harness: String = session.harness_of(foreground)
				if not harness.is_empty():
					entry["harness"] = harness
				# The foreground process group: a harness that exits and is
				# started again in the same terminal is a different one.
				if int(foreground.get("pid", 0)) > 0:
					entry["foreground_pid"] = int(foreground["pid"])
				# Seen through an agent-container launcher: the session it shows.
				if foreground.has("container"):
					entry["container"] = str(foreground["container"])
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
	# Asking for the Enter makes this ONE transaction instead of a raw write:
	# the guards move into the arbiter's admission, and nothing a person types
	# can land between the body and the Enter that submits it.
	if arguments.has("then_enter_after_ms"):
		return _terminal_write_transaction(session, text, arguments)
	# Both write-time guards — the typing window and the expected harness — are
	# the arbiter's, so a raw write and a transaction refuse on identical
	# evidence read from one clock. They are checked at the moment of the write
	# because any earlier check can be overtaken by a keystroke.
	var arbiter = session.get_input_arbiter() if session.has_method("get_input_arbiter") else null
	if arbiter == null:
		return {"success": false, "held": true,
			"error": "this terminal has no input arbiter; nothing was written"}
	# check_raw_write, not check_guards: a guarded write is also refused while a
	# transaction holds the terminal, because queueing it would deliver agent
	# text after the pause with its guards no longer proven.
	var guards: Dictionary = arbiter.check_raw_write(_guard_options(arguments))
	if not bool(guards.get("success", false)):
		return guards
	var harness_check: String = str(guards.get("harness_check",
		TerminalInputArbiter.HARNESS_NOT_REQUESTED))
	# The arbiter's own receipt says whether the bytes went to the PTY now or
	# are waiting behind a transaction — and, past the queue bound, which
	# transaction this write aborted. Merged in, so a queued write is never
	# reported as a plain send.
	var receipt: Dictionary = session.write_input(text)
	var result: Dictionary = {"success": true, "bytes_sent": text.length(),
		"harness_check": harness_check,
		"composer_check": str(guards.get("composer_check",
			TerminalInputArbiter.COMPOSER_NOT_REQUESTED)),
		"pane_mode_check": str(guards.get("pane_mode_check",
			TerminalInputArbiter.PANE_MODE_NOT_REQUESTED))}
	for key in ["queued", "queue_depth", "transaction", "released", "aborted_transaction"]:
		if receipt.has(key):
			result[key] = receipt[key]
	return result


## The guard options both halves of terminal_write hand the arbiter, built from
## the same arguments so neither can guard differently from the other.
func _guard_options(arguments: Dictionary) -> Dictionary:
	var options: Dictionary = {}
	var guard_ms: int = MCPToolUtils.coerce_int(arguments.get("unless_typed_within_ms", 0))
	if guard_ms > 0:
		options["unless_typed_within_ms"] = guard_ms
	var expected: String = str(arguments.get("expect_harness", ""))
	if not expected.is_empty():
		options["expect_harness"] = expected
	if bool(arguments.get("unless_composer_holds_text", false)):
		options["refuse_if_composer_holds_text"] = true
	var expected_process: int = MCPToolUtils.coerce_int(arguments.get("expect_process", 0))
	if expected_process > 0:
		options["expect_process"] = expected_process
	var ticket: String = str(arguments.get("write_ticket", ""))
	if not ticket.is_empty():
		options["write_ticket"] = ticket
	return options


## The transaction half of terminal_write: body, pause, Enter, admitted once by
## the session's arbiter, which owns the PTY until the Enter has gone out.
## Returns the arbiter's admission or its refusal unchanged — both already
## carry the {success, held, error} shape callers parse.
func _terminal_write_transaction(session, body: String, arguments: Dictionary) -> Dictionary:
	if not session.has_method("begin_write_transaction"):
		return {"success": false, "held": true,
			"error": "this terminal has no input arbiter; nothing was written"}
	var options: Dictionary = _guard_options(arguments)
	options["pause_ms"] = maxi(0, MCPToolUtils.coerce_int(arguments.get("then_enter_after_ms", 0)))
	return session.begin_write_transaction(body, options)


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
	var display_name: String = tab_name if not tab_name.is_empty() else str(new_term.name)
	# One place applies a title: the tab group's apply_title writes both the
	# tab bar and the session name, so a tab named here and a tab renamed by
	# double-click cannot drift apart. It leaves an open rename editor alone.
	tab_group.apply_title(tab_group.tab_count() - 1, display_name)

	var session = new_term.get_session()
	if session:
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
	# Same one title path as create: the name is already the session's, so this
	# only makes the tab bar agree with it.
	tab_group.apply_title(tab_group.tab_count() - 1, str(session.session_name))
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

	# A tab can close and free its session while process_frame is awaited.
	while is_instance_valid(session) and not session.is_queued_for_deletion() \
			and session.terminal_available:
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

	if is_instance_valid(session):
		session.vt_state_changed.disconnect(on_change)
	if not is_instance_valid(session) or session.is_queued_for_deletion() \
			or not session.terminal_available:
		return {"success": false, "error": "Terminal closed while waiting"}

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

## Deliver one notification exactly as minerva_terminal_notify does; for host
## code (triggers) that sends through the same holds and receipts. `expect`
## names the session the line is meant for, checked where the write happens
## (after every wait): "chat_id" (the passthrough chat bound to the terminal),
## or "harness" and "process" (the foreground harness and its process group;
## such a session has no chat, so a terminal that now has one is refused, as
## its chat would type the line later, unguarded). "ticket" is a host write
## ticket (TerminalInputArbiter.issue_ticket): once revoked, nothing more is
## written or queued. A different session there is refused, never written to.
func notify(arguments: Dictionary, expect: Dictionary = {}) -> Dictionary:
	return await _terminal_notify(arguments, expect)


## The terminals minerva_terminal_list reports, for host code choosing one.
func list_terminals() -> Array:
	return _terminal_list({}).get("terminals", [])


## The one terminal `to` names, as minerva_terminal_notify resolves it, plus
## "chat_id" when a passthrough chat is bound to it; {success:false, error}
## when none or several match.
func resolve_address(to: String) -> Dictionary:
	var target: Dictionary = await _resolve_notify_target(to, list_terminals())
	if target.get("success", false):
		var history = _find_passthrough_chat(str(target["terminal_id"]))
		if history != null:
			target["chat_id"] = str(history.HistoryId)
	return target


## The MCP tool: one delivery, and when it is held the line is KEPT. The first
## look (or looks, within wait_ms) is made here; a held line is then recorded
## in the ledger and retried there, one look each time, addressed by terminal
## id so a renamed tab keeps its line. Chat deliveries are tracked by the chat
## path itself. A request refused before any target was chosen (bad arguments,
## no such terminal, no harness) is not a delivery and gets no record.
func _notify_tool(arguments: Dictionary) -> Dictionary:
	var receipt: Dictionary = await _terminal_notify(arguments, {}, {"hold_busy": true})
	var target: Dictionary = receipt.get("target", {})
	if receipt.has("delivery_id") or target.is_empty():
		return receipt
	var ledger = NotifyDeliveryLedger.shared()
	var envelope: String = _envelope(arguments)
	var status: String = str(receipt.get("status", ""))
	if status == NotifyDeliveryLedger.HANDED or status == NotifyDeliveryLedger.UNCONFIRMED:
		receipt["delivery_id"] = ledger.open(target, envelope, "relay", status,
			{"submit": receipt.get("submit", "")})
		return receipt
	if status != NotifyDeliveryLedger.HELD:
		receipt["delivery_id"] = ledger.open(target, envelope, "relay", NotifyDeliveryLedger.FAILED,
			{"reason": str(receipt.get("error", status))})
		return receipt
	var id: String = ledger.open(target, envelope, "relay", NotifyDeliveryLedger.HELD, {
		"hold_reason": str(receipt.get("hold_reason", "")),
		"reason": str(receipt.get("reason", ""))})
	var retry: Dictionary = arguments.duplicate()
	retry["to"] = str(target.get("terminal_id", ""))
	retry["wait_ms"] = 0
	var attempt := func() -> Dictionary:
		return await _terminal_notify(retry, {}, {"hold_busy": true, "delivery_id": id})
	ledger.retain(id, attempt)
	var kept: Dictionary = receipt.duplicate()
	kept.erase("error")
	kept["success"] = true
	kept["retained"] = true
	kept["delivery_id"] = id
	kept["note"] = RETAINED_NOTE
	return kept


## One record, or the records for a terminal, from the ledger.
func _notify_status_tool(arguments: Dictionary) -> Dictionary:
	var ledger = NotifyDeliveryLedger.shared()
	var id: String = str(arguments.get("delivery_id", "")).strip_edges()
	if not id.is_empty():
		var record: Dictionary = ledger.get_record(id)
		if record.is_empty():
			return MCPToolUtils.error("No notification '%s' is on record (ids are per Minerva run; the oldest settled ones are dropped past %d)" % [
				id, NotifyDeliveryLedger.RECORDS_KEPT])
		return {"success": true, "delivery": record}
	var records: Array[Dictionary] = ledger.list(str(arguments.get("terminal_id", "")).strip_edges(),
		bool(arguments.get("open_only", false)))
	return {"success": true, "deliveries": records, "count": records.size()}


## The envelope every notification is delivered inside, built from the tool's
## arguments. The envelope, not the name inside it, is what recipients are told
## to trust: only the host writes this prefix. The reply address rides inside
## it so the recipient answers this instance and not a look-alike.
static func _envelope(arguments: Dictionary) -> String:
	var from: String = str(arguments.get("from", "")).strip_edges()
	var reply_to: String = str(arguments.get("reply_to", "")).strip_edges()
	var text: String = str(arguments.get("text", "")).strip_edges()
	var reply_suffix: String = "" if reply_to.is_empty() else " (reply to: %s)" % reply_to
	return "%s%s%s] %s" % [NOTIFY_ENVELOPE_PREFIX, from, reply_suffix, text]


## One line from one harness to another. The host resolves the target, holds
## while a person is typing there, then hands the envelope to whichever
## delivery path the target has: its passthrough chat (queue + bubble) or the
## relay's gated send straight into the harness. `options`:
##   hold_busy   — on the direct path, hold while the harness shows a turn
##                 running (BUSY_MARKERS) instead of typing into it
##   delivery_id — the ledger record a chat delivery is tracked into; without
##                 it the chat path opens one of its own
func _terminal_notify(arguments: Dictionary, expect: Dictionary = {}, options: Dictionary = {}) -> Dictionary:
	var to: String = str(arguments.get("to", "")).strip_edges()
	var text: String = str(arguments.get("text", "")).strip_edges()
	var from: String = str(arguments.get("from", "")).strip_edges()
	var reply_to: String = str(arguments.get("reply_to", "")).strip_edges()

	if to.is_empty():
		return MCPToolUtils.error("to is required: a terminal id, a tab name, harness@tab name, or a harness (claude/codex)")
	if from.is_empty():
		return MCPToolUtils.error("from is required: the name this notification is delivered under")
	var invalid: String = _validate_notify_line(text, from)
	if not invalid.is_empty():
		return MCPToolUtils.error(invalid)

	var listing: Array = _terminal_list({}).get("terminals", [])
	var target: Dictionary = await _resolve_notify_target(to, listing)
	if not target.get("success", false):
		return target
	# A reply address must be a terminal that exists: a typo here would send
	# every answer to nobody.
	if not reply_to.is_empty() and _listing_entry(listing, reply_to).is_empty():
		return MCPToolUtils.error("reply_to '%s' is not a terminal here; pass your own $MINERVA_TERMINAL_ID" % reply_to)

	var envelope: String = _envelope(arguments)

	var wait_ms: int = clampi(
		MCPToolUtils.coerce_int(arguments.get("wait_ms", 0)), 0, NOTIFY_MAX_WAIT_MS)
	var receipt_target: Dictionary = {
		"terminal_id": str(target["terminal_id"]),
		"name": str(target["name"]),
	}

	var history = _find_passthrough_chat(str(target["terminal_id"]))
	var expect_chat: String = str(expect.get("chat_id", ""))
	if not expect_chat.is_empty() and (history == null or str(history.HistoryId) != expect_chat):
		return _changed(receipt_target, "'%s' is no longer the terminal of the chat this was meant for" % str(target["name"]))
	if expect.has("process") and history != null:
		return _changed(receipt_target, "'%s' now has a passthrough chat; its session is not the one this was meant for" % str(target["name"]))
	if history == null:
		# The direct path paces its own holds within wait_ms.
		return await _notify_direct(target, receipt_target, envelope, wait_ms, expect,
			bool(options.get("hold_busy", false)))

	# The chat path queues, so its holds are decided once, now. A person
	# mid-sentence in the target outranks any agent: the write would submit
	# their half-typed line with the envelope stapled to it.
	var typed_ago: int = _ms_since_human_input(target, str(target["terminal_id"]))
	if typed_ago >= 0 and typed_ago < NOTIFY_HUMAN_TYPING_MS:
		return _held(receipt_target, "human_typing",
			"a person typed in '%s' %d ms ago; nothing was written" % [str(target["name"]), typed_ago])
	# The chat's relay types into the foreground process: without a harness
	# there the line would run as a shell command. A foreground the platform
	# can report but could not read just now is a hold, not a shell.
	if str(target.get("harness", "")).is_empty():
		if target.has("foreground_process") and str(target["foreground_process"]).is_empty():
			return _held(receipt_target, "foreground_unknown",
				"the foreground process of '%s' could not be read; nothing was written" % str(target["name"]))
		return _no_harness(target)
	if _withdrawn(expect):
		return _withdrawn_receipt(receipt_target)

	receipt_target["chat_id"] = str(history.HistoryId)
	# A notification is never urgent enough to take a turn the chat's agent is
	# blocked on: while a question card is unanswered this queues (deferred)
	# rather than starting a generate, so the human's answer goes first.
	# The ledger follows the line past the chat's queue to the relay's answer:
	# leaving the queue is not the harness taking it. The record goes to the
	# chat before the submit, because an idle chat starts the turn inside it.
	var ledger = NotifyDeliveryLedger.shared()
	var delivery_id: String = str(options.get("delivery_id", ""))
	if delivery_id.is_empty():
		delivery_id = ledger.open(receipt_target, envelope, "chat", NotifyDeliveryLedger.SENDING)
	ledger.begin_chat(delivery_id, str(history.HistoryId))
	var submitted: Dictionary = MCPToolUtils.submit_user_message(history, envelope, {}, true)
	if not submitted.get("success", false):
		ledger.update(delivery_id, NotifyDeliveryLedger.FAILED,
			{"reason": str(submitted.get("error", "the chat refused it"))})
		submitted["delivery_id"] = delivery_id
		submitted["status"] = NotifyDeliveryLedger.FAILED
		submitted["target"] = receipt_target
		return submitted

	# The receipt follows the QUEUE ENTRY, not the text: two identical
	# notifications are two entries, and an entry that vanishes from the queue
	# may have been cancelled rather than run.
	var entry_id: int = MCPToolUtils.coerce_int(submitted.get("entry_id", 0))
	ledger.track_chat_entry(delivery_id, entry_id)
	if wait_ms > 0:
		await _await_notify_taken(delivery_id, wait_ms)
	var record: Dictionary = ledger.get_record(delivery_id)
	var receipt: Dictionary = {
		"success": true,
		"target": receipt_target,
		"status": str(record.get("state", "")),
		"queue_position": MCPToolUtils.outgoing_queue_position(entry_id),
		"entry_id": entry_id,
		"delivery_id": delivery_id,
	}
	if not str(record.get("hold_reason", "")).is_empty():
		receipt["hold_reason"] = str(record["hold_reason"])
		receipt["retained"] = true
		receipt["note"] = RETAINED_NOTE
	return receipt


## Delivery to a terminal with no passthrough chat: the relay types the
## envelope, classifying the screen with the harness it can see in the
## foreground, and starts no watch (a watch would register a passthrough
## provider nobody asked for). A bare shell is refused outright — the line
## would run as a command.
##
## The relay is asked for ONE look at a time and the human-typing rule is
## re-read from the live session before each look: a relay left to wait out
## a dialog would write the instant a person's keystroke cleared it, which is
## exactly when that person is at the keyboard.
func _notify_direct(target: Dictionary, receipt_target: Dictionary,
		envelope: String, wait_ms: int, expect: Dictionary = {}, hold_busy: bool = false) -> Dictionary:
	var harness: String = str(target.get("harness", ""))
	var pid: int = int(target.get("foreground_pid", 0))
	var tid: String = str(target["terminal_id"])
	var session = _resolve_session(tid)
	var deadline: int = Time.get_ticks_msec() + wait_ms
	var tree: SceneTree = SingletonObject.get_tree()
	while true:
		# Every hold is decided per look, so a wait can outlast a person's
		# last keystroke or a momentarily unreadable foreground. The
		# foreground can change while a delivery waits (the harness exits,
		# the shell is back): the live process decides each look, and a
		# terminal whose foreground can no longer be read is not written to.
		var typed_ago: int = _ms_since_human_input(target, tid)
		var hold: Dictionary = {}
		if session == null and target.has("foreground_process") \
				and str(target["foreground_process"]).is_empty():
			# No live session to re-read (a listing-only caller): the snapshot
			# stands.
			hold = _held(receipt_target, "foreground_unknown",
				"the foreground process of '%s' could not be read; nothing was written" % str(target["name"]))
		elif harness.is_empty() and session == null:
			return _no_harness(target)
		elif session != null and target.has("foreground_process"):
			if not session.is_alive():
				var gone: Dictionary = MCPToolUtils.error("Terminal '%s' (id %s) exited; nothing was written" % [
					str(target["name"]), tid])
				gone["status"] = "error"
				gone["target"] = receipt_target
				return gone
			var foreground: Dictionary = session.get_foreground_process()
			if foreground.is_empty() or str(foreground.get("name", "")).is_empty():
				hold = _held(receipt_target, "foreground_unknown",
					"the foreground process of '%s' could not be read; nothing was written" % str(target["name"]))
			else:
				harness = session.harness_of(foreground)
				pid = int(foreground.get("pid", 0))
				if harness.is_empty():
					target["foreground_process"] = session.program_of(foreground)
					return _no_harness(target)
		if hold.is_empty() and typed_ago >= 0 and typed_ago < NOTIFY_HUMAN_TYPING_MS:
			hold = _held(receipt_target, "human_typing",
				"a person typed in '%s' %d ms ago; nothing was written" % [str(target["name"]), typed_ago])
		elif hold.is_empty() and _withdrawn(expect):
			return _withdrawn_receipt(receipt_target)
		elif hold.is_empty() and int(expect.get("process", 0)) > 0 and pid <= 0:
			hold = _held(receipt_target, "process_unknown",
				"the foreground process of '%s' cannot be identified just now, so it cannot be confirmed as the expected session; nothing was written" % str(target["name"]))
		elif hold.is_empty() and hold_busy and _busy_turn_shown(session, harness):
			hold = _held(receipt_target, "busy_turn",
				"%s in '%s' is in the middle of a turn; nothing was written" % [harness, str(target["name"])])
		elif hold.is_empty():
			var changed: String = _expectation_broken(expect, harness, pid, str(target["name"]))
			if not changed.is_empty():
				return _changed(receipt_target, changed)
			# The host decides these again when it admits the relay's write, so
			# a restart or a withdrawal during the relay's round trip still
			# stops it.
			var expected_harness: String = str(expect.get("harness", ""))
			var raw = await _relay_send({
				"terminal_id": tid, "text": envelope, "arm": false,
				"profile": harness, "gate_budget_ms": 0,
				"human_guard_ms": NOTIFY_HUMAN_TYPING_MS,
				"expect_harness": expected_harness if not expected_harness.is_empty() else harness,
				"expect_process": int(expect.get("process", 0)),
				"write_ticket": str(expect.get("ticket", "")),
			})
			var classified: Dictionary = PassthroughLaunchDialog._classify_watch_result(
				raw if raw is Dictionary else {"error": "relay send returned nothing"})
			if classified.get("ok", false):
				var sent: Dictionary = classified.get("result", {})
				var submit = sent.get("submit", null)
				var submit_state: String = str(submit.get("state", "")) if submit is Dictionary else ""
				# The relay's own confirmation is the only evidence the harness
				# took the line; any other outcome typed it and proved nothing.
				var written: Dictionary = {
					"success": true, "target": receipt_target,
					"status": NotifyDeliveryLedger.HANDED if submit_state == "submitted" \
						else NotifyDeliveryLedger.UNCONFIRMED,
					"harness": harness,
					"submit": submit_state,
				}
				# The host's pane-mode verdict ("unknown": the container does not
				# report it, so nothing could hold this for it); absent from an
				# older relay or host.
				if sent.get("pane_mode_check") is String:
					written["pane_mode_check"] = sent["pane_mode_check"]
				return written
			var reason: String = str(classified.get("error", ""))
			if not _relay_reply_is_hold(raw):
				var failed: Dictionary = MCPToolUtils.error(reason)
				failed["status"] = "error"
				failed["target"] = receipt_target
				return failed
			hold = _held(receipt_target, _relay_hold_reason(raw, reason), reason)
		# The budget is checked before sleeping and again on waking, so no
		# look is taken once the caller's wait has lapsed.
		var remaining_ms: int = deadline - Time.get_ticks_msec()
		if tree == null or remaining_ms <= 0:
			return hold
		await tree.create_timer(minf(NOTIFY_RETRY_INTERVAL_S, remaining_ms / 1000.0)).timeout
		if Time.get_ticks_msec() >= deadline:
			return hold
	# Unreachable: the loop only leaves through the returns above, but the
	# parser wants every path to yield a value.
	return {}


## The refusal for a terminal whose foreground is not an agent harness.
func _no_harness(target: Dictionary) -> Dictionary:
	return MCPToolUtils.error("Terminal '%s' (id %s) has no agent harness in the foreground (%s); a notification typed into a shell would run as a command" % [
		str(target["name"]), str(target["terminal_id"]),
		str(target.get("foreground_process", "unknown process"))])


## Why the session in the terminal is not the one `expect` names ("" when it
## is, or when nothing is expected): another harness, or the same kind of
## harness started again (a different process group). An unreadable process
## group is not judged here; callers hold or refuse on it themselves.
static func _expectation_broken(expect: Dictionary, harness: String, pid: int, name: String) -> String:
	var want_harness: String = str(expect.get("harness", ""))
	if not want_harness.is_empty() and harness != want_harness:
		return "'%s' now runs %s, not %s" % [name, harness if not harness.is_empty() else "no harness", want_harness]
	var want_pid: int = int(expect.get("process", 0))
	if want_pid > 0 and pid > 0 and pid != want_pid:
		return "the %s in '%s' was replaced by another one" % [want_harness, name]
	return ""


## Whether the caller has withdrawn this delivery (revoked its ticket).
static func _withdrawn(expect: Dictionary) -> bool:
	var ticket: String = str(expect.get("ticket", ""))
	return not ticket.is_empty() and not TerminalInputArbiter.ticket_valid(ticket)


func _withdrawn_receipt(receipt_target: Dictionary) -> Dictionary:
	var withdrawn: Dictionary = MCPToolUtils.error("the sender withdrew this notification; nothing was written")
	withdrawn["status"] = "withdrawn"
	withdrawn["target"] = receipt_target
	return withdrawn


## A refusal because the terminal now holds a different session than the one
## the caller meant.
func _changed(receipt_target: Dictionary, why: String) -> Dictionary:
	var changed: Dictionary = MCPToolUtils.error("%s; nothing was written" % why)
	changed["status"] = "error"
	changed["target"] = receipt_target
	return changed


## A hold receipt: not delivered, retry later, and why.
func _held(receipt_target: Dictionary, hold_reason: String, why: String) -> Dictionary:
	var held: Dictionary = MCPToolUtils.error("%s. Send again in a moment." % why)
	held["status"] = "held"
	held["hold_reason"] = hold_reason
	held["reason"] = why
	held["target"] = receipt_target
	return held


## The relay marks a gate refusal with held:true inside its error payload.
func _relay_reply_is_hold(raw) -> bool:
	return bool(_relay_error_payload(raw).get("held", false))


## The relay's error payload: the reply itself when the refusal keys are
## already at the top level, else the JSON inside its MCP content block.
func _relay_error_payload(raw) -> Dictionary:
	if not (raw is Dictionary):
		return {}
	for key in ["held", "outcome", "hold_reason"]:
		if raw.has(key):
			return raw
	var content = raw.get("content", null)
	if content is Array and content.size() > 0 and content[0] is Dictionary:
		var parsed = JSON.parse_string(str(content[0].get("text", "{}")))
		if parsed is Dictionary:
			return parsed
	return raw


## Why the relay held this delivery. The refusal's own structured keys decide
## it — hold_reason as sent, else the host outcome it carries, which the
## terminal arbiter names "refused_<reason>". Prose is the fallback for a relay
## build that sends only a message: the composer hold is then told from a
## screen hold by the phrase the arbiter writes into it.
func _relay_hold_reason(raw, reason: String) -> String:
	var payload: Dictionary = _relay_error_payload(raw)
	var stated: String = str(payload.get("hold_reason", ""))
	if not stated.is_empty():
		return stated
	var outcome: String = str(payload.get("outcome", ""))
	if not outcome.is_empty():
		return outcome.trim_prefix("refused_")
	if reason.contains(TerminalInputArbiter.COMPOSER_HOLD_PHRASE):
		return "composer_not_empty"
	# The relay's own slot: its previous prompt's turn has not ended.
	if reason.contains("still in flight"):
		return "busy_turn"
	return "screen"


## Milliseconds since a person last typed in this terminal, or -1 when never.
## Read from the live session when there is one — the listing is a snapshot
## and a keystroke can land while a delivery waits — else from the listing.
func _ms_since_human_input(target: Dictionary, terminal_id: String = "") -> int:
	var last: int = MCPToolUtils.coerce_int(target.get("last_input_ms", 0))
	if not terminal_id.is_empty():
		var session = _resolve_session(terminal_id)
		if session != null and "last_input_ms" in session:
			last = int(session.last_input_ms)
	if last <= 0:
		return -1
	return maxi(0, int(Time.get_unix_time_from_system() * 1000.0) - last)


func _listing_entry(listing: Array, terminal_id: String) -> Dictionary:
	for entry: Dictionary in listing:
		if str(entry.get("id", "")) == terminal_id:
			return entry
	return {}


func _relay_send(args: Dictionary):
	if relay_send_source.is_valid():
		return await relay_send_source.call(args)
	return await _call_relay_tool(AGENT_RELAY_SEND_TOOL, args)


## One relay tool call from inside the host: through PluginToolRegistry when
## it has synced the plugin's manifest tools, else straight down the plugin's
## connection (the registry learns manifest tools on a state change that a
## just-started plugin may not have had yet). Errors come back as {"error"}.
func _call_relay_tool(tool_name: String, args: Dictionary):
	var registry = SingletonObject.plugin_tool_registry if "plugin_tool_registry" in SingletonObject else null
	if registry != null and registry.has_method("is_plugin_tool") and registry.is_plugin_tool(tool_name):
		return await registry.handle_tool_call(tool_name, args)
	var manager = SingletonObject.plugin_manager if "plugin_manager" in SingletonObject else null
	var conn = manager.get_connection(AGENT_RELAY_PLUGIN_ID) if manager != null and manager.has_method("get_connection") else null
	if conn == null:
		var relay = manager.get_db().get_by_id(AGENT_RELAY_PLUGIN_ID) if manager != null and manager.has_method("get_db") else null
		var issue := RequiredPlugins.runtime_issue(relay) if relay != null else ""
		if manager != null and (relay == null or not issue.is_empty()):
			return {"error": "%s Nothing was typed into that terminal." % RequiredPlugins.missing_message(AGENT_RELAY_PLUGIN_ID, issue)}
		return {"error": "the agent-relay plugin is not running, so nothing can type into that terminal"}
	return await conn.call_tool(tool_name, args)


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
	if from.contains("(reply to:"):
		return "from must not contain '(reply to:' — the reply address is written by the host from reply_to, never self-declared"
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


## Which terminal `to` names — EXACTLY one, by terminal id, tab name
## (case-insensitive), harness@tab name or bare harness; no match or more
## than one is an error listing the candidates, never a guess. The match
## carries the listing facts delivery needs (harness, foreground process,
## last human keystroke). The harness is what the PTY shows in the
## foreground; only a terminal whose foreground cannot be read at all
## (ConPTY) falls back to its watch profile.
func _resolve_notify_target(to: String, listing: Array) -> Dictionary:
	if listing.is_empty():
		return MCPToolUtils.error("No terminals exist, so '%s' cannot be delivered to" % to)

	# The watch profile is asked for only where the foreground is unreadable;
	# it is one plugin round-trip per terminal.
	var ids: PackedStringArray = PackedStringArray()
	for entry: Dictionary in listing:
		if not entry.has("foreground_process"):
			ids.append(str(entry.get("id", "")))
	var profiles: Dictionary = await _watch_profiles(ids) if not ids.is_empty() else {}

	var needle: String = to.to_lower()
	var matches: Array[Dictionary] = []
	var described: PackedStringArray = PackedStringArray()
	for entry: Dictionary in listing:
		var tid: String = str(entry.get("id", ""))
		var tname: String = str(entry.get("name", ""))
		# The watch profile stands in only when the foreground could not be
		# read at all: a readable shell prompt is a shell, whatever was watched
		# there before.
		var harness: String = str(entry.get("harness", ""))
		if harness.is_empty() and not entry.has("foreground_process"):
			harness = str(profiles.get(tid, ""))
		# A renamed tab answers to BOTH names: the tab bar shows the new one,
		# but the running child still reads the spawn-time name out of its own
		# MINERVA_TERMINAL_NAME, and that is the name it quotes when it asks to
		# be addressed. No rename can update the child's environment.
		var lname: String = str(entry.get("launch_name", ""))
		var addresses: PackedStringArray = PackedStringArray([tname.to_lower()])
		if not lname.is_empty() and not addresses.has(lname.to_lower()):
			addresses.append(lname.to_lower())
		described.append("%s (id %s%s%s)" % [
			tname, tid,
			(", was %s" % lname) if not lname.is_empty() and lname != tname else "",
			(", %s" % harness) if not harness.is_empty() else ""])
		var by_name: bool = addresses.has(needle)
		var by_harness: bool = false
		if not harness.is_empty():
			by_harness = harness.to_lower() == needle
			for address: String in addresses:
				by_harness = by_harness or needle == "%s@%s" % [harness.to_lower(), address]
		if tid == to or by_name or by_harness:
			var hit: Dictionary = entry.duplicate()
			hit["terminal_id"] = tid
			hit["harness"] = harness
			matches.append(hit)

	if matches.is_empty():
		return MCPToolUtils.error("No terminal matches '%s'. Terminals: %s" % [
			to, ", ".join(described)])
	if matches.size() > 1:
		var ambiguous: PackedStringArray = PackedStringArray()
		for m: Dictionary in matches:
			ambiguous.append("%s (id %s)" % [str(m["name"]), str(m["terminal_id"])])
		return MCPToolUtils.error("'%s' matches %d terminals: %s. Name one by its terminal id." % [
			to, matches.size(), ", ".join(ambiguous)])

	var target: Dictionary = matches[0]
	target["success"] = true
	return target


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
## PluginToolRegistry — the same internal path MCP dispatch uses. This is the
## fallback harness identity for a terminal whose foreground process the
## listing cannot name; an unwatched one simply has no profile.
func _watch_profiles(terminal_ids: PackedStringArray) -> Dictionary:
	if watch_profile_source.is_valid():
		var injected = await watch_profile_source.call(terminal_ids)
		return injected if injected is Dictionary else {}
	var profiles: Dictionary = {}
	for terminal_id in terminal_ids:
		var raw = await _call_relay_tool(
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


## What became of the chat delivery that used queue entry `entry_id`, for a
## caller that holds only the entry (TriggerHarnessDelivery):
##   queued      — still waiting, `position` says where
##   the ledger's state for the delivery, when one used this entry (see
##               NotifyDeliveryLedger: sending, held, handed_to_harness, ...)
##   sending     — promoted to a turn (or started straight away: no entry)
##               with no ledger record to say whether the harness took it
##   dropped     — removed or discarded before it ran (a cancel, a closed bubble)
##   unknown     — the entry left the queue but its outcome is no longer on
##               record: the outcome ring is finite.
## Leaving the queue is never reported as the harness taking the line; only
## the ledger, told by the relay's reply, says handed_to_harness.
static func notify_status(entry_id: int, position: int) -> String:
	if position > 0:
		return NotifyDeliveryLedger.QUEUED
	var recorded: String = NotifyDeliveryLedger.shared().state_of_entry(entry_id)
	if not recorded.is_empty():
		return recorded
	# No entry at all means no queue was involved: the turn started on the spot.
	if entry_id <= 0:
		return NotifyDeliveryLedger.SENDING
	match MCPToolUtils.outgoing_queue_outcome(entry_id):
		ChatOutgoingQueue.Outcome.DROPPED:
			return NotifyDeliveryLedger.DROPPED
		ChatOutgoingQueue.Outcome.DISPATCHED:
			return NotifyDeliveryLedger.SENDING
		_:
			return "unknown"


## Wait until the harness takes this chat delivery, it is held, or it settles
## otherwise — or until the budget lapses. The receipt then reports the
## ledger's state either way.
func _await_notify_taken(delivery_id: String, wait_ms: int) -> void:
	var deadline: int = Time.get_ticks_msec() + wait_ms
	var tree: SceneTree = SingletonObject.get_tree()
	if tree == null:
		return
	var ledger = NotifyDeliveryLedger.shared()
	while Time.get_ticks_msec() < deadline:
		var state: String = str(ledger.get_record(delivery_id).get("state", ""))
		if state != NotifyDeliveryLedger.QUEUED and state != NotifyDeliveryLedger.SENDING:
			return
		await tree.process_frame


## Whether the harness in this session shows a turn running: its busy hint
## (BUSY_MARKERS) on one of the last BUSY_WINDOW_ROWS rows of the visible
## screen, blank rows at the foot left out. Both harnesses draw the hint just
## above their input box; a hint further up is an old screen scrolling away
## (a dialog drawn after it, say). A session that cannot be read is not judged
## busy here; the relay's own gate still classifies it.
func _busy_turn_shown(session, harness: String) -> bool:
	if session == null or not session.has_method("read_viewport_text"):
		return false
	var markers: Array = Array(BUSY_MARKERS.get(harness, []))
	if markers.is_empty():
		return false
	var rows: PackedStringArray = str(session.read_viewport_text()).split("\n")
	var last: int = rows.size() - 1
	while last >= 0 and rows[last].strip_edges().is_empty():
		last -= 1
	for row in range(maxi(0, last - BUSY_WINDOW_ROWS + 1), last + 1):
		for marker: String in markers:
			if rows[row].contains(marker):
				return true
	return false

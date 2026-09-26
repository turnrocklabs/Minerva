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
##
## Addresses: a registered session identity or role (HarnessSessionRegistry)
## is tried first, then terminal id, tab name, harness@tab and bare harness.
## A notification to an identity or role whose session is not reachable is
## kept as awaiting_recipient and delivered when one is (a registration or a
## handover); minerva_terminal_list reports such roles as unavailable_roles
## with their pending counts.
## Who may notify whom: any caller may notify any terminal with an agent
## harness in front except its own terminal, the one reply_to names (a
## terminal id, or a registered identity's bound terminal). Identity and role
## are addresses, not grants; the caller's name is declared, not verified.
## MCPNotifyDelivery.terminal_notify enforces it.
##
## A notification is routine or urgent (NotifyDeliveryClass). Both wait for the
## harness's turn to end; an urgent one is placed ahead of routine ones: in a
## passthrough chat's queue, or, on a harness/platform whose own input queue
## was measured, by typing it into that queue while the turn runs, where
## Minerva's held routine lines cannot pass it. Every receipt says which
## mechanism carried it and when the harness gets it; none says interrupted.


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

## Entry id the agent-relay provider registers per watched terminal — the ONLY
## binding between a passthrough chat and its terminal.
const PASSTHROUGH_ENTRY_PREFIX := "terminal-"

## Preloaded (not class_name) for the harness-check constants a write receipt
## reports, so this module still parses in isolated --script harnesses.
const TerminalInputArbiter := preload("res://Scripts/Services/Terminal/TerminalInputArbiter.gd")
const NotifyDeliveryLedger := preload("res://Scripts/Services/Terminal/NotifyDeliveryLedger.gd")
const HarnessSessionRegistry := preload("res://Scripts/Services/Terminal/HarnessSessionRegistry.gd")
const NotifyDeliveryClass := preload("res://Scripts/Services/Terminal/NotifyDeliveryClass.gd")
## The notify delivery path (holds, relay, chat, ledger glue, receipts).
const MCPNotifyDelivery := preload("res://Scripts/Services/MCP/Modules/MCPNotifyDelivery.gd")


## Injectable seam: Callable(PackedStringArray) -> Dictionary of
## terminal_id -> watch profile id. Empty Callable uses the agent-relay plugin
## (see MCPNotifyDelivery._watch_profiles). Tests inject a stub so profile addressing is
## exercisable without the plugin running.
var watch_profile_source: Callable = Callable()
## Injectable seam: Callable(Dictionary args) -> the relay send tool's raw
## reply. Empty Callable dispatches to the plugin (see MCPNotifyDelivery._relay_send).
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
		"List all terminal sessions with their IDs, names, and dimensions. A terminal holding a registered harness session also carries its identity and role; `sessions` lists every registered session (minerva_session_register) with identity, role, harness, terminal_id (empty when no terminal holds it this run), liveness (live, other_harness, no_harness, unknown, exited, unbound), pending (notifications kept for it) and superseded_by when a handover replaced it; `unavailable_roles` lists every role no live session holds, with its holders and the notifications pending for it. name is the current tab name (the address for notify); launch_name appears only when the tab was renamed after its shell started and the program inside still sees the old MINERVA_TERMINAL_NAME (notify accepts either name). Includes background sessions. visible=true means a person can see this terminal right now: it is has_view AND pane_shown AND selected, reported separately — has_view=false means no UI tab at all (use minerva_terminal_promote to show it), while pane_shown=false or selected=false means the tab exists but nobody is looking at it. alive=false means the shell has exited (scrollback still readable). delivery (terminals with a harness in front, or whose foreground this platform cannot read) says how a routine and an urgent minerva_terminal_notify would reach it here: mechanism (chat_queue, relay_when_idle, native_queue, relay_unclassified; relay_into_turn appears only on receipts) and delivered_at (turn_end, harness_queue, unknown).",
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
		"Deliver ONE line to the agent harness running in another Minerva terminal, foreground or background, passthrough or not. Any harness terminal may be notified except your own (the one reply_to names); that is refused with code notify_self. When the terminal has a passthrough chat the line is posted there as a user message; otherwise it is typed into the harness by the relay. Either way nothing is written while a dialog or menu owns the keyboard, while a person is typing there or has a draft in the harness's input box, or (typed path) while the harness is busy with a turn. Such a line is KEPT and delivered when that clears: its receipt says 'held' with retained=true and a delivery_id — do not send it again. A line addressed to a registered identity or role that no reachable session holds is kept too, as 'awaiting_recipient', and delivered once one does (it registers again, or the role is handed over with minerva_session_handover); a superseded identity's line goes to its successor. Receipt status: 'handed_to_harness' (the harness took it), 'queued' (waiting in its chat's queue), 'held' (kept, hold_reason says why), 'awaiting_recipient' (kept, no session to take it yet), 'sending' (offered, no answer yet), 'unconfirmed' (typed, but nothing confirmed the harness took it; never retyped), 'failed' or 'dropped'. Taking the line is not reading it: no receipt claims the recipient read it. Nothing interrupts a running turn: every receipt carries class (routine/urgent), mechanism (chat_queue: the passthrough chat's queue, after its turn; relay_when_idle: held while a turn runs, typed when none shows; native_queue: typed into the harness's own input queue while the turn runs, where the harness holds it and decides when it runs (an urgent line, where that queue was measured); relay_into_turn: typed while a turn ran where that queue was never measured; relay_unclassified: no harness could be identified in front) and delivered_at (turn_end, harness_queue, unknown). Pointer, not payload: say what happened and where to look, in one line. Errors (never a guess) when 'to' matches no terminal, matches more than one, or no harness is in the foreground.",
		{"type": "object", "properties": {
			"to": {"type": "string", "description": "Target: a registered session identity, a role held by exactly one live session, a terminal id, a tab name, 'harness@tab name', or a bare harness ('claude' / 'codex') when exactly one terminal runs it. Identity and role are tried first and survive tab renames and Minerva restarts."},
			"text": {"type": "string", "description": "The notification, ONE line, at most %d characters. No newlines." % NOTIFY_MAX_TEXT_LENGTH},
			"from": {"type": "string", "description": "Who this is from, self-declared: your harness name, plus '@' and your tab name when you are inside Minerva ($MINERVA_TERMINAL_NAME). Recipients are told to trust the envelope Minerva builds, not the name inside it."},
			"reply_to": {"type": "string", "description": "Your registered session identity (preferred: it survives restarts) or your own terminal id ($MINERVA_TERMINAL_ID) when you are inside Minerva. It is written into the envelope so the recipient can answer you, not a look-alike instance, and it names the terminal you may not notify. Omit from a host terminal."},
			"wait_ms": {"type": "integer", "description": "Block up to this long (0-%d, default 0) for the harness to take the line before the receipt returns; a line not taken by then is kept either way." % NOTIFY_MAX_WAIT_MS},
			"urgent": {"type": "boolean", "description": "Stop or scope steering rather than a routine pointer (default false). It goes ahead of routine notifications waiting for the same harness; it does NOT interrupt the turn in progress. The receipt's mechanism and delivered_at say how it went."},
		}, "required": ["to", "text", "from"]}, "terminal")

	server._register_tool("minerva_terminal_notify_status",
		"Where kept notifications stand: one by the delivery_id its minerva_terminal_notify receipt carried, or every one addressed to a terminal (all when terminal_id is omitted). Each record has state (queued, held, awaiting_recipient, sending, handed_to_harness, unconfirmed, failed, dropped), class (routine/urgent), mechanism and delivered_at (as in the notify receipt; mechanism is empty until an attempt chose one), its target (with the address it is retried under, and retargeted_from after a handover), hold_reason, reason, attempts and its state history. A failed one stays readable here.",
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
			# How each class of notification would reach this terminal now.
			if entry.has("harness") or not entry.has("foreground_process"):
				entry["delivery"] = NotifyDeliveryClass.plan_for_terminal(str(entry.get("harness", "")),
					_find_passthrough_chat(str(session.terminal_id)) != null)
			# cwd is absent, never guessed: a session started without one runs
			# in Minerva's own working directory, which the host cannot report
			# as the child's launch directory.
			if not session.launch_cwd.is_empty():
				entry["cwd"] = session.launch_cwd
			result.append(entry)
	# Registered sessions are judged against this same listing, and each
	# terminal holding one says which.
	var harness_sessions = HarnessSessionRegistry.shared()
	var sessions: Array[Dictionary] = harness_sessions.sessions(result)
	var pending: Dictionary = NotifyDeliveryLedger.shared().pending_by_address()
	for described: Dictionary in sessions:
		described["pending"] = int(pending.get(str(described["identity"]).to_lower(), 0))
		var held_in: Dictionary = _listing_entry(result, str(described["terminal_id"]))
		if not held_in.is_empty():
			held_in["identity"] = described["identity"]
			held_in["role"] = described["role"]
	return {"success": true, "terminals": result, "count": result.size(), "sessions": sessions,
		"unavailable_roles": harness_sessions.unavailable_roles(result, pending)}


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
# Delivery lives in MCPNotifyDelivery; these are the entry points callers and
# tests reach through this module.

## A delivery bound to this module's terminal facts and seams.
func _delivery():
	return MCPNotifyDelivery.new(self)


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
	return await _delivery().terminal_notify(arguments, expect)


## One notification as the MCP tool delivers it, for host code that wants the
## line kept: a held line is recorded in the ledger and retried there. The
## receipt carries delivery_id unless the request was refused before a target
## was chosen (then nothing is kept).
func notify_retained(arguments: Dictionary) -> Dictionary:
	return await _notify_tool(arguments)


## The terminals minerva_terminal_list reports, for host code choosing one.
func list_terminals() -> Array:
	return _terminal_list({}).get("terminals", [])


## The one terminal `to` names, as minerva_terminal_notify resolves it, plus
## "chat_id" when a passthrough chat is bound to it; {success:false, error}
## when none or several match.
func resolve_address(to: String) -> Dictionary:
	return await _delivery().resolve_address(to)


func _notify_tool(arguments: Dictionary) -> Dictionary:
	return await _delivery().notify_tool(arguments)


func _notify_status_tool(arguments: Dictionary) -> Dictionary:
	return _delivery().status_tool(arguments)


func _resolve_notify_target(to: String, listing: Array) -> Dictionary:
	return await _delivery().resolve_target(to, listing)


func _call_relay_tool(tool_name: String, args: Dictionary):
	return await _delivery().call_relay_tool(tool_name, args)


## What became of the chat delivery that used queue entry `entry_id`
## (MCPNotifyDelivery.notify_status).
static func notify_status(entry_id: int, position: int) -> String:
	return MCPNotifyDelivery.notify_status(entry_id, position)


func _listing_entry(listing: Array, terminal_id: String) -> Dictionary:
	for entry: Dictionary in listing:
		if str(entry.get("id", "")) == terminal_id:
			return entry
	return {}


## The chat whose provider is bound to this terminal. The binding IS the
## provider's entry_id ("terminal-<id>"); nothing else ties a chat to a PTY.
func _find_passthrough_chat(terminal_id: String):
	var entry_id: String = PASSTHROUGH_ENTRY_PREFIX + terminal_id
	for history in SingletonObject.ChatList:
		var provider = history.provider
		if provider is PluginProvider and provider.entry_id == entry_id:
			return history
	return null

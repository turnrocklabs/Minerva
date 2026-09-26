class_name TerminalTabGroup
extends VBoxContainer

## A self-contained tab group that manages one or more TerminalNew instances.
## Builds its own UI programmatically — no .tscn dependency required.
##
## Usage:
##   var group := TerminalTabGroup.new()
##   add_child(group)
##
## The first terminal is created automatically when the node becomes visible
## and the group is empty (same behaviour as the original TerminalTabContainer).

signal terminal_added(terminal: TerminalNew)
signal terminal_closed(tab: int)
signal became_empty()
signal focus_requested()

const _TERMINAL_THEME := preload("res://assets/themes/terminal.tres")
# Loaded at run time, not preloaded: the ledger reaches the chat queue, and
# this file stays compilable in isolated script-run harnesses.
const NOTIFY_LEDGER_PATH := "res://Scripts/Services/Terminal/NotifyDeliveryLedger.gd"
const SESSION_REGISTRY_PATH := "res://Scripts/Services/Terminal/HarnessSessionRegistry.gd"
const SESSIONS_DIALOG_PATH := "res://Scenes/HarnessSessionsDialog.tscn"

var _tab_bar: TabBar
var _panel: PanelContainer
# Shows the notifications Minerva is keeping for this group's terminals, so a
# person can see a line waiting on their draft, a dialog or a busy turn.
var _retained_label: Label

# The inline title editor, while a rename is open. Null otherwise.
var _rename_edit: LineEdit = null

# Set while a tooltip refresh is waiting for the end of the frame.
var _retained_refresh_queued: bool = false

# Internal signal used to synchronise tab metadata writes with tab_changed.
signal _tab_metadata_written()


func _init() -> void:
	theme = _TERMINAL_THEME
	_build_ui()

func _ready() -> void:
	# Discoverable by MCPTerminalTools (promote/visible-create) without walking
	# the tree from a terminal view — works even when the group has zero tabs.
	add_to_group("terminal_tab_group")
	visibility_changed.connect(_on_visibility_changed)
	# Background sessions are "tabs the pane hasn't shown yet": adopt sessions
	# created while the pane is open (e.g. a passthrough chat launching its
	# terminal) so they surface as regular, fully interactive tabs (W8 HITL).
	var registry = _get_session_registry()
	if registry != null and registry.has_signal("session_created") \
			and not registry.session_created.is_connected(_on_registry_session_created):
		registry.session_created.connect(_on_registry_session_created)
	# visibility_changed only fires on TOGGLES — a group entering the tree
	# already visible needs an initial sync (deferred past this add_child).
	if is_visible_in_tree():
		call_deferred("_adopt_viewless_sessions")
	var ledger = load(NOTIFY_LEDGER_PATH).shared()
	if not ledger.changed.is_connected(_on_notify_ledger_changed):
		ledger.changed.connect(_on_notify_ledger_changed)
	var sessions = load(SESSION_REGISTRY_PATH).shared()
	if not sessions.changed.is_connected(_queue_retained_refresh):
		sessions.changed.connect(_queue_retained_refresh)
	_refresh_retained()


func _build_ui() -> void:
	# ── Top row: TabBar + "+" button ──────────────────────────────────
	var header := HBoxContainer.new()
	header.name = "Header"
	add_child(header)

	_tab_bar = TabBar.new()
	_tab_bar.name = "TabBar"
	_tab_bar.clip_tabs = false
	_tab_bar.tab_close_display_policy = TabBar.CLOSE_BUTTON_SHOW_ACTIVE_ONLY
	_tab_bar.max_tab_width = 250
	_tab_bar.drag_to_rearrange_enabled = true
	_tab_bar.size_flags_horizontal = SIZE_EXPAND_FILL
	_tab_bar.tab_changed.connect(_on_tab_bar_tab_changed)
	_tab_bar.tab_close_pressed.connect(_on_tab_bar_tab_close_pressed)
	# The gui_input SIGNAL runs alongside TabBar's own handling, so watching for
	# the double-click here costs the bar none of its normal clicks or drags.
	_tab_bar.gui_input.connect(_on_tab_bar_gui_input)
	header.add_child(_tab_bar)

	var add_btn := Button.new()
	add_btn.name = "AddButton"
	add_btn.text = "+"
	add_btn.flat = true
	add_btn.pressed.connect(func() -> void: add_terminal())
	header.add_child(add_btn)

	var sessions_btn := Button.new()
	sessions_btn.name = "SessionsButton"
	sessions_btn.text = "Sessions"
	sessions_btn.flat = true
	sessions_btn.tooltip_text = "Register this tab's harness under a stable identity and role; see every registered session and whether it is live."
	sessions_btn.pressed.connect(open_sessions_dialog)
	header.add_child(sessions_btn)

	_retained_label = Label.new()
	_retained_label.name = "RetainedLabel"
	_retained_label.visible = false
	_retained_label.mouse_filter = Control.MOUSE_FILTER_PASS
	header.add_child(_retained_label)

	# ── Body: PanelContainer holds the terminal nodes ─────────────────
	_panel = PanelContainer.new()
	_panel.name = "TerminalPanel"
	_panel.size_flags_vertical = SIZE_EXPAND_FILL
	add_child(_panel)


## Resolves the TerminalSessionRegistry via the SingletonObject autoload through
## the tree (NOT the compile-time global) so this file compiles in isolated
## script-run test harnesses where the autoload identifier isn't yet bound.
func _get_session_registry():
	var tree := get_tree()
	if tree == null:
		return null
	var so = tree.root.get_node_or_null("SingletonObject")
	if so == null or not so.has_method("get_terminal_session_registry"):
		return null
	return so.get_terminal_session_registry()


## Adds a button to the header row (next to the TabBar and + button).
func add_header_button(button: Button) -> void:
	var header := get_node_or_null("Header")
	if header:
		header.add_child(button)


# ── Public API ────────────────────────────────────────────────────────

## Creates a new terminal view backed by a registry session, registers it in
## the tab bar, and returns the view. The PTY lives in the session (under the
## registry) so it survives the view being freed. Pass an existing background
## session to surface it as a tab without starting a new shell. chat-passthrough T1.
func add_terminal(session = null) -> TerminalNew:
	var terminal := TerminalNew.create()
	terminal.name = "Terminal"
	terminal.visible = false

	# If a background session was supplied, surface it (no new shell). Otherwise
	# let the view create its own session from the registry in _ready (the
	# default path — keeps SingletonObject out of this file's compile surface).
	if session != null:
		terminal._auto_create_session = false
		terminal.attach_session(session)
		if terminal.get_session() != session:
			terminal.free()
			return null

	_panel.add_child(terminal, true)

	# Surfaced sessions keep their given name (a passthrough chat's session is
	# named after the chat) so the tab is recognisable.
	var tab_title: String = terminal.name
	if session != null and "session_name" in session and not str(session.session_name).is_empty():
		tab_title = str(session.session_name)
	_tab_bar.add_tab(tab_title)
	_tab_bar.set_tab_metadata(_tab_bar.tab_count - 1, terminal)

	_tab_metadata_written.emit()

	_tab_bar.current_tab = _tab_bar.tab_count - 1

	focus_requested.emit()
	terminal_added.emit(terminal)
	return terminal


## Closes the tab at index *tab*, closes its session (tab close = PTY close, the
## established UX), and frees the view. Use detach + add_terminal elsewhere to
## move a session between tabs without killing the shell.
func close_terminal(tab: int) -> void:
	if tab < 0 or tab >= _tab_bar.tab_count:
		return

	# Untyped: the metadata is whatever view was registered, and every use
	# below asks by method rather than by class.
	var terminal = _tab_bar.get_tab_metadata(tab)
	_tab_bar.remove_tab(tab)
	if terminal:
		# Tab close = session close (preserve today's behaviour).
		var session = terminal.get_session() if terminal.has_method("get_session") else null
		var owns_session := session != null
		if owns_session and session.has_method("get_attached_view"):
			owns_session = session.get_attached_view() == terminal
		if terminal.has_method("detach_session"):
			terminal.detach_session()
		if owns_session:
			var registry = _get_session_registry()
			if registry:
				registry.close_session(session.terminal_id)
		terminal.queue_free()

	terminal_closed.emit(tab)

	if _tab_bar.tab_count == 0:
		became_empty.emit()


## Removes the tab at index *tab* and frees its VIEW without closing the
## session — the PTY keeps running under the registry (chat-passthrough T2
## demote). Counterpart of add_terminal(session); close_terminal() remains the
## tab-close = session-close path.
func detach_terminal(tab: int) -> void:
	if tab < 0 or tab >= _tab_bar.tab_count:
		return

	var terminal = _tab_bar.get_tab_metadata(tab)
	_tab_bar.remove_tab(tab)
	if terminal:
		if terminal.has_method("detach_session"):
			terminal.detach_session()
		terminal.queue_free()

	terminal_closed.emit(tab)

	if _tab_bar.tab_count == 0:
		became_empty.emit()


## Returns the currently visible terminal, or null if the group is empty.
func get_active_terminal() -> TerminalNew:
	var tab := _tab_bar.current_tab
	if tab < 0:
		return null
	return _tab_bar.get_tab_metadata(tab) as TerminalNew


## Returns the number of open tabs.
func tab_count() -> int:
	return _tab_bar.tab_count


## Returns true when there are no open tabs.
func is_empty() -> bool:
	return _tab_bar.tab_count == 0


# ── Internal signal handlers ──────────────────────────────────────────

func _on_visibility_changed() -> void:
	if not is_visible_in_tree():
		return
	# A visible pane shows EVERY live session as a tab — background terminals
	# are just tabs the pane hadn't rendered yet (W8 HITL expectation). A fresh
	# bare shell is only created when there is nothing to adopt.
	_adopt_viewless_sessions()
	if _tab_bar.tab_count == 0:
		add_terminal()


## A session was created while this group exists (e.g. the passthrough launch
## dialog starting a terminal with the pane open). Deferred: on the default
## add_terminal() path the NEW VIEW creates the session and attaches right
## after — adopting synchronously would race that attach and duplicate the tab.
func _on_registry_session_created(_session) -> void:
	if is_visible_in_tree():
		call_deferred("_adopt_viewless_sessions")


## Give every registry session without an attached view a tab in this group.
## Idempotent: sessions whose view exists anywhere (any tab group) are skipped.
## Demoted tabs therefore stay demoted until the next visibility change or
## session creation — demote is "until the pane next syncs", not forever.
func _adopt_viewless_sessions() -> void:
	var registry = _get_session_registry()
	if registry == null:
		return
	for session in registry.list_sessions():
		if session == null or not is_instance_valid(session):
			continue
		if _view_exists_for(session):
			continue
		add_terminal(session)


## True when ANY terminal view (in any tab group) is attached to `session`.
func _view_exists_for(session) -> bool:
	if session.has_method("get_attached_view") and session.get_attached_view() != null:
		return true
	var tree := get_tree()
	if tree == null:
		return false
	for term in tree.get_nodes_in_group("terminal_pane"):
		if is_instance_valid(term) and term.has_method("get_session") \
				and term.get_session() == session:
			return true
	return false


# ── Inline tab rename ─────────────────────────────────────────────────

func _on_tab_bar_gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton):
		return
	var mb := event as InputEventMouseButton
	if not (mb.pressed and mb.double_click and mb.button_index == MOUSE_BUTTON_LEFT):
		return
	var tab: int = _tab_bar.get_tab_idx_at_point(mb.position)
	if tab < 0:
		return
	begin_rename(tab)


## Opens the inline title editor over tab *tab* and returns it (null when the
## index is out of range). Enter commits, Escape or clicking away cancels.
func begin_rename(tab: int) -> LineEdit:
	if tab < 0 or tab >= _tab_bar.tab_count:
		return null
	_cancel_rename()

	var edit := LineEdit.new()
	edit.name = "TabRenameEdit"
	edit.text = _tab_bar.get_tab_title(tab)
	edit.select_all_on_focus = true
	var rect: Rect2 = _tab_bar.get_tab_rect(tab)
	edit.position = rect.position
	edit.size = Vector2(maxf(rect.size.x, 80.0), rect.size.y)
	# The editor outlives the index it was opened over — a tab closing under it
	# renumbers everything after it — so the commit is bound to the VIEW and
	# resolves its index again at commit time.
	var view = _tab_bar.get_tab_metadata(tab)
	# Every callback names the editor it belongs to. begin_rename closes the
	# previous editor but cannot free it on the spot, so the old editor is still
	# focused when the new one grabs focus — and the focus_exited that fires
	# then would otherwise close its own replacement.
	edit.text_submitted.connect(func(new_title: String) -> void:
		if edit == _rename_edit:
			_commit_rename_for(view, new_title)
	)
	edit.focus_exited.connect(_cancel_rename_for.bind(edit))
	edit.gui_input.connect(func(e: InputEvent) -> void:
		if e.is_action_pressed("ui_cancel"):
			_cancel_rename_for(edit)
	)

	_rename_edit = edit
	_tab_bar.add_child(edit)
	edit.grab_focus()
	return edit


## Commits the inline editor onto the tab it was opened over, wherever that
## tab has moved to since. A view that has been closed takes its rename with
## it rather than renaming whichever tab now holds its old index.
func _commit_rename_for(view, new_title: String) -> void:
	_close_rename_edit()
	if view == null or not is_instance_valid(view):
		return
	var tab: int = _tab_index_of(view)
	if tab >= 0:
		apply_title(tab, new_title)


## The tab holding *view*, or -1 when it has none.
func _tab_index_of(view) -> int:
	for tab in range(_tab_bar.tab_count):
		if _tab_bar.get_tab_metadata(tab) == view:
			return tab
	return -1


## The ONE place a tab title is applied — the inline rename editor and
## MCPTerminalTools' create/promote all come through here. It leaves any open
## rename editor alone: an MCP create or promote can land while a person is
## typing in one, and closing it would drop their edit.
## Applies *new_title* to the tab AND to the session behind it: the session name
## is what minerva_terminal_list reports and what the notify resolver addresses,
## so a rename that stopped at the TabBar would leave the tab unaddressable
## under its visible name. The PTY keeps the name it was spawned with
## (TerminalSession.launch_name) — env cannot be changed under a running child.
func apply_title(tab: int, new_title: String) -> void:
	var title: String = new_title.strip_edges()
	if title.is_empty() or tab < 0 or tab >= _tab_bar.tab_count:
		return
	_tab_bar.set_tab_title(tab, title)

	var terminal = _tab_bar.get_tab_metadata(tab)
	if terminal == null or not terminal.has_method("get_session"):
		return
	var session = terminal.get_session()
	if session != null and is_instance_valid(session) and "session_name" in session:
		session.session_name = title


func _cancel_rename() -> void:
	_close_rename_edit()


## Cancels only if *edit* is still THE open editor. A superseded editor goes on
## emitting focus_exited until it is freed, and that belongs to nobody.
func _cancel_rename_for(edit: LineEdit) -> void:
	if edit != _rename_edit:
		return
	_close_rename_edit()


## Drops the editor without touching any title. The focus_exited connection
## goes first, so the focus the node loses on its way out reaches no handler,
## and the reference is cleared before the free.
func _close_rename_edit() -> void:
	var edit := _rename_edit
	_rename_edit = null
	if edit == null or not is_instance_valid(edit):
		return
	var cancel := _cancel_rename_for.bind(edit)
	if edit.focus_exited.is_connected(cancel):
		edit.focus_exited.disconnect(cancel)
	edit.queue_free()


func _on_tab_bar_tab_changed(tab: int) -> void:
	if tab == -1:
		return

	for child in _panel.get_children():
		child.visible = false

	# Metadata is written synchronously in add_terminal(), but guard defensively.
	if not _tab_bar.get_tab_metadata(tab):
		await _tab_metadata_written

	var terminal = _tab_bar.get_tab_metadata(tab)
	if terminal:
		terminal.visible = true
		focus_requested.emit()


func _on_tab_bar_tab_close_pressed(tab: int) -> void:
	close_terminal(tab)


func _on_notify_ledger_changed(_delivery_id: String) -> void:
	_refresh_retained()


## Opens the harness sessions dialog for the current tab's terminal.
func open_sessions_dialog() -> void:
	var dialog = load(SESSIONS_DIALOG_PATH).instantiate()
	var view = get_active_terminal()
	var session = view.get_session() if view != null else null
	dialog.terminal_id = str(session.terminal_id) if session != null else ""
	add_child(dialog)
	dialog.popup_centered()


## The session registry signals while it is read (a container binding itself
## during the refresh), so its changes refresh the tooltips once, deferred.
func _queue_retained_refresh() -> void:
	if _retained_refresh_queued:
		return
	_retained_refresh_queued = true
	_refresh_retained.call_deferred()


## The notifications still open for each tab's terminal: the tab's tooltip
## names the registered session the tab holds and lists them with their state
## and reason, and the header counts them.
func _refresh_retained() -> void:
	_retained_refresh_queued = false
	var ledger = load(NOTIFY_LEDGER_PATH).shared()
	var sessions = load(SESSION_REGISTRY_PATH).shared()
	var total: int = 0
	for tab in range(_tab_bar.tab_count):
		var terminal = _tab_bar.get_tab_metadata(tab)
		var session = terminal.get_session() if terminal != null and terminal.has_method("get_session") else null
		if session == null or not is_instance_valid(session) or not "terminal_id" in session:
			continue
		var lines := PackedStringArray()
		for record: Dictionary in ledger.list(str(session.terminal_id), true):
			var why: String = str(record.get("hold_reason", ""))
			lines.append("%s %s%s: %s" % [str(record["delivery_id"]), str(record["state"]),
				(" (%s)" % why) if not why.is_empty() else "", str(record["text"]).left(80)])
		total += lines.size()
		var tip: String = "" if lines.is_empty() else "Notifications waiting:\n" + "\n".join(lines)
		var identity: String = sessions.identity_for_terminal(str(session.terminal_id))
		if not identity.is_empty():
			tip = "Session: %s\n%s" % [identity, tip]
		_tab_bar.set_tab_tooltip(tab, tip.strip_edges())
	_retained_label.visible = total > 0
	_retained_label.text = "%d notification%s waiting" % [total, "" if total == 1 else "s"]
	_retained_label.tooltip_text = "Minerva is keeping these until the terminal can take them; hover a tab for details."

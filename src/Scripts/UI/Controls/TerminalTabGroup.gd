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

var _tab_bar: TabBar
var _panel: PanelContainer

# Internal signal used to synchronise tab metadata writes with tab_changed.
signal _tab_metadata_written()


func _init() -> void:
	theme = _TERMINAL_THEME
	_build_ui()

func _ready() -> void:
	visibility_changed.connect(_on_visibility_changed)


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
	header.add_child(_tab_bar)

	var add_btn := Button.new()
	add_btn.name = "AddButton"
	add_btn.text = "+"
	add_btn.flat = true
	add_btn.pressed.connect(func() -> void: add_terminal())
	header.add_child(add_btn)

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

	_panel.add_child(terminal, true)

	_tab_bar.add_tab(terminal.name)
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

	var terminal: TerminalNew = _tab_bar.get_tab_metadata(tab)
	_tab_bar.remove_tab(tab)
	if terminal:
		# Tab close = session close (preserve today's behaviour).
		var session = terminal.get_session() if terminal.has_method("get_session") else null
		if terminal.has_method("detach_session"):
			terminal.detach_session()
		if session:
			var registry = _get_session_registry()
			if registry:
				registry.close_session(session.terminal_id)
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
	if is_visible_in_tree() and _tab_bar.tab_count == 0:
		add_terminal()


func _on_tab_bar_tab_changed(tab: int) -> void:
	if tab == -1:
		return

	for child in _panel.get_children():
		child.visible = false

	# Metadata is written synchronously in add_terminal(), but guard defensively.
	if not _tab_bar.get_tab_metadata(tab):
		await _tab_metadata_written

	var terminal: TerminalNew = _tab_bar.get_tab_metadata(tab)
	if terminal:
		terminal.visible = true
		focus_requested.emit()


func _on_tab_bar_tab_close_pressed(tab: int) -> void:
	close_terminal(tab)

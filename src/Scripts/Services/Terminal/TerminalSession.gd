class_name TerminalSession
extends Node

## A headless terminal session: owns the PTY + ghostty-vt cell grid (the
## `Terminal` GDExtension node) with NO visible UI. Lives parented under
## TerminalSessionRegistry so the extension node still `_process`es and pumps
## the PTY even when no TerminalNew view is attached.
##
## TerminalNew is now a *view* that attaches to one of these. The PTY/vt core
## (forkpty, cell grid, scrollback, bell, shell-exit) lives here; rendering,
## input, command-blocks, selection live in the view.
##
## Extraction lineage (chat-passthrough DCR, T1): the PTY-start +
## bell/shell-exit plumbing + cell→text extraction were CUT from
## TerminalNew.gd (_ready PTY portion, _on_bell, _on_shell_exited,
## _extract_row_text*, _viewport_to_screen_row) and live here verbatim so
## MCPTerminalTools / CapabilityBroker keep working unchanged via the view's
## delegating shims.

## Standalone BEL from the PTY (OSC-terminating BELs excluded by the ghostty
## shim). Re-emitted from the underlying Terminal node's `bell` signal.
signal bell_rung(count: int)

## The PTY child (shell) exited on its own — not a stop()/close.
## Re-emitted from the underlying Terminal node's `process_exited`.
signal shell_exited(exit_code: int)

## libghostty-vt cell-grid changed — views redraw on this.
signal vt_state_changed()

## Shell-prompt markers (block detection). Re-emitted for the view.
signal prompt_start()
signal prompt_end()

## Raw legacy output (used by the view's Windows CWD-regex prompt detection).
signal output_received(text: String, type: int)

# The Terminal GDExtension node — owns forkpty + ghostty-vt. May be null if the
# extension isn't available (e.g. CI without the built binary).
var terminal = null
var terminal_available: bool = false

# Stable identity for registry lookups. Distinct from the view's instance id.
var terminal_id: String = ""

# Human-facing name (tab title default).
var session_name: String = "Terminal"

# Terminal dimensions in cells. The view drives resizes via resize().
var _cols: int = 80
var _rows: int = 24

# True once start() succeeded.
var started: bool = false

## Cumulative bell count since terminal start. Monotonic, so waiters can
## snapshot it and diff instead of racing the signal.
var bell_serial: int = 0

## Set once if the shell exits on its own. null until then.
var shell_exit_code = null


func _init(p_name: String = "Terminal") -> void:
	session_name = p_name
	terminal_id = str(get_instance_id())


func _ready() -> void:
	_create_terminal_node()


## Builds the Terminal extension node, wires its signals, and adds it as a child
## of THIS session (not a Control) so it processes headless.
func _create_terminal_node() -> void:
	if not ClassDB.class_exists("Terminal"):
		push_error("Terminal GDExtension not available - terminal functionality disabled")
		return
	terminal = ClassDB.instantiate("Terminal")
	terminal_available = true
	add_child(terminal)

	# libghostty-vt cell-grid state changes
	if terminal.has_signal("vt_state_changed"):
		terminal.vt_state_changed.connect(_on_vt_state_changed)
	else:
		push_warning("[TerminalSession] vt_state_changed signal NOT found — libghostty-vt not available")

	# Legacy output signal (Windows prompt detection lives in the view)
	terminal.output_received.connect(_on_output_received)

	# Shell prompt markers → block detection (in the view)
	terminal.on_shell_prompt_start.connect(_on_prompt_start)
	terminal.on_shell_prompt_end.connect(_on_prompt_end)

	# Bell + shell-exit (guarded: older extension builds lack these)
	if terminal.has_signal("bell"):
		terminal.bell.connect(_on_bell)
	if terminal.has_signal("process_exited"):
		terminal.process_exited.connect(_on_shell_exited)


## Starts the PTY at the given grid size. Idempotent guard via `started`.
func start(cols: int, rows: int) -> bool:
	if not terminal_available:
		return false
	if started:
		return true
	_cols = maxi(1, cols)
	_rows = maxi(1, rows)
	var ok: bool = terminal.start(_cols, _rows)
	started = ok
	return ok


## Resize the PTY grid. Views call this from their layout handler.
func resize(cols: int, rows: int) -> void:
	if not terminal_available:
		return
	_cols = maxi(1, cols)
	_rows = maxi(1, rows)
	if terminal.has_method("resize"):
		terminal.resize(_cols, _rows)


func get_cols() -> int:
	return _cols


func get_rows() -> int:
	return _rows


func is_alive() -> bool:
	return terminal_available and started and shell_exit_code == null


# ── PTY primitives ─────────────────────────────────────────────────────

## Write raw bytes/text to the PTY. Non-blocking.
func write_input(text: String) -> void:
	if terminal_available:
		terminal.write_input(text)


func get_scroll_info() -> Dictionary:
	if terminal_available and terminal.has_method("get_scroll_info"):
		return terminal.get_scroll_info()
	return {}


func scroll_viewport(delta: int) -> void:
	if terminal_available and terminal.has_method("scroll_viewport"):
		terminal.scroll_viewport(delta)


func get_cursor() -> Dictionary:
	if terminal_available and terminal.has_method("get_cursor"):
		return terminal.get_cursor()
	return {}


func get_cell(col: int, row: int) -> Dictionary:
	if terminal_available and terminal.has_method("get_cell"):
		return terminal.get_cell(col, row)
	return {}


func get_cell_screen(col: int, row: int) -> Dictionary:
	if terminal_available and terminal.has_method("get_cell_screen"):
		return terminal.get_cell_screen(col, row)
	return {}


func get_plain_text() -> String:
	if terminal_available and terminal.has_method("get_plain_text"):
		return terminal.get_plain_text()
	return ""


func encode_key(gk: int, action: int, mods: int, utf8_text: String) -> PackedByteArray:
	if terminal_available and terminal.has_method("encode_key"):
		return terminal.encode_key(gk, action, mods, utf8_text)
	return PackedByteArray()


# ── Cell → text extraction (scrollback access, no UI) ──────────────────

func extract_row_text(row: int) -> String:
	## Read one row of text from the terminal cells (viewport-relative).
	if not terminal_available:
		return ""
	var line: String = ""
	var max_cols: int = maxi(_cols, 256)
	for col in range(max_cols):
		var cell: Dictionary = terminal.get_cell(col, row)
		if cell.is_empty():
			break  # out of bounds
		var cp: int = cell.get("codepoint", 0)
		if cp >= 32:
			line += char(cp)
		else:
			line += " "  # unwritten cell or control char → space
	return line.rstrip(" ")


func extract_row_text_screen(screen_row: int) -> String:
	## Read one row of text using screen-absolute coordinates (scrollback-safe).
	## Uses a generous max column count because scrollback rows may have been
	## written at a wider terminal size than the current one. Does NOT break on
	## codepoint 0 mid-row — programs like ls use cursor positioning to create
	## columns, leaving gaps of unwritten cells.
	if not terminal_available:
		return ""
	if not terminal.has_method("get_cell_screen"):
		return extract_row_text(screen_row)  # fallback
	var line: String = ""
	var max_cols: int = maxi(_cols, 256)
	for col in range(max_cols):
		var cell: Dictionary = terminal.get_cell_screen(col, screen_row)
		if cell.is_empty():
			break  # out of bounds — end of row
		var cp: int = cell.get("codepoint", 0)
		if cp >= 32:
			line += char(cp)
		else:
			line += " "  # unwritten cell or control char → space
	return line.rstrip(" ")


func viewport_to_screen_row(viewport_row: int) -> int:
	## Convert a viewport-relative row to a screen-absolute row.
	var info: Dictionary = get_scroll_info()
	var total: int = info.get("total_rows", 0)
	var viewport: int = info.get("viewport_rows", 0)
	# Screen row = viewport_row + scroll_offset. When at bottom: total - viewport.
	var scroll_offset: int = maxi(0, total - viewport)
	return viewport_row + scroll_offset


## Plain-text dump of the current screen viewport (no trailing blank lines).
## Used by views to render existing scrollback on attach.
func read_viewport_text() -> String:
	if not terminal_available:
		return ""
	var info: Dictionary = get_scroll_info()
	var total_rows: int = info.get("total_rows", 0)
	var viewport_rows: int = info.get("viewport_rows", _rows)
	var viewport_start: int = maxi(0, total_rows - viewport_rows)
	var lines: PackedStringArray = []
	for row in range(viewport_start, total_rows):
		lines.append(extract_row_text_screen(row))
	while lines.size() > 0 and lines[lines.size() - 1].strip_edges().is_empty():
		lines.remove_at(lines.size() - 1)
	return "\n".join(lines)


# ── Signal re-emitters ─────────────────────────────────────────────────

func _on_bell(count: int) -> void:
	bell_serial += count
	bell_rung.emit(count)


func _on_shell_exited(exit_code: int) -> void:
	shell_exit_code = exit_code
	shell_exited.emit(exit_code)


func _on_vt_state_changed() -> void:
	vt_state_changed.emit()


func _on_output_received(text: String, type: int) -> void:
	output_received.emit(text, type)


func _on_prompt_start() -> void:
	prompt_start.emit()


func _on_prompt_end() -> void:
	prompt_end.emit()


## Stops the PTY and frees the extension node. Called by the registry on close.
func close() -> void:
	if terminal and is_instance_valid(terminal):
		if terminal.has_method("stop"):
			terminal.stop()
		terminal.queue_free()
		terminal = null
	terminal_available = false
	started = false

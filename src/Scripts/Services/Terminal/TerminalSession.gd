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
const ShellEnvironment := preload("res://Scripts/Services/Terminal/ShellEnvironment.gd")
const TerminalInputArbiter := preload("res://Scripts/Services/Terminal/TerminalInputArbiter.gd")
const AgentContainerForeground := preload("res://Scripts/Services/Terminal/AgentContainerForeground.gd")

signal shell_exited(exit_code: int)

## libghostty-vt cell-grid changed — views redraw on this.
signal vt_state_changed()

## Shell-prompt markers (block detection). Re-emitted for the view.
signal prompt_start()
signal prompt_end()

## A full-screen erase invalidates view-owned command-block overlays. The bool
## distinguishes clearing the viewport (2J) from clearing scrollback (3J).
signal screen_cleared(include_scrollback: bool)

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

## True when start() handed the working directory to the extension natively
## (PTY child spawns there). False → callers wanting a cwd must fall back to
## writing a `cd` line (older extension binaries without set_start_directory).
var start_directory_applied: bool = false

## The name the PTY child was spawned with: it reaches the child as
## MINERVA_TERMINAL_NAME and cannot be changed afterwards. Empty until start()
## spawns a child. session_name CAN change later (a tab rename), so the two
## disagree from then on and listings report both.
var launch_name: String = ""

## Working directory start() was asked for. Empty when no caller supplied one:
## the child then inherits Minerva's own cwd, which this class does not know.
## Recorded even when start_directory_applied is false — the `cd` fallback puts
## the shell in the same directory before anything is launched in it.
var launch_cwd: String = ""

## Session creation time, epoch milliseconds. Set at construction, so it
## precedes the PTY start.
var created_at_ms: int = 0

## Cumulative bell count since terminal start. Monotonic, so waiters can
## snapshot it and diff instead of racing the signal.
var bell_serial: int = 0

## Set once if the shell exits on its own. null until then.
var shell_exit_code = null

## Epoch milliseconds of the last keystroke or paste a HUMAN sent through a
## view of this session; 0 when none yet. Agent writes (MCP, relay) do not
## stamp it: it exists so a notification can yield to a person mid-sentence.
var last_input_ms: int = 0

## The same keystroke stamped with the monotonic clock, for guards that must
## not be fooled by a wall-clock step. 0 when no human input yet.
var last_input_ticks_ms: int = 0

# A session may have at most one rendering view. Keeping this on the session
# makes ownership survive transient scene-tree removal during split rebuilds.
var _attached_view: WeakRef = null

# The one gate every byte to the PTY passes. Built in _ready().
var _arbiter: TerminalInputArbiter = null

## The agent container's tmux reports whether its pane is in a mode by setting
## this terminal's title to this prefix, the attachment's lease generation, ":"
## and 0 or 1 (scripts/agent-container/tmux.conf). Anything in the pane can
## only set the pane's own title, not this one.
const PANE_MODE_TITLE_PREFIX := "minerva-pane-mode:"

# The last report from the attachment in front when it arrived:
# {in_mode, container, generation}, or {} when the last title was not a well
# formed report.
var _pane_mode_report: Dictionary = {}


func _init(p_name: String = "Terminal") -> void:
	session_name = p_name
	terminal_id = str(get_instance_id())
	created_at_ms = int(Time.get_unix_time_from_system() * 1000.0)


func _ready() -> void:
	_create_terminal_node()
	_arbiter = TerminalInputArbiter.new()
	_arbiter.setup(self)


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
	if terminal.has_signal("seq_erase_entire_screen"):
		terminal.seq_erase_entire_screen.connect(_on_screen_cleared.bind(false))
	if terminal.has_signal("seq_erase_saved_lines"):
		terminal.seq_erase_saved_lines.connect(_on_screen_cleared.bind(true))

	# Bell, title + shell-exit (guarded: older extension builds lack these)
	if terminal.has_signal("bell"):
		terminal.bell.connect(_on_bell)
	if terminal.has_signal("vt_title_changed"):
		terminal.vt_title_changed.connect(_on_vt_title_changed)
	if terminal.has_signal("process_exited"):
		terminal.process_exited.connect(_on_shell_exited)


## Starts the PTY at the given grid size. Idempotent guard via `started`.
## start_dir (optional) is the child process's working directory — applied
## natively when the extension binary supports it (has_method guard keeps
## older binaries working; callers check start_directory_applied).
func start(cols: int, rows: int, start_dir: String = "") -> bool:
	if not terminal_available:
		return false
	if started:
		return true
	# Every PTY child inherits Minerva's process environment, and the shell is
	# rc-less by design, so this is the one chokepoint where the user's real
	# login PATH can still be installed. Idempotent: only the first call probes.
	ShellEnvironment.apply_login_path()
	_cols = maxi(1, cols)
	_rows = maxi(1, rows)
	launch_cwd = start_dir
	# The child learns its own address (MINERVA_TERMINAL_ID / _NAME) so a
	# program in the terminal can name this tab to the host.
	launch_name = session_name
	if terminal.has_method("set_identity"):
		terminal.set_identity(terminal_id, session_name)
	if not start_dir.is_empty() and terminal.has_method("set_start_directory"):
		terminal.set_start_directory(start_dir)
		start_directory_applied = true
	var ok: bool = terminal.start(_cols, _rows)
	started = ok
	return ok


## The name fields of a listing entry: the address this session answers to now,
## plus the name the running child still believes when a rename made the two
## differ. One derivation so the listing cannot claim they agree.
func name_fields() -> Dictionary:
	var fields: Dictionary = {"name": session_name}
	if not launch_name.is_empty() and launch_name != session_name:
		fields["launch_name"] = launch_name
	return fields


func attach_view(view: Node) -> bool:
	var current: Node = get_attached_view()
	if current != null and current != view:
		return false
	_attached_view = weakref(view)
	return true


func detach_view(view: Node) -> void:
	if get_attached_view() == view:
		_attached_view = null


func get_attached_view() -> Node:
	if _attached_view == null:
		return null
	var view := _attached_view.get_ref() as Node
	if view == null or not is_instance_valid(view):
		_attached_view = null
		return null
	return view


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

## Write raw bytes/text to the PTY through the arbiter. Non-blocking: the text
## goes straight out unless a write transaction holds the PTY, in which case it
## is queued and released, unchanged and in order, when that transaction ends.
## Returns the arbiter receipt, which says which of those two happened; callers
## that only want the bytes sent may ignore it.
func write_input(text: String) -> Dictionary:
	if _arbiter != null:
		return _arbiter.submit(text, false)
	write_pty(text)
	return {"success": true, "queued": false, "bytes_sent": text.length()}


## The same entry for input a PERSON produced: stamps the typing clocks (which
## the transaction guards read) and then goes through the arbiter. Returns the
## arbiter receipt, which says whether the text was queued.
func write_human_input(text: String) -> Dictionary:
	note_human_input()
	if _arbiter == null:
		write_pty(text)
		return {"success": true, "queued": false, "bytes_sent": text.length()}
	return _arbiter.submit(text, true)


## Bypasses the arbiter and writes to the PTY. Only the arbiter calls this;
## everything else goes through write_input / write_human_input.
func write_pty(text: String) -> void:
	if terminal_available:
		terminal.write_input(text)


## Admit a guarded body + pause + Enter as one transaction (see
## TerminalInputArbiter.begin_transaction for the options and the result).
func begin_write_transaction(body: String, options: Dictionary = {}) -> Dictionary:
	if _arbiter == null:
		return {"success": false, "held": true,
			"error": "this terminal has no input arbiter; nothing was written"}
	return _arbiter.begin_transaction(body, options)


## The session's arbiter, for callers that need its signals or records.
func get_input_arbiter() -> TerminalInputArbiter:
	return _arbiter


## Views call this for every key or paste a person sends, before writing it.
func note_human_input() -> void:
	last_input_ms = int(Time.get_unix_time_from_system() * 1000.0)
	last_input_ticks_ms = Time.get_ticks_msec()


## Whether this platform can say who holds the PTY at all. Where it cannot
## (ConPTY), the host falls back to other identity; where it can, an empty
## answer means "unreadable right now", never "nobody".
func foreground_supported() -> bool:
	return terminal_available and terminal.has_method("get_foreground_process") \
		and OS.get_name() != "Windows"


## The process group holding the PTY: {pid, name, argv, exe, exe_name}, or {}
## when the query failed (not running, tcgetpgrp or /proc unreadable). `name`
## is the main thread's name, `exe`/`exe_name` the running binary's path and
## basename (empty where the executable could not be read). When the PTY's
## foreground is an agent-container launcher bound to this tab, the answer is
## the program in front inside that container, plus `container` (its session
## name) and `container_generation` (that attachment's lease generation); see
## AgentContainerForeground.
func get_foreground_process() -> Dictionary:
	if terminal_available and terminal.has_method("get_foreground_process"):
		return AgentContainerForeground.resolve(terminal_id, terminal.get_foreground_process())
	return {}


## Whether bytes written now would reach the program in the agent container's
## tmux pane or drive tmux itself (a person has the pane in copy, clock or
## tree mode): TerminalInputArbiter.PANE_MODE_ACTIVE or _LIVE, from the last
## report the attachment in front sent; _UNKNOWN for an attachment that has
## sent none (an image or launcher without the report, or none since it
## attached); or
## _NOT_CONTAINER when no agent container is in front. Reports arrive after
## tmux changes mode, not with it; see TerminalInputArbiter.check_guards.
func pane_mode() -> String:
	var front: Dictionary = get_foreground_process()
	if str(front.get("container", "")).is_empty():
		return TerminalInputArbiter.PANE_MODE_NOT_CONTAINER
	if _pane_mode_report.is_empty() \
			or _pane_mode_report["container"] != str(front["container"]) \
			or _pane_mode_report["generation"] != str(front.get("container_generation", "")):
		return TerminalInputArbiter.PANE_MODE_UNKNOWN
	return TerminalInputArbiter.PANE_MODE_ACTIVE if _pane_mode_report["in_mode"] \
		else TerminalInputArbiter.PANE_MODE_LIVE


## Which agent harness the foreground process is: "claude", "codex", or ""
## for anything else (the shell itself included). It keys on the PROGRAM (see
## program_of). A harness is either the
## program itself (a native claude or codex binary) or the script an
## interpreter was started on: node on Claude Code's npm package, or any
## interpreter on a script named after the harness (`codex.js` in the npm
## package, or a script named codex run by an interpreter). Only the
## interpreter's first argument counts, so `less codex` is a pager, not a
## harness.
const HARNESS_INTERPRETERS := ["node", "bun", "deno", "python", "python3"]

## The program in the foreground, lower-cased. The running BINARY decides:
## when the executable's basename names a program it is the answer, whatever
## argv[0] claims (`exec -a codex sleep` is sleep). argv[0] stands in only
## when the executable's name says nothing — empty, or a launcher symlink
## whose target is named by version (Claude Code's exe resolves to
## ".../versions/2.1.x") — such an install is therefore identified by
## argv[0] alone, and a rewritten or empty argv leaves it unrecognised. The
## thread name is the last resort: a runtime may rename its main thread
## (node calls it "MainThread").
static func program_of(process: Dictionary) -> String:
	var exe_name: String = str(process.get("exe_name", ""))
	if exe_name.is_empty():
		exe_name = str(process.get("exe", "")).get_file()
	exe_name = exe_name.to_lower()
	var argv0: String = ""
	var argv: Array = Array(process.get("argv", []))
	if argv.size() > 0:
		argv0 = str(argv[0]).get_file().to_lower()
	if not exe_name.is_empty() and not _is_version_like(exe_name):
		return exe_name
	if not argv0.is_empty():
		return argv0
	if not exe_name.is_empty():
		return exe_name
	return str(process.get("name", "")).to_lower()


## The harness a native binary's name denotes: "codex" or "claude" exactly,
## or the release filename a launcher symlink may point at
## ("codex-x86_64-unknown-linux-gnu", "claude-2.1.278"): the name followed by
## a separator. Anything else ("codexpert") is nobody.
static func _native_harness(program: String) -> String:
	for harness in ["claude", "codex"]:
		if program == harness:
			return harness
		if program.begins_with(harness) and program.length() > harness.length():
			var next: String = program[harness.length()]
			if next == "-" or next == "_" or next == ".":
				return harness
	return ""


## "2.1.278": digits and dots only — a launcher target named by version,
## which identifies no program.
static func _is_version_like(basename: String) -> bool:
	if basename.is_empty():
		return false
	for i in range(basename.length()):
		var c: int = basename.unicode_at(i)
		if not ((c >= 48 and c <= 57) or c == 46):
			return false
	return true


static func harness_of(process: Dictionary) -> String:
	var program: String = program_of(process)
	var native: String = _native_harness(program)
	if not native.is_empty():
		return native
	if not (program in HARNESS_INTERPRETERS or program.begins_with("python3.")):
		return ""
	var argv: Array = Array(process.get("argv", []))
	if argv.size() < 2:
		return ""
	var script: String = str(argv[1]).to_lower()
	var base: String = script.get_file().get_basename()
	if base == "claude" or base == "codex":
		return base
	return "claude" if script.contains("claude-code") else ""


func harness_name() -> String:
	return harness_of(get_foreground_process())


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
	_pane_mode_report = {}
	shell_exited.emit(exit_code)


## A report names the attachment that sent it, so one that arrives after
## another attachment took this tab (titles are delivered a frame late) is
## ignored rather than taken as the new attachment's.
func _on_vt_title_changed(title: String) -> void:
	var fields: PackedStringArray = title.trim_prefix(PANE_MODE_TITLE_PREFIX).split(":")
	if not title.begins_with(PANE_MODE_TITLE_PREFIX) or fields.size() != 2 \
			or fields[0].is_empty() or not fields[1] in ["0", "1"]:
		_pane_mode_report = {}
		return
	var front: Dictionary = get_foreground_process()
	if str(front.get("container", "")).is_empty() \
			or str(front.get("container_generation", "")) != fields[0]:
		return
	_pane_mode_report = {"in_mode": fields[1] == "1", "container": str(front["container"]),
		"generation": fields[0]}


func _on_vt_state_changed() -> void:
	vt_state_changed.emit()


func _on_output_received(text: String, type: int) -> void:
	output_received.emit(text, type)


func _on_prompt_start() -> void:
	prompt_start.emit()


func _on_prompt_end() -> void:
	prompt_end.emit()


func _on_screen_cleared(include_scrollback: bool) -> void:
	screen_cleared.emit(include_scrollback)


## Stops the PTY and frees the extension node. Called by the registry on close.
func close() -> void:
	if terminal and is_instance_valid(terminal):
		if terminal.has_method("stop"):
			terminal.stop()
		terminal.queue_free()
		terminal = null
	terminal_available = false
	started = false

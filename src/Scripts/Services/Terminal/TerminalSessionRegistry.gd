class_name TerminalSessionRegistry
extends Node

## Owns all live TerminalSession objects. Sessions parent the `Terminal`
## GDExtension node, so a session can run a PTY with NO visible Control — they
## live here, under SingletonObject, not under any TerminalNew view.
##
## chat-passthrough DCR T1: this is the home for background/headless terminals.
## A TerminalNew view attaches to a session for rendering and detaches without
## killing it; closing a terminal TAB asks the registry to close the session
## (preserving today's tab-close = PTY-close UX).

signal session_created(session)
signal session_closed(session_id: String)

# Preload (not class_name) to avoid autoload/script-run parse-order issues where
# the TerminalSession global isn't resolved when this is loaded via load().
const TerminalSessionScript := preload("res://Scripts/Services/Terminal/TerminalSession.gd")

# session_id (String) -> TerminalSession
var _sessions: Dictionary = {}


## Creates a new session, parents it (so the PTY processes headless), and
## optionally starts it at the given grid size. Returns the session.
## If cols/rows are <= 0 the caller is expected to start() later (e.g. once a
## view supplies real layout geometry).
func create_session(p_name: String = "Terminal", cols: int = 80, rows: int = 24):
	var session = TerminalSessionScript.new(p_name)
	add_child(session)  # triggers _ready → builds the Terminal extension node
	_sessions[session.terminal_id] = session
	if cols > 0 and rows > 0:
		session.start(cols, rows)
	session_created.emit(session)
	return session


## Look up a session by its id. Returns null if absent.
func get_session(session_id: String):
	return _sessions.get(session_id, null)


## All live sessions (insertion order).
func list_sessions() -> Array:
	return _sessions.values()


func session_count() -> int:
	return _sessions.size()


func has_session(session_id: String) -> bool:
	return _sessions.has(session_id)


## Closes the session (stops its PTY, frees the extension node, frees the
## session node) and drops it from the registry. No-op if unknown.
func close_session(session_id: String) -> void:
	var session = _sessions.get(session_id, null)
	if session == null:
		return
	_sessions.erase(session_id)
	session.close()
	session.queue_free()
	session_closed.emit(session_id)

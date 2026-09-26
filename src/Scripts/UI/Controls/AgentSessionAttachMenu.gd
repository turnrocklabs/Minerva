extends Node
## The terminal tab's right-click menu: "Attach agent session here" for each
## running agent-container session. Picking one fronts it in that tab through
## AgentSessionStore.attach, taking it over from any tab that fronts it now
## (the GUI twin of minerva_agent_session_attach). A refusal or failure is
## shown in ResultDialog; success needs no dialog, the tab shows the session.
## Scene: res://Scenes/AgentSessionAttachMenu.tscn; TerminalTabGroup adds it
## and calls open_at(). It frees itself once the menu and dialog are done.

const AgentSessionStore := preload("res://Scripts/Services/AgentSessions/AgentSessionStore.gd")
## A keystroke in the tab this recent refuses the attach: the command would be
## appended to whatever the person was typing at the prompt.
const TYPED_WINDOW_MS := 1500

## The tab's terminal session; set before the node enters the tree.
var terminal: TerminalSession = null

## Session ids by item id, filled once the list arrives.
var _ids: PackedStringArray = []
var _attaching: bool = false
## True while the session list is being fetched; the node waits for it.
var _loading: bool = false

@onready var _menu: PopupMenu = %Menu
@onready var _result: AcceptDialog = %ResultDialog


func _ready() -> void:
	_menu.id_pressed.connect(_on_id_pressed)
	# PopupMenu hides before it emits id_pressed, so the check waits a frame
	# for a pick to start its attach.
	_menu.popup_hide.connect(func() -> void: _free_if_done.call_deferred())
	_result.visibility_changed.connect(func() -> void: _free_if_done.call_deferred())


## Shows the menu at `at` (viewport coordinates) and fills it with the
## running sessions.
func open_at(at: Vector2i) -> void:
	_menu.popup(Rect2i(at, Vector2i.ZERO))
	_load_sessions()


func _free_if_done() -> void:
	if not _menu.visible and not _result.visible and not _attaching and not _loading:
		queue_free()


func _load_sessions() -> void:
	_menu.clear()
	_menu.add_item("Loading agent sessions…")
	_menu.set_item_disabled(0, true)
	_loading = true
	var listed: Dictionary = await AgentSessionStore.shared().list_sessions()
	_loading = false
	if not _menu.visible:
		_free_if_done()
		return
	_menu.clear()
	_ids.clear()
	if not bool(listed.get("ok", false)):
		_menu.add_item("Agent sessions unavailable: %s" % str(listed.get("error", "")).left(80))
		_menu.set_item_disabled(0, true)
		return
	var here: String = str(terminal.terminal_id) if terminal != null else ""
	var sessions: Array = listed.get("sessions", []) if listed.get("sessions") is Array else []
	for session: Variant in sessions:
		if not session is Dictionary or str((session as Dictionary).get("state", "")) != "running":
			continue
		var id: String = str(session["id"])
		var held: String = str(session.get("attached_terminal", ""))
		var label: String = "Attach agent session here: %s" % id
		if held == here and not here.is_empty():
			label += " (attached here)"
		elif not held.is_empty():
			label += " (take over from %s)" % _tab_name(held)
		_menu.add_item(label, _ids.size())
		_ids.append(id)
	if _ids.is_empty():
		_menu.add_item("No running agent sessions (Preferences > Containers)")
		_menu.set_item_disabled(0, true)
	# The popup was sized for the loading line.
	_menu.reset_size()


func _on_id_pressed(item: int) -> void:
	if item < 0 or item >= _ids.size() or terminal == null:
		return
	_attaching = true
	var answer: Dictionary = await AgentSessionStore.shared().attach(_ids[item], terminal, TYPED_WINDOW_MS)
	_attaching = false
	var ok: bool = bool(answer.get("ok", false))
	if ok and bool(answer.get("pane_readable", true)):
		_free_if_done()
		return
	_result.dialog_text = str(answer.get("message", "")) if ok else str(answer.get("error", "the attach failed"))
	_result.popup_centered()


## The tab name of the terminal holding a session, else its id.
static func _tab_name(terminal_id: String) -> String:
	var registry = SingletonObject.get_terminal_session_registry()
	var session = registry.get_session(terminal_id) if registry != null else null
	return str(session.session_name) if session != null else "terminal %s" % terminal_id

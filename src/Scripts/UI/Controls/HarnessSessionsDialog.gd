extends Window
## Lists every registered harness session (identity, role, harness, terminal,
## liveness) and registers the tab it was opened from under an identity and a
## role — the GUI twin of minerva_session_register / minerva_session_forget.
## Scene: res://Scenes/HarnessSessionsDialog.tscn. Opened from the Sessions
## button of a TerminalTabGroup.

const HarnessSessionRegistry := preload("res://Scripts/Services/Terminal/HarnessSessionRegistry.gd")
const TERMINAL_TOOLS_PATH := "res://Scripts/Services/MCP/Modules/MCPTerminalTools.gd"

enum Column { IDENTITY, ROLE, HARNESS, TERMINAL, LIVENESS }

## The terminal "Register this tab" registers; set before the dialog enters
## the tree. Empty disables registration.
var terminal_id: String = ""

var _refresh_queued: bool = false

@onready var _tree: Tree = %Sessions
@onready var _identity: LineEdit = %Identity
@onready var _role: LineEdit = %Role
@onready var _register: Button = %Register
@onready var _forget: Button = %Forget
@onready var _this_tab: Label = %ThisTab
@onready var _status: Label = %Status


func _ready() -> void:
	close_requested.connect(queue_free)
	%Close.pressed.connect(queue_free)
	%Refresh.pressed.connect(_refresh)
	_register.pressed.connect(_on_register_pressed)
	_forget.pressed.connect(_on_forget_pressed)
	_tree.item_selected.connect(_on_item_selected)
	for column: int in Column.values():
		_tree.set_column_title(column, Column.keys()[column].capitalize())
	var registry = HarnessSessionRegistry.shared()
	registry.changed.connect(_queue_refresh)
	_refresh()


func _exit_tree() -> void:
	var registry = HarnessSessionRegistry.shared()
	if registry.changed.is_connected(_queue_refresh):
		registry.changed.disconnect(_queue_refresh)


## The registry also signals while it is being read (a container binding
## itself), so a change rebuilds the list once, after the current frame's
## work, never in the middle of a rebuild.
func _queue_refresh() -> void:
	if _refresh_queued:
		return
	_refresh_queued = true
	_refresh.call_deferred()


func _listing() -> Array:
	return load(TERMINAL_TOOLS_PATH).new(null).list_terminals()


func _refresh() -> void:
	_refresh_queued = false
	var listing: Array = _listing()
	var registry = HarnessSessionRegistry.shared()
	_tree.clear()
	var root: TreeItem = _tree.create_item()
	for described: Dictionary in registry.sessions(listing):
		var item: TreeItem = _tree.create_item(root)
		var terminal: String = str(described["terminal_id"])
		if not str(described["name"]).is_empty():
			terminal = "%s (%s)" % [described["name"], terminal]
		elif described.has("container"):
			terminal = "container %s" % described["container"]
		item.set_text(Column.IDENTITY, str(described["identity"]))
		item.set_text(Column.ROLE, str(described["role"]))
		item.set_text(Column.HARNESS, str(described["harness"]))
		item.set_text(Column.TERMINAL, terminal)
		item.set_text(Column.LIVENESS, str(described["liveness"]))
		item.set_metadata(Column.IDENTITY, str(described["identity"]))
	_forget.disabled = true
	var here: String = registry.identity_for_terminal(terminal_id)
	var tab_name: String = ""
	for entry: Dictionary in listing:
		if str(entry.get("id", "")) == terminal_id:
			tab_name = str(entry.get("name", ""))
	_register.disabled = tab_name.is_empty()
	if tab_name.is_empty():
		_this_tab.text = "Open this from a terminal tab to register it."
	elif here.is_empty():
		_this_tab.text = "This tab (%s) holds no registered session." % tab_name
	else:
		_this_tab.text = "This tab (%s) holds session %s." % [tab_name, here]


func _on_item_selected() -> void:
	var item: TreeItem = _tree.get_selected()
	_forget.disabled = item == null
	if item != null:
		_identity.text = item.get_text(Column.IDENTITY)
		_role.text = item.get_text(Column.ROLE)


func _on_register_pressed() -> void:
	var reply: Dictionary = HarnessSessionRegistry.shared().register(
		_identity.text, _role.text, terminal_id, "", "", _listing())
	if not reply.get("success", false):
		_status.text = str(reply.get("error", "Registration failed"))
		return
	var session: Dictionary = reply["session"]
	_identity.text = str(session["identity"])
	_status.text = "Registered %s (%s)%s" % [session["identity"], session["liveness"],
		("; unbound %s" % ", ".join(PackedStringArray(reply["displaced"]))) if reply.has("displaced") else ""]


func _on_forget_pressed() -> void:
	var item: TreeItem = _tree.get_selected()
	if item == null:
		return
	var identity: String = str(item.get_metadata(Column.IDENTITY))
	HarnessSessionRegistry.shared().forget(identity)
	_status.text = "Forgot %s" % identity

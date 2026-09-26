extends VBoxContainer
## Agent sessions in the Containers area: lists every session record with its
## live state, starts and stops the selected one, copies the command that
## attaches it in a Minerva terminal tab, shows its details (session
## identity, path mappings, Git identity, toolchain profile) and a read-only
## readiness check, builds the agent image, and creates
## a session from a name, harness, mode, folders, start folder and optional
## Docket projects. The GUI twin of minerva_agent_session_*; both drive
## AgentSessionStore. Scene: res://Scenes/AgentSessionsPanel.tscn, placed in
## Preferences > Containers.

const AgentSessionStore := preload("res://Scripts/Services/AgentSessions/AgentSessionStore.gd")

enum Column { ID, HARNESS, STATE, FOLDERS }

const OK_COLOR := Color(0.2, 0.8, 0.2)
const ERROR_COLOR := Color(0.9, 0.3, 0.3)
const MUTED_COLOR := Color(0.7, 0.7, 0.7)

var _store: RefCounted
## Session answers from the last listing, by id.
var _sessions: Dictionary = {}
var _refreshing: bool = false
var _refresh_again: bool = false
var _busy: bool = false

## The image and listing line; _status holds the last action's outcome.
@onready var _image_status: Label = %ImageStatus
@onready var _status: Label = %Status
@onready var _tree: Tree = %Sessions
@onready var _start: Button = %Start
@onready var _stop: Button = %Stop
@onready var _copy_attach: Button = %CopyAttach
@onready var _inspect: Button = %Inspect
@onready var _readiness: Button = %Readiness
## The last Details or readiness answer for the selected session.
@onready var _details: RichTextLabel = %Details
@onready var _build_image: Button = %BuildImage
@onready var _new_name: LineEdit = %NewName
@onready var _harness: OptionButton = %Harness
@onready var _mode: OptionButton = %Mode
@onready var _folders: ItemList = %Folders
@onready var _remove_folder: Button = %RemoveFolder
@onready var _start_in: OptionButton = %StartIn
@onready var _projects: LineEdit = %Projects
@onready var _create: Button = %Create
@onready var _folder_dialog: FileDialog = %FolderDialog


func _ready() -> void:
	_store = AgentSessionStore.shared()
	_store.changed.connect(_refresh)
	for column: int in Column.values():
		_tree.set_column_title(column, Column.keys()[column].capitalize())
	_tree.set_column_expand(Column.FOLDERS, true)
	for column: int in [Column.ID, Column.HARNESS, Column.STATE]:
		_tree.set_column_expand(column, false)
		_tree.set_column_custom_minimum_width(column, 110)
	%Refresh.pressed.connect(_refresh)
	_build_image.pressed.connect(_on_build_pressed)
	_tree.item_selected.connect(_update_buttons)
	_tree.item_selected.connect(_show_details.bind(""))
	_start.pressed.connect(_on_start_pressed)
	_stop.pressed.connect(_on_stop_pressed)
	_copy_attach.pressed.connect(_on_copy_attach_pressed)
	_inspect.pressed.connect(_on_inspect_pressed)
	_readiness.pressed.connect(_on_readiness_pressed)
	%AddFolder.pressed.connect(_folder_dialog.popup_centered)
	_folder_dialog.dir_selected.connect(_on_folder_chosen)
	_folders.item_selected.connect(func(_index: int) -> void: _remove_folder.disabled = false)
	_remove_folder.pressed.connect(_on_remove_folder_pressed)
	_create.pressed.connect(_on_create_pressed)
	_refresh()


func _exit_tree() -> void:
	if _store != null and _store.changed.is_connected(_refresh):
		_store.changed.disconnect(_refresh)


## Re-lists the records. A refresh asked for while one runs runs once more
## after it, so the list always ends on the latest state.
func _refresh() -> void:
	if _refreshing:
		_refresh_again = true
		return
	_refreshing = true
	var listing: Dictionary = await _store.list_sessions()
	_refreshing = false
	if not is_inside_tree():
		return
	_show_listing(listing)
	if _refresh_again:
		_refresh_again = false
		_refresh()


func _show_listing(listing: Dictionary) -> void:
	var selected: String = _selected_id()
	_sessions.clear()
	_tree.clear()
	var root: TreeItem = _tree.create_item()
	if not bool(listing.get("ok", false)):
		_set_label(_image_status, str(listing.get("error", "could not list sessions")), ERROR_COLOR)
		_update_buttons()
		return
	var sessions: Array = listing.get("sessions", []) if listing.get("sessions") is Array else []
	for session: Variant in sessions:
		if not session is Dictionary:
			continue
		var entry: Dictionary = session
		var id: String = str(entry.get("id", ""))
		_sessions[id] = entry
		var item: TreeItem = _tree.create_item(root)
		item.set_text(Column.ID, id)
		if not bool(entry.get("ok", false)):
			item.set_text(Column.STATE, "unreadable")
			item.set_text(Column.FOLDERS, str(entry.get("error", "")))
			item.set_custom_color(Column.STATE, ERROR_COLOR)
		else:
			var state: String = str(entry.get("state", ""))
			item.set_text(Column.HARNESS, str(entry.get("harness", "")))
			item.set_text(Column.STATE, state)
			item.set_custom_color(Column.STATE, OK_COLOR if state == "running" else MUTED_COLOR)
			item.set_text(Column.FOLDERS, _folders_text(entry))
			item.set_tooltip_text(Column.FOLDERS, "Starts in %s\nDocket: %s" % [
				str(entry.get("start_in", "")), ", ".join(PackedStringArray(entry.get("projects", [])))])
		if id == selected:
			item.select(Column.ID)
	var image: Dictionary = listing.get("image", {}) if listing.get("image") is Dictionary else {}
	if bool(listing.get("building", false)):
		_set_label(_image_status, "Building the agent image %s… the first build can take a long while." % str(image.get("tag", "")), MUTED_COLOR)
	elif bool(image.get("built", false)):
		_set_label(_image_status, "Agent image %s is built. %d session(s)." % [str(image.get("tag", "")), _sessions.size()], OK_COLOR)
	else:
		_set_label(_image_status, "Agent image %s is not built yet: Build image before starting a session." % str(image.get("tag", "")), MUTED_COLOR)
	_build_image.disabled = bool(listing.get("building", false))
	_update_buttons()


static func _folders_text(entry: Dictionary) -> String:
	var parts := PackedStringArray()
	var folders: Array = entry.get("folders", []) if entry.get("folders") is Array else []
	for folder: Variant in folders:
		if folder is Dictionary:
			var host: String = str(folder.get("host", ""))
			parts.append(host if not host.is_empty() else str(folder.get("path", "")))
	return ", ".join(parts)


func _selected_id() -> String:
	var item: TreeItem = _tree.get_selected() if _tree != null else null
	return item.get_text(Column.ID) if item != null else ""


func _update_buttons() -> void:
	var entry: Dictionary = _sessions.get(_selected_id(), {})
	var readable: bool = bool(entry.get("ok", false))
	var state: String = str(entry.get("state", ""))
	_start.disabled = _busy or not readable or state == "running"
	_stop.disabled = _busy or not readable or state != "running"
	_copy_attach.disabled = not readable or state != "running" or str(entry.get("attach_command", "")).is_empty()
	_inspect.disabled = _busy or not readable
	_readiness.disabled = _busy or not readable
	_create.disabled = _busy


func _set_busy(busy: bool) -> void:
	_busy = busy
	_update_buttons()


func _set_status(text: String, color: Color) -> void:
	_set_label(_status, text, color)


static func _set_label(label: Label, text: String, color: Color) -> void:
	label.text = text
	label.add_theme_color_override("font_color", color)


## Shows the launcher's answer: its error, or `done` when it succeeded.
func _report(result: Dictionary, done: String) -> void:
	if bool(result.get("ok", false)):
		_set_status(done, OK_COLOR)
	else:
		_set_status(str(result.get("error", "the launcher failed")), ERROR_COLOR)


func _on_start_pressed() -> void:
	var id: String = _selected_id()
	_set_busy(true)
	_set_status("Starting %s… the first start clones its checkout folders." % id, MUTED_COLOR)
	var result: Dictionary = await _store.start(id)
	_set_busy(false)
	_report(result, "%s is running. Copy the attach command and run it in a terminal tab." % id)


func _on_stop_pressed() -> void:
	var id: String = _selected_id()
	_set_busy(true)
	var result: Dictionary = await _store.stop(id)
	_set_busy(false)
	_report(result, "%s stopped; its home and clones are kept." % id)


func _on_copy_attach_pressed() -> void:
	var entry: Dictionary = _sessions.get(_selected_id(), {})
	DisplayServer.clipboard_set(str(entry.get("attach_command", "")))
	_set_status("Attach command copied: paste it into a Minerva terminal tab.", OK_COLOR)


func _on_inspect_pressed() -> void:
	var id: String = _selected_id()
	_set_busy(true)
	_set_status("Reading %s…" % id, MUTED_COLOR)
	var result: Dictionary = await _store.info(id)
	_set_busy(false)
	_report(result, "Details of %s." % id)
	_show_details(_info_text(result) if bool(result.get("ok", false)) else "")


func _on_readiness_pressed() -> void:
	var id: String = _selected_id()
	_set_busy(true)
	_set_status("Checking %s (read-only)…" % id, MUTED_COLOR)
	var result: Dictionary = await _store.readiness(id)
	_set_busy(false)
	if not bool(result.get("ok", false)):
		_report(result, "")
		_show_details("")
		return
	var ready: bool = bool(result.get("ready", false))
	_set_status("%s is ready." % id if ready else "%s is missing something; see below." % id,
		OK_COLOR if ready else ERROR_COLOR)
	_show_details(_readiness_text(result))


func _show_details(text: String) -> void:
	_details.text = text
	_details.visible = not text.is_empty()


static func _info_text(info: Dictionary) -> String:
	var lines := PackedStringArray()
	var identity: Dictionary = info.get("session_identity", {}) if info.get("session_identity") is Dictionary else {}
	if bool(identity.get("registered", false)):
		lines.append("[b]Session identity:[/b] %s" % _esc(str(identity.get("identity", ""))))
	else:
		lines.append("[b]Session identity:[/b] not registered")
	if identity.has("consistent") and not bool(identity["consistent"]):
		lines.append("  terminal %s answers %s" % [_esc(str(identity.get("terminal_id", ""))),
			_esc(str(identity.get("terminal_identity", "")))])
	var git: Dictionary = info.get("git_identity", {}) if info.get("git_identity") is Dictionary else {}
	if bool(git.get("set", false)):
		lines.append("[b]Commits as:[/b] %s <%s>" % [_esc(str(git.get("name", ""))), _esc(str(git.get("email", "")))])
	else:
		lines.append("[b]Commits as:[/b] unknown — %s" % _esc(str(git.get("detail", ""))))
	var profile: Dictionary = info.get("toolchain_profile", {}) if info.get("toolchain_profile") is Dictionary else {}
	lines.append("[b]Toolchain profile:[/b] %s" % _esc(str(profile.get("name", ""))))
	lines.append("[b]Paths[/b] (host → in the container):")
	var mappings: Array = info.get("path_mappings", []) if info.get("path_mappings") is Array else []
	for mapping: Variant in mappings:
		if mapping is Dictionary:
			lines.append("  %s → %s (%s)" % [_esc(str(mapping.get("host", ""))),
				_esc(str(mapping.get("container", ""))), _esc(str(mapping.get("kind", "")))])
	return "\n".join(lines)


static func _readiness_text(result: Dictionary) -> String:
	var lines := PackedStringArray()
	lines.append("[b]Profile:[/b] %s — checked %s" % [_esc(str(result.get("profile", ""))), _esc(str(result.get("checked", "")))])
	var checks: Array = result.get("checks", []) if result.get("checks") is Array else []
	for check: Variant in checks:
		if check is Dictionary:
			var ok: bool = bool(check.get("ok", false))
			lines.append("[color=%s]%s[/color] %s %s: %s" % [
				(OK_COLOR if ok else ERROR_COLOR).to_html(false), "ok" if ok else "MISSING",
				_esc(str(check.get("check", ""))), _esc(str(check.get("name", ""))), _esc(str(check.get("detail", "")))])
	return "\n".join(lines)


## Launcher and container text shown literally, never as BBCode.
static func _esc(text: String) -> String:
	return text.replace("[", "[lb]")


func _on_build_pressed() -> void:
	_build_image.disabled = true
	var result: Dictionary = await _store.build()
	_report(result, "Agent image built.")


func _on_folder_chosen(path: String) -> void:
	for index: int in _folders.item_count:
		if _folders.get_item_text(index) == path:
			return
	_folders.add_item(path)
	_start_in.add_item(path)
	if _start_in.selected < 0:
		_start_in.select(0)


func _on_remove_folder_pressed() -> void:
	var chosen: PackedInt32Array = _folders.get_selected_items()
	if chosen.is_empty():
		return
	_folders.remove_item(chosen[0])
	_start_in.remove_item(chosen[0])
	if _start_in.item_count > 0 and _start_in.selected < 0:
		_start_in.select(0)
	_remove_folder.disabled = true


func _on_create_pressed() -> void:
	var folders := PackedStringArray()
	for index: int in _folders.item_count:
		folders.append(_folders.get_item_text(index))
	var projects := PackedStringArray()
	for project: String in _projects.text.split(",", false):
		if not project.strip_edges().is_empty():
			projects.append(project.strip_edges())
	var start_in: String = _start_in.get_item_text(_start_in.selected) if _start_in.selected >= 0 else ""
	var id: String = _new_name.text.strip_edges()
	_set_busy(true)
	var result: Dictionary = await _store.create(id, _harness.get_item_text(_harness.selected),
		folders, start_in, projects, _mode.get_item_text(_mode.selected))
	_set_busy(false)
	_report(result, "Created %s. Select it and Start." % id)
	if bool(result.get("ok", false)):
		_new_name.clear()
		_projects.clear()
		_folders.clear()
		_start_in.clear()

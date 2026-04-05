extends RefCounted
class_name MenuBuilder
## Builds MenuBar with File, View, Work PopupMenus and keyboard shortcuts.
## Emits action_triggered(action_name) for AppShell to handle.

signal action_triggered(action: String)

var menu_bar: MenuBar
var work_popup: PopupMenu
var _type_names: PackedStringArray
var _recent_sub: PopupMenu
var _add_recent_sub: PopupMenu
var _close_project_sub: PopupMenu


func build(type_names: PackedStringArray) -> MenuBar:
	_type_names = type_names
	menu_bar = MenuBar.new()
	menu_bar.prefer_global_menu = false
	menu_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_build_file_menu()
	_build_view_menu()
	_build_work_menu()
	_build_help_menu()

	return menu_bar


func _build_file_menu() -> void:
	var popup := PopupMenu.new()
	popup.name = "File"

	# New > submenu: Query + one entry per item type
	var new_sub := PopupMenu.new()
	new_sub.name = "NewSub"
	new_sub.add_item("Query", 100)
	new_sub.add_separator()
	for i in range(_type_names.size()):
		new_sub.add_item(_type_names[i].capitalize(), i)
	new_sub.id_pressed.connect(_on_new_sub_pressed)
	popup.add_child(new_sub)
	popup.add_submenu_node_item("New...", new_sub)

	popup.add_separator()

	popup.add_item("New Docket", 0)
	popup.set_item_shortcut(popup.get_item_index(0), _make_shortcut(KEY_N, true))

	popup.add_item("Open...", 1)
	popup.set_item_shortcut(popup.get_item_index(1), _make_shortcut(KEY_O, true))

	_recent_sub = PopupMenu.new()
	_recent_sub.name = "RecentSub"
	_recent_sub.id_pressed.connect(_on_recent_pressed)
	popup.add_child(_recent_sub)
	popup.add_submenu_node_item("Open Recent", _recent_sub)

	popup.add_item("Add Project...", 5)

	_add_recent_sub = PopupMenu.new()
	_add_recent_sub.name = "AddRecentSub"
	_add_recent_sub.id_pressed.connect(_on_add_recent_pressed)
	popup.add_child(_add_recent_sub)
	popup.add_submenu_node_item("Add Recent...", _add_recent_sub)

	_close_project_sub = PopupMenu.new()
	_close_project_sub.name = "CloseProjectSub"
	_close_project_sub.id_pressed.connect(_on_close_project_pressed)
	popup.add_child(_close_project_sub)
	popup.add_submenu_node_item("Close Project", _close_project_sub)

	popup.add_item("Save", 2)
	popup.set_item_shortcut(popup.get_item_index(2), _make_shortcut(KEY_S, true))

	popup.add_item("Save As...", 3)
	popup.set_item_shortcut(popup.get_item_index(3), _make_shortcut(KEY_S, true, true))

	popup.add_separator()

	popup.add_item("Open Query...", 6)
	popup.add_item("Save Query As...", 7)

	popup.add_separator()

	popup.add_item("Quit", 4)
	popup.set_item_shortcut(popup.get_item_index(4), _make_shortcut(KEY_Q, true))

	popup.id_pressed.connect(_on_file_id_pressed)
	menu_bar.add_child(popup)


func _build_view_menu() -> void:
	var popup := PopupMenu.new()
	popup.name = "View"

	popup.add_item("Query Mode", 0)
	popup.set_item_shortcut(0, _make_shortcut(KEY_1, true))

	popup.add_item("Detail Mode", 1)
	popup.set_item_shortcut(1, _make_shortcut(KEY_2, true))

	popup.add_item("Side-by-Side", 2)
	popup.set_item_shortcut(2, _make_shortcut(KEY_3, true))

	popup.add_separator()

	popup.add_item("Zoom In", 10)
	popup.set_item_shortcut(popup.get_item_index(10), _make_shortcut(KEY_EQUAL, true))

	popup.add_item("Zoom Out", 11)
	popup.set_item_shortcut(popup.get_item_index(11), _make_shortcut(KEY_MINUS, true))

	popup.add_item("Reset Zoom", 12)
	popup.set_item_shortcut(popup.get_item_index(12), _make_shortcut(KEY_0, true))

	popup.add_separator()

	popup.add_item("Font Size: Small", 20)
	popup.add_item("Font Size: Medium", 21)
	popup.add_item("Font Size: Large", 22)

	popup.id_pressed.connect(_on_view_id_pressed)
	menu_bar.add_child(popup)


func _build_work_menu() -> void:
	work_popup = PopupMenu.new()
	work_popup.name = "Work"
	work_popup.id_pressed.connect(_on_work_id_pressed)
	menu_bar.add_child(work_popup)


func _on_file_id_pressed(id: int) -> void:
	match id:
		0: action_triggered.emit("new_docket")
		1: action_triggered.emit("open")
		2: action_triggered.emit("save")
		3: action_triggered.emit("save_as")
		4: action_triggered.emit("quit")
		5: action_triggered.emit("add_project")
		6: action_triggered.emit("open_query")
		7: action_triggered.emit("save_query_as")


func _on_new_sub_pressed(id: int) -> void:
	if id == 100:
		action_triggered.emit("new_query")
	else:
		action_triggered.emit("new_item:" + _type_names[id])


func _on_view_id_pressed(id: int) -> void:
	match id:
		0: action_triggered.emit("view_query")
		1: action_triggered.emit("view_detail")
		2: action_triggered.emit("view_split")
		10: action_triggered.emit("zoom_in")
		11: action_triggered.emit("zoom_out")
		12: action_triggered.emit("zoom_reset")
		20: action_triggered.emit("font_small")
		21: action_triggered.emit("font_medium")
		22: action_triggered.emit("font_large")


func _build_help_menu() -> void:
	var popup := PopupMenu.new()
	popup.name = "Help"

	popup.add_item("Preferences...", 2)
	popup.add_separator()
	popup.add_item("MCP Connection Info", 0)
	popup.add_separator()
	popup.add_item("About Docket", 1)

	popup.id_pressed.connect(_on_help_id_pressed)
	menu_bar.add_child(popup)


func _on_work_id_pressed(id: int) -> void:
	action_triggered.emit("work:" + str(id))


func _on_help_id_pressed(id: int) -> void:
	match id:
		0: action_triggered.emit("help_mcp")
		1: action_triggered.emit("help_about")
		2: action_triggered.emit("preferences")


func set_recent_files(paths: PackedStringArray) -> void:
	_recent_sub.clear()
	_add_recent_sub.clear()
	if paths.is_empty():
		_recent_sub.add_item("(No recent files)", -1)
		_recent_sub.set_item_disabled(0, true)
		_add_recent_sub.add_item("(No recent files)", -1)
		_add_recent_sub.set_item_disabled(0, true)
		return
	for i in range(mini(paths.size(), 5)):
		_recent_sub.add_item(paths[i].get_file(), i)
		_add_recent_sub.add_item(paths[i].get_file(), i)
	_recent_sub.add_separator()
	_recent_sub.add_item("Clear Recent", 99)


func _on_recent_pressed(id: int) -> void:
	if id == 99:
		action_triggered.emit("clear_recent")
	elif id >= 0:
		action_triggered.emit("open_recent:" + str(id))


func _on_add_recent_pressed(id: int) -> void:
	if id >= 0:
		action_triggered.emit("add_recent:" + str(id))


var _close_project_names: PackedStringArray = []

func set_project_list(names: PackedStringArray) -> void:
	## Update the Close Project submenu with current project names.
	_close_project_sub.clear()
	_close_project_names = names
	if names.is_empty():
		_close_project_sub.add_item("(no projects open)", -1)
		_close_project_sub.set_item_disabled(0, true)
		return
	for i in range(names.size()):
		_close_project_sub.add_item(names[i], i)


func _on_close_project_pressed(id: int) -> void:
	if id >= 0 and id < _close_project_names.size():
		action_triggered.emit("close_project:" + _close_project_names[id])


func _make_shortcut(key: Key, ctrl: bool = false, shift: bool = false) -> Shortcut:
	var ev := InputEventKey.new()
	ev.keycode = key
	ev.ctrl_pressed = ctrl
	ev.shift_pressed = shift
	var sc := Shortcut.new()
	sc.events = [ev]
	return sc

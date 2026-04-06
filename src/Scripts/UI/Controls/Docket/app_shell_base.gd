extends VBoxContainer
class_name DocketPanel
## Docket UI panel for Minerva. Adapted from docket standalone AppShell.
## MenuBar + content area with work-entry switching.
## Each open query or item is a "work entry" listed in the Work menu.

enum ViewMode { QUERY, DETAIL, SPLIT }

var _state: AppState
var _menu_builder: MenuBuilder
var _content_area: PanelContainer
var _query_grid: QueryGrid
var _record_form: RecordForm
var _split_container: HSplitContainer
var _current_mode: ViewMode = ViewMode.QUERY

var _file_label: Label
var _open_dialog: FileDialog
var _save_dialog: FileDialog
var _new_dialog: FileDialog
var _info_dialog: AcceptDialog
var _add_project_dialog: FileDialog
var _open_query_dialog: FileDialog
var _save_query_dialog: FileDialog
var _prefs_dialog: ConfirmationDialog
var _prefs_first: LineEdit
var _prefs_last: LineEdit
var _prefs_vault_pw: LineEdit
var _prefs_vault_hint: LineEdit

# Zoom levels
const _ZOOM_LEVELS := [0.75, 0.85, 1.0, 1.15, 1.3, 1.5, 1.75, 2.0, 2.5]
var _current_zoom_idx: int = 2  # 1.0 default
const _FONT_SIZES := {"small": 12, "medium": 14, "large": 18}
var _current_font_size: String = "medium"

# Work entries: each is {type: "query"|"item", label: String, filter: String, item_id: String}
var _work_entries: Array = []
var _current_work_idx: int = -1
var _nav_history: Array = []  # Stack of previous _current_work_idx values

# Recent files
const _RECENTS_PATH := "user://recent_dockets.json"
const _MAX_RECENTS := 5
var _recent_files: PackedStringArray = []

## DocketManager reference (Minerva integration)
var _dm: DocketManager = null




func init(dm: DocketManager) -> void:
	_dm = dm
	_state = AppState.new()
	_state.load_schema()
	_state.load_from_docket_manager(dm)
	_build_ui()
	# Connect DocketManager signals for live refresh
	dm.item_created.connect(_on_dm_item_mutated)
	dm.item_transitioned.connect(_on_dm_transition)
	dm.item_updated.connect(_on_dm_item_mutated)
	dm.comment_added.connect(_on_dm_item_mutated)
	dm.project_loaded.connect(_on_dm_project_changed)
	dm.project_unloaded.connect(_on_dm_project_changed)


func _sync_state() -> void:
	if _dm:
		_state.sync_from_docket_manager(_dm)
		_update_project_menu()


func _on_dm_item_mutated(_id: String, _arg2 = null, _arg3 = null) -> void:
	_query_grid.refresh()

func _on_dm_transition(_id: String, _old: String, _new: String, _proj: String) -> void:
	_query_grid.refresh()
	if _record_form.is_inside_tree() and _record_form._current_id == _id:
		_record_form.load_item(_id)

func _on_dm_project_changed(_proj: String) -> void:
	_sync_state()
	_query_grid.refresh()


func _ready() -> void:
	# Restore persisted UI settings (zoom, font size)
	_restore_ui_settings()

	# Restore last query if available, otherwise start with "All Items"
	var last_q := UserPrefs.load_last_query()
	if last_q.is_empty():
		_add_work_entry("query", "All Items", "", "")
	else:
		_add_work_entry("query", last_q.label, last_q.filter, "")
	_activate_work_entry(0)


func _exit_tree() -> void:
	_persist_last_query()
	_save_session()


func _persist_last_query() -> void:
	# Find the current (or most recent) query work entry and save its filter/label.
	var entry: Dictionary = {}
	if _current_work_idx >= 0 and _current_work_idx < _work_entries.size():
		var cur: Dictionary = _work_entries[_current_work_idx]
		if cur.type == "query":
			entry = cur
	# If the current entry isn't a query, walk backwards to find the last one.
	if entry.is_empty():
		for i in range(_work_entries.size() - 1, -1, -1):
			if _work_entries[i].type == "query":
				entry = _work_entries[i]
				break
	if entry.is_empty():
		return
	UserPrefs.save_last_query(entry.filter, entry.label)


func _build_ui() -> void:
	# Menu bar inside a colored panel
	var menu_panel := PanelContainer.new()
	menu_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var menu_bg := StyleBoxFlat.new()
	menu_bg.bg_color = Color(0.18, 0.18, 0.22)
	menu_bg.content_margin_left = 4
	menu_bg.content_margin_right = 4
	menu_bg.content_margin_top = 2
	menu_bg.content_margin_bottom = 2
	menu_panel.add_theme_stylebox_override("panel", menu_bg)

	_menu_builder = MenuBuilder.new()
	_menu_builder.action_triggered.connect(_on_menu_action)
	var type_keys: Array = _state.schema.types.keys()
	type_keys.sort()
	var type_names := PackedStringArray()
	for t in type_keys:
		type_names.append(t)
	var mbar := _menu_builder.build(type_names)

	_load_recent_files()
	_menu_builder.set_recent_files(_recent_files)
	if not _state.dct_path.is_empty():
		_add_to_recent(_state.dct_path)

	var menu_row := HBoxContainer.new()
	menu_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu_row.add_child(mbar)

	# Spacer pushes filename to the right
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	menu_row.add_child(spacer)

	_file_label = Label.new()
	_file_label.text = _state.dct_path.get_file()
	_file_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.65))
	menu_row.add_child(_file_label)

	menu_panel.add_child(menu_row)
	add_child(menu_panel)

	# Content area with margin
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_theme_constant_override("margin_left", 8)
	margin.add_theme_constant_override("margin_right", 8)
	margin.add_theme_constant_override("margin_top", 8)
	margin.add_theme_constant_override("margin_bottom", 8)
	add_child(margin)

	_content_area = PanelContainer.new()
	_content_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	margin.add_child(_content_area)

	# Build child panels (not yet parented to content_area)
	_query_grid = QueryGrid.new()
	_query_grid.custom_minimum_size.x = 400
	_query_grid.init(_state)
	_query_grid.item_selected.connect(_on_item_selected)
	_query_grid.item_activated.connect(_on_item_activated)

	_record_form = RecordForm.new()
	_record_form.custom_minimum_size.x = 400
	_record_form.init(_state)
	_record_form.item_changed.connect(_on_item_changed)
	_record_form.back_pressed.connect(_on_back_pressed)
	_record_form.child_opened.connect(_open_item_entry)

	_split_container = HSplitContainer.new()
	_split_container.split_offset = 500
	_split_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_split_container.size_flags_vertical = Control.SIZE_EXPAND_FILL

	# File dialogs
	_open_dialog = FileDialog.new()
	_open_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_open_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_open_dialog.add_filter("*.dct", "Docket Files")
	_open_dialog.file_selected.connect(_on_open_file_selected)
	add_child(_open_dialog)

	_save_dialog = FileDialog.new()
	_save_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_save_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_save_dialog.add_filter("*.dct", "Docket Files")
	_save_dialog.file_selected.connect(_on_save_as_file_selected)
	add_child(_save_dialog)

	_new_dialog = FileDialog.new()
	_new_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_new_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_new_dialog.add_filter("*.dct", "Docket Files")
	_new_dialog.file_selected.connect(_on_new_file_selected)
	add_child(_new_dialog)

	# Add Project dialog
	_add_project_dialog = FileDialog.new()
	_add_project_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_add_project_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_add_project_dialog.add_filter("*.dct", "Docket Files")
	_add_project_dialog.file_selected.connect(_on_add_project_selected)
	add_child(_add_project_dialog)

	# Open Query dialog (.dcq)
	_open_query_dialog = FileDialog.new()
	_open_query_dialog.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	_open_query_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_open_query_dialog.add_filter("*.dcq", "Docket Query Files")
	_open_query_dialog.file_selected.connect(_on_open_query_selected)
	add_child(_open_query_dialog)

	# Save Query dialog (.dcq)
	_save_query_dialog = FileDialog.new()
	_save_query_dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	_save_query_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_save_query_dialog.add_filter("*.dcq", "Docket Query Files")
	_save_query_dialog.file_selected.connect(_on_save_query_selected)
	add_child(_save_query_dialog)

	# Reusable info dialog for Help menu
	_info_dialog = AcceptDialog.new()
	add_child(_info_dialog)

	# Populate Close Project submenu with current projects
	_update_project_menu()

	# Listen for project changes to update menu and persist session
	_state.file_changed.connect(_on_file_changed)
	_state.open_item_requested.connect(func(id: String): _open_item_entry.call_deferred(id))
	_state.open_query_requested.connect(_on_open_query_from_mcp)

	# Preferences dialog
	_prefs_dialog = ConfirmationDialog.new()
	_prefs_dialog.title = "Preferences"
	_prefs_dialog.ok_button_text = "Save"
	_prefs_dialog.confirmed.connect(_on_prefs_confirmed)
	var prefs_vbox := VBoxContainer.new()
	prefs_vbox.add_theme_constant_override("separation", 8)

	var fn_label := Label.new()
	fn_label.text = "First Name"
	prefs_vbox.add_child(fn_label)
	_prefs_first = LineEdit.new()
	_prefs_first.placeholder_text = "First name"
	prefs_vbox.add_child(_prefs_first)

	var ln_label := Label.new()
	ln_label.text = "Last Name"
	prefs_vbox.add_child(ln_label)
	_prefs_last = LineEdit.new()
	_prefs_last.placeholder_text = "Last name"
	prefs_vbox.add_child(_prefs_last)

	var initials_note := Label.new()
	initials_note.text = "Initials are derived from your name (e.g. IP)."
	initials_note.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	prefs_vbox.add_child(initials_note)

	# Vault password section
	var vault_sep := HSeparator.new()
	prefs_vbox.add_child(vault_sep)

	var vault_label := Label.new()
	vault_label.text = "Vault Password"
	prefs_vbox.add_child(vault_label)

	_prefs_vault_pw = LineEdit.new()
	_prefs_vault_pw.secret = true
	_prefs_vault_pw.placeholder_text = "Vault password for secrets"
	prefs_vbox.add_child(_prefs_vault_pw)

	var vault_note := Label.new()
	vault_note.text = "Used to encrypt/decrypt secrets in docket files.\nShare with collaborators who need access."
	vault_note.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	prefs_vbox.add_child(vault_note)

	var hint_label := Label.new()
	hint_label.text = "Password Hint"
	prefs_vbox.add_child(hint_label)

	_prefs_vault_hint = LineEdit.new()
	_prefs_vault_hint.placeholder_text = "Optional hint (shown when password is needed)"
	prefs_vbox.add_child(_prefs_vault_hint)

	var hint_note := Label.new()
	hint_note.text = "This hint is NOT encrypted. Keep it vague."
	hint_note.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	prefs_vbox.add_child(hint_note)

	_prefs_dialog.add_child(prefs_vbox)
	add_child(_prefs_dialog)


# -- Work entries ----------------------------------------------------------

func _add_work_entry(type: String, label: String, filter: String, item_id: String) -> int:
	var entry := {"type": type, "label": label, "filter": filter, "item_id": item_id}
	_work_entries.append(entry)
	_rebuild_work_menu()
	return _work_entries.size() - 1


func _activate_work_entry(idx: int) -> void:
	# Save state of current entry before switching away
	_save_current_work_state()

	if _current_work_idx >= 0 and _current_work_idx != idx:
		_nav_history.append(_current_work_idx)
	_current_work_idx = idx
	var entry: Dictionary = _work_entries[idx]

	if entry.type == "query":
		_query_grid.set_filter(entry.filter)
		switch_view(ViewMode.QUERY)
	elif entry.type == "item":
		switch_view(ViewMode.DETAIL)
		_record_form.load_item(entry.item_id)

	_rebuild_work_menu()


func _save_current_work_state() -> void:
	if _current_work_idx < 0 or _current_work_idx >= _work_entries.size():
		return
	var entry: Dictionary = _work_entries[_current_work_idx]
	if entry.type == "query":
		entry.filter = _query_grid.get_filter()
		entry.label = _query_grid.get_filter_summary()


func _find_item_work_entry(item_id: String) -> int:
	for i in range(_work_entries.size()):
		if _work_entries[i].type == "item" and _work_entries[i].item_id == item_id:
			return i
	return -1


func _rebuild_work_menu() -> void:
	var popup: PopupMenu = _menu_builder.work_popup
	popup.clear()
	for i in range(_work_entries.size()):
		var entry: Dictionary = _work_entries[i]
		var prefix := "* " if i == _current_work_idx else "  "
		popup.add_item(prefix + entry.label, i)


# -- View switching --------------------------------------------------------

func switch_view(mode: ViewMode) -> void:
	_detach_all()
	_current_mode = mode
	match mode:
		ViewMode.QUERY:
			_content_area.add_child(_query_grid)
		ViewMode.DETAIL:
			_content_area.add_child(_record_form)
		ViewMode.SPLIT:
			_content_area.add_child(_split_container)
			_split_container.add_child(_query_grid)
			_split_container.add_child(_record_form)


func _detach_all() -> void:
	if _query_grid and _query_grid.get_parent():
		_query_grid.get_parent().remove_child(_query_grid)
	if _record_form and _record_form.get_parent():
		_record_form.get_parent().remove_child(_record_form)
	if _split_container and _split_container.get_parent():
		_split_container.get_parent().remove_child(_split_container)


# -- State change handling -------------------------------------------------

func _on_file_changed() -> void:
	## AppState project list changed — update menus.
	_update_project_menu()


# -- Menu actions ----------------------------------------------------------

func _on_menu_action(action: String) -> void:
	if action.begins_with("new_item:"):
		var type_name := action.substr("new_item:".length())
		_create_and_edit_item(type_name)
		return
	if action.begins_with("work:"):
		var idx := int(action.substr("work:".length()))
		if idx >= 0 and idx < _work_entries.size():
			_activate_work_entry(idx)
		return
	if action.begins_with("open_recent:"):
		var recent_idx := int(action.split(":")[1])
		if recent_idx >= 0 and recent_idx < _recent_files.size():
			if _dm:
				_dm.open_project(_recent_files[recent_idx])
				_sync_state()
			_add_to_recent(_recent_files[recent_idx])
			_update_file_label()
			_update_project_menu()
		return
	if action.begins_with("add_recent:"):
		var recent_idx := int(action.split(":")[1])
		if recent_idx >= 0 and recent_idx < _recent_files.size():
			var path := _recent_files[recent_idx]
			if FileAccess.file_exists(path) and _dm:
				_dm.open_project(path)
				_sync_state()
				_add_to_recent(path)
				_update_file_label()
				_update_project_menu()
		return
	if action.begins_with("close_project:"):
		var proj_name := action.substr("close_project:".length())
		if _dm:
			_dm.close_project(proj_name)
			_sync_state()
		_update_file_label()
		_update_project_menu()
		_query_grid.refresh()
		return
	match action:
		"new_query":
			var idx := _add_work_entry("query", "All Items", "", "")
			_activate_work_entry(idx)
		"new_docket":
			_new_dialog.popup_centered(Vector2i(600, 400))
		"open":
			_open_dialog.popup_centered(Vector2i(600, 400))
		"save":
			if _dm:
				_dm.save_all()
		"save_as":
			_save_dialog.popup_centered(Vector2i(600, 400))
		"add_project":
			_add_project_dialog.popup_centered(Vector2i(600, 400))
		"open_query":
			_open_query_dialog.popup_centered(Vector2i(600, 400))
		"save_query_as":
			_save_query_dialog.popup_centered(Vector2i(600, 400))
		"clear_recent":
			_recent_files = PackedStringArray()
			_save_recent_files()
			_menu_builder.set_recent_files(_recent_files)
		"quit":
			pass  # In Minerva, closing is handled by the editor tab
		"view_query":
			switch_view(ViewMode.QUERY)
		"view_detail":
			switch_view(ViewMode.DETAIL)
		"view_split":
			switch_view(ViewMode.SPLIT)
		"zoom_in":
			_zoom_in()
		"zoom_out":
			_zoom_out()
		"zoom_reset":
			_zoom_reset()
		"font_small":
			_set_font_size("small")
		"font_medium":
			_set_font_size("medium")
		"font_large":
			_set_font_size("large")
		"help_mcp":
			_show_mcp_info()
		"help_about":
			_show_about()
		"preferences":
			_show_preferences()


# -- File dialog callbacks -------------------------------------------------

func _on_open_file_selected(path: String) -> void:
	if _dm:
		_dm.open_project(path)
		_sync_state()
	_add_to_recent(path)
	_update_file_label()
	_update_project_menu()


func _on_save_as_file_selected(path: String) -> void:
	if _dm:
		_dm.save_all()
	_add_to_recent(path)
	_update_file_label()


func _on_new_file_selected(path: String) -> void:
	# Create empty JSONL file, then open via DocketManager
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		var basename := path.get_file().get_basename()
		var prefix := DocketDB._derive_prefix(basename)
		var meta_line := JSON.stringify({"_type": "meta", "version": "1.0.0", "counter": 0, "id_prefix": prefix, "project": basename})
		f.store_line(meta_line)
		f.close()
	if _dm:
		_dm.open_project(path)
		_sync_state()
	_add_to_recent(path)
	_update_file_label()
	_update_project_menu()


func _update_file_label() -> void:
	if not _dm:
		_file_label.text = ""
		return
	var projects := _dm.get_loaded_projects()
	if projects.is_empty():
		_file_label.text = ""
	elif projects.size() == 1:
		_file_label.text = projects[0]
	else:
		_file_label.text = "%d projects" % projects.size()


func _save_session() -> void:
	## Save the list of open project JSONL paths for restore on next launch.
	if not _dm:
		return
	var paths := PackedStringArray()
	for proj_name in _dm.get_loaded_projects():
		var p := _dm.get_project_path(proj_name)
		if not p.is_empty():
			paths.append(p)
	UserPrefs.save_session(paths)


func _update_project_menu() -> void:
	## Update the Close Project submenu with current project names.
	var names := PackedStringArray()
	for proj_name in _state.get_project_dbs():
		names.append(proj_name)
	_menu_builder.set_project_list(names)




# -- Grid/form callbacks ---------------------------------------------------

func _on_item_selected(id: String) -> void:
	if _record_form.is_inside_tree():
		_record_form.load_item(id)


func _create_and_edit_item(type_name: String) -> void:
	var fields := {"title": ""}
	if type_name == "insight":
		fields["assumed"] = ""
		fields["corrected"] = ""
	elif type_name == "hint":
		fields["value"] = ""
	var item = DataModel.create_item(_state.schema, type_name, fields)
	if item.has("error"):
		print("Create error: %s" % item.error)
		return
	# Don't insert into DB yet — open as draft for user to fill in
	_record_form.load_draft(type_name, item)
	switch_view(ViewMode.DETAIL)


func _on_item_activated(id: String) -> void:
	_open_item_entry(id)


func _open_item_entry(id: String) -> void:
	# Reuse existing work entry for this item, or create one
	var idx := _find_item_work_entry(id)
	if idx >= 0:
		_activate_work_entry(idx)
	else:
		var label := id
		if _state.db and _state.db.has_item(id):
			var item: Dictionary = _state.db.get_item(id)
			label = "%s: %s" % [id, str(item.get("title", ""))]
		idx = _add_work_entry("item", label, "", id)
		_activate_work_entry(idx)


func _on_item_changed() -> void:
	_query_grid.refresh()
	# Update the work entry label if the title changed
	if _current_work_idx >= 0 and _current_work_idx < _work_entries.size():
		var entry: Dictionary = _work_entries[_current_work_idx]
		if entry.type == "item" and _state.db and _state.db.has_item(entry.item_id):
			var item: Dictionary = _state.db.get_item(entry.item_id)
			entry.label = "%s: %s" % [entry.item_id, str(item.get("title", ""))]
			_rebuild_work_menu()


func _on_back_pressed() -> void:
	if _nav_history.size() > 0:
		var prev_idx: int = _nav_history.pop_back()
		# Navigate without pushing to history (avoid back-loop)
		_save_current_work_state()
		_current_work_idx = prev_idx
		var entry: Dictionary = _work_entries[prev_idx]
		if entry.type == "query":
			_query_grid.set_filter(entry.filter)
			switch_view(ViewMode.QUERY)
		elif entry.type == "item":
			_record_form.load_item(entry.item_id)
			switch_view(ViewMode.DETAIL)
		_rebuild_work_menu()
	else:
		switch_view(ViewMode.QUERY)


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_ESCAPE and _current_mode == ViewMode.DETAIL:
			_on_back_pressed()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_ENTER and _current_mode == ViewMode.QUERY:
			var focused := get_viewport().gui_get_focus_owner()
			if focused is LineEdit or focused is TextEdit:
				return
			var sel_id := _query_grid.get_selected_id()
			if not sel_id.is_empty():
				_open_item_entry(sel_id)
				get_viewport().set_input_as_handled()


# -- Add Project / Query file callbacks ------------------------------------

func _on_open_query_from_mcp(filter: String, label: String) -> void:
	# Defer to next frame — signal may fire during HTTP _process()
	(func():
		var idx := _add_work_entry("query", label, filter, "")
		_activate_work_entry(idx)
	).call_deferred()


func _on_add_project_selected(path: String) -> void:
	if _dm:
		_dm.open_project(path)
		_sync_state()
	_add_to_recent(path)
	_update_project_menu()


func _on_open_query_selected(path: String) -> void:
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if not parsed is Dictionary:
		return
	var label: String = str(parsed.get("name", path.get_file().get_basename()))
	var filter_json := JSON.stringify(parsed.get("filter", {}))
	var idx := _add_work_entry("query", label, filter_json, "")
	_activate_work_entry(idx)


func _on_save_query_selected(path: String) -> void:
	_query_grid.save_dcq(path)


# -- Zoom / Font size ------------------------------------------------------

func _zoom_in() -> void:
	if _current_zoom_idx < _ZOOM_LEVELS.size() - 1:
		_current_zoom_idx += 1
		_apply_zoom()


func _zoom_out() -> void:
	if _current_zoom_idx > 0:
		_current_zoom_idx -= 1
		_apply_zoom()


func _zoom_reset() -> void:
	_current_zoom_idx = 2  # 1.0
	_apply_zoom()


func _apply_zoom() -> void:
	var zoom_factor: float = _ZOOM_LEVELS[_current_zoom_idx]
	get_tree().root.content_scale_factor = zoom_factor
	if _state.db:
		_state.db.set_meta_value("ui_scale", str(zoom_factor))


func _set_font_size(preset: String) -> void:
	_current_font_size = preset
	var font_sz: int = _FONT_SIZES.get(preset, 14)
	get_tree().root.add_theme_font_size_override("font_size", font_sz)
	if _state.db:
		_state.db.set_meta_value("ui_font_size", preset)


func _restore_ui_settings() -> void:
	if not _state.db:
		return
	var scale_str := _state.db.get_meta_value("ui_scale", "1.0")
	var zoom_factor := float(scale_str)
	for i in _ZOOM_LEVELS.size():
		if absf(_ZOOM_LEVELS[i] - zoom_factor) < 0.01:
			_current_zoom_idx = i
			break
	get_tree().root.content_scale_factor = zoom_factor

	var font_preset := _state.db.get_meta_value("ui_font_size", "medium")
	_current_font_size = font_preset
	var font_size: int = _FONT_SIZES.get(font_preset, 14)
	get_tree().root.add_theme_font_size_override("font_size", font_size)


func _show_mcp_info() -> void:
	_info_dialog.title = "MCP Connection"
	_info_dialog.dialog_text = (
		"Docket MCP Server\n\n" +
		"Transport:  HTTP JSON-RPC 2.0\n" +
		"Endpoint:   POST http://127.0.0.1:3010/mcp\n" +
		"Port:       3010 (default, --port to override)\n\n" +
		"Start server:\n" +
		"  godot --headless --path <project> -- serve\n" +
		"  godot --headless --path <project> -- serve --port 3010\n\n" +
		"Python fallback:\n" +
		"  cd mcp && python docket_mcp_server.py\n\n" +
		"Tools: create, get, update, transition, query,\n" +
		"       link, context, saved_query,\n" +
		"       hint_set, hint_get, hint_query,\n" +
		"       attach, detach\n\n" +
		"File: %s" % _state.dct_path
	)
	_info_dialog.popup_centered()


func _show_about() -> void:
	_info_dialog.title = "About Docket"
	_info_dialog.dialog_text = (
		"Docket — RAID-Inspired Work-Item Tracker\n\n" +
		"11 item types: Bug, DCR, RCA, Chore, Hint, Insight, Question,\n" +
		"Work Item, Secret, Encrypted Note, Discussion\n" +
		"Each with its own state machine.\n\n" +
		"Secrets and encrypted notes require a vault password (Preferences).\n" +
		"Data format: .dct (SQLite)\n" +
		"Schema: data/schema.json"
	)
	_info_dialog.popup_centered()


func _show_preferences() -> void:
	_prefs_first.text = _state.prefs.first_name
	_prefs_last.text = _state.prefs.last_name
	_prefs_vault_pw.text = UserPrefs.load_vault_password()
	_prefs_vault_hint.text = UserPrefs.load_vault_password_hint()
	_prefs_dialog.popup_centered(Vector2i(300, 380))


func _on_prefs_confirmed() -> void:
	_state.prefs.first_name = _prefs_first.text.strip_edges()
	_state.prefs.last_name = _prefs_last.text.strip_edges()
	_state.prefs.save()

	# Save vault password hint
	UserPrefs.save_vault_password_hint(_prefs_vault_hint.text.strip_edges())

	# Handle vault password change
	var new_password := _prefs_vault_pw.text
	var old_password := UserPrefs.load_vault_password()
	if new_password != old_password:
		_reencrypt_vault_secrets(old_password, new_password)
		if new_password.is_empty():
			UserPrefs.clear_vault_password()
		else:
			UserPrefs.save_vault_password(new_password)


func _reencrypt_vault_secrets(old_password: String, new_password: String) -> void:
	## Re-encrypt all secrets in all open dockets when vault password changes.
	if old_password.is_empty() or new_password.is_empty():
		return
	for proj_name in _state.get_project_dbs():
		var pdb: DocketDB = _state.get_project_dbs()[proj_name]
		if not pdb.has_vault():
			continue
		var old_salt := pdb.get_vault_salt()
		var old_key := VaultCrypto.derive_key(old_password, old_salt)
		if not pdb.verify_vault(old_key):
			push_warning("Vault password mismatch for project '%s', skipping re-encryption" % proj_name)
			continue
		# Decrypt all secrets with old key, re-encrypt with new key
		var new_salt := VaultCrypto.generate_salt()
		var new_key := VaultCrypto.derive_key(new_password, new_salt)
		var all_secrets := pdb.get_all_secrets_raw()
		for secret in all_secrets:
			var plaintext := VaultCrypto.decrypt(secret.ciphertext, secret.iv, secret.mac, old_key)
			if plaintext.is_empty():
				push_warning("Failed to decrypt secret '%s' in '%s', skipping" % [secret.handle, proj_name])
				continue
			var encrypted := VaultCrypto.encrypt(plaintext, new_key)
			pdb.set_secret(secret.handle, encrypted.ciphertext, encrypted.iv, encrypted.mac)
		# Update vault metadata with new salt and verify hash
		pdb.init_vault(new_key, new_salt)




func _load_recent_files() -> void:
	_recent_files = PackedStringArray()
	if not FileAccess.file_exists(_RECENTS_PATH):
		return
	var f := FileAccess.open(_RECENTS_PATH, FileAccess.READ)
	if not f:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if parsed is Array:
		for p in parsed:
			_recent_files.append(str(p))


func _save_recent_files() -> void:
	var arr: Array = []
	for p in _recent_files:
		arr.append(p)
	var f := FileAccess.open(_RECENTS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(arr))


func _add_to_recent(path: String) -> void:
	var abs_path := ProjectSettings.globalize_path(path) if path.begins_with("res://") else path
	# Remove if already present, then prepend
	var updated := PackedStringArray()
	updated.append(abs_path)
	for p in _recent_files:
		if p != abs_path and updated.size() < _MAX_RECENTS:
			updated.append(p)
	_recent_files = updated
	_save_recent_files()
	_menu_builder.set_recent_files(_recent_files)

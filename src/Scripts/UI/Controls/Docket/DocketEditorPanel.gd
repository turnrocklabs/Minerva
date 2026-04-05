class_name DocketEditorPanel
extends PanelContainer
## Docket editor panel for Minerva. Replaces docket's standalone app_shell.
## Shows query grid (item list) and record form (item detail) in a split view.

signal data_changed()

var _state: AppState
var _query_grid: QueryGrid
var _record_form: RecordForm
var _split: HSplitContainer
var _toolbar: HBoxContainer
var _project_label: Label
var _project_option: OptionButton
var _refresh_btn: Button
var _new_item_btn: Button

## Track which project this editor was opened for (empty = all)
var project_filter: String = ""


func _ready() -> void:
	_state = AppState.new()
	_state.load_schema()

	var dm: DocketManager = SingletonObject.docket_manager
	if dm:
		_state.load_from_docket_manager(dm)
		dm.project_loaded.connect(_on_project_changed)
		dm.project_unloaded.connect(_on_project_changed)
		dm.item_created.connect(_on_item_mutated)
		dm.item_transitioned.connect(_on_item_transitioned)
		dm.item_updated.connect(_on_item_mutated)
		dm.comment_added.connect(_on_item_mutated)

	_build_ui()
	_query_grid.run_query()


func _build_ui() -> void:
	var main_vbox := VBoxContainer.new()
	main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(main_vbox)

	# Toolbar
	_toolbar = HBoxContainer.new()
	_toolbar.custom_minimum_size.y = 32
	main_vbox.add_child(_toolbar)

	_project_label = Label.new()
	_project_label.text = "Project:"
	_toolbar.add_child(_project_label)

	_project_option = OptionButton.new()
	_project_option.custom_minimum_size.x = 150
	_project_option.item_selected.connect(_on_project_selected)
	_toolbar.add_child(_project_option)
	_populate_project_dropdown()

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_toolbar.add_child(spacer)

	_new_item_btn = Button.new()
	_new_item_btn.text = "New Item"
	_new_item_btn.pressed.connect(_on_new_item)
	_toolbar.add_child(_new_item_btn)

	_refresh_btn = Button.new()
	_refresh_btn.text = "Refresh"
	_refresh_btn.pressed.connect(_on_refresh)
	_toolbar.add_child(_refresh_btn)

	# Split: query grid (left) + record form (right)
	_split = HSplitContainer.new()
	_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_split.split_offset = 500
	main_vbox.add_child(_split)

	# Query grid
	_query_grid = QueryGrid.new()
	_query_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_query_grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_query_grid.custom_minimum_size.x = 300
	_query_grid.init(_state)
	_query_grid.item_activated.connect(_on_item_activated)
	_split.add_child(_query_grid)

	# Record form
	_record_form = RecordForm.new()
	_record_form.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_record_form.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_record_form.custom_minimum_size.x = 300
	_record_form.init(_state)
	_record_form.item_changed.connect(_on_item_changed)
	_record_form.back_pressed.connect(_on_back_pressed)
	_record_form.child_opened.connect(_on_item_activated)
	_record_form.visible = false
	_split.add_child(_record_form)


func _populate_project_dropdown() -> void:
	_project_option.clear()
	_project_option.add_item("All Projects", 0)
	var dm: DocketManager = SingletonObject.docket_manager
	if dm:
		var idx := 1
		for proj_name in dm.get_loaded_projects():
			_project_option.add_item(proj_name, idx)
			if proj_name == project_filter:
				_project_option.selected = idx
			idx += 1


# -- Event handlers -----------------------------------------------------------

func _on_item_activated(id: String) -> void:
	_record_form.load_item(id)
	_record_form.visible = true


func _on_item_changed() -> void:
	_query_grid.run_query()
	data_changed.emit()


func _on_back_pressed() -> void:
	_record_form.visible = false


func _on_project_selected(index: int) -> void:
	if index == 0:
		project_filter = ""
	else:
		project_filter = _project_option.get_item_text(index)
	_query_grid.run_query()


func _on_new_item() -> void:
	var dm: DocketManager = SingletonObject.docket_manager
	if not dm:
		return
	var target_project := project_filter if not project_filter.is_empty() else "master"
	var target_db := dm.get_db(target_project)
	if not target_db:
		return
	# Create a blank work_item and open it in the record form
	var id := target_db.next_uuid7_id()
	var item := DataModel.create_item(_state.schema, "work_item", {"title": "New Item"})
	var ts := Time.get_datetime_string_from_system(true).replace("T", " ").left(19)
	item["created_at"] = ts
	item["updated_at"] = ts
	target_db.insert_item(id, item)
	target_db.append_event(id, "created", "Item created")
	dm.item_created.emit(id, "work_item", target_project)
	_record_form.load_item(id)
	_record_form.visible = true


func _on_refresh() -> void:
	var dm: DocketManager = SingletonObject.docket_manager
	if dm:
		_state.sync_from_docket_manager(dm)
		_populate_project_dropdown()
	_query_grid.run_query()


func _on_project_changed(_project_name: String) -> void:
	var dm: DocketManager = SingletonObject.docket_manager
	if dm:
		_state.sync_from_docket_manager(dm)
		_populate_project_dropdown()
	_query_grid.run_query()


func _on_item_mutated(_id: String, _arg2 = null, _arg3 = null) -> void:
	## Refresh grid when any item is created/updated/transitioned via MCP.
	_query_grid.run_query()


func _on_item_transitioned(_id: String, _old: String, _new: String, _proj: String) -> void:
	_query_grid.run_query()
	# If the record form is showing this item, reload it
	if _record_form.visible and _record_form._current_id == _id:
		_record_form.load_item(_id)

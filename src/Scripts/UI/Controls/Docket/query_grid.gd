extends VBoxContainer
class_name QueryGrid
## Query panel: visual condition builder + spreadsheet-style results with resizable columns.
## Custom header row supports drag-to-resize and click-to-sort.

signal item_selected(id: String)
signal item_activated(id: String)

var _state: AppState
var _run_btn: Button
var _add_btn: Button
var _count_label: Label
var _tree: Tree
var _header: Control
var _context_menu: PopupMenu
var _current_results: Array = []

# Visual query builder
var _conditions_container: VBoxContainer
var _condition_rows: Array = []  # Array of {conj, field, op, value, hbox, remove_btn}
var _user_has_modified: bool = false  # Track if user has interacted with the builder

# Available fields for dropdown (ordered for usability)
const _QUERY_FIELDS := [
	"type", "status", "priority", "severity", "title", "description",
	"assigned_to", "directed_to", "tags", "has_attachment", "id", "component", "key",
	"resolution", "environment", "created_at", "updated_at", "project",
	"blocked_by", "parent",
]

# Field → applicable operators
const _TEXT_OPS := ["eq", "neq", "contains", "not_contains", "like", "is_empty", "is_not_empty"]
const _NUMERIC_OPS := ["eq", "neq", "gt", "lt", "gte", "lte", "is_empty", "is_not_empty"]
const _DATE_OPS := ["eq", "neq", "before", "after", "is_empty", "is_not_empty"]
const _BOOL_OPS := ["eq"]
const _TAG_OPS := ["eq", "neq", "contains", "not_contains"]

# Op labels for display
const _OP_LABELS := {
	"eq": "equals", "neq": "not equals",
	"contains": "contains", "not_contains": "not contains",
	"like": "like", "gt": ">", "lt": "<", "gte": ">=", "lte": "<=",
	"before": "before", "after": "after",
	"is_empty": "is empty", "is_not_empty": "is not empty",
}

# Fields with fixed-value dropdowns
const _DROPDOWN_VALUES := {
	"type": ["bug", "dcr", "rca", "chore", "hint", "insight", "question", "work_item", "test", "discussion", "skill", "prompt", "kb", "policy"],
	"status": [
		"new", "triaged", "active", "resolved", "verified", "closed",
		"proposed", "approved", "designing", "implementing", "reviewing", "shipped",
		"detected", "investigating", "root_caused", "remediating",
		"open", "in_progress", "done",
		"draft", "validated", "promoted", "confirmed",
		"asked", "escalated", "answered",
		"backlog", "blocked",
		"ready", "passing", "failing", "skipped", "retired",
	],
	"priority": ["1", "2", "3", "4"],
	"severity": ["1", "2", "3", "4"],
	"has_attachment": ["true", "false"],
	"resolution": ["fixed", "wont_fix", "by_design", "duplicate", "not_repro"],
}

# Column index → data field name (dynamic — may include "project" when multi-project)
var _col_fields: Array = ["id", "type", "status", "priority", "title"]
var _col_titles: Array = ["ID", "Type", "Status", "Pri", "Title"]
var _col_min_widths: Array = [50, 40, 50, 30, 80]

# Column widths (pixel values, managed by header drag)
var _col_widths: Array = [90, 70, 100, 40, 0]  # last col = fill remaining

# Multi-project mode tracking
var _multi_project: bool = false

# Sort state
var _sort_field: String = ""
var _sort_dir: String = "asc"

# Header drag state
var _drag_col: int = -1   # index of column whose RIGHT edge is being dragged
var _drag_start_x: float = 0
var _drag_start_width: int = 0
const _DRAG_ZONE: int = 5  # pixels from column edge to trigger resize


func init(state: AppState) -> void:
	_state = state
	_state.file_changed.connect(_on_file_changed)
	_build_ui()


func _on_file_changed() -> void:
	refresh()


func _build_ui() -> void:
	# Condition rows container
	_conditions_container = VBoxContainer.new()
	_conditions_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(_conditions_container)

	# Add first empty row
	_add_condition_row(true)

	# Buttons bar: [+ Add] [Run]
	var btn_bar := HBoxContainer.new()
	btn_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	_add_btn = Button.new()
	_add_btn.text = "+ Add"
	_add_btn.pressed.connect(func():
		_user_has_modified = true
		_add_condition_row(false)
	)
	btn_bar.add_child(_add_btn)

	_run_btn = Button.new()
	_run_btn.text = "Run"
	_run_btn.pressed.connect(_run_query)
	btn_bar.add_child(_run_btn)

	add_child(btn_bar)

	# Custom column header (handles drag-resize + click-sort)
	_header = Control.new()
	_header.custom_minimum_size.y = 24
	_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header.draw.connect(_draw_header)
	_header.gui_input.connect(_header_gui_input)
	_header.mouse_default_cursor_shape = Control.CURSOR_ARROW
	add_child(_header)

	# Tree (spreadsheet-style: flat rows, no built-in titles)
	_tree = Tree.new()
	_tree.select_mode = Tree.SELECT_ROW
	_tree.hide_root = true
	_tree.hide_folding = true
	_tree.allow_reselect = true
	_tree.allow_rmb_select = true
	_tree.column_titles_visible = false
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tree.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tree.columns = _col_titles.size()
	for i in range(_col_titles.size()):
		_tree.set_column_clip_content(i, true)
	_tree.item_selected.connect(_on_item_selected)
	_tree.item_activated.connect(_on_item_activated)
	_tree.item_mouse_selected.connect(_on_tree_item_mouse_selected)
	add_child(_tree)

	_context_menu = PopupMenu.new()
	_context_menu.add_item("Copy ID", 0)
	_context_menu.id_pressed.connect(_on_context_menu_id_pressed)
	add_child(_context_menu)

	# Status bar (count) at bottom
	_count_label = Label.new()
	_count_label.text = "0 items"
	_count_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.55))
	_count_label.add_theme_font_size_override("font_size", 12)
	add_child(_count_label)

	# Initial load
	_sync_tree_columns()
	_run_query()


# -- Dynamic column rebuilding ---------------------------------------------

func _rebuild_columns() -> void:
	## Rebuild column arrays for current multi-project state.
	var is_multi := _state._project_dbs.size() > 1
	if is_multi == _multi_project and _tree != null and _tree.columns == _col_titles.size():
		return  # No change needed
	_multi_project = is_multi

	if _multi_project:
		_col_fields = ["id", "project", "type", "status", "priority", "title"]
		_col_titles = ["ID", "Project", "Type", "Status", "Pri", "Title"]
		_col_min_widths = [50, 50, 40, 50, 30, 80]
		_col_widths = [90, 80, 70, 100, 40, 0]
	else:
		_col_fields = ["id", "type", "status", "priority", "title"]
		_col_titles = ["ID", "Type", "Status", "Pri", "Title"]
		_col_min_widths = [50, 40, 50, 30, 80]
		_col_widths = [90, 70, 100, 40, 0]

	if _tree:
		_tree.columns = _col_titles.size()
		for i in range(_col_titles.size()):
			_tree.set_column_clip_content(i, true)
		_sync_tree_columns()
	if _header:
		_header.queue_redraw()


# -- Column width management -----------------------------------------------

func _get_fill_width() -> int:
	## Width available for the last (fill) column.
	var total := int(_header.size.x) if _header else 400
	var fixed := 0
	for i in range(_col_widths.size() - 1):
		fixed += _col_widths[i]
	return maxi(total - fixed, _col_min_widths[_col_widths.size() - 1])


func _col_x(col: int) -> int:
	## Left x position of column col.
	var x := 0
	for i in range(col):
		if i == _col_widths.size() - 1:
			x += _get_fill_width()
		else:
			x += _col_widths[i]
	return x


func _col_w(col: int) -> int:
	## Width of column col.
	if col == _col_widths.size() - 1:
		return _get_fill_width()
	return _col_widths[col]


func _sync_tree_columns() -> void:
	## Push current column widths into the Tree.
	for i in range(_col_widths.size()):
		var w := _col_w(i)
		if i == _col_widths.size() - 1:
			_tree.set_column_expand(i, true)
			_tree.set_column_custom_minimum_width(i, w)
		else:
			_tree.set_column_expand(i, false)
			_tree.set_column_custom_minimum_width(i, w)


# -- Custom header drawing -------------------------------------------------

func _draw_header() -> void:
	var h := int(_header.size.y)
	var total_w := int(_header.size.x)

	# Background
	_header.draw_rect(Rect2(0, 0, total_w, h), Color(0.22, 0.22, 0.26))

	# Columns
	for i in range(_col_titles.size()):
		var x := _col_x(i)
		var w := _col_w(i)

		# Title text
		var title: String = _col_titles[i]
		if _col_fields[i] == _sort_field:
			title += "  v" if _sort_dir == "asc" else "  ^"
		var font := _header.get_theme_default_font()
		var font_size := _header.get_theme_default_font_size()
		var text_y := int((h + font.get_ascent(font_size)) / 2) - 2
		_header.draw_string(font, Vector2(x + 6, text_y), title, HORIZONTAL_ALIGNMENT_LEFT, w - 12, font_size, Color(0.8, 0.8, 0.85))

		# Right separator line
		if i < _col_titles.size() - 1:
			var sep_x := x + w
			_header.draw_line(Vector2(sep_x, 2), Vector2(sep_x, h - 2), Color(0.35, 0.35, 0.4), 1.0)

	# Bottom border
	_header.draw_line(Vector2(0, h - 1), Vector2(total_w, h - 1), Color(0.35, 0.35, 0.4), 1.0)


# -- Header input (sort click + drag resize) -------------------------------

func _header_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_header_mouse_button(event)
	elif event is InputEventMouseMotion:
		_header_mouse_motion(event)


func _header_mouse_button(event: InputEventMouseButton) -> void:
	if event.button_index != MOUSE_BUTTON_LEFT:
		return

	if event.pressed:
		# Check if we're on a column separator → start drag
		var sep_col := _hit_separator(event.position.x)
		if sep_col >= 0:
			_drag_col = sep_col
			_drag_start_x = event.position.x
			_drag_start_width = _col_widths[sep_col]
		else:
			# Click on column title → sort toggle
			var col := _hit_column(event.position.x)
			if col >= 0:
				_toggle_sort(col)
	else:
		# Release → end drag
		if _drag_col >= 0:
			_drag_col = -1


func _header_mouse_motion(event: InputEventMouseMotion) -> void:
	if _drag_col >= 0:
		# Dragging a separator
		var delta := event.position.x - _drag_start_x
		var new_width := maxi(int(_drag_start_width + delta), _col_min_widths[_drag_col])
		_col_widths[_drag_col] = new_width
		_sync_tree_columns()
		_header.queue_redraw()
	else:
		# Hover: update cursor
		var sep_col := _hit_separator(event.position.x)
		if sep_col >= 0:
			_header.mouse_default_cursor_shape = Control.CURSOR_HSIZE
		else:
			_header.mouse_default_cursor_shape = Control.CURSOR_ARROW


func _hit_separator(mx: float) -> int:
	## Return column index whose right edge is near mx, or -1.
	for i in range(_col_widths.size() - 1):  # last col has no right separator
		var edge := _col_x(i) + _col_w(i)
		if absf(mx - edge) <= _DRAG_ZONE:
			return i
	return -1


func _hit_column(mx: float) -> int:
	## Return column index that contains mx, or -1.
	for i in range(_col_titles.size()):
		var x := _col_x(i)
		var w := _col_w(i)
		if mx >= x and mx < x + w:
			return i
	return -1


func _toggle_sort(col: int) -> void:
	var field: String = _col_fields[col]
	if _sort_field == field:
		if _sort_dir == "asc":
			_sort_dir = "desc"
		else:
			_sort_field = ""
			_sort_dir = "asc"
	else:
		_sort_field = field
		_sort_dir = "asc"
	_header.queue_redraw()
	_run_query()


# -- Header resize on parent resize ----------------------------------------

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and _header:
		_sync_tree_columns()
		_header.queue_redraw()


# -- Condition row builder -------------------------------------------------

const _GROUP_BAR_COLOR := Color(0.35, 0.55, 0.85)  # blue accent
const _GROUP_BAR_WIDTH: int = 3
const _GROUP_INDENT: int = 16

func _add_condition_row(is_first: bool) -> void:
	var row_data := {}

	# Outer container: [group_bar] [indent] [inner hbox with widgets]
	var outer := HBoxContainer.new()
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# Group bar — colored left bar visible for AND rows (group members)
	var group_bar := ColorRect.new()
	group_bar.color = _GROUP_BAR_COLOR
	group_bar.custom_minimum_size.x = _GROUP_BAR_WIDTH
	group_bar.size_flags_vertical = Control.SIZE_EXPAND_FILL
	group_bar.visible = false
	outer.add_child(group_bar)
	row_data["group_bar"] = group_bar

	# Indent spacer — visible for AND rows
	var indent := Control.new()
	indent.custom_minimum_size.x = _GROUP_INDENT
	indent.visible = false
	outer.add_child(indent)
	row_data["indent"] = indent

	# Inner hbox with all the condition widgets
	var hbox := HBoxContainer.new()
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL

	# AND/OR conjunction dropdown (hidden for first row)
	var conj_option := OptionButton.new()
	conj_option.add_item("AND", 0)
	conj_option.add_item("OR", 1)
	conj_option.custom_minimum_size.x = 65
	if is_first:
		conj_option.visible = false
	hbox.add_child(conj_option)
	row_data["conj"] = conj_option

	# Field dropdown
	var field_option := OptionButton.new()
	var sorted_fields: Array = _QUERY_FIELDS.duplicate()
	sorted_fields.sort_custom(func(a, b): return a.to_lower() < b.to_lower())
	for f in sorted_fields:
		field_option.add_item(f)
	field_option.custom_minimum_size.x = 120
	hbox.add_child(field_option)
	row_data["field"] = field_option

	# Operator dropdown
	var op_option := OptionButton.new()
	op_option.custom_minimum_size.x = 100
	hbox.add_child(op_option)
	row_data["op"] = op_option

	# Value input — LineEdit for free-form, OptionButton for fixed values
	var value_edit := LineEdit.new()
	value_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value_edit.placeholder_text = "value"
	value_edit.text_changed.connect(func(_t): _user_has_modified = true)
	value_edit.text_submitted.connect(func(_t): _run_query())
	hbox.add_child(value_edit)
	row_data["value"] = value_edit

	var value_dropdown := OptionButton.new()
	value_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	value_dropdown.visible = false
	value_dropdown.item_selected.connect(func(_idx): _user_has_modified = true)
	hbox.add_child(value_dropdown)
	row_data["value_dropdown"] = value_dropdown

	# Remove button
	var remove_btn := Button.new()
	remove_btn.text = "X"
	remove_btn.custom_minimum_size.x = 30
	hbox.add_child(remove_btn)
	row_data["remove_btn"] = remove_btn

	outer.add_child(hbox)
	row_data["hbox"] = outer  # outer is what gets added/removed from tree

	var row_idx := _condition_rows.size()
	remove_btn.pressed.connect(_remove_condition_row.bind(row_idx))

	# Wire field change to update operators
	field_option.item_selected.connect(func(_idx):
		_user_has_modified = true
		_update_ops_for_row(row_idx)
	)

	# Wire conjunction change to update group visuals
	conj_option.item_selected.connect(func(_idx):
		_user_has_modified = true
		_update_group_visuals()
	)

	_condition_rows.append(row_data)
	_conditions_container.add_child(outer)

	# Populate initial operators
	_update_ops_for_row(row_idx)
	_update_remove_buttons()
	_update_group_visuals()


func _remove_condition_row(idx: int) -> void:
	if _condition_rows.size() <= 1:
		return  # Keep at least one row
	var row: Dictionary = _condition_rows[idx]
	row["hbox"].queue_free()
	_condition_rows.remove_at(idx)

	# Re-bind remove buttons with correct indices
	for i in _condition_rows.size():
		var btn: Button = _condition_rows[i]["remove_btn"]
		# Disconnect all pressed signals and reconnect
		for conn in btn.pressed.get_connections():
			btn.pressed.disconnect(conn.callable)
		btn.pressed.connect(_remove_condition_row.bind(i))

	# First row should hide conjunction
	if _condition_rows.size() > 0:
		_condition_rows[0]["conj"].visible = false

	_update_remove_buttons()
	_update_group_visuals()


func _update_remove_buttons() -> void:
	# Disable X on last remaining row
	for row in _condition_rows:
		row["remove_btn"].disabled = (_condition_rows.size() <= 1)


func _update_group_visuals() -> void:
	## Show/hide group bars and indents based on AND/OR conjunctions.
	## Rule: AND rows (non-first) are group members → show bar + indent.
	## OR rows and the first row are group leaders → no bar, no indent.
	for i in _condition_rows.size():
		var row: Dictionary = _condition_rows[i]
		var bar: ColorRect = row["group_bar"]
		var indent_ctrl: Control = row["indent"]
		if i == 0:
			# First row: always a group leader
			bar.visible = false
			indent_ctrl.visible = false
		else:
			var conj_opt: OptionButton = row["conj"]
			var is_and: bool = (conj_opt.selected == 0)
			bar.visible = is_and
			indent_ctrl.visible = is_and


func _get_ops_for_field(field_name: String) -> Array:
	match field_name:
		"priority", "severity", "retrieval_count", "research_cost":
			return _NUMERIC_OPS
		"created_at", "updated_at", "occurred_at", "detected_at":
			return _DATE_OPS
		"has_attachment":
			return _BOOL_OPS
		"tags":
			return _TAG_OPS
		_:
			return _TEXT_OPS


func _update_ops_for_row(row_idx: int) -> void:
	if row_idx >= _condition_rows.size():
		return
	var row: Dictionary = _condition_rows[row_idx]
	var field_option: OptionButton = row["field"]
	var op_option: OptionButton = row["op"]
	var value_edit: LineEdit = row["value"]
	var value_dropdown: OptionButton = row["value_dropdown"]

	var field_name: String = field_option.get_item_text(field_option.selected)
	var ops := _get_ops_for_field(field_name)

	op_option.clear()
	for o in ops:
		op_option.add_item(_OP_LABELS.get(o, o))

	# Determine if this field uses a dropdown
	var use_dropdown: bool = _DROPDOWN_VALUES.has(field_name)

	if use_dropdown:
		# Populate dropdown with fixed values for this field
		value_dropdown.clear()
		value_dropdown.add_item("(any)")
		var values: Array = _DROPDOWN_VALUES[field_name]
		for v in values:
			value_dropdown.add_item(str(v))
		value_dropdown.visible = true
		value_edit.visible = false
	else:
		value_dropdown.visible = false
		value_edit.visible = true
		value_edit.placeholder_text = "value"

	# Show/hide value widgets for is_empty/is_not_empty
	op_option.item_selected.connect(func(_idx):
		_user_has_modified = true
		var op_text: String = op_option.get_item_text(op_option.selected)
		var is_no_value: bool = (op_text == "is empty" or op_text == "is not empty")
		if is_no_value:
			value_edit.visible = false
			value_dropdown.visible = false
		elif use_dropdown:
			value_dropdown.visible = true
			value_edit.visible = false
		else:
			value_edit.visible = true
			value_dropdown.visible = false
	)


func _op_label_to_key(label: String) -> String:
	for k in _OP_LABELS:
		if _OP_LABELS[k] == label:
			return k
	return "eq"


# -- Query -----------------------------------------------------------------

func _run_query() -> void:
	_rebuild_columns()
	var filter := _build_conditions_filter()
	var query := {"filter": filter}
	if not _sort_field.is_empty():
		query["sort"] = [{"field": _sort_field, "dir": _sort_dir}]

	# Use cross-project query if multiple projects loaded
	if _state._project_dbs.size() > 1:
		_current_results = _state.execute_cross_project_query(query)
	elif _state.db:
		_current_results = _state.db.execute_query(query)
	else:
		_current_results = []
	_populate_tree()


func _build_conditions_filter() -> Dictionary:
	var conditions: Array = []
	for i in _condition_rows.size():
		var row: Dictionary = _condition_rows[i]
		var field_option: OptionButton = row["field"]
		var op_option: OptionButton = row["op"]
		var value_edit: LineEdit = row["value"]
		var value_dropdown: OptionButton = row["value_dropdown"]
		var conj_option: OptionButton = row["conj"]

		var field_name: String = field_option.get_item_text(field_option.selected)
		var op_label: String = op_option.get_item_text(op_option.selected)
		var op_key: String = _op_label_to_key(op_label)

		# Read value from dropdown or text input depending on field
		var raw_value: String
		if _DROPDOWN_VALUES.has(field_name) and value_dropdown.visible:
			raw_value = value_dropdown.get_item_text(value_dropdown.selected) if value_dropdown.item_count > 0 else ""
		else:
			raw_value = value_edit.text.strip_edges()

		# Skip conditions where "(any)" is selected — matches everything
		if raw_value == "(any)" and op_key not in ["is_empty", "is_not_empty"]:
			continue

		var cond := {"field": field_name, "op": op_key}
		if i > 0:
			cond["conj"] = "or" if conj_option.selected == 1 else "and"

		# Parse value
		if op_key in ["is_empty", "is_not_empty"]:
			pass  # no value needed
		elif field_name == "has_attachment":
			cond["value"] = raw_value.to_lower() == "true"
		elif field_name in ["priority", "severity", "retrieval_count", "research_cost"]:
			cond["value"] = int(raw_value) if raw_value.is_valid_int() else 0
		else:
			cond["value"] = raw_value

		conditions.append(cond)

	if conditions.size() == 0:
		return {}
	if not _user_has_modified:
		# No user interaction yet — show all items
		return {}
	if conditions.size() == 1:
		# Single condition with no conjunction and default eq with empty value → return all
		var only: Dictionary = conditions[0]
		if only["op"] == "eq" and only.get("value", "") == "":
			return {}
	return {"conditions": conditions}


func _serialize_all_conditions() -> Dictionary:
	## Like _build_conditions_filter() but preserves "(any)" rows for UI state.
	var conditions: Array = []
	for i in _condition_rows.size():
		var row: Dictionary = _condition_rows[i]
		var field_option: OptionButton = row["field"]
		var op_option: OptionButton = row["op"]
		var value_edit: LineEdit = row["value"]
		var value_dropdown: OptionButton = row["value_dropdown"]
		var conj_option: OptionButton = row["conj"]

		var field_name: String = field_option.get_item_text(field_option.selected)
		var op_label: String = op_option.get_item_text(op_option.selected)
		var op_key: String = _op_label_to_key(op_label)

		var raw_value: String
		if _DROPDOWN_VALUES.has(field_name) and value_dropdown.visible:
			raw_value = value_dropdown.get_item_text(value_dropdown.selected) if value_dropdown.item_count > 0 else ""
		else:
			raw_value = value_edit.text.strip_edges()

		var cond := {"field": field_name, "op": op_key}
		if i > 0:
			cond["conj"] = "or" if conj_option.selected == 1 else "and"

		if op_key in ["is_empty", "is_not_empty"]:
			pass
		elif field_name == "has_attachment":
			cond["value"] = raw_value.to_lower() == "true"
		elif field_name in ["priority", "severity", "retrieval_count", "research_cost"]:
			cond["value"] = int(raw_value) if raw_value.is_valid_int() else 0
		else:
			cond["value"] = raw_value

		conditions.append(cond)

	if conditions.size() == 0:
		return {}
	return {"conditions": conditions}


## Status → display color mapping.
const _STATUS_COLORS := {
	# Active / in-progress states → green
	"active": Color(0.4, 0.85, 0.45),
	"in_progress": Color(0.4, 0.85, 0.45),
	"implementing": Color(0.4, 0.85, 0.45),
	"remediating": Color(0.4, 0.85, 0.45),
	# Terminal / done states → grey
	"resolved": Color(0.55, 0.55, 0.6),
	"closed": Color(0.55, 0.55, 0.6),
	"shipped": Color(0.55, 0.55, 0.6),
	"done": Color(0.55, 0.55, 0.6),
	"verified": Color(0.55, 0.55, 0.6),
	# Warning / blocked states → yellow
	"blocked": Color(1.0, 0.75, 0.2),
	"failing": Color(1.0, 0.75, 0.2),
}


func _populate_tree() -> void:
	_tree.clear()
	var root := _tree.create_item()

	for item in _current_results:
		var row := _tree.create_item(root)
		var full_id: String = str(item.get("id", ""))
		var item_status: String = str(item.get("status", ""))
		for col_idx in range(_col_fields.size()):
			var field: String = _col_fields[col_idx]
			if field == "priority":
				var pri = item.get("priority", 0)
				row.set_text(col_idx, str(int(pri)) if pri else "")
			elif field == "id" and DocketDB._is_uuid7(full_id):
				# Display short ID for UUID7, set tooltip to full ID
				var display_id := full_id.substr(0, 7)
				if _state.db:
					display_id = _state.db.short_id(full_id)
				row.set_text(col_idx, display_id)
				row.set_tooltip_text(col_idx, full_id)
			elif field == "status":
				row.set_text(col_idx, item_status)
				if _STATUS_COLORS.has(item_status):
					row.set_custom_color(col_idx, _STATUS_COLORS[item_status])
			else:
				row.set_text(col_idx, str(item.get(field, "")))
		# Metadata always stores full ID for selection signals
		row.set_metadata(0, full_id)

	_count_label.text = "%d items" % _current_results.size()


func _on_item_selected() -> void:
	var selected := _tree.get_selected()
	if selected:
		var id: String = selected.get_metadata(0)
		item_selected.emit(id)


func _on_item_activated() -> void:
	var selected := _tree.get_selected()
	if selected:
		var id: String = selected.get_metadata(0)
		item_activated.emit(id)


func _on_tree_item_mouse_selected(_position: Vector2, mouse_button_index: int) -> void:
	if mouse_button_index == MOUSE_BUTTON_RIGHT:
		_context_menu.popup(Rect2i(Vector2i(get_global_mouse_position()), Vector2i.ZERO))


func _on_context_menu_id_pressed(id: int) -> void:
	if id == 0:  # Copy ID
		var selected := _tree.get_selected()
		if selected:
			var full_id: String = selected.get_metadata(0)
			DisplayServer.clipboard_set(full_id)


func get_selected_id() -> String:
	var selected := _tree.get_selected()
	if selected:
		return selected.get_metadata(0)
	return ""


func get_filter() -> String:
	## Returns JSON string of {"conditions": [...]} for UI state serialization.
	## Uses _serialize_all_conditions() to preserve "(any)" rows across navigation.
	var filter := _serialize_all_conditions()
	if filter.is_empty():
		return ""
	return JSON.stringify(filter)


func set_filter(text: String) -> void:
	## Accepts JSON conditions format or old "key:value" format.
	if not text.strip_edges().is_empty():
		_user_has_modified = true
	# Clear existing rows
	for row in _condition_rows:
		row["hbox"].queue_free()
	_condition_rows.clear()

	if text.strip_edges().is_empty():
		_add_condition_row(true)
		_run_query()
		return

	# Try JSON parse
	var parsed = JSON.parse_string(text)
	if parsed is Dictionary and parsed.has("conditions"):
		var conditions: Array = parsed["conditions"]
		for i in conditions.size():
			var cond: Dictionary = conditions[i]
			_add_condition_row(i == 0)
			var row: Dictionary = _condition_rows[i]
			# Set conjunction
			if i > 0 and cond.has("conj"):
				var conj_opt: OptionButton = row["conj"]
				conj_opt.selected = 1 if str(cond.conj).to_lower() == "or" else 0
			# Set field
			var field_opt: OptionButton = row["field"]
			var field_name: String = str(cond.get("field", "type"))
			for fi in field_opt.item_count:
				if field_opt.get_item_text(fi) == field_name:
					field_opt.selected = fi
					break
			_update_ops_for_row(i)
			# Set op
			var op_key: String = str(cond.get("op", "eq"))
			var op_label: String = _OP_LABELS.get(op_key, op_key)
			var op_opt: OptionButton = row["op"]
			for oi in op_opt.item_count:
				if op_opt.get_item_text(oi) == op_label:
					op_opt.selected = oi
					break
			# Set value
			if cond.has("value"):
				var val_str: String = str(cond["value"])
				if _DROPDOWN_VALUES.has(field_name):
					var dd: OptionButton = row["value_dropdown"]
					for vi in dd.item_count:
						if dd.get_item_text(vi) == val_str:
							dd.selected = vi
							break
					dd.visible = op_key not in ["is_empty", "is_not_empty"]
					row["value"].visible = false
				else:
					var val_edit: LineEdit = row["value"]
					val_edit.text = val_str
					val_edit.visible = op_key not in ["is_empty", "is_not_empty"]
					row["value_dropdown"].visible = false
	else:
		# Old "key:value" format → convert to condition rows
		var parts := text.split(" ")
		var idx := 0
		for part in parts:
			var kv := part.split(":")
			if kv.size() == 2:
				_add_condition_row(idx == 0)
				var row: Dictionary = _condition_rows[idx]
				if idx > 0:
					row["conj"].selected = 0  # AND
				# Set field
				var field_opt: OptionButton = row["field"]
				for fi in field_opt.item_count:
					if field_opt.get_item_text(fi) == kv[0]:
						field_opt.selected = fi
						break
				_update_ops_for_row(idx)
				# Set value
				var kv_field: String = kv[0]
				if _DROPDOWN_VALUES.has(kv_field):
					var dd: OptionButton = row["value_dropdown"]
					for vi in dd.item_count:
						if dd.get_item_text(vi) == kv[1]:
							dd.selected = vi
							break
				else:
					row["value"].text = kv[1]
				idx += 1
		if idx == 0:
			_add_condition_row(true)

	_run_query()


func get_filter_summary() -> String:
	## Human-readable summary like "type equals bug, priority > 2"
	var parts := PackedStringArray()
	for i in _condition_rows.size():
		var row: Dictionary = _condition_rows[i]
		var field_opt: OptionButton = row["field"]
		var op_opt: OptionButton = row["op"]
		var value_edit: LineEdit = row["value"]
		var value_dropdown: OptionButton = row["value_dropdown"]
		var conj_opt: OptionButton = row["conj"]

		var field_name: String = field_opt.get_item_text(field_opt.selected)
		var op_label: String = op_opt.get_item_text(op_opt.selected)
		var val: String
		if _DROPDOWN_VALUES.has(field_name) and value_dropdown.visible:
			val = value_dropdown.get_item_text(value_dropdown.selected) if value_dropdown.item_count > 0 else ""
		else:
			val = value_edit.text.strip_edges()

		var part := ""
		if i > 0:
			part += "OR " if conj_opt.selected == 1 else "AND "
		part += "%s %s" % [field_name, op_label]
		if op_label not in ["is empty", "is not empty"] and not val.is_empty():
			part += " %s" % val
		parts.append(part)

	var summary := ", ".join(parts)
	return summary if not summary.is_empty() else "All Items"


func load_dcq(path: String) -> void:
	## Load a .dcq query file and apply its filter.
	var f := FileAccess.open(path, FileAccess.READ)
	if not f:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	if not parsed is Dictionary:
		return
	if parsed.has("filter"):
		set_filter(JSON.stringify(parsed.filter))


func save_dcq(path: String) -> void:
	## Save current query builder state as a .dcq file.
	var filter := _build_conditions_filter()
	var dcq := {"filter": filter}
	# Include sort if active
	if not _sort_field.is_empty():
		dcq["sort"] = [{"field": _sort_field, "dir": _sort_dir}]
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(dcq, "\t"))


func refresh() -> void:
	_run_query()

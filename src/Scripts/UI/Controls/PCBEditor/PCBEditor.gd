class_name PCBEditor
extends PanelContainer
## Main PCB Editor control with toolbar, canvas, and panels.

const PCBDataScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBData.gd")
const PCBComponentScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBComponent.gd")
const PCBCanvasScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBCanvas.gd")
const PCBSpatialIndexScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBSpatialIndex.gd")
const PCBSuggestionScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBSuggestion.gd")

## Signals
signal data_changed()
signal component_selected(component_id: String)
signal suggestion_pending(suggestion_id: String)

## Data model
var data: PCBDataScript = null
var spatial_index: PCBSpatialIndexScript = null

## Unique ID for this editor instance
var editor_id: String = ""

## File path (if loaded/saved)
var file_path: String = ""
var is_modified: bool = false

## UI References (set in _ready or via scene)
var canvas: PCBCanvasScript = null
var toolbar: HBoxContainer = null
var component_library: ItemList = null
var properties_panel: VBoxContainer = null
var suggestion_bar: HBoxContainer = null

## Suggestion bar elements
var suggestion_label: Label = null
var accept_button: Button = null
var reject_button: Button = null

## Properties panel elements
var prop_id_label: Label = null
var prop_position_label: Label = null
var prop_rotation_label: Label = null
var prop_footprint_label: Label = null


func _ready() -> void:
	# Generate unique ID
	editor_id = str(randi() % 1000000).pad_zeros(6)

	# Initialize data
	data = PCBDataScript.new()
	spatial_index = PCBSpatialIndexScript.new(data)

	# Build UI
	_build_ui()

	# Connect signals
	_connect_signals()


func _build_ui() -> void:
	# Main vertical layout
	var main_vbox := VBoxContainer.new()
	main_vbox.name = "MainVBox"
	main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(main_vbox)

	# Toolbar
	toolbar = _create_toolbar()
	main_vbox.add_child(toolbar)

	# Content area (sidebar + canvas + properties)
	var content_hbox := HBoxContainer.new()
	content_hbox.name = "ContentHBox"
	content_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(content_hbox)

	# Left sidebar - component library
	var sidebar := _create_component_library()
	content_hbox.add_child(sidebar)

	# Canvas (main editing area)
	var canvas_container := PanelContainer.new()
	canvas_container.name = "CanvasContainer"
	canvas_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_hbox.add_child(canvas_container)

	canvas = PCBCanvasScript.new()
	canvas.name = "PCBCanvas"
	canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas_container.add_child(canvas)

	# Right sidebar - properties panel
	properties_panel = _create_properties_panel()
	content_hbox.add_child(properties_panel)

	# Bottom - suggestion bar
	suggestion_bar = _create_suggestion_bar()
	suggestion_bar.visible = false  # Hidden until there are suggestions
	main_vbox.add_child(suggestion_bar)


func _create_toolbar() -> HBoxContainer:
	var tb := HBoxContainer.new()
	tb.name = "Toolbar"
	tb.custom_minimum_size.y = 32

	# New button
	var new_btn := Button.new()
	new_btn.text = "New"
	new_btn.pressed.connect(_on_new_pressed)
	tb.add_child(new_btn)

	# Import button
	var import_btn := Button.new()
	import_btn.text = "Import"
	import_btn.pressed.connect(_on_import_pressed)
	tb.add_child(import_btn)

	# Export button
	var export_btn := Button.new()
	export_btn.text = "Export"
	export_btn.pressed.connect(_on_export_pressed)
	tb.add_child(export_btn)

	tb.add_child(VSeparator.new())

	# Undo button
	var undo_btn := Button.new()
	undo_btn.text = "Undo"
	undo_btn.pressed.connect(_on_undo_pressed)
	tb.add_child(undo_btn)

	# Redo button
	var redo_btn := Button.new()
	redo_btn.text = "Redo"
	redo_btn.pressed.connect(_on_redo_pressed)
	tb.add_child(redo_btn)

	tb.add_child(VSeparator.new())

	# Zoom controls
	var zoom_out_btn := Button.new()
	zoom_out_btn.text = "-"
	zoom_out_btn.custom_minimum_size.x = 30
	zoom_out_btn.pressed.connect(func(): canvas._zoom_at(canvas.size / 2, 0.8))
	tb.add_child(zoom_out_btn)

	var zoom_fit_btn := Button.new()
	zoom_fit_btn.text = "Fit"
	zoom_fit_btn.pressed.connect(func(): canvas.zoom_to_fit())
	tb.add_child(zoom_fit_btn)

	var zoom_in_btn := Button.new()
	zoom_in_btn.text = "+"
	zoom_in_btn.custom_minimum_size.x = 30
	zoom_in_btn.pressed.connect(func(): canvas._zoom_at(canvas.size / 2, 1.2))
	tb.add_child(zoom_in_btn)

	tb.add_child(VSeparator.new())

	# View toggles
	var grid_check := CheckButton.new()
	grid_check.text = "Grid"
	grid_check.button_pressed = true
	grid_check.toggled.connect(func(pressed): canvas.show_grid = pressed; canvas.queue_redraw())
	tb.add_child(grid_check)

	var ratsnest_check := CheckButton.new()
	ratsnest_check.text = "Ratsnest"
	ratsnest_check.button_pressed = true
	ratsnest_check.toggled.connect(func(pressed): canvas.show_ratsnest = pressed; canvas.queue_redraw())
	tb.add_child(ratsnest_check)

	var labels_check := CheckButton.new()
	labels_check.text = "Labels"
	labels_check.button_pressed = true
	labels_check.toggled.connect(func(pressed): canvas.show_labels = pressed; canvas.queue_redraw())
	tb.add_child(labels_check)

	# Spacer
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tb.add_child(spacer)

	# Board size
	var size_label := Label.new()
	size_label.text = "Board: 100x100mm"
	tb.add_child(size_label)

	return tb


func _create_component_library() -> VBoxContainer:
	var sidebar := VBoxContainer.new()
	sidebar.name = "ComponentLibrary"
	sidebar.custom_minimum_size.x = 150

	var header := Label.new()
	header.text = "Components"
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sidebar.add_child(header)

	component_library = ItemList.new()
	component_library.name = "LibraryList"
	component_library.size_flags_vertical = Control.SIZE_EXPAND_FILL
	component_library.item_activated.connect(_on_library_item_activated)
	sidebar.add_child(component_library)

	# Add component types
	var types := ["Resistor", "Capacitor", "IC DIP", "IC QFP", "Switch", "Connector", "LED", "Diode", "Transistor", "Header"]
	for type_name in types:
		component_library.add_item(type_name)

	return sidebar


func _create_properties_panel() -> VBoxContainer:
	var panel := VBoxContainer.new()
	panel.name = "PropertiesPanel"
	panel.custom_minimum_size.x = 200

	var header := Label.new()
	header.text = "Properties"
	header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(header)

	panel.add_child(HSeparator.new())

	# ID
	var id_row := HBoxContainer.new()
	var id_label := Label.new()
	id_label.text = "ID:"
	id_label.custom_minimum_size.x = 60
	id_row.add_child(id_label)
	prop_id_label = Label.new()
	prop_id_label.text = "-"
	id_row.add_child(prop_id_label)
	panel.add_child(id_row)

	# Position
	var pos_row := HBoxContainer.new()
	var pos_label := Label.new()
	pos_label.text = "Position:"
	pos_label.custom_minimum_size.x = 60
	pos_row.add_child(pos_label)
	prop_position_label = Label.new()
	prop_position_label.text = "-"
	pos_row.add_child(prop_position_label)
	panel.add_child(pos_row)

	# Rotation
	var rot_row := HBoxContainer.new()
	var rot_label := Label.new()
	rot_label.text = "Rotation:"
	rot_label.custom_minimum_size.x = 60
	rot_row.add_child(rot_label)
	prop_rotation_label = Label.new()
	prop_rotation_label.text = "-"
	rot_row.add_child(prop_rotation_label)
	panel.add_child(rot_row)

	# Footprint
	var fp_row := HBoxContainer.new()
	var fp_label := Label.new()
	fp_label.text = "Footprint:"
	fp_label.custom_minimum_size.x = 60
	fp_row.add_child(fp_label)
	prop_footprint_label = Label.new()
	prop_footprint_label.text = "-"
	fp_row.add_child(prop_footprint_label)
	panel.add_child(fp_row)

	panel.add_child(HSeparator.new())

	# Actions
	var rotate_btn := Button.new()
	rotate_btn.text = "Rotate 90"
	rotate_btn.pressed.connect(_on_rotate_pressed)
	panel.add_child(rotate_btn)

	var delete_btn := Button.new()
	delete_btn.text = "Delete"
	delete_btn.pressed.connect(_on_delete_pressed)
	panel.add_child(delete_btn)

	# Spacer
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(spacer)

	# Stats
	var stats_label := Label.new()
	stats_label.text = "Stats"
	stats_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(stats_label)

	return panel


func _create_suggestion_bar() -> HBoxContainer:
	var bar := HBoxContainer.new()
	bar.name = "SuggestionBar"
	bar.custom_minimum_size.y = 40

	var icon := Label.new()
	icon.text = "AI:"
	bar.add_child(icon)

	suggestion_label = Label.new()
	suggestion_label.text = "No suggestions"
	suggestion_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(suggestion_label)

	accept_button = Button.new()
	accept_button.text = "Accept"
	accept_button.pressed.connect(_on_accept_suggestion)
	bar.add_child(accept_button)

	reject_button = Button.new()
	reject_button.text = "Reject"
	reject_button.pressed.connect(_on_reject_suggestion)
	bar.add_child(reject_button)

	return bar


func _connect_signals() -> void:
	# Canvas signals
	canvas.component_selected.connect(_on_component_selected)
	canvas.component_moved.connect(_on_component_moved)
	canvas.component_double_clicked.connect(_on_component_double_clicked)
	canvas.suggestion_accepted.connect(_on_suggestion_accepted)
	canvas.suggestion_rejected.connect(_on_suggestion_rejected)
	canvas.selection_changed.connect(_on_selection_changed)

	# Data signals
	data.data_changed.connect(_on_data_changed)
	data.suggestion_added.connect(_on_suggestion_added)
	data.suggestion_resolved.connect(_on_suggestion_resolved)

	# Set data to canvas
	canvas.set_data(data)


func _add_demo_components() -> void:
	# Add some example components
	var sw1 := PCBComponentScript.new()
	sw1.id = "SW1"
	sw1.footprint = PCBComponentScript.FootprintType.SWITCH
	sw1.position = Vector2(30, 30)
	sw1.setup_standard_pins()
	data.add_component(sw1)

	var u1 := PCBComponentScript.new()
	u1.id = "U1"
	u1.footprint = PCBComponentScript.FootprintType.IC_DIP
	u1.position = Vector2(50, 50)
	u1.setup_standard_pins()
	data.add_component(u1)

	var r1 := PCBComponentScript.new()
	r1.id = "R1"
	r1.footprint = PCBComponentScript.FootprintType.RESISTOR
	r1.position = Vector2(70, 30)
	r1.properties["value"] = "10K"
	r1.setup_standard_pins()
	data.add_component(r1)

	var c1 := PCBComponentScript.new()
	c1.id = "C1"
	c1.footprint = PCBComponentScript.FootprintType.CAPACITOR
	c1.position = Vector2(70, 50)
	c1.properties["value"] = "100nF"
	c1.setup_standard_pins()
	data.add_component(c1)

	# Add some nets
	data.connect_pin_to_net("VCC", "U1", "8")
	data.connect_pin_to_net("VCC", "R1", "1")
	data.connect_pin_to_net("GND", "U1", "4")
	data.connect_pin_to_net("GND", "C1", "2")
	data.connect_pin_to_net("SW_OUT", "SW1", "2")
	data.connect_pin_to_net("SW_OUT", "U1", "1")

	# Save initial state
	data.save_to_history("Initial state")


#region Event Handlers

func _on_new_pressed() -> void:
	data.clear()
	is_modified = false
	file_path = ""


func _on_import_pressed() -> void:
	# TODO: Implement file dialog
	print("[PCBEditor] Import not yet implemented")


func _on_export_pressed() -> void:
	# TODO: Implement file dialog
	print("[PCBEditor] Export not yet implemented")


func _on_undo_pressed() -> void:
	if data.undo():
		canvas.queue_redraw()


func _on_redo_pressed() -> void:
	if data.redo():
		canvas.queue_redraw()


func _on_rotate_pressed() -> void:
	canvas._rotate_selected()


func _on_delete_pressed() -> void:
	canvas._delete_selected()


func _on_library_item_activated(index: int) -> void:
	var type_names := ["RESISTOR", "CAPACITOR", "IC_DIP", "IC_QFP", "SWITCH", "CONNECTOR", "LED", "DIODE", "TRANSISTOR", "HEADER"]
	if index >= type_names.size():
		return

	# Create new component
	var prefix: String = type_names[index][0]  # First letter
	var comp := PCBComponentScript.new()
	comp.id = data.generate_component_id(prefix)
	comp.footprint = index as PCBComponentScript.FootprintType
	comp.position = Vector2(data.board_width / 2, data.board_height / 2)
	comp.setup_standard_pins()

	data.save_to_history("Add " + comp.id)
	data.add_component(comp)

	# Select the new component
	canvas.select_component(comp.id)


func _on_component_selected(component_id: String) -> void:
	_update_properties_panel(component_id)
	component_selected.emit(component_id)


func _on_component_moved(component_id: String, new_position: Vector2) -> void:
	is_modified = true
	_update_properties_panel(component_id)
	data_changed.emit()


func _on_component_double_clicked(component_id: String) -> void:
	# Could open a component editor dialog
	print("[PCBEditor] Double clicked: ", component_id)


func _on_suggestion_accepted(suggestion_id: String) -> void:
	_update_suggestion_bar()


func _on_suggestion_rejected(suggestion_id: String) -> void:
	_update_suggestion_bar()


func _on_selection_changed() -> void:
	var selected := canvas.get_selected_components()
	if selected.size() == 1:
		_update_properties_panel(selected[0])
	else:
		_clear_properties_panel()


func _on_data_changed() -> void:
	is_modified = true
	data_changed.emit()


func _on_suggestion_added(suggestion_id: String) -> void:
	_update_suggestion_bar()
	suggestion_pending.emit(suggestion_id)


func _on_suggestion_resolved(suggestion_id: String, accepted: bool) -> void:
	_update_suggestion_bar()


func _on_accept_suggestion() -> void:
	canvas.accept_active_suggestion()


func _on_reject_suggestion() -> void:
	canvas.reject_active_suggestion()

#endregion


#region Properties Panel

func _update_properties_panel(component_id: String) -> void:
	var comp := data.get_component(component_id)
	if not comp:
		_clear_properties_panel()
		return

	prop_id_label.text = comp.id
	prop_position_label.text = "(%.1f, %.1f)" % [comp.position.x, comp.position.y]
	prop_rotation_label.text = "%.0f" % comp.rotation
	prop_footprint_label.text = PCBComponentScript.FootprintType.keys()[comp.footprint]


func _clear_properties_panel() -> void:
	prop_id_label.text = "-"
	prop_position_label.text = "-"
	prop_rotation_label.text = "-"
	prop_footprint_label.text = "-"

#endregion


#region Suggestion Bar

func _update_suggestion_bar() -> void:
	var pending := data.get_pending_suggestions()
	if pending.is_empty():
		suggestion_bar.visible = false
		canvas.set_active_suggestion("")
		return

	suggestion_bar.visible = true

	# Show first pending suggestion
	var suggestion := pending[0]
	suggestion_label.text = suggestion.description
	if not suggestion.reason.is_empty():
		suggestion_label.text += " - " + suggestion.reason

	canvas.set_active_suggestion(suggestion.id)

#endregion


#region Public API

## Get the PCB data
func get_data() -> PCBDataScript:
	return data


## Get the spatial index
func get_spatial_index() -> PCBSpatialIndexScript:
	return spatial_index


## Load data from dictionary
func load_from_dict(dict_data: Dictionary) -> void:
	data.load_from_dict(dict_data)
	is_modified = false
	canvas.zoom_to_fit()


## Get data as dictionary
func to_dict() -> Dictionary:
	return data.to_dict()


## Import from CSV
func import_csv(csv_text: String) -> void:
	data.from_csv(csv_text)
	is_modified = true
	canvas.zoom_to_fit()


## Export to CSV
func export_csv() -> String:
	return data.to_csv()


## Export to YAML
func export_yaml() -> String:
	return data.to_yaml()


## Add a component programmatically
func add_component_at(component_id: String, footprint_type: int, position: Vector2) -> void:
	var comp := PCBComponentScript.new()
	comp.id = component_id if not component_id.is_empty() else data.generate_component_id("U")
	comp.footprint = footprint_type as PCBComponentScript.FootprintType
	comp.position = position
	comp.setup_standard_pins()

	data.save_to_history("Add " + comp.id)
	data.add_component(comp)


## Move a component using natural language
func move_component_relative(component_id: String, description: String) -> Vector2:
	var new_pos := spatial_index.interpret_relative_move(component_id, description)
	if data.has_component(component_id):
		data.save_to_history("Move " + component_id)
		data.move_component(component_id, data.snap_to_grid(new_pos))
	return new_pos


## Create a suggestion for moving a component
func suggest_move(component_id: String, direction: String, reason: String = "") -> String:
	var comp := data.get_component(component_id)
	if not comp:
		return ""

	var new_pos := spatial_index.interpret_relative_move(component_id, direction)
	new_pos = data.snap_to_grid(new_pos)

	var suggestion = PCBSuggestionScript.create_move_suggestion(
		component_id,
		comp.position,
		new_pos,
		reason
	)

	data.add_suggestion(suggestion)
	return suggestion.id


## Get component context description
func describe_component(component_id: String) -> Dictionary:
	return spatial_index.describe_component_context(component_id)


## Get components near another component
func get_nearby_components(component_id: String, radius: float = 20.0) -> Array[String]:
	return spatial_index.get_components_near(component_id, radius)

#endregion

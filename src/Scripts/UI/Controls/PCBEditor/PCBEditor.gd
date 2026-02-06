class_name PCBEditor
extends PanelContainer
## PCB Viewer for displaying boards loaded from pcb-architect.
## Provides viewing, annotation, and AI suggestion capabilities.

const PCBDataScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBData.gd")
const PCBComponentScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBComponent.gd")
const PCBCanvasScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBCanvas.gd")
const PCBSpatialIndexScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBSpatialIndex.gd")
const PCBAnnotationScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBAnnotation.gd")

## Signals
signal data_changed()
signal component_selected(component_id: String)

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
var properties_panel: VBoxContainer = null

## Tool mode buttons (Select, Translate, Rotate)
var tool_buttons: Dictionary = {}  # mode -> Button
var tool_mode_label: Label = null

## Annotation toolbar elements
var annotation_buttons: Dictionary = {}  # mode -> Button
var annotation_mode_label: Label = null

## Route hint toolbar elements
var route_hint_buttons: Dictionary = {}  # mode -> Button
var route_hint_mode_label: Label = null

## Board size label in toolbar
var board_size_label: Label = null

## Text input dialog for annotations
var text_input_dialog: AcceptDialog = null
var text_input_line: LineEdit = null
var pending_text_position: Vector2 = Vector2.ZERO

## Properties panel elements
var prop_id_label: Label = null
var prop_position_label: Label = null
var prop_rotation_label: Label = null
var prop_footprint_label: Label = null

## Pin properties elements (for INSPECT_PIN mode)
var prop_pin_section: VBoxContainer = null
var prop_pin_label: Label = null
var prop_pin_name_label: Label = null


func _ready() -> void:
	# Generate unique ID
	editor_id = str(randi() % 1000000).pad_zeros(6)

	# Check if data was pre-loaded (e.g. via load_from_dict before entering tree)
	var preloaded := data != null

	# Initialize data (only if not already loaded via load_from_dict)
	if not data:
		data = PCBDataScript.new()
		spatial_index = PCBSpatialIndexScript.new(data)

	# Build UI
	_build_ui()

	# Connect signals
	_connect_signals()

	# If data was pre-loaded, the earlier call_deferred("_post_load_update") likely
	# fired before _build_ui() ran (UI didn't exist yet). Re-schedule it now.
	if preloaded:
		call_deferred("_post_load_update")


func _build_ui() -> void:
	# Main vertical layout
	var main_vbox := VBoxContainer.new()
	main_vbox.name = "MainVBox"
	main_vbox.clip_contents = true
	main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(main_vbox)

	# Toolbar in a scroll container for overflow handling
	var toolbar_scroll := ScrollContainer.new()
	toolbar_scroll.name = "ToolbarScroll"
	toolbar_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	toolbar_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	toolbar_scroll.custom_minimum_size.y = 36
	main_vbox.add_child(toolbar_scroll)

	toolbar = _create_toolbar()
	toolbar_scroll.add_child(toolbar)

	# Content area (canvas + properties)
	var content_hbox := HBoxContainer.new()
	content_hbox.name = "ContentHBox"
	content_hbox.clip_contents = true
	content_hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_child(content_hbox)

	# Canvas (main viewing area)
	var canvas_container := PanelContainer.new()
	canvas_container.name = "CanvasContainer"
	canvas_container.clip_contents = true
	canvas_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas_container.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_hbox.add_child(canvas_container)

	canvas = PCBCanvasScript.new()
	canvas.name = "PCBCanvas"
	canvas.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	canvas.size_flags_vertical = Control.SIZE_EXPAND_FILL
	canvas_container.add_child(canvas)

	# Right sidebar - tools + properties
	var right_sidebar := VBoxContainer.new()
	right_sidebar.name = "RightSidebar"
	right_sidebar.custom_minimum_size.x = 100
	content_hbox.add_child(right_sidebar)

	# Tools panel (annotations + route hints)
	var tools_panel := _create_tools_panel()
	right_sidebar.add_child(tools_panel)

	right_sidebar.add_child(HSeparator.new())

	# Properties panel
	properties_panel = _create_properties_panel()
	properties_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_sidebar.add_child(properties_panel)



func _create_toolbar() -> HBoxContainer:
	var tb := HBoxContainer.new()
	tb.name = "Toolbar"
	tb.custom_minimum_size.y = 32

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

	var traces_check := CheckButton.new()
	traces_check.text = "Traces"
	traces_check.button_pressed = true
	traces_check.toggled.connect(func(pressed): canvas.show_traces = pressed; canvas.queue_redraw())
	tb.add_child(traces_check)

	# Spacer
	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tb.add_child(spacer)

	# Board size
	board_size_label = Label.new()
	board_size_label.text = "Board: 100x100mm"
	tb.add_child(board_size_label)

	return tb


func _create_tools_panel() -> VBoxContainer:
	var panel := VBoxContainer.new()
	panel.name = "ToolsPanel"

	# Tools section (works on components and annotations)
	var tools_header := Label.new()
	tools_header.text = "Tools"
	tools_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(tools_header)

	var select_btn := Button.new()
	select_btn.text = "Select"
	select_btn.tooltip_text = "Select components or annotations (S)"
	select_btn.toggle_mode = true
	select_btn.pressed.connect(func(): _toggle_tool_mode(PCBCanvasScript.ToolMode.SELECT))
	panel.add_child(select_btn)
	tool_buttons[PCBCanvasScript.ToolMode.SELECT] = select_btn

	var translate_btn := Button.new()
	translate_btn.text = "Translate"
	translate_btn.tooltip_text = "Move selected items"
	translate_btn.toggle_mode = true
	translate_btn.pressed.connect(func(): _toggle_tool_mode(PCBCanvasScript.ToolMode.TRANSLATE))
	panel.add_child(translate_btn)
	tool_buttons[PCBCanvasScript.ToolMode.TRANSLATE] = translate_btn

	var rotate_btn := Button.new()
	rotate_btn.text = "Rotate"
	rotate_btn.tooltip_text = "Rotate selected items (R)"
	rotate_btn.toggle_mode = true
	rotate_btn.pressed.connect(func(): _toggle_tool_mode(PCBCanvasScript.ToolMode.ROTATE))
	panel.add_child(rotate_btn)
	tool_buttons[PCBCanvasScript.ToolMode.ROTATE] = rotate_btn

	# Tool mode label
	tool_mode_label = Label.new()
	tool_mode_label.text = ""
	tool_mode_label.add_theme_color_override("font_color", Color(0.5, 0.8, 1.0))
	panel.add_child(tool_mode_label)

	panel.add_child(HSeparator.new())

	# Annotation section
	var ann_header := Label.new()
	ann_header.text = "Annotate"
	ann_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(ann_header)

	var arrow_btn := Button.new()
	arrow_btn.text = "Arrow"
	arrow_btn.tooltip_text = "Draw arrow annotation (A)"
	arrow_btn.toggle_mode = true
	arrow_btn.pressed.connect(func(): _toggle_annotation_mode(PCBCanvasScript.AnnotationMode.ARROW))
	panel.add_child(arrow_btn)
	annotation_buttons[PCBCanvasScript.AnnotationMode.ARROW] = arrow_btn

	var text_btn := Button.new()
	text_btn.text = "Text"
	text_btn.tooltip_text = "Add text annotation (T)"
	text_btn.toggle_mode = true
	text_btn.pressed.connect(func(): _toggle_annotation_mode(PCBCanvasScript.AnnotationMode.TEXT))
	panel.add_child(text_btn)
	annotation_buttons[PCBCanvasScript.AnnotationMode.TEXT] = text_btn

	var region_btn := Button.new()
	region_btn.text = "Region"
	region_btn.tooltip_text = "Highlight region annotation (Shift+R)"
	region_btn.toggle_mode = true
	region_btn.pressed.connect(func(): _toggle_annotation_mode(PCBCanvasScript.AnnotationMode.REGION))
	panel.add_child(region_btn)
	annotation_buttons[PCBCanvasScript.AnnotationMode.REGION] = region_btn

	var polyline_btn := Button.new()
	polyline_btn.text = "Polyline"
	polyline_btn.tooltip_text = "Draw polyline annotation (P)"
	polyline_btn.toggle_mode = true
	polyline_btn.pressed.connect(func(): _toggle_annotation_mode(PCBCanvasScript.AnnotationMode.POLYLINE))
	panel.add_child(polyline_btn)
	annotation_buttons[PCBCanvasScript.AnnotationMode.POLYLINE] = polyline_btn

	# Annotation mode label
	annotation_mode_label = Label.new()
	annotation_mode_label.text = ""
	annotation_mode_label.add_theme_color_override("font_color", Color(0.9, 0.7, 0.2))
	panel.add_child(annotation_mode_label)

	panel.add_child(HSeparator.new())

	# Route hint section
	var rhint_header := Label.new()
	rhint_header.text = "Route Hints"
	rhint_header.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(rhint_header)

	var waypoint_btn := Button.new()
	waypoint_btn.text = "Waypoint"
	waypoint_btn.tooltip_text = "Add waypoint-only hint (W)"
	waypoint_btn.toggle_mode = true
	waypoint_btn.pressed.connect(func(): _toggle_route_hint_mode(PCBCanvasScript.RouteHintMode.WAYPOINT))
	panel.add_child(waypoint_btn)
	route_hint_buttons[PCBCanvasScript.RouteHintMode.WAYPOINT] = waypoint_btn

	var trace_btn := Button.new()
	trace_btn.text = "Trace"
	trace_btn.tooltip_text = "Add single trace hint - click pins or waypoints"
	trace_btn.toggle_mode = true
	trace_btn.pressed.connect(func(): _toggle_route_hint_mode(PCBCanvasScript.RouteHintMode.SINGLE_TRACE))
	panel.add_child(trace_btn)
	route_hint_buttons[PCBCanvasScript.RouteHintMode.SINGLE_TRACE] = trace_btn

	var bus_btn := Button.new()
	bus_btn.text = "Bus"
	bus_btn.tooltip_text = "Add bus hint - click pin groups for parallel routing"
	bus_btn.toggle_mode = true
	bus_btn.pressed.connect(func(): _toggle_route_hint_mode(PCBCanvasScript.RouteHintMode.BUS))
	panel.add_child(bus_btn)
	route_hint_buttons[PCBCanvasScript.RouteHintMode.BUS] = bus_btn

	var inspect_pin_btn := Button.new()
	inspect_pin_btn.text = "Inspect Pin"
	inspect_pin_btn.tooltip_text = "Click on a pin to see its info (Shift+P)"
	inspect_pin_btn.toggle_mode = true
	inspect_pin_btn.pressed.connect(func(): _toggle_route_hint_mode(PCBCanvasScript.RouteHintMode.INSPECT_PIN))
	panel.add_child(inspect_pin_btn)
	route_hint_buttons[PCBCanvasScript.RouteHintMode.INSPECT_PIN] = inspect_pin_btn

	# Route hint mode label
	route_hint_mode_label = Label.new()
	route_hint_mode_label.text = ""
	route_hint_mode_label.add_theme_color_override("font_color", Color(0.2, 0.8, 0.6))
	panel.add_child(route_hint_mode_label)

	return panel


func _create_properties_panel() -> VBoxContainer:
	var panel := VBoxContainer.new()
	panel.name = "PropertiesPanel"

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

	# Pin section (shown when pin selected in INSPECT_PIN mode)
	panel.add_child(HSeparator.new())

	prop_pin_section = VBoxContainer.new()
	prop_pin_section.name = "PinSection"
	prop_pin_section.visible = false  # Hidden until pin selected
	panel.add_child(prop_pin_section)

	var pin_header := Label.new()
	pin_header.text = "Pin Info"
	pin_header.add_theme_font_size_override("font_size", 11)
	pin_header.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
	prop_pin_section.add_child(pin_header)

	var pin_row := HBoxContainer.new()
	var pin_lbl := Label.new()
	pin_lbl.text = "Pin:"
	pin_lbl.custom_minimum_size.x = 60
	pin_row.add_child(pin_lbl)
	prop_pin_label = Label.new()
	prop_pin_label.text = "-"
	prop_pin_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	pin_row.add_child(prop_pin_label)
	prop_pin_section.add_child(pin_row)

	var name_row := HBoxContainer.new()
	var name_lbl := Label.new()
	name_lbl.text = "Name:"
	name_lbl.custom_minimum_size.x = 60
	name_row.add_child(name_lbl)
	prop_pin_name_label = Label.new()
	prop_pin_name_label.text = "-"
	prop_pin_name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	prop_pin_name_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	name_row.add_child(prop_pin_name_label)
	prop_pin_section.add_child(name_row)

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


func _connect_signals() -> void:
	# Canvas signals
	canvas.component_selected.connect(_on_component_selected)
	canvas.component_moved.connect(_on_component_moved)
	canvas.component_double_clicked.connect(_on_component_double_clicked)
	canvas.selection_changed.connect(_on_selection_changed)

	# Tool mode signals
	canvas.tool_mode_changed.connect(_on_tool_mode_changed)

	# Annotation signals
	canvas.annotation_mode_changed.connect(_on_annotation_mode_changed)
	canvas.annotation_text_requested.connect(_on_annotation_text_requested)
	canvas.annotation_created.connect(_on_annotation_created)

	# Route hint signals
	canvas.route_hint_mode_changed.connect(_on_route_hint_mode_changed)
	canvas.route_hint_created.connect(_on_route_hint_created)
	canvas.pin_selected.connect(_on_pin_selected)

	# Data signals
	data.data_changed.connect(_on_data_changed)

	# Set data to canvas
	canvas.set_data(data)

	# Create text input dialog
	_create_text_input_dialog()


#region Event Handlers


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


func _on_selection_changed() -> void:
	var selected := canvas.get_selected_components()
	if selected.size() == 1:
		_update_properties_panel(selected[0])
	else:
		_clear_properties_panel()


func _on_data_changed() -> void:
	is_modified = true
	_update_board_size_label()
	data_changed.emit()


func _update_board_size_label() -> void:
	if board_size_label and data:
		board_size_label.text = "Board: %sx%smm" % [data.board_width, data.board_height]


## Toggle tool mode from sidebar button
func _toggle_tool_mode(mode: int) -> void:
	var canvas_mode: PCBCanvasScript.ToolMode = mode as PCBCanvasScript.ToolMode
	if canvas.tool_mode == canvas_mode:
		canvas.clear_tool_mode()
	else:
		canvas.set_tool_mode(canvas_mode)


## Handle tool mode change from canvas
func _on_tool_mode_changed(mode: int) -> void:
	# Update button states
	for btn_mode in tool_buttons:
		var btn: Button = tool_buttons[btn_mode]
		btn.button_pressed = (btn_mode == mode)

	# Update mode label
	if mode == PCBCanvasScript.ToolMode.NONE:
		tool_mode_label.text = ""
	else:
		var mode_names := ["", "Select", "Translate", "Rotate"]
		tool_mode_label.text = mode_names[mode]


## Toggle annotation mode from sidebar button
func _toggle_annotation_mode(mode: int) -> void:
	var canvas_mode: PCBCanvasScript.AnnotationMode = mode as PCBCanvasScript.AnnotationMode
	if canvas.annotation_mode == canvas_mode:
		canvas.clear_annotation_mode()
	else:
		canvas.set_annotation_mode(canvas_mode)


## Handle annotation mode change from canvas
func _on_annotation_mode_changed(mode: int) -> void:
	# Update button states
	for btn_mode in annotation_buttons:
		var btn: Button = annotation_buttons[btn_mode]
		btn.button_pressed = (btn_mode == mode)

	# Update mode label
	if mode == PCBCanvasScript.AnnotationMode.NONE:
		annotation_mode_label.text = ""
	else:
		var mode_names := ["", "Arrow", "Text", "Region", "Polyline"]
		annotation_mode_label.text = mode_names[mode]


## Handle request for text input (when placing text annotation)
func _on_annotation_text_requested(position: Vector2) -> void:
	pending_text_position = position
	text_input_line.text = ""
	text_input_dialog.popup_centered()
	text_input_line.grab_focus()


## Handle annotation created
func _on_annotation_created(annotation_id: String) -> void:
	# Could show a brief notification or update stats
	pass


## Toggle route hint mode from toolbar button
func _toggle_route_hint_mode(mode: int) -> void:
	var canvas_mode: PCBCanvasScript.RouteHintMode = mode as PCBCanvasScript.RouteHintMode
	if canvas.route_hint_mode == canvas_mode:
		canvas.clear_route_hint_mode()
	else:
		canvas.set_route_hint_mode(canvas_mode)


## Handle route hint mode change from canvas
func _on_route_hint_mode_changed(mode: int) -> void:
	# Update button states
	for btn_mode in route_hint_buttons:
		var btn: Button = route_hint_buttons[btn_mode]
		btn.button_pressed = (btn_mode == mode)

	# Update mode label
	if mode == PCBCanvasScript.RouteHintMode.NONE:
		route_hint_mode_label.text = ""
	else:
		var mode_names := ["", "Waypoint", "Trace", "Bus", "Inspect Pin"]
		route_hint_mode_label.text = mode_names[mode]


## Handle route hint created
func _on_route_hint_created(hint_id: String) -> void:
	# Could show a brief notification
	pass


## Handle pin selected (from INSPECT_PIN mode)
func _on_pin_selected(pin_info: Dictionary) -> void:
	if pin_info.is_empty():
		prop_pin_section.visible = false
		prop_pin_label.text = "-"
		prop_pin_name_label.text = "-"
		return

	# Show the pin section
	prop_pin_section.visible = true

	# Update pin label with Component.Pin format
	prop_pin_label.text = "%s.%s" % [pin_info.component, pin_info.pin]

	# Look up pin name from component geometry (e.g., "3V3", "GND")
	var pin_name := ""
	var comp = data.get_component(pin_info.component)
	if comp:
		pin_name = comp.get_pin_name(pin_info.pin)

	# If no geometry name, fall back to net name
	if pin_name.is_empty():
		for net_name in data.nets:
			var net = data.nets[net_name]  # PCBNet object
			for pin in net.pins:
				if pin.get("component_id", "") == pin_info.component and pin.get("pin_name", "") == pin_info.pin:
					pin_name = net_name
					break
			if not pin_name.is_empty():
				break

	if pin_name.is_empty():
		prop_pin_name_label.text = "(unconnected)"
	else:
		prop_pin_name_label.text = pin_name


## Create text input dialog for text annotations
func _create_text_input_dialog() -> void:
	text_input_dialog = AcceptDialog.new()
	text_input_dialog.title = "Add Text Annotation"
	text_input_dialog.size = Vector2i(300, 100)
	add_child(text_input_dialog)

	var vbox := VBoxContainer.new()
	text_input_dialog.add_child(vbox)

	var label := Label.new()
	label.text = "Enter annotation text:"
	vbox.add_child(label)

	text_input_line = LineEdit.new()
	text_input_line.placeholder_text = "Type your annotation..."
	text_input_line.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(text_input_line)

	# Connect signals
	text_input_dialog.confirmed.connect(_on_text_input_confirmed)
	text_input_dialog.canceled.connect(_on_text_input_canceled)
	text_input_line.text_submitted.connect(func(_text): text_input_dialog.hide(); _on_text_input_confirmed())


## Handle text input confirmed
func _on_text_input_confirmed() -> void:
	var text_content := text_input_line.text.strip_edges()
	if not text_content.is_empty():
		canvas.create_text_annotation(pending_text_position, text_content)


## Handle text input canceled
func _on_text_input_canceled() -> void:
	# Just close, don't create annotation
	pass

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


#region Public API

## Get the PCB data
func get_data() -> PCBDataScript:
	return data


## Get the spatial index
func get_spatial_index() -> PCBSpatialIndexScript:
	return spatial_index


## Load data from dictionary
func load_from_dict(dict_data: Dictionary) -> void:
	# Ensure data exists (may be called before _ready)
	if not data:
		data = PCBDataScript.new()
		spatial_index = PCBSpatialIndexScript.new(data)
	data.load_from_dict(dict_data)
	is_modified = false
	# Schedule canvas update after _ready completes
	call_deferred("_post_load_update")


## Called after load_from_dict to update canvas once _ready has run
func _post_load_update() -> void:
	_update_board_size_label()
	if canvas:
		canvas.queue_redraw()
		# Canvas may not have a valid size yet during project load.
		# Wait for it to be laid out before zooming.
		if canvas.size.x > 0 and canvas.size.y > 0:
			canvas.zoom_to_fit()
		else:
			canvas.resized.connect(canvas.zoom_to_fit, CONNECT_ONE_SHOT)


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


## Get component context description
func describe_component(component_id: String) -> Dictionary:
	return spatial_index.describe_component_context(component_id)


## Get components near another component
func get_nearby_components(component_id: String, radius: float = 20.0) -> Array[String]:
	return spatial_index.get_components_near(component_id, radius)

#endregion

class_name PCBCanvas
extends Control
## Renders the PCB board with components, traces, and suggestions.

const PCBDataScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBData.gd")
const PCBComponentScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBComponent.gd")
const PCBSpatialIndexScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBSpatialIndex.gd")
const PCBSuggestionScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBSuggestion.gd")
const PCBAnnotationScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBAnnotation.gd")

## Signals
signal component_selected(component_id: String)
signal component_deselected(component_id: String)
signal component_moved(component_id: String, new_position: Vector2)
signal component_double_clicked(component_id: String)
signal canvas_clicked(world_position: Vector2)
signal suggestion_accepted(suggestion_id: String)
signal suggestion_rejected(suggestion_id: String)
signal zoom_changed(new_zoom: float)
signal selection_changed()

## Data references
var data: PCBDataScript = null
var spatial_index: PCBSpatialIndexScript = null

## View state
var zoom: float = 4.0  # Pixels per mm (4 = 1mm = 4px)
var pan_offset: Vector2 = Vector2.ZERO
var min_zoom: float = 0.5
var max_zoom: float = 50.0

## Display options
var show_grid: bool = true
var show_ratsnest: bool = true
var show_traces: bool = true
var show_labels: bool = true
var show_pins: bool = true
var snap_to_grid: bool = true

## Selection state
var selected_components: Array[String] = []
var hovered_component: String = ""

## Interaction state
var is_panning: bool = false
var pan_start_mouse: Vector2 = Vector2.ZERO
var pan_start_offset: Vector2 = Vector2.ZERO

var is_dragging_component: bool = false
var drag_component_id: String = ""
var drag_start_mouse: Vector2 = Vector2.ZERO
var drag_start_component_pos: Vector2 = Vector2.ZERO

var is_box_selecting: bool = false
var box_select_start: Vector2 = Vector2.ZERO
var box_select_end: Vector2 = Vector2.ZERO

## Annotation drawing mode
enum AnnotationMode { NONE, SELECT, ARROW, TEXT, REGION, POLYLINE }
var annotation_mode: AnnotationMode = AnnotationMode.NONE
var is_drawing_annotation: bool = false
var annotation_points: Array[Vector2] = []  # World coordinates
var annotation_preview_point: Vector2 = Vector2.ZERO  # Current mouse position for preview

## Annotation selection state
var selected_annotation_id: String = ""
var is_dragging_annotation: bool = false
var annotation_drag_start: Vector2 = Vector2.ZERO
var annotation_drag_offset: Vector2 = Vector2.ZERO

## Signal for annotation mode changes and text input requests
signal annotation_mode_changed(mode: AnnotationMode)
signal annotation_text_requested(position: Vector2)  # Emitted when text annotation needs input
signal annotation_created(annotation_id: String)

## Ghost layer for suggestion preview
var active_suggestion_id: String = ""

## Colors
var board_color: Color = Color(0.15, 0.25, 0.15, 1.0)
var board_edge_color: Color = Color(0.4, 0.4, 0.4, 1.0)
var grid_color: Color = Color(0.25, 0.35, 0.25, 0.5)
var grid_major_color: Color = Color(0.3, 0.4, 0.3, 0.7)
var component_color: Color = Color(0.2, 0.6, 0.3, 1.0)
var component_selected_color: Color = Color(0.3, 0.8, 0.4, 1.0)
var component_hover_color: Color = Color(0.25, 0.7, 0.35, 1.0)
var pin_color: Color = Color(0.9, 0.75, 0.3, 1.0)
var label_color: Color = Color.WHITE
var trace_color: Color = Color(0.8, 0.2, 0.2, 1.0)
var ratsnest_color: Color = Color(0.5, 0.5, 0.8, 0.5)
var selection_box_color: Color = Color(0.3, 0.5, 0.8, 0.3)
var selection_border_color: Color = Color(0.4, 0.6, 0.9, 1.0)
var ghost_color: Color = Color(0.5, 0.8, 1.0, 0.5)
var move_arrow_color: Color = Color(0.5, 0.8, 1.0, 0.8)

## Pad colors (copper/solder appearance)
var pad_copper_color: Color = Color(0.85, 0.65, 0.3, 1.0)  # Copper/gold for THT
var pad_smd_color: Color = Color(0.75, 0.55, 0.25, 1.0)  # SMD pads
var drill_hole_color: Color = Color(0.08, 0.08, 0.08, 1.0)  # Drill holes (match background)
var mounting_hole_color: Color = Color(0.2, 0.2, 0.2, 1.0)  # Non-plated holes

## Display option for pad rendering
var show_pads: bool = true

## Display option for annotations
var show_annotations: bool = true

## Annotation colors (by author)
var annotation_human_color: Color = Color(0.9, 0.7, 0.2)  # Yellow for human
var annotation_ai_color: Color = Color(0.3, 0.7, 0.9)     # Cyan for AI

## Pin remap suggestion colors
var pin_remap_old_color: Color = Color(0.9, 0.3, 0.3, 0.7)  # Red for old pin
var pin_remap_new_color: Color = Color(0.3, 0.9, 0.3, 0.7)  # Green for new pin

## Route suggestion colors
var route_ghost_color: Color = Color(0.5, 0.8, 1.0, 0.6)  # Light blue for route ghost

## Font
var font: Font
var font_size: int = 12


## Context menu
var context_menu: PopupMenu = null
var context_menu_world_pos: Vector2 = Vector2.ZERO
var right_click_start_pos: Vector2 = Vector2.ZERO
const RIGHT_CLICK_THRESHOLD := 5.0  # Pixels - if moved less than this, show context menu

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	clip_contents = true

	font = ThemeDB.fallback_font
	font_size = ThemeDB.fallback_font_size

	# Initialize spatial index
	spatial_index = PCBSpatialIndexScript.new()

	# Create context menu
	_create_context_menu()


## Create the right-click context menu
func _create_context_menu() -> void:
	context_menu = PopupMenu.new()
	context_menu.name = "ContextMenu"
	add_child(context_menu)

	# Add annotation submenu
	var annotation_menu := PopupMenu.new()
	annotation_menu.name = "AnnotationMenu"
	annotation_menu.add_item("Select (S)", 0)
	annotation_menu.add_item("Arrow (A)", 1)
	annotation_menu.add_item("Text (T)", 2)
	annotation_menu.add_item("Region (R)", 3)
	annotation_menu.add_item("Polyline (P)", 4)
	annotation_menu.id_pressed.connect(_on_annotation_menu_pressed)

	context_menu.add_child(annotation_menu)
	context_menu.add_submenu_item("Add Annotation", "AnnotationMenu")
	context_menu.add_separator()
	context_menu.add_item("Clear My Annotations", 100)
	context_menu.add_item("Clear AI Annotations", 101)
	context_menu.add_item("Clear All Annotations", 102)
	context_menu.id_pressed.connect(_on_context_menu_pressed)


## Update context menu based on current selection
func _update_context_menu_for_selection() -> void:
	# Remove old annotation action items (IDs 200-205)
	var indices_to_remove: Array[int] = []
	for i in range(context_menu.item_count):
		var id := context_menu.get_item_id(i)
		if id >= 200 and id <= 210:
			indices_to_remove.append(i)

	# Remove in reverse order to avoid index shifting
	for i in range(indices_to_remove.size() - 1, -1, -1):
		context_menu.remove_item(indices_to_remove[i])

	# Add annotation transform items if an annotation is selected
	if not selected_annotation_id.is_empty():
		var annotation := data.get_annotation(selected_annotation_id)
		if annotation:
			# Find position after separator
			var sep_index := 1  # After "Add Annotation" submenu
			for i in range(context_menu.item_count):
				if context_menu.is_item_separator(i):
					sep_index = i
					break

			context_menu.add_separator("", 200)
			context_menu.add_item("Rotate Annotation (R)", 201)
			context_menu.add_item("Scale Up (+)", 202)
			context_menu.add_item("Scale Down (-)", 203)
			context_menu.add_item("Delete Annotation (Del)", 204)

			if annotation.type == PCBAnnotationScript.AnnotationType.ARROW:
				context_menu.add_item("Invert Arrow (I)", 205)


## Handle annotation submenu selection
func _on_annotation_menu_pressed(id: int) -> void:
	match id:
		0: set_annotation_mode(AnnotationMode.SELECT)
		1: set_annotation_mode(AnnotationMode.ARROW)
		2: set_annotation_mode(AnnotationMode.TEXT)
		3: set_annotation_mode(AnnotationMode.REGION)
		4: set_annotation_mode(AnnotationMode.POLYLINE)


## Handle main context menu selection
func _on_context_menu_pressed(id: int) -> void:
	if not data:
		return

	match id:
		100:  # Clear my annotations
			data.clear_annotations("human")
		101:  # Clear AI annotations
			data.clear_annotations("ai")
		102:  # Clear all annotations
			data.clear_annotations("")
		201:  # Rotate annotation
			_rotate_selected_annotation()
		202:  # Scale up
			_scale_selected_annotation(1.2)
		203:  # Scale down
			_scale_selected_annotation(0.8)
		204:  # Delete annotation
			_delete_selected_annotation()
		205:  # Invert arrow
			_invert_selected_arrow()


## Show the context menu at the given screen position
func _show_context_menu(screen_pos: Vector2) -> void:
	if not context_menu:
		return

	# Update menu items based on current selection
	_update_context_menu_for_selection()

	# Convert to global position for the popup
	var global_pos := get_global_transform() * screen_pos
	context_menu.position = Vector2i(global_pos)
	context_menu.popup()


func _draw() -> void:
	if not data:
		draw_rect(Rect2(Vector2.ZERO, size), Color(0.1, 0.1, 0.1))
		return

	# Draw background
	draw_rect(Rect2(Vector2.ZERO, size), Color(0.08, 0.08, 0.08))

	# Draw board outline
	_draw_board()

	# Draw grid
	if show_grid:
		_draw_grid()

	# Draw traces
	if show_traces:
		_draw_traces()

	# Draw components
	_draw_components()

	# Draw ratsnest (unrouted connections) - drawn AFTER components so lines are visible on top
	if show_ratsnest:
		_draw_ratsnest()

	# Draw suggestion ghosts
	_draw_suggestion_ghosts()

	# Draw annotations (on top of everything except selection)
	if show_annotations:
		_draw_annotations()

	# Draw selection box
	if is_box_selecting:
		_draw_selection_box()

	# Draw annotation preview while drawing
	if is_drawing_annotation or annotation_mode != AnnotationMode.NONE:
		_draw_annotation_preview()

	# Draw active suggestion arrow
	_draw_suggestion_arrow()


## Draw the PCB board outline
func _draw_board() -> void:
	var board_rect := Rect2(
		world_to_screen(Vector2.ZERO),
		Vector2(data.board_width, data.board_height) * zoom
	)

	draw_rect(board_rect, board_color)
	draw_rect(board_rect, board_edge_color, false, 2.0)


## Draw the alignment grid
func _draw_grid() -> void:
	var board_start := world_to_screen(Vector2.ZERO)
	var board_end := world_to_screen(Vector2(data.board_width, data.board_height))

	var grid_step := data.grid_size * zoom
	var major_interval := 10  # Every 10 grid lines is major

	# Only draw grid if it's visible (not too zoomed out)
	if grid_step < 3:
		return

	var start_x := board_start.x
	var end_x := board_end.x
	var start_y := board_start.y
	var end_y := board_end.y

	# Vertical lines
	var x := start_x
	var line_count := 0
	while x <= end_x:
		var color := grid_major_color if line_count % major_interval == 0 else grid_color
		draw_line(Vector2(x, start_y), Vector2(x, end_y), color, 1.0)
		x += grid_step
		line_count += 1

	# Horizontal lines
	var y := start_y
	line_count = 0
	while y <= end_y:
		var color := grid_major_color if line_count % major_interval == 0 else grid_color
		draw_line(Vector2(start_x, y), Vector2(end_x, y), color, 1.0)
		y += grid_step
		line_count += 1


## Draw all traces
func _draw_traces() -> void:
	for trace_id in data.traces:
		var trace = data.traces[trace_id]
		if trace.waypoints.size() < 2:
			continue

		var net = data.get_net(trace.net_name)
		var color := trace_color
		if net:
			color = net.color

		var points: PackedVector2Array = []
		for wp in trace.waypoints:
			points.append(world_to_screen(wp))

		if points.size() >= 2:
			var trace_width = trace.width * zoom
			draw_polyline(points, color, maxf(trace_width, 1.0))


## Draw ratsnest (unrouted net connections)
func _draw_ratsnest() -> void:
	for net_name in data.nets:
		var net = data.nets[net_name]
		if net.pins.size() < 2:
			continue

		# Get pin positions with component info for better visualization
		var pin_data: Array = []  # [{pos: Vector2, comp_id: String, pin_name: String}]
		for pin in net.pins:
			var comp_id: String = pin.get("component_id", "")
			var pin_name: String = pin.get("pin_name", "")
			var comp := data.get_component(comp_id)
			if comp:
				pin_data.append({
					"pos": comp.get_pin_world_position(pin_name),
					"comp_id": comp_id,
					"pin_name": pin_name
				})

		# Draw connections between consecutive pins (chain topology)
		# This shows clearer pin-to-pin connections than star topology
		if pin_data.size() >= 2:
			var net_color = net.color
			net_color.a = 0.6

			for i in range(pin_data.size() - 1):
				var p1 := world_to_screen(pin_data[i]["pos"])
				var p2 := world_to_screen(pin_data[i + 1]["pos"])
				_draw_dashed_line(p1, p2, net_color, 1.5, 5.0)

				# Draw small circles at pin endpoints for visibility
				draw_circle(p1, 3.0, net_color)
				draw_circle(p2, 3.0, net_color)


## Draw all components
func _draw_components() -> void:
	for comp_id in data.components:
		var comp: PCBComponentScript = data.components[comp_id]
		_draw_component(comp)


## Draw a single component using rigid body transform
func _draw_component(comp: PCBComponentScript) -> void:
	# Determine color
	var color := comp.color
	if comp.id in selected_components:
		color = component_selected_color
	elif comp.id == hovered_component:
		color = component_hover_color

	# Get the rigid body transform for this component
	# This ensures body and pads rotate together as a unit around the anchor
	var xform := comp.get_transform()

	# Draw body using local_bounds transformed to world coordinates
	var local_poly := comp.get_local_body_polygon()  # [TL, TR, BR, BL] relative to anchor
	var screen_poly: PackedVector2Array = []

	for point in local_poly:
		# Apply component rotation, then translate to world position
		var world_point: Vector2 = comp.position + (xform * point)
		screen_poly.append(world_to_screen(world_point))

	draw_colored_polygon(screen_poly, color)

	# Draw outline
	var outline_points: PackedVector2Array = screen_poly.duplicate()
	outline_points.append(screen_poly[0])  # Close loop
	draw_polyline(outline_points, color.darkened(0.3), 1.0)

	# Draw pads with accurate geometry if available
	if show_pads and comp.has_pad_geometry and comp.pads.size() > 0:
		_draw_component_pads(comp, xform)
	elif show_pins:
		# Fall back to footprint-appropriate rendering
		_draw_fallback_pins(comp, xform)

	# Draw label anchored to body center
	if show_labels and comp.label_visible:
		var local_center := comp.local_bounds.get_center()
		var world_center: Vector2 = comp.position + (xform * local_center)
		var screen_center := world_to_screen(world_center)
		var label_pos := screen_center - Vector2(0, comp.height * zoom / 2 + 10)
		draw_string(font, label_pos, comp.id, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, label_color)


## Draw pads with accurate geometry from KiCAD footprint
func _draw_component_pads(comp: PCBComponentScript, xform: Transform2D) -> void:
	# Use same rotation sign as xform (negated for KiCAD CCW → Godot CW)
	var pad_rot := -comp.rotation

	for pad in comp.pads:
		var pad_type: String = pad.get("type", "smd")
		var pad_shape: String = pad.get("shape", "rect")
		var local_pos: Vector2 = pad.get("position", Vector2.ZERO)
		var pad_size: Vector2 = pad.get("size", Vector2(1, 1))

		# Determine if this is a through-hole pad
		var is_tht := pad_type in ["thru_hole", "np_thru_hole"]

		# Transform pad position using the same rigid body transform
		var world_pos: Vector2 = comp.position + (xform * local_pos)
		var screen_pos := world_to_screen(world_pos)
		var screen_size := pad_size * zoom

		# NOTE: We do NOT swap width/height here - the shape drawing functions
		# handle rotation themselves via pad_rot. Double-swapping causes distortion.

		# Determine pad color based on type
		var draw_color := pad_copper_color
		if pad_type == "smd":
			draw_color = pad_smd_color
		elif pad_type == "np_thru_hole":
			draw_color = mounting_hole_color

		# Draw pad based on shape (use pad_rot for consistent rotation with xform)
		match pad_shape:
			"rect":
				_draw_rect_pad(screen_pos, screen_size, pad_rot, draw_color)
			"circle":
				_draw_circle_pad(screen_pos, screen_size, draw_color)
			"oval":
				_draw_oval_pad(screen_pos, screen_size, pad_rot, draw_color)
			"roundrect":
				_draw_roundrect_pad(screen_pos, screen_size, pad_rot, draw_color)
			_:
				# Default to rectangle for unknown shapes
				_draw_rect_pad(screen_pos, screen_size, pad_rot, draw_color)

		# Draw drill hole for through-hole pads (drawn ON TOP of copper)
		if is_tht:
			# Get drill size (may be Vector2 for slots or float for round holes)
			var drill_val = pad.get("drill", Vector2.ZERO)
			var drill_diameter: float = 0.0
			if drill_val is Vector2:
				drill_diameter = maxf(drill_val.x, drill_val.y)
			elif drill_val is float or drill_val is int:
				drill_diameter = float(drill_val)

			# Fallback: use pad size if drill is missing/zero
			if drill_diameter <= 0.0:
				drill_diameter = minf(pad_size.x, pad_size.y)

			if drill_diameter > 0.0:
				var drill_radius := (drill_diameter * zoom) / 2.0
				# Draw hole in background color to simulate actual hole
				draw_circle(screen_pos, maxf(drill_radius, 1.0), drill_hole_color)
				# Draw thin outline for visibility
				draw_arc(screen_pos, maxf(drill_radius, 1.0), 0, TAU, 16, Color(0.4, 0.4, 0.4, 0.6), 1.0)


## Fallback pin rendering when pad geometry not available
## Uses footprint-appropriate sizing instead of tiny markers
func _draw_fallback_pins(comp: PCBComponentScript, xform: Transform2D) -> void:
	# Determine rendering style based on footprint type
	var is_mounting_hole := comp.footprint == PCBComponentScript.FootprintType.MOUNTING_HOLE
	var is_tht_footprint := comp.footprint in [
		PCBComponentScript.FootprintType.IC_DIP,
		PCBComponentScript.FootprintType.HEADER,
		PCBComponentScript.FootprintType.CONNECTOR,
		PCBComponentScript.FootprintType.MODULE,
	]
	# These can be either SMD or THT - assume THT for fallback
	var is_likely_tht := comp.footprint in [
		PCBComponentScript.FootprintType.RESISTOR,
		PCBComponentScript.FootprintType.CAPACITOR,
		PCBComponentScript.FootprintType.DIODE,
		PCBComponentScript.FootprintType.LED,
		PCBComponentScript.FootprintType.TRANSISTOR,
		PCBComponentScript.FootprintType.SWITCH,
		PCBComponentScript.FootprintType.CRYSTAL,
	]

	if is_mounting_hole:
		# Draw mounting hole as a large non-plated hole
		# Use component width as hole diameter (typically 3.2mm for M3)
		var hole_diameter := comp.width
		var hole_radius := (hole_diameter * zoom) / 2.0

		for pin_name in comp.pins:
			var local_pin_pos: Vector2 = comp.pins[pin_name]
			var world_pin_pos: Vector2 = comp.position + (xform * local_pin_pos)
			var pin_screen := world_to_screen(world_pin_pos)

			# Draw copper annulus (plated ring around hole)
			var annulus_radius := hole_radius + (0.5 * zoom)  # 0.5mm annulus
			draw_circle(pin_screen, maxf(annulus_radius, 2.0), mounting_hole_color)
			# Draw the hole itself
			draw_circle(pin_screen, maxf(hole_radius, 1.5), drill_hole_color)
			# Draw outline for visibility
			draw_arc(pin_screen, maxf(hole_radius, 1.5), 0, TAU, 24, Color(0.5, 0.5, 0.5, 0.8), 1.5)

	elif is_tht_footprint or is_likely_tht:
		# Draw THT pads with copper annulus and drill hole
		# Standard THT pad: ~1.7mm pad diameter, ~1.0mm drill
		var pad_diameter := 1.7  # mm
		var drill_diameter := 1.0  # mm
		var pad_radius := (pad_diameter * zoom) / 2.0
		var drill_radius := (drill_diameter * zoom) / 2.0

		for pin_name in comp.pins:
			var local_pin_pos: Vector2 = comp.pins[pin_name]
			var world_pin_pos: Vector2 = comp.position + (xform * local_pin_pos)
			var pin_screen := world_to_screen(world_pin_pos)

			# Pin 1 gets square pad, others get round (check actual pin name, not iteration order)
			if pin_name == "1":
				# Square pad for pin 1
				var pad_size := Vector2(pad_diameter, pad_diameter) * zoom
				_draw_rect_pad(pin_screen, pad_size, -comp.rotation, pad_copper_color)
			else:
				# Round copper pad
				draw_circle(pin_screen, maxf(pad_radius, 2.0), pad_copper_color)

			# Draw drill hole on top
			draw_circle(pin_screen, maxf(drill_radius, 1.0), drill_hole_color)
			draw_arc(pin_screen, maxf(drill_radius, 1.0), 0, TAU, 16, Color(0.4, 0.4, 0.4, 0.6), 1.0)

	else:
		# SMD or unknown - draw simple pad markers
		var pad_size := 1.0  # mm
		var pad_radius := (pad_size * zoom) / 2.0

		for pin_name in comp.pins:
			var local_pin_pos: Vector2 = comp.pins[pin_name]
			var world_pin_pos: Vector2 = comp.position + (xform * local_pin_pos)
			var pin_screen := world_to_screen(world_pin_pos)
			draw_circle(pin_screen, maxf(pad_radius, 2.0), pad_smd_color)


## Draw rectangular pad (sharp corners)
func _draw_rect_pad(center: Vector2, size: Vector2, rotation_degrees: float, color: Color) -> void:
	var rect_points := _get_rotated_rect_points(center, size, rotation_degrees)
	draw_colored_polygon(rect_points, color)


## Draw circular pad
func _draw_circle_pad(center: Vector2, size: Vector2, color: Color) -> void:
	var radius := maxf(size.x, size.y) / 2.0
	draw_circle(center, maxf(radius, 1.0), color)


## Draw oval pad (elongated circle)
func _draw_oval_pad(center: Vector2, size: Vector2, rotation_degrees: float, color: Color) -> void:
	# Approximate oval with a capsule shape
	var rot_rad := deg_to_rad(rotation_degrees)

	if size.x > size.y:
		# Horizontal oval
		var radius := size.y / 2.0
		var half_length := (size.x - size.y) / 2.0

		# Draw center rectangle
		var rect_size := Vector2(half_length * 2, size.y)
		var rect_points := _get_rotated_rect_points(center, rect_size, rotation_degrees)
		draw_colored_polygon(rect_points, color)

		# Draw end circles
		var offset := Vector2(half_length, 0).rotated(rot_rad)
		draw_circle(center - offset, maxf(radius, 1.0), color)
		draw_circle(center + offset, maxf(radius, 1.0), color)
	else:
		# Vertical oval
		var radius := size.x / 2.0
		var half_length := (size.y - size.x) / 2.0

		# Draw center rectangle
		var rect_size := Vector2(size.x, half_length * 2)
		var rect_points := _get_rotated_rect_points(center, rect_size, rotation_degrees)
		draw_colored_polygon(rect_points, color)

		# Draw end circles
		var offset := Vector2(0, half_length).rotated(rot_rad)
		draw_circle(center - offset, maxf(radius, 1.0), color)
		draw_circle(center + offset, maxf(radius, 1.0), color)


## Draw rounded rectangle pad
func _draw_roundrect_pad(center: Vector2, size: Vector2, rotation_degrees: float, color: Color) -> void:
	# Approximate with a smaller rect and corner circles
	var corner_radius := minf(size.x, size.y) * 0.25
	var inner_size := size - Vector2(corner_radius * 2, corner_radius * 2)

	# Draw inner rectangle
	var rect_points := _get_rotated_rect_points(center, size, rotation_degrees)
	draw_colored_polygon(rect_points, color)

	# Note: For true rounded corners we'd need more complex geometry
	# This approximation is close enough for most PCB visualization


## Get rotated rectangle points
func _get_rotated_rect_points(center: Vector2, size: Vector2, rotation_degrees: float) -> PackedVector2Array:
	var half_size := size / 2.0
	var corners := [
		Vector2(-half_size.x, -half_size.y),
		Vector2(half_size.x, -half_size.y),
		Vector2(half_size.x, half_size.y),
		Vector2(-half_size.x, half_size.y)
	]

	var rot_rad := deg_to_rad(rotation_degrees)
	var result: PackedVector2Array = []

	for corner in corners:
		result.append(center + corner.rotated(rot_rad))

	return result


## Draw suggestion ghost overlay
func _draw_suggestion_ghosts() -> void:
	for sug_id in data.suggestions:
		var suggestion: PCBSuggestionScript = data.suggestions[sug_id]
		if not suggestion.is_pending():
			continue

		match suggestion.type:
			PCBSuggestionScript.SuggestionType.MOVE:
				_draw_move_ghost(suggestion)
			PCBSuggestionScript.SuggestionType.ADD:
				_draw_add_ghost(suggestion)
			PCBSuggestionScript.SuggestionType.PIN_REMAP:
				_draw_pin_remap_ghost(suggestion)
			PCBSuggestionScript.SuggestionType.ROUTE:
				_draw_route_ghost(suggestion)


## Draw ghost for move suggestion
func _draw_move_ghost(suggestion: PCBSuggestionScript) -> void:
	var comp := data.get_component(suggestion.target_component)
	if not comp:
		return

	var proposed_pos := suggestion.get_proposed_position()
	var screen_pos := world_to_screen(proposed_pos)
	var screen_size := Vector2(comp.width, comp.height) * zoom

	# Draw ghost rectangle
	var rect_points := _get_rotated_rect_points(screen_pos, screen_size, comp.rotation)
	var ghost := ghost_color
	if suggestion.id == active_suggestion_id:
		ghost.a = 0.7
	draw_colored_polygon(rect_points, ghost)
	var ghost_outline_points: PackedVector2Array = rect_points.duplicate()
	ghost_outline_points.append(rect_points[0])
	draw_polyline(ghost_outline_points, ghost.lightened(0.3), 2.0)

	# Draw ghost label
	var label_pos := screen_pos - Vector2(0, screen_size.y / 2 + 10)
	draw_string(font, label_pos, comp.id + " (proposed)", HORIZONTAL_ALIGNMENT_CENTER, -1, font_size, ghost)


## Draw ghost for add suggestion
func _draw_add_ghost(suggestion: PCBSuggestionScript) -> void:
	var pos_data: Dictionary = suggestion.proposed_state.get("position", {})
	var pos := Vector2(pos_data.get("x", 0), pos_data.get("y", 0))
	var screen_pos := world_to_screen(pos)

	# Draw simple placeholder
	var placeholder_size := Vector2(20, 10) * zoom
	var rect := Rect2(screen_pos - placeholder_size / 2, placeholder_size)
	draw_rect(rect, ghost_color)
	draw_rect(rect, ghost_color.lightened(0.3), false, 2.0)


## Draw ghost for pin remap suggestion
func _draw_pin_remap_ghost(suggestion: PCBSuggestionScript) -> void:
	var old_pin := suggestion.get_old_pin()
	var new_pin := suggestion.get_new_pin()

	var old_comp := data.get_component(old_pin.get("component", ""))
	var new_comp := data.get_component(new_pin.get("component", ""))

	if not old_comp or not new_comp:
		return

	var old_pin_name: String = old_pin.get("pin", "")
	var new_pin_name: String = new_pin.get("pin", "")

	var old_pos := old_comp.get_pin_world_position(old_pin_name)
	var new_pos := new_comp.get_pin_world_position(new_pin_name)

	var old_screen := world_to_screen(old_pos)
	var new_screen := world_to_screen(new_pos)

	# Draw dimmed old pin with X (red)
	var marker_size := 6.0
	draw_circle(old_screen, marker_size, pin_remap_old_color)
	# Draw X over old pin
	var x_size := 4.0
	draw_line(old_screen - Vector2(x_size, x_size), old_screen + Vector2(x_size, x_size), Color.RED, 2.0)
	draw_line(old_screen - Vector2(x_size, -x_size), old_screen + Vector2(x_size, -x_size), Color.RED, 2.0)

	# Draw highlighted new pin (green)
	draw_circle(new_screen, marker_size, pin_remap_new_color)
	# Draw checkmark-like indicator
	draw_circle(new_screen, marker_size - 2, Color(0.2, 0.8, 0.2, 1.0))

	# Draw arrow from old to new
	_draw_arrow(old_screen, new_screen, Color(0.8, 0.8, 0.3, 0.8), 2.0)

	# Draw net name label at midpoint
	var midpoint := (old_screen + new_screen) / 2.0
	var net_name := suggestion.get_net_name()
	if not net_name.is_empty():
		draw_string(font, midpoint + Vector2(5, -5), net_name, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)


## Draw ghost for route suggestion
func _draw_route_ghost(suggestion: PCBSuggestionScript) -> void:
	var waypoints := suggestion.get_route_waypoints()
	if waypoints.size() < 2:
		return

	var net_name := suggestion.get_net_name()
	var width := suggestion.get_route_width()

	# Get net color if available, otherwise use default
	var color := route_ghost_color
	var net = data.get_net(net_name)
	if net:
		color = net.color
		color.a = 0.6

	# Convert waypoints to screen coordinates
	var screen_points: PackedVector2Array = []
	for wp in waypoints:
		screen_points.append(world_to_screen(wp))

	# Draw dashed polyline for the route
	var trace_width := maxf(width * zoom, 2.0)
	for i in range(screen_points.size() - 1):
		_draw_dashed_line(screen_points[i], screen_points[i + 1], color, trace_width, 8.0)

	# Draw waypoint markers
	var endpoint_radius := 5.0
	var midpoint_radius := 3.0

	for i in range(screen_points.size()):
		var is_endpoint := (i == 0 or i == screen_points.size() - 1)
		var radius := endpoint_radius if is_endpoint else midpoint_radius
		draw_circle(screen_points[i], radius, color.lightened(0.2))
		draw_arc(screen_points[i], radius, 0, TAU, 16, color.darkened(0.2), 1.5)

	# Draw net name label near first waypoint
	if not net_name.is_empty() and screen_points.size() > 0:
		draw_string(font, screen_points[0] + Vector2(8, -8), net_name, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, color.lightened(0.3))


## Draw all annotations
func _draw_annotations() -> void:
	for ann_id in data.annotations:
		var annotation: PCBAnnotationScript = data.annotations[ann_id]
		_draw_annotation(annotation)


## Draw a single annotation
func _draw_annotation(annotation: PCBAnnotationScript) -> void:
	var is_selected := annotation.id == selected_annotation_id

	match annotation.type:
		PCBAnnotationScript.AnnotationType.ARROW:
			_draw_arrow_annotation(annotation)
		PCBAnnotationScript.AnnotationType.TEXT:
			_draw_text_annotation(annotation)
		PCBAnnotationScript.AnnotationType.REGION:
			_draw_region_annotation(annotation)
		PCBAnnotationScript.AnnotationType.POLYLINE:
			_draw_polyline_annotation(annotation)

	# Draw selection highlight if selected
	if is_selected:
		_draw_annotation_selection(annotation)


## Draw an arrow annotation
func _draw_arrow_annotation(annotation: PCBAnnotationScript) -> void:
	if annotation.positions.size() < 2:
		return

	var start := world_to_screen(annotation.positions[0])
	var end := world_to_screen(annotation.positions[1])

	_draw_arrow(start, end, annotation.color, 2.5)

	# Draw label at midpoint if provided
	if not annotation.text.is_empty():
		var midpoint := (start + end) / 2.0
		var offset := Vector2(8, -8)
		draw_string(font, midpoint + offset, annotation.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, annotation.color)


## Draw a text annotation
func _draw_text_annotation(annotation: PCBAnnotationScript) -> void:
	if annotation.positions.is_empty() or annotation.text.is_empty():
		return

	var screen_pos := world_to_screen(annotation.positions[0])

	# Draw background rectangle for readability
	var text_size := font.get_string_size(annotation.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var padding := Vector2(6, 4)
	var bg_rect := Rect2(screen_pos - padding, text_size + padding * 2)

	var bg_color := annotation.color
	bg_color.a = 0.3
	draw_rect(bg_rect, bg_color)
	draw_rect(bg_rect, annotation.color, false, 1.5)

	# Draw text
	draw_string(font, screen_pos + Vector2(0, text_size.y - 2), annotation.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, annotation.color)


## Draw a region highlight annotation
func _draw_region_annotation(annotation: PCBAnnotationScript) -> void:
	if annotation.positions.size() < 2:
		return

	var corner1 := world_to_screen(annotation.positions[0])
	var corner2 := world_to_screen(annotation.positions[1])

	var rect := Rect2(
		corner1.min(corner2),
		(corner1 - corner2).abs()
	)

	# Draw semi-transparent fill
	var fill_color := annotation.color
	fill_color.a = 0.15
	draw_rect(rect, fill_color)

	# Draw border (dashed)
	var border_color := annotation.color
	border_color.a = 0.8
	_draw_dashed_rect(rect, border_color, 2.0, 6.0)

	# Draw label if provided
	if not annotation.text.is_empty():
		var label_pos := rect.position + Vector2(4, font_size + 2)
		draw_string(font, label_pos, annotation.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, annotation.color)


## Draw a polyline annotation
func _draw_polyline_annotation(annotation: PCBAnnotationScript) -> void:
	if annotation.positions.size() < 2:
		return

	var screen_points: PackedVector2Array = []
	for pos in annotation.positions:
		screen_points.append(world_to_screen(pos))

	# Draw polyline
	draw_polyline(screen_points, annotation.color, 2.5)

	# Draw small circles at each point
	for point in screen_points:
		draw_circle(point, 3.0, annotation.color)

	# Draw label near first point if provided
	if not annotation.text.is_empty() and screen_points.size() > 0:
		draw_string(font, screen_points[0] + Vector2(6, -6), annotation.text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, annotation.color)


## Draw selection highlight for an annotation
func _draw_annotation_selection(annotation: PCBAnnotationScript) -> void:
	var bounding := annotation.get_bounding_rect()
	var screen_min := world_to_screen(bounding.position)
	var screen_max := world_to_screen(bounding.position + bounding.size)

	# Expand the bounding rect for visibility
	var padding := 6.0
	var rect := Rect2(
		screen_min - Vector2(padding, padding),
		screen_max - screen_min + Vector2(padding * 2, padding * 2)
	)

	# Draw selection border (dashed)
	var select_color := Color.WHITE
	select_color.a = 0.8
	_draw_dashed_rect(rect, select_color, 1.5, 4.0)

	# Draw corner handles
	var handle_size := 5.0
	var corners := [
		rect.position,
		rect.position + Vector2(rect.size.x, 0),
		rect.position + rect.size,
		rect.position + Vector2(0, rect.size.y)
	]

	for corner in corners:
		var handle_rect := Rect2(corner - Vector2(handle_size, handle_size), Vector2(handle_size * 2, handle_size * 2))
		draw_rect(handle_rect, Color.WHITE)
		draw_rect(handle_rect, Color.BLACK, false, 1.0)

	# Draw rotation indicator (small arc at top)
	var top_center := rect.position + Vector2(rect.size.x / 2, -15)
	draw_arc(top_center, 8.0, deg_to_rad(-135), deg_to_rad(-45), 8, Color.WHITE, 2.0)
	# Draw arrow tip
	var arrow_tip := top_center + Vector2(6, 0).rotated(deg_to_rad(-45))
	draw_line(arrow_tip, arrow_tip + Vector2(-4, -2), Color.WHITE, 2.0)
	draw_line(arrow_tip, arrow_tip + Vector2(-2, 4), Color.WHITE, 2.0)

	# For arrows, show invert hint
	if annotation.type == PCBAnnotationScript.AnnotationType.ARROW:
		var center := (screen_min + screen_max) / 2.0
		draw_string(font, center + Vector2(0, rect.size.y / 2 + 15), "I=invert", HORIZONTAL_ALIGNMENT_CENTER, -1, font_size - 2, Color(0.8, 0.8, 0.8))


## Draw a dashed rectangle
func _draw_dashed_rect(rect: Rect2, color: Color, width: float, dash_length: float) -> void:
	var corners := [
		rect.position,
		rect.position + Vector2(rect.size.x, 0),
		rect.position + rect.size,
		rect.position + Vector2(0, rect.size.y)
	]

	for i in range(4):
		_draw_dashed_line(corners[i], corners[(i + 1) % 4], color, width, dash_length)


## Draw annotation preview while user is drawing
func _draw_annotation_preview() -> void:
	var preview_color := annotation_human_color
	preview_color.a = 0.7

	# Draw mode indicator cursor crosshair
	if annotation_mode != AnnotationMode.NONE and not is_drawing_annotation:
		var cursor_pos := get_local_mouse_position()
		var crosshair_size := 10.0
		draw_line(cursor_pos - Vector2(crosshair_size, 0), cursor_pos + Vector2(crosshair_size, 0), preview_color, 1.5)
		draw_line(cursor_pos - Vector2(0, crosshair_size), cursor_pos + Vector2(0, crosshair_size), preview_color, 1.5)

		# Draw mode label
		var mode_name: String = AnnotationMode.keys()[annotation_mode]
		draw_string(font, cursor_pos + Vector2(12, -5), mode_name, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, preview_color)

	if not is_drawing_annotation:
		return

	var screen_points: PackedVector2Array = []
	for p in annotation_points:
		screen_points.append(world_to_screen(p))

	var preview_screen := world_to_screen(annotation_preview_point)

	match annotation_mode:
		AnnotationMode.ARROW:
			if screen_points.size() >= 1:
				_draw_arrow(screen_points[0], preview_screen, preview_color, 2.0)

		AnnotationMode.TEXT:
			# Draw a text placeholder cursor
			draw_circle(preview_screen, 5.0, preview_color)
			draw_string(font, preview_screen + Vector2(8, 4), "Click to place text", HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, preview_color)

		AnnotationMode.REGION:
			if screen_points.size() >= 1:
				var rect := Rect2(
					screen_points[0].min(preview_screen),
					(screen_points[0] - preview_screen).abs()
				)
				var fill := preview_color
				fill.a = 0.15
				draw_rect(rect, fill)
				_draw_dashed_rect(rect, preview_color, 2.0, 6.0)

		AnnotationMode.POLYLINE:
			# Draw existing points and lines
			if screen_points.size() >= 1:
				for i in range(screen_points.size() - 1):
					draw_line(screen_points[i], screen_points[i + 1], preview_color, 2.0)

				# Draw line to current mouse position
				draw_line(screen_points[screen_points.size() - 1], preview_screen, preview_color, 2.0)

				# Draw point markers
				for p in screen_points:
					draw_circle(p, 4.0, preview_color)

			# Draw current preview point
			draw_circle(preview_screen, 4.0, preview_color.lightened(0.3))


## Draw arrow showing suggested move
func _draw_suggestion_arrow() -> void:
	if active_suggestion_id.is_empty():
		return

	var suggestion := data.get_suggestion(active_suggestion_id)
	if not suggestion or suggestion.type != PCBSuggestionScript.SuggestionType.MOVE:
		return

	var comp := data.get_component(suggestion.target_component)
	if not comp:
		return

	var from_pos := world_to_screen(comp.position)
	var to_pos := world_to_screen(suggestion.get_proposed_position())

	_draw_arrow(from_pos, to_pos, move_arrow_color, 2.0)


## Draw an arrow from start to end
func _draw_arrow(start: Vector2, end: Vector2, color: Color, width: float) -> void:
	draw_line(start, end, color, width)

	# Draw arrowhead
	var direction := (end - start).normalized()
	var arrow_size := 10.0
	var arrow_angle := 0.5  # radians

	var left := end - direction.rotated(arrow_angle) * arrow_size
	var right := end - direction.rotated(-arrow_angle) * arrow_size

	draw_line(end, left, color, width)
	draw_line(end, right, color, width)


## Draw selection box
func _draw_selection_box() -> void:
	var rect := Rect2(
		box_select_start.min(box_select_end),
		(box_select_end - box_select_start).abs()
	)
	draw_rect(rect, selection_box_color)
	draw_rect(rect, selection_border_color, false, 1.0)


## Draw a dashed line (renamed to avoid conflict with parent)
func _draw_dashed_line(from: Vector2, to: Vector2, color: Color, width: float, dash_length: float) -> void:
	var direction := (to - from).normalized()
	var distance := from.distance_to(to)
	var current := 0.0
	var drawing := true

	while current < distance:
		var segment_end := minf(current + dash_length, distance)
		if drawing:
			draw_line(
				from + direction * current,
				from + direction * segment_end,
				color,
				width
			)
		drawing = not drawing
		current = segment_end


#region Coordinate Transformation

## Convert world position (mm) to screen position (pixels)
func world_to_screen(world_pos: Vector2) -> Vector2:
	return (world_pos * zoom) + pan_offset + size / 2

## Convert screen position (pixels) to world position (mm)
func screen_to_world(screen_pos: Vector2) -> Vector2:
	return (screen_pos - pan_offset - size / 2) / zoom

#endregion


#region Input Handling

func _gui_input(event: InputEvent) -> void:
	if not data:
		return

	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event)
	elif event is InputEventKey:
		_handle_key_input(event)


func _handle_mouse_button(event: InputEventMouseButton) -> void:
	var world_pos := screen_to_world(event.position)

	if event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			grab_focus()

			# Handle annotation mode first
			if annotation_mode != AnnotationMode.NONE:
				_handle_annotation_click(world_pos, event.double_click)
				queue_redraw()
				return

			var hit_component := data.get_component_at(world_pos)

			if event.double_click and not hit_component.is_empty():
				component_double_clicked.emit(hit_component)
			elif not hit_component.is_empty():
				# Start dragging or select
				if event.shift_pressed:
					# Add to selection
					if hit_component not in selected_components:
						selected_components.append(hit_component)
						component_selected.emit(hit_component)
				elif hit_component not in selected_components:
					# New selection
					_clear_selection()
					selected_components.append(hit_component)
					component_selected.emit(hit_component)

				# Start drag
				is_dragging_component = true
				drag_component_id = hit_component
				drag_start_mouse = event.position
				var comp := data.get_component(hit_component)
				if comp:
					drag_start_component_pos = comp.position
			else:
				# Start box selection or clear selection
				if not event.shift_pressed:
					_clear_selection()
				is_box_selecting = true
				box_select_start = event.position
				box_select_end = event.position

			selection_changed.emit()
			queue_redraw()
		else:
			# Mouse released - end annotation dragging if active
			if is_dragging_annotation:
				is_dragging_annotation = false
				queue_redraw()
				return

			# End drag or box select
			if is_dragging_component:
				is_dragging_component = false
				if drag_component_id:
					var comp := data.get_component(drag_component_id)
					if comp and comp.position != drag_start_component_pos:
						data.save_to_history("Move " + drag_component_id)
						component_moved.emit(drag_component_id, comp.position)
				drag_component_id = ""

			if is_box_selecting:
				is_box_selecting = false
				_finalize_box_selection()

			queue_redraw()

	elif event.button_index == MOUSE_BUTTON_RIGHT:
		if event.pressed:
			# Start panning
			is_panning = true
			pan_start_mouse = event.position
			pan_start_offset = pan_offset
			right_click_start_pos = event.position
			context_menu_world_pos = world_pos
		else:
			is_panning = false
			# Check if this was a tap (no significant movement) - show context menu
			if event.position.distance_to(right_click_start_pos) < RIGHT_CLICK_THRESHOLD:
				_show_context_menu(event.position)

	elif event.button_index == MOUSE_BUTTON_MIDDLE:
		if event.pressed:
			# Start panning
			is_panning = true
			pan_start_mouse = event.position
			pan_start_offset = pan_offset
		else:
			is_panning = false

	elif event.button_index == MOUSE_BUTTON_WHEEL_UP:
		_zoom_at(event.position, 1.2)

	elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_zoom_at(event.position, 0.8)


func _handle_mouse_motion(event: InputEventMouseMotion) -> void:
	var world_pos := screen_to_world(event.position)

	# Update annotation preview point
	if annotation_mode != AnnotationMode.NONE:
		annotation_preview_point = world_pos
		queue_redraw()

	# Handle annotation dragging in SELECT mode
	if is_dragging_annotation and not selected_annotation_id.is_empty():
		var annotation := data.get_annotation(selected_annotation_id)
		if annotation:
			var offset := world_pos - annotation_drag_start
			annotation.translate(offset)
			annotation_drag_start = world_pos
			data.data_changed.emit()
		queue_redraw()
		return

	# Update hover
	var new_hover := data.get_component_at(world_pos)
	if new_hover != hovered_component:
		hovered_component = new_hover
		queue_redraw()

	# Handle panning
	if is_panning:
		pan_offset = pan_start_offset + (event.position - pan_start_mouse)
		queue_redraw()

	# Handle component dragging
	if is_dragging_component and drag_component_id:
		var comp := data.get_component(drag_component_id)
		if comp:
			var new_pos := screen_to_world(event.position) - screen_to_world(drag_start_mouse) + drag_start_component_pos
			if snap_to_grid:
				new_pos = data.snap_to_grid(new_pos)
			comp.position = new_pos
			queue_redraw()

	# Handle box selection
	if is_box_selecting:
		box_select_end = event.position
		queue_redraw()


func _handle_key_input(event: InputEventKey) -> void:
	if not event.pressed:
		return

	match event.keycode:
		KEY_DELETE, KEY_BACKSPACE:
			# Delete selected annotation first, otherwise delete selected components
			if not selected_annotation_id.is_empty():
				_delete_selected_annotation()
			else:
				_delete_selected()
		KEY_ESCAPE:
			# Cancel annotation first, then clear annotation selection, then component selection
			if is_drawing_annotation:
				cancel_annotation()
			elif annotation_mode != AnnotationMode.NONE:
				clear_annotation_mode()
				selected_annotation_id = ""
			else:
				_clear_selection()
				active_suggestion_id = ""
			queue_redraw()
		KEY_R:
			# Rotate selected annotation, or rotate selected components, or enter region mode
			if not selected_annotation_id.is_empty():
				_rotate_selected_annotation()
			elif annotation_mode == AnnotationMode.NONE:
				_rotate_selected()
			else:
				set_annotation_mode(AnnotationMode.REGION)
		KEY_I:
			# Invert arrow direction
			if not selected_annotation_id.is_empty():
				_invert_selected_arrow()
		KEY_G:
			show_grid = not show_grid
			queue_redraw()
		KEY_N:
			show_ratsnest = not show_ratsnest
			queue_redraw()
		KEY_L:
			show_labels = not show_labels
			queue_redraw()
		KEY_HOME:
			_center_view()
		KEY_PLUS, KEY_KP_ADD:
			# Scale up selected annotation, or zoom in
			if not selected_annotation_id.is_empty():
				_scale_selected_annotation(1.2)
			else:
				_zoom_at(size / 2, 1.2)
		KEY_MINUS, KEY_KP_SUBTRACT:
			# Scale down selected annotation, or zoom out
			if not selected_annotation_id.is_empty():
				_scale_selected_annotation(0.8)
			else:
				_zoom_at(size / 2, 0.8)
		# Annotation mode shortcuts
		KEY_S:
			# Select mode for annotations
			if annotation_mode == AnnotationMode.SELECT:
				clear_annotation_mode()
			else:
				set_annotation_mode(AnnotationMode.SELECT)
		KEY_A:
			if annotation_mode == AnnotationMode.ARROW:
				clear_annotation_mode()
			else:
				set_annotation_mode(AnnotationMode.ARROW)
		KEY_T:
			if annotation_mode == AnnotationMode.TEXT:
				clear_annotation_mode()
			else:
				set_annotation_mode(AnnotationMode.TEXT)
		KEY_P:
			if annotation_mode == AnnotationMode.POLYLINE:
				clear_annotation_mode()
			else:
				set_annotation_mode(AnnotationMode.POLYLINE)


func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var world_before := screen_to_world(screen_pos)
	zoom = clampf(zoom * factor, min_zoom, max_zoom)
	var world_after := screen_to_world(screen_pos)

	# Adjust pan to keep the point under cursor stable
	pan_offset += (world_after - world_before) * zoom

	zoom_changed.emit(zoom)
	queue_redraw()


func _center_view() -> void:
	if not data:
		return

	pan_offset = Vector2.ZERO
	queue_redraw()


func _clear_selection() -> void:
	for comp_id in selected_components:
		component_deselected.emit(comp_id)
	selected_components.clear()
	selection_changed.emit()


func _finalize_box_selection() -> void:
	var world_start := screen_to_world(box_select_start.min(box_select_end))
	var world_end := screen_to_world(box_select_start.max(box_select_end))
	var select_rect := Rect2(world_start, world_end - world_start)

	var hits := data.get_components_in_region(select_rect)
	for comp_id in hits:
		if comp_id not in selected_components:
			selected_components.append(comp_id)
			component_selected.emit(comp_id)

	selection_changed.emit()


func _delete_selected() -> void:
	if selected_components.is_empty():
		return

	data.save_to_history("Delete components")
	for comp_id in selected_components:
		data.remove_component(comp_id)

	selected_components.clear()
	selection_changed.emit()
	queue_redraw()


func _rotate_selected() -> void:
	if selected_components.is_empty():
		return

	data.save_to_history("Rotate components")
	for comp_id in selected_components:
		var comp := data.get_component(comp_id)
		if comp:
			comp.rotate_clockwise()
			data.component_changed.emit(comp_id)

	queue_redraw()


## Delete selected annotation
func _delete_selected_annotation() -> void:
	if selected_annotation_id.is_empty():
		return

	data.remove_annotation(selected_annotation_id)
	selected_annotation_id = ""
	queue_redraw()


## Rotate selected annotation by 45 degrees
func _rotate_selected_annotation() -> void:
	if selected_annotation_id.is_empty():
		return

	var annotation := data.get_annotation(selected_annotation_id)
	if annotation:
		annotation.rotate_around_center(deg_to_rad(45.0))
		data.data_changed.emit()
		queue_redraw()


## Scale selected annotation
func _scale_selected_annotation(factor: float) -> void:
	if selected_annotation_id.is_empty():
		return

	var annotation := data.get_annotation(selected_annotation_id)
	if annotation:
		annotation.scale_from_center(factor)
		data.data_changed.emit()
		queue_redraw()


## Invert selected arrow direction (swap head/tail)
func _invert_selected_arrow() -> void:
	if selected_annotation_id.is_empty():
		return

	var annotation := data.get_annotation(selected_annotation_id)
	if annotation and annotation.type == PCBAnnotationScript.AnnotationType.ARROW:
		annotation.invert_direction()
		data.data_changed.emit()
		queue_redraw()


## Handle annotation click based on current mode
func _handle_annotation_click(world_pos: Vector2, is_double_click: bool) -> void:
	match annotation_mode:
		AnnotationMode.SELECT:
			_handle_select_click(world_pos)
		AnnotationMode.ARROW:
			_handle_arrow_click(world_pos)
		AnnotationMode.TEXT:
			_handle_text_click(world_pos)
		AnnotationMode.REGION:
			_handle_region_click(world_pos)
		AnnotationMode.POLYLINE:
			_handle_polyline_click(world_pos, is_double_click)


## Handle select mode click - select annotation for transforms
func _handle_select_click(world_pos: Vector2) -> void:
	# Try to find an annotation at click position
	var hit_ann_id := data.get_annotation_at(world_pos, 3.0 / zoom)  # Threshold in world units

	if not hit_ann_id.is_empty():
		# Select the annotation and start dragging
		selected_annotation_id = hit_ann_id
		is_dragging_annotation = true
		annotation_drag_start = world_pos
		var annotation := data.get_annotation(hit_ann_id)
		if annotation:
			annotation_drag_offset = annotation.get_center() - world_pos
	else:
		# Clicked on empty space - deselect
		selected_annotation_id = ""
		is_dragging_annotation = false


## Handle arrow annotation click
func _handle_arrow_click(world_pos: Vector2) -> void:
	if not is_drawing_annotation:
		# First click - start arrow
		is_drawing_annotation = true
		annotation_points.clear()
		annotation_points.append(world_pos)
	else:
		# Second click - finish arrow
		_create_arrow_annotation(annotation_points[0], world_pos)
		_finish_annotation_drawing()


## Handle text annotation click
func _handle_text_click(world_pos: Vector2) -> void:
	# Single click places text - emit signal for text input
	annotation_text_requested.emit(world_pos)
	# Don't finish mode yet - wait for text input


## Handle region annotation click
func _handle_region_click(world_pos: Vector2) -> void:
	if not is_drawing_annotation:
		# First click - start region
		is_drawing_annotation = true
		annotation_points.clear()
		annotation_points.append(world_pos)
	else:
		# Second click - finish region
		_create_region_annotation(annotation_points[0], world_pos)
		_finish_annotation_drawing()


## Handle polyline annotation click
func _handle_polyline_click(world_pos: Vector2, is_double_click: bool) -> void:
	if not is_drawing_annotation:
		# First click - start polyline
		is_drawing_annotation = true
		annotation_points.clear()
		annotation_points.append(world_pos)
	elif is_double_click:
		# Double click - finish polyline
		if annotation_points.size() >= 2:
			_create_polyline_annotation(annotation_points)
		_finish_annotation_drawing()
	else:
		# Single click - add point
		annotation_points.append(world_pos)


## Create arrow annotation
func _create_arrow_annotation(start: Vector2, end: Vector2) -> void:
	var annotation := PCBAnnotationScript.create_arrow(start, end, "", "human")
	data.add_annotation(annotation)
	annotation_created.emit(annotation.id)


## Create text annotation (called externally after text input)
func create_text_annotation(position: Vector2, text_content: String) -> void:
	if text_content.is_empty():
		return
	var annotation := PCBAnnotationScript.create_text(position, text_content, "human")
	data.add_annotation(annotation)
	annotation_created.emit(annotation.id)
	queue_redraw()


## Create region annotation
func _create_region_annotation(corner1: Vector2, corner2: Vector2) -> void:
	var annotation := PCBAnnotationScript.create_region(corner1, corner2, "", "human")
	data.add_annotation(annotation)
	annotation_created.emit(annotation.id)


## Create polyline annotation
func _create_polyline_annotation(points: Array[Vector2]) -> void:
	var annotation := PCBAnnotationScript.create_polyline(points, "", "human")
	data.add_annotation(annotation)
	annotation_created.emit(annotation.id)


## Finish annotation drawing (reset state but keep mode)
func _finish_annotation_drawing() -> void:
	is_drawing_annotation = false
	annotation_points.clear()
	queue_redraw()


## Cancel current annotation drawing
func cancel_annotation() -> void:
	is_drawing_annotation = false
	annotation_points.clear()
	queue_redraw()


## Set annotation mode
func set_annotation_mode(mode: AnnotationMode) -> void:
	if annotation_mode != mode:
		cancel_annotation()
		annotation_mode = mode
		annotation_mode_changed.emit(mode)
		queue_redraw()


## Clear annotation mode (return to normal)
func clear_annotation_mode() -> void:
	set_annotation_mode(AnnotationMode.NONE)

#endregion


#region Public API

## Set the PCB data
func set_data(new_data: PCBDataScript) -> void:
	if data:
		if data.data_changed.is_connected(_on_data_changed):
			data.data_changed.disconnect(_on_data_changed)
		if data.structure_changed.is_connected(_on_structure_changed):
			data.structure_changed.disconnect(_on_structure_changed)

	data = new_data

	if data:
		data.data_changed.connect(_on_data_changed)
		data.structure_changed.connect(_on_structure_changed)
		spatial_index.set_data(data)

	_center_view()
	queue_redraw()


## Get current selection
func get_selected_components() -> Array[String]:
	return selected_components.duplicate()


## Select a component
func select_component(component_id: String, add_to_selection: bool = false) -> void:
	if not add_to_selection:
		_clear_selection()

	if component_id not in selected_components and data.has_component(component_id):
		selected_components.append(component_id)
		component_selected.emit(component_id)
		selection_changed.emit()
		queue_redraw()


## Set active suggestion for preview
func set_active_suggestion(suggestion_id: String) -> void:
	active_suggestion_id = suggestion_id
	queue_redraw()


## Accept the active suggestion
func accept_active_suggestion() -> void:
	if active_suggestion_id:
		data.accept_suggestion(active_suggestion_id)
		suggestion_accepted.emit(active_suggestion_id)
		active_suggestion_id = ""
		queue_redraw()


## Reject the active suggestion
func reject_active_suggestion() -> void:
	if active_suggestion_id:
		data.reject_suggestion(active_suggestion_id)
		suggestion_rejected.emit(active_suggestion_id)
		active_suggestion_id = ""
		queue_redraw()


## Zoom to fit all components
func zoom_to_fit() -> void:
	if not data or data.components.is_empty():
		_center_view()
		return

	# Find bounds of all components
	var min_pos := Vector2(INF, INF)
	var max_pos := Vector2(-INF, -INF)

	for comp_id in data.components:
		var comp: PCBComponentScript = data.components[comp_id]
		var bounds := comp.get_bounding_rect()
		min_pos.x = minf(min_pos.x, bounds.position.x)
		min_pos.y = minf(min_pos.y, bounds.position.y)
		max_pos.x = maxf(max_pos.x, bounds.end.x)
		max_pos.y = maxf(max_pos.y, bounds.end.y)

	# Add margin
	var margin := 10.0  # mm
	min_pos -= Vector2(margin, margin)
	max_pos += Vector2(margin, margin)

	var content_size := max_pos - min_pos
	var content_center := (min_pos + max_pos) / 2.0

	# Calculate zoom to fit
	var zoom_x := size.x / content_size.x
	var zoom_y := size.y / content_size.y
	zoom = minf(zoom_x, zoom_y)
	zoom = clampf(zoom, min_zoom, max_zoom)

	# Center on content
	pan_offset = -content_center * zoom

	zoom_changed.emit(zoom)
	queue_redraw()


func _on_data_changed() -> void:
	queue_redraw()


func _on_structure_changed() -> void:
	queue_redraw()

#endregion

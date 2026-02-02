class_name PCBCanvas
extends Control
## Renders the PCB board with components, traces, and suggestions.

const PCBDataScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBData.gd")
const PCBComponentScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBComponent.gd")
const PCBSpatialIndexScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBSpatialIndex.gd")
const PCBSuggestionScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBSuggestion.gd")

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

## Font
var font: Font
var font_size: int = 12


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	clip_contents = true

	font = ThemeDB.fallback_font
	font_size = ThemeDB.fallback_font_size

	# Initialize spatial index
	spatial_index = PCBSpatialIndexScript.new()


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

	# Draw ratsnest (unrouted connections)
	if show_ratsnest:
		_draw_ratsnest()

	# Draw components
	_draw_components()

	# Draw suggestion ghosts
	_draw_suggestion_ghosts()

	# Draw selection box
	if is_box_selecting:
		_draw_selection_box()

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

		# Get pin positions
		var pin_positions: Array[Vector2] = []
		for pin in net.pins:
			var comp_id: String = pin.get("component_id", "")
			var pin_name: String = pin.get("pin_name", "")
			var comp := data.get_component(comp_id)
			if comp:
				pin_positions.append(comp.get_pin_world_position(pin_name))

		# Draw connections (simple star pattern from first pin)
		if pin_positions.size() >= 2:
			var net_color = net.color
			net_color.a = 0.4

			for i in range(1, pin_positions.size()):
				var p1 := world_to_screen(pin_positions[0])
				var p2 := world_to_screen(pin_positions[i])
				_draw_dashed_line(p1, p2, net_color, 1.0, 4.0)


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

		var pin_idx := 0
		for pin_name in comp.pins:
			var local_pin_pos: Vector2 = comp.pins[pin_name]
			var world_pin_pos: Vector2 = comp.position + (xform * local_pin_pos)
			var pin_screen := world_to_screen(world_pin_pos)

			# Pin 1 gets square pad, others get round
			if pin_idx == 0:
				# Square pad for pin 1
				var pad_size := Vector2(pad_diameter, pad_diameter) * zoom
				_draw_rect_pad(pin_screen, pad_size, -comp.rotation, pad_copper_color)
			else:
				# Round copper pad
				draw_circle(pin_screen, maxf(pad_radius, 2.0), pad_copper_color)

			# Draw drill hole on top
			draw_circle(pin_screen, maxf(drill_radius, 1.0), drill_hole_color)
			draw_arc(pin_screen, maxf(drill_radius, 1.0), 0, TAU, 16, Color(0.4, 0.4, 0.4, 0.6), 1.0)

			pin_idx += 1

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
		else:
			is_panning = false

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
			_delete_selected()
		KEY_ESCAPE:
			_clear_selection()
			active_suggestion_id = ""
			queue_redraw()
		KEY_R:
			_rotate_selected()
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
			_zoom_at(size / 2, 1.2)
		KEY_MINUS, KEY_KP_SUBTRACT:
			_zoom_at(size / 2, 0.8)


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

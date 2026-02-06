class_name PCBComponent
extends RefCounted
## Represents a component on the PCB board (resistor, IC, switch, etc.)

const _Self := preload("res://Scripts/UI/Controls/PCBEditor/PCBComponent.gd")

## Footprint types for visual rendering
enum FootprintType {
	RESISTOR,
	CAPACITOR,
	IC_DIP,
	IC_QFP,
	IC_BGA,
	SWITCH,
	CONNECTOR,
	LED,
	DIODE,
	TRANSISTOR,
	CRYSTAL,
	HEADER,
	MOUNTING_HOLE,
	MODULE,  # Large modules like ESP32 dev boards
	CUSTOM
}

## Unique identifier (e.g., "SW1", "U3", "R12")
var id: String = ""

## Component footprint type
var footprint: FootprintType = FootprintType.CUSTOM

## Origin/anchor position in mm (typically pin 1, following KiCAD convention)
var position: Vector2 = Vector2.ZERO

## Rotation in degrees (0, 90, 180, 270)
var rotation: float = 0.0

## Bounding box dimensions in mm
var width: float = 5.0
var height: float = 2.5

## The bounding box relative to the footprint origin/pin 1 (0,0)
## e.g. Rect2(-1.27, -1.27, 10, 5) means body starts 1.27mm before origin, extends right/down
var local_bounds: Rect2 = Rect2(-1.27, -1.27, 5.0, 2.5)

## Pin definitions: pin_name -> relative Vector2 offset from anchor (origin)
var pins: Dictionary = {}

## Additional properties (value, package, manufacturer, etc.)
var properties: Dictionary = {}

## Layer: "top" or "bottom"
var layer: String = "top"

## Whether this component is locked (skipped during hit-testing)
var locked: bool = false

## Visual properties
var color: Color = Color(0.2, 0.6, 0.3, 1.0)
var label_visible: bool = true

## KiCAD footprint ID (e.g., "Button_Switch_SMD:SW_SPST_PTS645Sx43SMTR92")
var footprint_id: String = ""

## Detailed pad geometry from KiCAD footprint library
## Each pad is a Dictionary with keys:
##   number: String - Pad number/name
##   type: String - "smd", "thru_hole", or "np_thru_hole"
##   shape: String - "rect", "circle", "oval", "roundrect", "custom"
##   position: Vector2 - Position relative to component center (mm)
##   size: Vector2 - Pad size (width, height in mm)
##   drill: float - Drill diameter for through-holes (0 for SMD)
##   layers: Array[String] - Copper/mask layers
var pads: Array = []

## Whether pad geometry has been loaded from footprint library
var has_pad_geometry: bool = false

## Bounding box center offset from footprint origin (for origin-based positioning)
## When has_pad_geometry is true, position = origin, visual center = position + bbox_center_offset
var bbox_center_offset: Vector2 = Vector2.ZERO


## Get the world-space position of a pin using rigid body transform
func get_pin_world_position(pin_name: String) -> Vector2:
	var local_pos: Vector2 = pins.get(pin_name, Vector2.ZERO)
	var xform := get_transform()
	return position + (xform * local_pos)


## Get the symbolic name for a pin number (from geometry import)
## Returns empty string if no name is defined
func get_pin_name(pin_number: String) -> String:
	for pad in pads:
		if str(pad.get("number", "")) == pin_number:
			var name = pad.get("name", "")
			if name != null and not str(name).is_empty():
				return str(name)
			break
	return ""


## Get the Transform2D for this component (rotation around anchor/origin)
func get_transform() -> Transform2D:
	# KiCAD uses CCW positive, Godot uses CW positive
	# Negate rotation for correct visual alignment
	return Transform2D(deg_to_rad(-rotation), Vector2.ZERO)


## Get local body polygon for drawing (4 corners relative to anchor)
func get_local_body_polygon() -> PackedVector2Array:
	return PackedVector2Array([
		local_bounds.position,  # Top-Left
		Vector2(local_bounds.end.x, local_bounds.position.y),  # Top-Right
		local_bounds.end,  # Bottom-Right
		Vector2(local_bounds.position.x, local_bounds.end.y)  # Bottom-Left
	])


## Load pad geometry from pcb-architect footprint-geometry output
## geometry: Dictionary with keys: pads, bounding_box, footprint_id, footprint_found
func load_pad_geometry(geometry: Dictionary) -> void:
	footprint_id = geometry.get("footprint_id", "")
	has_pad_geometry = geometry.get("footprint_found", false)

	# Update bounding box from footprint data
	var bbox: Dictionary = geometry.get("bounding_box", {})
	if bbox.size() > 0:
		width = bbox.get("width", width)
		height = bbox.get("height", height)
		# Get the center offset (how far body center is from origin)
		var center_x: float = bbox.get("center_x", 0.0)
		var center_y: float = bbox.get("center_y", 0.0)
		bbox_center_offset = Vector2(center_x, center_y)

		# Calculate local_bounds: Rect2 relative to anchor (0,0)
		# If center is at (cx, cy), then top-left is at (cx - w/2, cy - h/2)
		local_bounds = Rect2(
			center_x - width / 2.0,
			center_y - height / 2.0,
			width,
			height
		)

	# Load pads
	pads.clear()
	var pads_data: Array = geometry.get("pads", [])
	for pad_data in pads_data:
		var pos_dict: Dictionary = pad_data.get("position", {})
		var size_dict: Dictionary = pad_data.get("size", {})

		# Robust drill parsing (handles float, dict, or null)
		var drill_raw = pad_data.get("drill")
		var drill_size := Vector2.ZERO
		if drill_raw is Dictionary:
			# Slot drill: {x, y} or {width, height}
			var dx := float(drill_raw.get("x", drill_raw.get("width", 0.0)))
			var dy := float(drill_raw.get("y", drill_raw.get("height", 0.0)))
			drill_size = Vector2(dx, dy)
		elif drill_raw != null and (drill_raw is float or drill_raw is int):
			var d := float(drill_raw)
			drill_size = Vector2(d, d)

		var pad := {
			"number": pad_data.get("number", ""),
			"name": pad_data.get("name", ""),  # Symbolic pin name from YAML
			"type": pad_data.get("type", "smd"),
			"shape": pad_data.get("shape", "rect"),
			"position": Vector2(pos_dict.get("x", 0), pos_dict.get("y", 0)),
			"size": Vector2(size_dict.get("width", 1), size_dict.get("height", 1)),
			"drill": drill_size,  # Now Vector2 for slot support
			"layers": pad_data.get("layers", [])
		}
		pads.append(pad)

	# Also update pins dictionary for net connections (electrical pads only)
	pins.clear()
	for pad in pads:
		var num := str(pad.get("number", ""))
		var ptype := str(pad.get("type", "smd"))
		if num.is_empty():
			continue
		if ptype == "np_thru_hole":
			continue  # Mechanical hole: not an electrical pin
		pins[num] = pad.get("position", Vector2.ZERO)


## Get a pad's world-space position and size, accounting for component rotation
func get_pad_world_transform(pad: Dictionary) -> Dictionary:
	var rot_rad := deg_to_rad(rotation)
	var local_pos: Vector2 = pad.get("position", Vector2.ZERO)
	var local_size: Vector2 = pad.get("size", Vector2(1, 1))

	# Rotate position around component center
	var world_pos := position + local_pos.rotated(rot_rad)

	# For 90/270 rotation, swap width and height
	var world_size := local_size
	if int(rotation) % 180 == 90:
		world_size = Vector2(local_size.y, local_size.x)

	return {
		"position": world_pos,
		"size": world_size,
		"rotation": rotation
	}


## Get all pin world positions
func get_all_pin_positions() -> Dictionary:
	var result: Dictionary = {}
	for pin_name in pins:
		result[pin_name] = get_pin_world_position(pin_name)
	return result


## Get the bounding rectangle in world space
func get_bounding_rect() -> Rect2:
	# Use rigid body transform for consistent rotation
	var xform := get_transform()
	var local_poly := get_local_body_polygon()

	# Transform corners and find axis-aligned bounds
	var min_pos := Vector2(INF, INF)
	var max_pos := Vector2(-INF, -INF)

	for corner in local_poly:
		var world_point: Vector2 = position + (xform * corner)
		min_pos.x = minf(min_pos.x, world_point.x)
		min_pos.y = minf(min_pos.y, world_point.y)
		max_pos.x = maxf(max_pos.x, world_point.x)
		max_pos.y = maxf(max_pos.y, world_point.y)

	return Rect2(min_pos, max_pos - min_pos)


## Check if a point is inside this component's bounding rect
func contains_point(point: Vector2) -> bool:
	return get_bounding_rect().has_point(point)


## Set position (for undo/redo support)
func set_position(new_pos: Vector2) -> void:
	position = new_pos


## Set rotation (constrained to 0, 90, 180, 270)
func set_rotation(degrees: float) -> void:
	# Normalize to 0, 90, 180, 270
	rotation = fmod(degrees, 360.0)
	if rotation < 0:
		rotation += 360.0
	rotation = roundf(rotation / 90.0) * 90.0


## Rotate clockwise by 90 degrees
func rotate_clockwise() -> void:
	set_rotation(rotation + 90.0)


## Rotate counter-clockwise by 90 degrees
func rotate_counterclockwise() -> void:
	set_rotation(rotation - 90.0)


## Initialize standard pin layout for common footprints
## KiCAD convention: Pin 1 at origin (0,0), body extends from there
func setup_standard_pins() -> void:
	pins.clear()

	match footprint:
		FootprintType.RESISTOR, FootprintType.CAPACITOR, FootprintType.DIODE, FootprintType.LED:
			# Two-terminal component, horizontal, pin 1 at origin
			width = 3.0
			height = 1.5
			pins["1"] = Vector2(0, 0)
			pins["2"] = Vector2(2.54, 0)
			local_bounds = Rect2(-0.5, -height / 2.0, width, height)
			bbox_center_offset = Vector2(1.27, 0)

		FootprintType.TRANSISTOR:
			# Three-terminal (TO-92 style), pin 1 at origin
			width = 3.0
			height = 2.0
			pins["B"] = Vector2(0, 0)
			pins["C"] = Vector2(1.27, 0)
			pins["E"] = Vector2(2.54, 0)
			local_bounds = Rect2(-0.5, -height / 2.0, width, height)
			bbox_center_offset = Vector2(1.27, 0)

		FootprintType.IC_DIP:
			# 8-pin DIP as default, pin 1 at origin (top-left)
			var row_spacing := 7.62
			var pins_per_side := 4
			var total_height := (pins_per_side - 1) * 2.54
			width = row_spacing + 2.54
			height = total_height + 2.54
			for i in range(pins_per_side):
				pins[str(i + 1)] = Vector2(0, i * 2.54)
				pins[str(8 - i)] = Vector2(row_spacing, i * 2.54)
			local_bounds = Rect2(-1.27, -1.27, width, height)
			bbox_center_offset = Vector2(row_spacing / 2.0, total_height / 2.0)

		FootprintType.SWITCH:
			# Simple push button, pin 1 at origin (top-left)
			width = 6.0
			height = 6.0
			pins["1"] = Vector2(0, 0)
			pins["2"] = Vector2(5.08, 0)
			pins["3"] = Vector2(0, 5.08)
			pins["4"] = Vector2(5.08, 5.08)
			local_bounds = Rect2(-0.5, -0.5, width, height)
			bbox_center_offset = Vector2(2.54, 2.54)

		FootprintType.CONNECTOR, FootprintType.HEADER:
			# 2-pin header as default, vertical, pin 1 at origin
			width = 2.54
			height = 2.54 + 2.54
			pins["1"] = Vector2(0, 0)
			pins["2"] = Vector2(0, 2.54)
			local_bounds = Rect2(-width / 2.0, -1.27, width, height)
			bbox_center_offset = Vector2(0, 1.27)

		FootprintType.MOUNTING_HOLE:
			# Mounting hole - single pin at origin
			width = 3.2
			height = 3.2
			pins["1"] = Vector2(0, 0)
			local_bounds = Rect2(-width / 2.0, -height / 2.0, width, height)
			bbox_center_offset = Vector2.ZERO

		FootprintType.MODULE:
			# Large module (like ESP32 dev board) - default 2x20 pins
			# Pin 1 at origin (top-left), body extends beyond pin rows
			var row_spacing := 22.86  # ~0.9" for dev boards
			var pins_per_side := 20
			var body_extension := 9.0  # Body extends beyond pins on each end
			var total_pin_height := (pins_per_side - 1) * 2.54
			width = row_spacing + 2.54
			height = total_pin_height + (body_extension * 2)
			for i in range(pins_per_side):
				pins[str(i + 1)] = Vector2(0, i * 2.54)
				pins[str(40 - i)] = Vector2(row_spacing, i * 2.54)
			local_bounds = Rect2(-1.27, -body_extension, width, height)
			bbox_center_offset = Vector2(row_spacing / 2.0, total_pin_height / 2.0)

		FootprintType.CRYSTAL:
			# Crystal oscillator, pin 1 at origin
			width = 5.0
			height = 2.0
			pins["1"] = Vector2(0, 0)
			pins["2"] = Vector2(4.0, 0)
			local_bounds = Rect2(-0.5, -height / 2.0, width, height)
			bbox_center_offset = Vector2(2.0, 0)

		_:
			# Default fallback
			width = 5.0
			height = 2.5
			pins["1"] = Vector2(0, 0)
			local_bounds = Rect2(-1.0, -height / 2.0, width, height)
			bbox_center_offset = Vector2(width / 2.0 - 1.0, 0)


## Setup a single-row header/connector with custom pin count
## KiCAD convention: Vertical orientation, pin 1 at origin (0,0), pins going down (+Y)
func setup_header_pins(pin_count: int, pin_names: Array = []) -> void:
	pins.clear()
	var spacing := 2.54  # Standard 0.1" spacing
	var total_length := (pin_count - 1) * spacing
	# Vertical orientation: width is narrow, height is long
	width = 2.54
	height = total_length + 2.54

	for i in range(pin_count):
		var pin_name: String
		if i < pin_names.size():
			pin_name = str(pin_names[i])
		else:
			pin_name = str(i + 1)
		# Pin 1 at origin (0, 0), subsequent pins going down (+Y)
		pins[pin_name] = Vector2(0, i * spacing)

	# local_bounds relative to pin 1 origin: body centered on X, extends down from pin 1
	local_bounds = Rect2(-width / 2.0, -1.27, width, height)
	# Calculate center offset from origin for compatibility
	bbox_center_offset = Vector2(0, total_length / 2.0)


## Setup a dual-row DIP with custom pin count (must be even)
## KiCAD convention: Pin 1 at origin (0,0) top-left, left side going down, right side going up
func setup_dip_pins(pin_count: int, row_spacing: float = 7.62) -> void:
	pins.clear()
	var pins_per_side := pin_count / 2
	var spacing := 2.54
	var total_pin_height := (pins_per_side - 1) * spacing
	width = row_spacing + 2.54
	height = total_pin_height + 2.54

	for i in range(pins_per_side):
		# Left side: 1, 2, 3... going down from origin
		# Pin 1 at (0, 0), Pin 2 at (0, 2.54), etc.
		pins[str(i + 1)] = Vector2(0, i * spacing)
		# Right side: N, N-1, N-2... going up from bottom-right
		# Pin N at (row_spacing, 0), Pin N-1 at (row_spacing, 2.54), etc.
		pins[str(pin_count - i)] = Vector2(row_spacing, i * spacing)

	# local_bounds relative to pin 1 origin: extends right and down from origin
	local_bounds = Rect2(-1.27, -1.27, width, height)
	# Calculate center offset from origin
	bbox_center_offset = Vector2(row_spacing / 2.0, total_pin_height / 2.0)


## Setup a large module (ESP32 dev boards, etc.) with custom pin count
## KiCAD convention: Pin 1 at origin (0,0), body extends beyond pin rows
## row_spacing: distance between pin rows (default ~22.86mm for dev boards)
## body_extension: how much the body extends beyond pin rows on each end
func setup_module_pins(pin_count: int, row_spacing: float = 22.86, body_extension: float = 9.0) -> void:
	pins.clear()
	var pins_per_side := pin_count / 2
	var spacing := 2.54
	var total_pin_height := (pins_per_side - 1) * spacing

	# Body dimensions - wider than DIP, extends beyond pins
	width = row_spacing + 2.54
	# Height: pin area + extension on both ends
	height = total_pin_height + (body_extension * 2)

	for i in range(pins_per_side):
		# Left side: 1, 2, 3... going down from origin
		pins[str(i + 1)] = Vector2(0, i * spacing)
		# Right side: N, N-1, N-2... going up from bottom-right
		pins[str(pin_count - i)] = Vector2(row_spacing, i * spacing)

	# local_bounds: body extends beyond pins
	# Top edge at -body_extension (above pin 1), bottom at total_pin_height + body_extension
	local_bounds = Rect2(-1.27, -body_extension, width, height)
	# Center offset from pin 1 origin
	bbox_center_offset = Vector2(row_spacing / 2.0, total_pin_height / 2.0)


## Setup custom size without changing pins
## Maintains origin-based positioning (body extends from near origin)
func set_size(new_width: float, new_height: float) -> void:
	width = new_width
	height = new_height
	# Update local_bounds - body starts slightly before origin, extends right/down
	# Use small margin (-1.27mm) to allow pin 1 to be inside the body
	local_bounds = Rect2(-1.27, -1.27, width, height)
	# Update center offset
	bbox_center_offset = Vector2(width / 2.0 - 1.27, height / 2.0 - 1.27)


## Create a deep copy of this component
func duplicate_component():
	var copy = _Self.new()
	copy.id = id
	copy.footprint = footprint
	copy.position = position
	copy.rotation = rotation
	copy.width = width
	copy.height = height
	copy.pins = pins.duplicate(true)
	copy.properties = properties.duplicate(true)
	copy.layer = layer
	copy.color = color
	copy.label_visible = label_visible
	copy.footprint_id = footprint_id
	copy.pads = pads.duplicate(true)
	copy.has_pad_geometry = has_pad_geometry
	copy.bbox_center_offset = bbox_center_offset
	copy.local_bounds = local_bounds
	copy.locked = locked
	return copy


## Serialize to dictionary
func to_dict() -> Dictionary:
	var pins_dict := {}
	for pin_name in pins:
		var pin_pos: Vector2 = pins[pin_name]
		pins_dict[pin_name] = {"x": pin_pos.x, "y": pin_pos.y}

	# Serialize pads
	var pads_list := []
	for pad in pads:
		var pad_pos: Vector2 = pad.get("position", Vector2.ZERO)
		var pad_size: Vector2 = pad.get("size", Vector2(1, 1))
		var drill_val = pad.get("drill", Vector2.ZERO)
		var drill_dict: Dictionary
		if drill_val is Vector2:
			drill_dict = {"x": drill_val.x, "y": drill_val.y}
		else:
			# Legacy: float drill value
			var d := float(drill_val) if drill_val != null else 0.0
			drill_dict = {"x": d, "y": d}
		pads_list.append({
			"number": pad.get("number", ""),
			"type": pad.get("type", "smd"),
			"shape": pad.get("shape", "rect"),
			"position": {"x": pad_pos.x, "y": pad_pos.y},
			"size": {"width": pad_size.x, "height": pad_size.y},
			"drill": drill_dict,
			"layers": pad.get("layers", [])
		})

	return {
		"id": id,
		"footprint": FootprintType.keys()[footprint],
		"footprint_id": footprint_id,
		"position": {"x": position.x, "y": position.y},
		"rotation": rotation,
		"width": width,
		"height": height,
		"local_bounds": {"x": local_bounds.position.x, "y": local_bounds.position.y, "w": local_bounds.size.x, "h": local_bounds.size.y},
		"pins": pins_dict,
		"pads": pads_list,
		"has_pad_geometry": has_pad_geometry,
		"bbox_center_offset": {"x": bbox_center_offset.x, "y": bbox_center_offset.y},
		"properties": properties.duplicate(),
		"layer": layer,
		"color": {"r": color.r, "g": color.g, "b": color.b, "a": color.a},
		"label_visible": label_visible,
		"locked": locked
	}


## Deserialize from dictionary
func load_from_dict(data: Dictionary) -> void:
	id = data.get("id", "")

	var footprint_str: String = data.get("footprint", "CUSTOM")
	var footprint_idx := FootprintType.keys().find(footprint_str)
	footprint = footprint_idx if footprint_idx >= 0 else FootprintType.CUSTOM

	footprint_id = data.get("footprint_id", "")

	var pos_data: Dictionary = data.get("position", {})
	position = Vector2(pos_data.get("x", 0), pos_data.get("y", 0))

	rotation = data.get("rotation", 0.0)
	width = data.get("width", 5.0)
	height = data.get("height", 2.5)

	# Load local_bounds or compute from width/height
	var bounds_data: Dictionary = data.get("local_bounds", {})
	if bounds_data.size() > 0:
		local_bounds = Rect2(
			bounds_data.get("x", -width / 2.0),
			bounds_data.get("y", -height / 2.0),
			bounds_data.get("w", width),
			bounds_data.get("h", height)
		)
	else:
		# Default: centered at anchor
		local_bounds = Rect2(-width / 2.0, -height / 2.0, width, height)

	pins.clear()
	var pins_data: Dictionary = data.get("pins", {})
	for pin_name in pins_data:
		var pin_pos_data: Dictionary = pins_data[pin_name]
		pins[pin_name] = Vector2(pin_pos_data.get("x", 0), pin_pos_data.get("y", 0))

	# Load pad geometry
	pads.clear()
	has_pad_geometry = data.get("has_pad_geometry", false)
	var bbox_offset_data: Dictionary = data.get("bbox_center_offset", {})
	bbox_center_offset = Vector2(bbox_offset_data.get("x", 0), bbox_offset_data.get("y", 0))
	var pads_data: Array = data.get("pads", [])
	for pad_data in pads_data:
		var pad_pos: Dictionary = pad_data.get("position", {})
		var pad_size: Dictionary = pad_data.get("size", {})
		# Handle both legacy float drill and new Vector2 dict drill
		var drill_raw = pad_data.get("drill", 0.0)
		var drill_vec := Vector2.ZERO
		if drill_raw is Dictionary:
			drill_vec = Vector2(drill_raw.get("x", 0), drill_raw.get("y", 0))
		elif drill_raw is float or drill_raw is int:
			var d := float(drill_raw)
			drill_vec = Vector2(d, d)
		pads.append({
			"number": pad_data.get("number", ""),
			"type": pad_data.get("type", "smd"),
			"shape": pad_data.get("shape", "rect"),
			"position": Vector2(pad_pos.get("x", 0), pad_pos.get("y", 0)),
			"size": Vector2(pad_size.get("width", 1), pad_size.get("height", 1)),
			"drill": drill_vec,
			"layers": pad_data.get("layers", [])
		})

	properties = data.get("properties", {}).duplicate()
	layer = data.get("layer", "top")

	var color_data: Dictionary = data.get("color", {})
	if color_data.size() > 0:
		color = Color(
			color_data.get("r", 0.2),
			color_data.get("g", 0.6),
			color_data.get("b", 0.3),
			color_data.get("a", 1.0)
		)

	label_visible = data.get("label_visible", true)
	locked = data.get("locked", false)


## Create from dictionary (static constructor)
static func from_dict(data: Dictionary):
	var component := _Self.new()
	component.load_from_dict(data)
	return component


## Get a human-readable description
func get_description() -> String:
	var value_str := ""
	if properties.has("value"):
		value_str = " (%s)" % properties["value"]
	return "%s%s - %s on %s layer" % [id, value_str, FootprintType.keys()[footprint], layer]

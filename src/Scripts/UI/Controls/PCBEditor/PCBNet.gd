class_name PCBNet
extends RefCounted
## Represents an electrical net connecting component pins on the PCB.

const _Self := preload("res://Scripts/UI/Controls/PCBEditor/PCBNet.gd")

## Net name (e.g., "VCC", "GND", "SDA", "NET_001")
var name: String = ""

## Connected pins: Array of {component_id: String, pin_name: String}
var pins: Array[Dictionary] = []

## Visual color for this net
var color: Color = Color.WHITE

## Net properties (voltage, current rating, etc.)
var properties: Dictionary = {}

## Whether this is a power net (VCC, GND, etc.)
var is_power_net: bool = false


## Add a pin connection to this net
func add_pin(component_id: String, pin_name: String) -> void:
	# Check if already connected
	for pin in pins:
		if pin.get("component_id") == component_id and pin.get("pin_name") == pin_name:
			return  # Already exists

	pins.append({
		"component_id": component_id,
		"pin_name": pin_name
	})


## Remove a pin connection from this net
func remove_pin(component_id: String, pin_name: String) -> void:
	for i in range(pins.size() - 1, -1, -1):
		if pins[i].get("component_id") == component_id and pins[i].get("pin_name") == pin_name:
			pins.remove_at(i)
			return


## Remove all pins for a component (when component is deleted)
func remove_component_pins(component_id: String) -> void:
	for i in range(pins.size() - 1, -1, -1):
		if pins[i].get("component_id") == component_id:
			pins.remove_at(i)


## Check if a pin is in this net
func has_pin(component_id: String, pin_name: String) -> bool:
	for pin in pins:
		if pin.get("component_id") == component_id and pin.get("pin_name") == pin_name:
			return true
	return false


## Get all unique component IDs connected by this net
func get_connected_components() -> Array[String]:
	var components: Array[String] = []
	for pin in pins:
		var comp_id: String = pin.get("component_id", "")
		if comp_id and comp_id not in components:
			components.append(comp_id)
	return components


## Get all pins for a specific component in this net
func get_pins_for_component(component_id: String) -> Array[String]:
	var result: Array[String] = []
	for pin in pins:
		if pin.get("component_id") == component_id:
			result.append(pin.get("pin_name", ""))
	return result


## Get the number of connections
func get_connection_count() -> int:
	return pins.size()


## Check if this net has any connections
func is_empty() -> bool:
	return pins.is_empty()


## Check if this net needs routing (has 2+ pins)
func needs_routing() -> bool:
	return pins.size() >= 2


## Create a deep copy of this net
func duplicate_net():
	var copy := _Self.new()
	copy.name = name
	copy.color = color
	copy.properties = properties.duplicate(true)
	copy.is_power_net = is_power_net

	for pin in pins:
		copy.pins.append(pin.duplicate())

	return copy


## Serialize to dictionary
func to_dict() -> Dictionary:
	var pins_arr: Array = []
	for pin in pins:
		pins_arr.append({
			"component_id": pin.get("component_id", ""),
			"pin_name": pin.get("pin_name", "")
		})

	return {
		"name": name,
		"pins": pins_arr,
		"color": {"r": color.r, "g": color.g, "b": color.b, "a": color.a},
		"properties": properties.duplicate(),
		"is_power_net": is_power_net
	}


## Deserialize from dictionary
func load_from_dict(data: Dictionary) -> void:
	name = data.get("name", "")

	pins.clear()
	var pins_data: Array = data.get("pins", [])
	for pin_data in pins_data:
		if pin_data is Dictionary:
			pins.append({
				"component_id": pin_data.get("component_id", ""),
				"pin_name": pin_data.get("pin_name", "")
			})

	var color_data: Dictionary = data.get("color", {})
	if color_data.size() > 0:
		color = Color(
			color_data.get("r", 1.0),
			color_data.get("g", 1.0),
			color_data.get("b", 1.0),
			color_data.get("a", 1.0)
		)

	properties = data.get("properties", {}).duplicate()
	is_power_net = data.get("is_power_net", false)


## Create from dictionary (static constructor)
static func from_dict(data: Dictionary):
	var net := _Self.new()
	net.load_from_dict(data)
	return net


## Get a human-readable description
func get_description() -> String:
	var comp_count := get_connected_components().size()
	var power_str := " [POWER]" if is_power_net else ""
	return "%s%s: %d pins across %d components" % [name, power_str, pins.size(), comp_count]


## Generate a unique color based on net name (for auto-coloring)
static func generate_color_for_name(net_name: String) -> Color:
	# Special colors for common power nets
	match net_name.to_upper():
		"VCC", "VDD", "V+", "5V", "3V3", "3.3V", "12V":
			return Color.RED
		"GND", "VSS", "V-", "0V":
			return Color.BLACK
		"SDA", "I2C_SDA":
			return Color.CYAN
		"SCL", "I2C_SCL":
			return Color.BLUE
		"TX", "TXD":
			return Color.GREEN
		"RX", "RXD":
			return Color.YELLOW

	# Generate color from hash for other nets
	var hash_val := net_name.hash()
	var hue := fmod(absf(float(hash_val)), 360.0) / 360.0
	return Color.from_hsv(hue, 0.7, 0.9)

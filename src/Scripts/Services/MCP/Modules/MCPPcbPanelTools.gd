class_name MCPPcbPanelTools
extends MCPToolModule
## MCP tool module for the PCB PLUGIN panel's panel-coupled tools.
## Docket: minerva 019eb47e72a7 · DCR 019dc140.
##
## This is the re-homed surface for the panel-local half of the legacy in-tree
## MCPPCBTools (~31 tools). The legacy module stays until cutover; both surfaces
## coexist (see NAME-COLLISION GUARD below). The tools here drive the pcb plugin
## panel's board model live — add/move/rotate/delete components, connect nets,
## resize the board, CSV + footprint/trace geometry round-trips, spatial queries,
## the change journal, and a snapshot image — all resolved off the registered
## PcbAnnotationHost.
##
## Architecture (copies the CAD precedent, MCPCadTools):
##   * Off-tree discipline. PcbAnnotationHost and the pcb model scripts
##     (pcb_data/pcb_component/pcb_spatial_index) are PLUGIN classes living
##     outside res://. This core module MUST NOT reference them by class_name /
##     preload. Every host/model/component call goes through duck typing
##     (has_method / call / property access on the returned Variant). The host is
##     typed as AnnotationHost (the platform base class the registry stores).
##   * Single gateway. AnnotationHostRegistry.get_host(editor_name) yields the
##     PcbAnnotationHost; host.get_board_data() vends the live pcb_data model and
##     host.get_spatial_index() vends the pcb_spatial_index. All mutations run
##     against the model API so its change journal, undo history and data_changed
##     dirty relay come for free.
##
## RETIRED legacy tools (NOT here — see pcb/docs/tools.md for the disposition):
##   annotations/route-hints → core minerva_annotations_*; interpret_route_hints
##   → agent-router; create_note → generic plugin_data note flow;
##   minerva_create_pcb_editor → minerva_create_plugin_editor; export_yaml →
##   worker pcb.serialize / the panel's Export YAML action.
## WORKER tools (already live, not here): pcb_validate / pcb_generate /
##   pcb_check_libraries / pcb_check_bom.
##
## NAME-COLLISION GUARD. The legacy in-tree MCPPCBTools registers these SAME
## minerva_pcb_* names (for the in-tree PCBEditor) and sits earlier in
## MinervaMCPServer._modules, so it wins dispatch (first can_handle wins) AND its
## schema would be clobbered by a later duplicate registration (tool_registry is
## a name-keyed Dict, last-writer-wins). MinervaMCPServer offers no per-argument
## routing at can_handle time. So this module registers a name ONLY when it is
## absent from the registry — i.e. only after the legacy module is removed at
## cutover. Until then legacy owns the runtime minerva_pcb_* surface for the
## in-tree editor; this module's handlers are still fully exercised by the test
## suite (which calls handle() directly), and flip on automatically at cutover.
## The names are byte-identical so the agent-facing surface never changes.


const _PANEL_LOCAL_TOOLS: Array[String] = [
	"minerva_pcb_set_board_size",
	"minerva_pcb_get_components",
	"minerva_pcb_get_nets",
	"minerva_pcb_get_pin_position",
	"minerva_pcb_pin_info",
	"minerva_pcb_add_component",
	"minerva_pcb_move_component",
	"minerva_pcb_move_relative",
	"minerva_pcb_rotate_component",
	"minerva_pcb_delete_component",
	"minerva_pcb_connect_net",
	"minerva_pcb_spatial_query",
	"minerva_pcb_describe_component",
	"minerva_pcb_get_change_journal",
	"minerva_pcb_import_csv",
	"minerva_pcb_export_csv",
	"minerva_pcb_import_footprint_geometry",
	"minerva_pcb_import_trace_geometry",
	"minerva_pcb_export_trace_geometry",
	"minerva_pcb_get_image",
	"minerva_pcb_apply_route_hints",
]

## Footprint names accepted by add_component (mirrors the legacy schema enum; the
## plugin component enum carries extra values but is set by NAME, off-tree safe).
const _VALID_FOOTPRINTS: Array[String] = [
	"RESISTOR", "CAPACITOR", "IC_DIP", "IC_QFP", "SWITCH", "CONNECTOR",
	"LED", "DIODE", "TRANSISTOR", "HEADER", "MOUNTING_HOLE", "MODULE",
]


func get_tool_names() -> Array[String]:
	return _PANEL_LOCAL_TOOLS.duplicate()


func register_tools() -> void:
	_reg("minerva_pcb_set_board_size",
		"Set the PCB board dimensions.",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
				"width": {"type": "number", "description": "Board width in mm"},
				"height": {"type": "number", "description": "Board height in mm"},
			},
			"required": ["editor_name", "width", "height"],
		})

	_reg("minerva_pcb_get_components",
		"Get all components from a PCB editor with their positions and connections.",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
			},
			"required": ["editor_name"],
		})

	_reg("minerva_pcb_get_nets",
		"Get all electrical nets (connections) from a PCB.",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
			},
			"required": ["editor_name"],
		})

	_reg("minerva_pcb_get_pin_position",
		"Get the world position and info for a specific pin on a component. Useful for calculating waypoints or verifying pin locations before creating route hints.",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
				"component_id": {"type": "string", "description": "Component ID (e.g., 'U3', 'R1')"},
				"pin": {"type": "string", "description": "Pin name or number (e.g., '1', 'VCC', 'SDA')"},
			},
			"required": ["editor_name", "component_id", "pin"],
		})

	_reg("minerva_pcb_pin_info",
		"Pin inspector parity tool (WC-1): returns the SAME info the panel's Pin Info section shows for a pin — footprint geometry pin name, net, net members, and touching traces — plus display_name computed by the exact display rule the UI uses (geometry pin_name > net > \"(unconnected)\"). Identify the pin either by ref (\"U1.15\") or by a board point (x_mm/y_mm, hit-tests the nearest pad).",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
				"ref": {"type": "string", "description": "Component.Pin reference, e.g. 'U1.15'. Mutually exclusive with x_mm/y_mm."},
				"x_mm": {"type": "number", "description": "Board X in mm — hit-tests the nearest pad. Requires y_mm. Mutually exclusive with ref."},
				"y_mm": {"type": "number", "description": "Board Y in mm. Requires x_mm."},
			},
			"required": ["editor_name"],
		})

	_reg("minerva_pcb_add_component",
		"Add a new component to the PCB. NOTE: Component dimensions are estimated defaults based on footprint type. For accurate sizing from KiCAD libraries, run pcb-architect's footprint-geometry command and then call minerva_pcb_import_footprint_geometry to update components with real dimensions.",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
				"id": {"type": "string", "description": "Component ID (e.g., 'R15', 'U3'). Auto-generated if not specified."},
				"footprint": {
					"type": "string",
					"description": "Footprint type: RESISTOR, CAPACITOR, IC_DIP, IC_QFP, SWITCH, CONNECTOR, LED, DIODE, TRANSISTOR, HEADER, MOUNTING_HOLE, MODULE",
					"enum": _VALID_FOOTPRINTS,
				},
				"x": {"type": "number", "description": "X position in mm"},
				"y": {"type": "number", "description": "Y position in mm"},
				"rotation": {"type": "number", "description": "Rotation in degrees (0, 90, 180, 270). Default: 0"},
				"value": {"type": "string", "description": "Component value (e.g., '10K', '100nF')"},
				"pin_count": {"type": "integer", "description": "Number of pins. Works for all footprint types. HEADER/CONNECTOR = single row, IC_DIP/MODULE = dual row (even), others use generic layout via pad_type/pad_spacing/row_spacing."},
				"pad_type": {"type": "string", "enum": ["smd", "tht"], "description": "Pad type for placeholder geometry (default: tht). Used when pin_count is set on non-specialised footprint types."},
				"pad_spacing": {"type": "number", "description": "Centre-to-centre pad spacing in mm (default: 2.54). Used with generic pin layout."},
				"row_spacing": {"type": "number", "description": "Row-to-row spacing for dual-row layouts in mm (default: 7.62). Used with generic pin layout."},
				"width": {"type": "number", "description": "Custom width in mm (overrides default)"},
				"height": {"type": "number", "description": "Custom height in mm (overrides default)"},
				"pin_names": {"type": "array", "items": {"type": "string"}, "description": "Custom pin names (e.g., ['GND', 'VCC', 'SDA', 'SCL'] for a 4-pin header)"},
				"snap_to_grid": {"type": "boolean", "description": "Whether to snap position to grid (default: true). Set to false for exact positioning."},
			},
			"required": ["editor_name", "footprint", "x", "y"],
		})

	_reg("minerva_pcb_move_component",
		"Move a component to an absolute position. Requires editor_name from minerva_list_editors and component names from minerva_pcb_get_components.",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
				"component_id": {"type": "string", "description": "Component ID to move"},
				"x": {"type": "number", "description": "New X position in mm"},
				"y": {"type": "number", "description": "New Y position in mm"},
			},
			"required": ["editor_name", "component_id", "x", "y"],
		})

	_reg("minerva_pcb_move_relative",
		"Move a component using natural language direction (e.g., 'down a bit', 'closer to U3').",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
				"component_id": {"type": "string", "description": "Component ID to move"},
				"direction": {"type": "string", "description": "Natural language direction: 'up', 'down', 'left', 'right', 'closer to X', 'away from X', 'toward center', etc."},
			},
			"required": ["editor_name", "component_id", "direction"],
		})

	_reg("minerva_pcb_rotate_component",
		"Rotate a component. Positive degrees rotate counter-clockwise (CCW), negative rotate clockwise (CW). Requires editor_name from minerva_list_editors.",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
				"component_id": {"type": "string", "description": "Component ID to rotate"},
				"degrees": {"type": "number", "description": "Rotation angle. Positive = counter-clockwise (CCW), negative = clockwise (CW). Common values: 90 (CCW), -90 (CW), 180."},
			},
			"required": ["editor_name", "component_id", "degrees"],
		})

	_reg("minerva_pcb_delete_component",
		"Delete a component from the PCB. Requires editor_name from minerva_list_editors.",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
				"component_id": {"type": "string", "description": "Component ID to delete"},
			},
			"required": ["editor_name", "component_id"],
		})

	_reg("minerva_pcb_connect_net",
		"Connect component pins to a net (creates net if it doesn't exist). Get pin names from minerva_pcb_describe_component first. Requires editor_name from minerva_list_editors.",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
				"net_name": {"type": "string", "description": "Net name (e.g., 'VCC', 'GND', 'SDA')"},
				"pins": {
					"type": "array",
					"description": "Array of pin connections: [{\"component\": \"U1\", \"pin\": \"8\"}, ...]",
					"items": {
						"type": "object",
						"properties": {"component": {"type": "string"}, "pin": {"type": "string"}},
					},
				},
			},
			"required": ["editor_name", "net_name", "pins"],
		})

	_reg("minerva_pcb_spatial_query",
		"Query components based on spatial relationships (e.g., 'what components are near U3?').",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
				"query": {"type": "string", "description": "Natural language spatial query"},
				"reference_component": {"type": "string", "description": "Component ID to query relative to"},
				"radius_mm": {"type": "number", "description": "Search radius in mm. Default: 20"},
			},
			"required": ["editor_name"],
		})

	_reg("minerva_pcb_describe_component",
		"Get detailed spatial context for a component including nearby components, connections, and region.",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
				"component_id": {"type": "string", "description": "Component ID (e.g., 'SW1', 'U3')"},
			},
			"required": ["editor_name", "component_id"],
		})

	_reg("minerva_pcb_get_change_journal",
		"Get the change journal for a PCB editor. Returns an append-only log of forward actions (moves, rotations, deletions, etc.) with timestamps.",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
				"since_timestamp": {"type": "number", "description": "Optional Unix timestamp to filter entries from. Only entries at or after this time are returned."},
				"limit": {"type": "integer", "description": "Maximum number of entries to return (most recent). Default: 50"},
			},
			"required": ["editor_name"],
		})

	_reg("minerva_pcb_import_csv",
		"Import component placement from CSV.",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
				"csv_content": {"type": "string", "description": "CSV content with columns: id,footprint,x,y,rotation,layer,value"},
			},
			"required": ["editor_name", "csv_content"],
		})

	_reg("minerva_pcb_export_csv",
		"Export PCB component placement as CSV.",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
			},
			"required": ["editor_name"],
		})

	_reg("minerva_pcb_import_footprint_geometry",
		"IMPORTANT: Call this after adding components to get accurate dimensions from KiCAD footprint libraries. Without this, components use estimated sizes that may not match actual footprints. Run 'pcb-architect footprint-geometry board.yaml -o geometry.json' to generate the input data. Updates component pads with accurate shapes, sizes, drill holes, and body dimensions. Can also correct positions if YAML used different coordinate conventions (use position_is_center and/or invert_y flags).",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
				"geometry": {
					"type": "object",
					"description": "Footprint geometry JSON from pcb-architect footprint-geometry command. Contains board_name and components with pad arrays.",
				},
				"position_is_center": {"type": "boolean", "description": "If true, current component positions are geometric centers (not footprint origins). Will adjust positions by subtracting bounding_box center offset. Default: false"},
				"invert_y": {"type": "boolean", "description": "If true, Y coordinates are inverted (Y=0 at bottom instead of top). Will flip Y relative to board height. Default: false"},
			},
			"required": ["editor_name", "geometry"],
		})

	_reg("minerva_pcb_import_trace_geometry",
		"Import routed traces and vias from pcb-architect's trace-geometry command output. Clears existing traces and imports new ones. Trace segments are automatically connected into polylines.",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
				"trace_data": {
					"type": "object",
					"description": "Trace geometry JSON from pcb-architect trace-geometry command",
				},
			},
			"required": ["editor_name", "trace_data"],
		})

	_reg("minerva_pcb_export_trace_geometry",
		"Export routed traces and vias from a PCB editor. Returns trace data in the same format accepted by import_trace_geometry, enabling round-trip workflows.",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
			},
			"required": ["editor_name"],
		})

	_reg("minerva_pcb_get_image",
		"Export a PCB view as a base64-encoded PNG image for LLM viewing.",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
				"width": {"type": "integer", "description": "Requested image width in pixels (advisory). Default: 800"},
				"height": {"type": "integer", "description": "Requested image height in pixels (advisory). Default: 600"},
			},
			"required": ["editor_name"],
		})

	_reg("minerva_pcb_apply_route_hints",
		"Route the board's open route hints and either PROPOSE routes (default) or COMMIT them as real traces. Default (commit absent/false): runs the router over the selected open route hints and writes the results back as AI-authored (cyan) proposal annotations — inspectable polylines that do NOT mutate the board; each proposal links to the source hint(s) it answers (kind_payload.proposal_for). Set commit=true to materialize the routed polylines as real traces in the board model (journaled) and transition the source hints open→applied. Partial/failed routing returns WHERE it got stuck (unrouted nets with their blocked pad pairs) as structured feedback. Iterate: edit/add hints and re-run; applied hints are excluded by default so only fresh open hints re-route.",
		{
			"type": "object",
			"properties": {
				"editor_name": {"type": "string", "description": "Name of the PCB editor tab"},
				"hint_ids": {"type": "array", "items": {"type": "string"}, "description": "Optional explicit route-hint annotation ids to route. Omit to route all OPEN route hints (applied/resolved hints are excluded)."},
				"commit": {"type": "boolean", "description": "false/absent (default): write back cyan proposal annotations only, board unchanged. true: materialize routed traces + mark source hints applied."},
			},
			"required": ["editor_name"],
		})


## Guarded registration — see the NAME-COLLISION GUARD note in the class doc. A
## name already in the registry belongs to the legacy in-tree MCPPCBTools; we
## leave it be and register only the absent names (post-cutover).
func _reg(tool_name: String, description: String, input_schema: Dictionary) -> void:
	if server == null or server.mcp_manager == null:
		return
	if server.mcp_manager.tool_registry.has(tool_name):
		return
	server._register_tool(tool_name, description, input_schema, "pcb")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_pcb_set_board_size":
			return _set_board_size(arguments)
		"minerva_pcb_get_components":
			return _get_components(arguments)
		"minerva_pcb_get_nets":
			return _get_nets(arguments)
		"minerva_pcb_get_pin_position":
			return _get_pin_position(arguments)
		"minerva_pcb_pin_info":
			return _pin_info(arguments)
		"minerva_pcb_add_component":
			return _add_component(arguments)
		"minerva_pcb_move_component":
			return _move_component(arguments)
		"minerva_pcb_move_relative":
			return _move_relative(arguments)
		"minerva_pcb_rotate_component":
			return _rotate_component(arguments)
		"minerva_pcb_delete_component":
			return _delete_component(arguments)
		"minerva_pcb_connect_net":
			return _connect_net(arguments)
		"minerva_pcb_spatial_query":
			return _spatial_query(arguments)
		"minerva_pcb_describe_component":
			return _describe_component(arguments)
		"minerva_pcb_get_change_journal":
			return _get_change_journal(arguments)
		"minerva_pcb_import_csv":
			return _import_csv(arguments)
		"minerva_pcb_export_csv":
			return _export_csv(arguments)
		"minerva_pcb_import_footprint_geometry":
			return _import_footprint_geometry(arguments)
		"minerva_pcb_import_trace_geometry":
			return _import_trace_geometry(arguments)
		"minerva_pcb_export_trace_geometry":
			return _export_trace_geometry(arguments)
		"minerva_pcb_get_image":
			return _get_image(arguments)
		"minerva_pcb_apply_route_hints":
			return await _apply_route_hints(arguments)
	return _err("Unknown PCB panel tool: %s" % tool_name)


# ── Tool implementations ──────────────────────────────────────────────────────

func _set_board_size(args: Dictionary) -> Dictionary:
	var data = _resolve_data(args)
	if not (data is Object):
		return data
	var width: float = float(args.get("width", 100.0))
	var height: float = float(args.get("height", 100.0))
	data.set_board_size(width, height)
	return _ok({"board_width": width, "board_height": height})


func _get_components(args: Dictionary) -> Dictionary:
	var data = _resolve_data(args)
	if not (data is Object):
		return data
	var components: Array = []
	for comp_id in data.components:
		var comp = data.components[comp_id]
		var comp_info := {
			"id": comp.id,
			"footprint": comp.get_footprint_name(),
			"x": comp.position.x,
			"y": comp.position.y,
			"rotation": comp.rotation,
			"layer": comp.layer,
			"pins": comp.pins.keys(),
		}
		if comp.properties.has("value"):
			comp_info["value"] = comp.properties["value"]
		components.append(comp_info)
	return _ok({"component_count": components.size(), "components": components})


func _get_nets(args: Dictionary) -> Dictionary:
	var data = _resolve_data(args)
	if not (data is Object):
		return data
	var nets_arr: Array = []
	for net_name in data.nets:
		var net = data.nets[net_name]
		var pins_arr: Array = []
		for pin in net.pins:
			pins_arr.append("%s.%s" % [pin.get("component_id", ""), pin.get("pin_name", "")])
		nets_arr.append({"name": net.name, "pins": pins_arr, "is_power": net.is_power_net})
	return _ok({"net_count": nets_arr.size(), "nets": nets_arr})


func _get_pin_position(args: Dictionary) -> Dictionary:
	var data = _resolve_data(args)
	if not (data is Object):
		return data
	var component_id: String = str(args.get("component_id", ""))
	var pin: String = str(args.get("pin", ""))
	if component_id.is_empty():
		return _err("component_id is required")
	if pin.is_empty():
		return _err("pin is required")

	var comp = data.get_component(component_id)
	if not comp:
		return _err("Component not found: %s" % component_id)

	var available_pins: Array = []
	for pin_name in comp.pins:
		var pin_sym_name: String = comp.get_pin_name(str(pin_name))
		var entry := {"pin": str(pin_name)}
		if not pin_sym_name.is_empty():
			entry["name"] = pin_sym_name
		available_pins.append(entry)

	if not comp.pins.has(pin):
		return {
			"error": "Pin '%s' not found on component '%s'" % [pin, component_id],
			"success": false,
			"available_pins": available_pins,
		}

	var world_pos: Vector2 = comp.get_pin_world_position(pin)
	return {
		"success": true,
		"world_position": {"x": float(world_pos.x), "y": float(world_pos.y)},
		"component_position": {"x": float(comp.position.x), "y": float(comp.position.y)},
		"component_rotation": float(comp.rotation),
		"pin": str(pin),
		"pin_name": comp.get_pin_name(pin),
		"available_pins": available_pins,
	}


## WC-1 pin inspector MCP parity (contract §2/§3): resolves the SAME
## host.pad_at()/host.pin_info() the canvas's INSPECT_PIN mode drives, then adds
## display_name via host.pin_display_name() so this tool's answer is byte-for-byte
## what the panel's Pin Info section shows for the same pin. Duck-typed
## has_method guards (never a class reference — PcbAnnotationHost is off-tree);
## a garbage/malformed ref or an x_mm/y_mm miss returns a structured _err, never
## a crash.
func _pin_info(args: Dictionary) -> Dictionary:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)
	if not host.has_method("pad_at") or not host.has_method("pin_info"):
		return _err("PCB pin inspector not available on this host")

	var component := ""
	var pin := ""
	if args.has("ref"):
		var ref: String = str(args.get("ref", ""))
		if ref.is_empty():
			return _err("ref must be a non-empty string")
		var dot := ref.rfind(".")
		if dot <= 0 or dot >= ref.length() - 1:
			return _err("malformed ref '%s' — expected 'Component.Pin'" % ref)
		component = ref.left(dot)
		pin = ref.substr(dot + 1)
	elif args.has("x_mm") and args.has("y_mm"):
		var x_mm: float = float(args.get("x_mm", 0.0))
		var y_mm: float = float(args.get("y_mm", 0.0))
		var hit: Dictionary = host.pad_at(Vector2(x_mm, y_mm))
		if hit.is_empty():
			return _err("no pad found near (%.3f, %.3f) mm" % [x_mm, y_mm])
		component = str(hit.get("component", ""))
		pin = str(hit.get("pin", ""))
	else:
		return _err("either ref (\"Component.Pin\") or x_mm/y_mm is required")

	var info: Dictionary = host.pin_info(component, pin)
	if info.is_empty():
		return _err("unknown pin '%s.%s'" % [component, pin])

	var result: Dictionary = info.duplicate(true)
	result["display_name"] = host.pin_display_name(info) if host.has_method("pin_display_name") else ""
	return _ok(result)


func _add_component(args: Dictionary) -> Dictionary:
	var data = _resolve_data(args)
	if not (data is Object):
		return data
	var footprint_str: String = str(args.get("footprint", ""))
	if footprint_str.is_empty():
		return _err("footprint is required")
	if not _VALID_FOOTPRINTS.has(footprint_str.to_upper()):
		return _err("Invalid footprint type: %s" % footprint_str)

	var x: float = float(args.get("x", 50.0))
	var y: float = float(args.get("y", 50.0))

	var component_id: String = str(args.get("id", ""))
	if component_id.is_empty():
		var prefix: String = footprint_str[0] if footprint_str.length() > 0 else "U"
		component_id = data.generate_component_id(prefix)

	var comp = data.new_component()
	comp.id = component_id
	comp.set_footprint_by_name(footprint_str.to_upper())

	var snap: bool = bool(args.get("snap_to_grid", true))
	if snap:
		comp.position = data.snap_to_grid(Vector2(x, y))
	else:
		comp.position = Vector2(x, y)
	comp.rotation = float(args.get("rotation", 0.0))

	var pin_count: int = int(args.get("pin_count", 0))
	var pin_names: Array = args.get("pin_names", [])
	if pin_count > 0:
		var pad_type: String = str(args.get("pad_type", "tht"))
		var pad_spacing: float = float(args.get("pad_spacing", 2.54))
		var row_sp: float = float(args.get("row_spacing", 7.62))
		match footprint_str.to_upper():
			"HEADER", "CONNECTOR":
				comp.setup_header_pins(pin_count, pin_names)
			"IC_DIP":
				comp.setup_dip_pins(pin_count)
			"MODULE":
				comp.setup_module_pins(pin_count)
			_:
				comp.setup_generic_pins(pin_count, pad_type, pad_spacing, row_sp)
	else:
		comp.setup_standard_pins()

	if args.has("width") or args.has("height"):
		var custom_width: float = float(args.get("width", comp.width))
		var custom_height: float = float(args.get("height", comp.height))
		comp.set_size(custom_width, custom_height)

	if args.has("value"):
		comp.properties["value"] = args.get("value")

	data.save_to_history("Add " + component_id)
	data.add_component(comp)

	return _ok({
		"component_id": component_id,
		"x": comp.position.x,
		"y": comp.position.y,
		"pin_count": comp.pins.size(),
	})


func _move_component(args: Dictionary) -> Dictionary:
	var data = _resolve_data(args)
	if not (data is Object):
		return data
	var component_id: String = str(args.get("component_id", ""))
	if component_id.is_empty():
		return _err("component_id is required")
	if not data.has_component(component_id):
		return _err("Component not found: %s" % component_id)

	var new_pos: Vector2 = data.snap_to_grid(Vector2(float(args.get("x", 0.0)), float(args.get("y", 0.0))))
	data.save_to_history("Move " + component_id)
	data.move_component(component_id, new_pos)
	return _ok({"component_id": component_id, "x": new_pos.x, "y": new_pos.y})


func _move_relative(args: Dictionary) -> Dictionary:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)
	var data = _get_data(host)
	if data == null:
		return _err("PCB data not available")
	var component_id: String = str(args.get("component_id", ""))
	var direction: String = str(args.get("direction", ""))
	if component_id.is_empty():
		return _err("component_id is required")
	if direction.is_empty():
		return _err("direction is required")

	var spatial = _get_spatial(host)
	if spatial == null:
		return _err("PCB data not available")

	var new_pos: Vector2 = spatial.interpret_relative_move(component_id, direction)
	if data.has_component(component_id):
		data.save_to_history("Move " + component_id)
		data.move_component(component_id, data.snap_to_grid(new_pos))

	return _ok({
		"component_id": component_id,
		"new_x": new_pos.x,
		"new_y": new_pos.y,
		"interpreted_direction": direction,
	})


func _rotate_component(args: Dictionary) -> Dictionary:
	var data = _resolve_data(args)
	if not (data is Object):
		return data
	var component_id: String = str(args.get("component_id", ""))
	if component_id.is_empty():
		return _err("component_id is required")
	var comp = data.get_component(component_id)
	if not comp:
		return _err("Component not found: %s" % component_id)

	var degrees = args.get("degrees", 90)
	var new_rotation: float = comp.rotation
	if degrees is String:
		if degrees.to_lower() == "clockwise":
			new_rotation = fmod(comp.rotation + 90.0, 360.0)
		elif degrees.to_lower() == "counterclockwise":
			new_rotation = fmod(comp.rotation - 90.0 + 360.0, 360.0)
	else:
		new_rotation = float(degrees)

	data.save_to_history("Rotate " + component_id)
	data.rotate_component(component_id, new_rotation)
	return _ok({"component_id": component_id, "rotation": new_rotation})


func _delete_component(args: Dictionary) -> Dictionary:
	var data = _resolve_data(args)
	if not (data is Object):
		return data
	var component_id: String = str(args.get("component_id", ""))
	if component_id.is_empty():
		return _err("component_id is required")
	if not data.has_component(component_id):
		return _err("Component not found: %s" % component_id)

	data.save_to_history("Delete " + component_id)
	data.remove_component(component_id)
	return _ok({"deleted": component_id})


func _connect_net(args: Dictionary) -> Dictionary:
	var data = _resolve_data(args)
	if not (data is Object):
		return data
	var net_name: String = str(args.get("net_name", ""))
	var pins: Array = args.get("pins", [])
	if net_name.is_empty():
		return _err("net_name is required")
	if pins.is_empty():
		return _err("pins array is required")

	var operations: Array = []
	for pin_info in pins:
		if pin_info is Dictionary:
			var comp_id: String = str(pin_info.get("component", ""))
			var pin_name: String = str(pin_info.get("pin", ""))
			if not comp_id.is_empty() and not pin_name.is_empty():
				operations.append({"component": comp_id, "pin": pin_name})

	var connected: Array = []
	for op in operations:
		connected.append("%s.%s" % [str(op.component), str(op.pin)])

	var result := {"success": true, "net_name": str(net_name), "connected_pins": connected}
	if JSON.stringify(result).is_empty():
		return _err("Internal serialization error")

	for op in operations:
		data.connect_pin_to_net(net_name, op.component, op.pin)
	return result


func _spatial_query(args: Dictionary) -> Dictionary:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)
	var data = _get_data(host)
	if data == null:
		return _err("PCB data not available")

	var reference_component: String = str(args.get("reference_component", ""))
	var radius: float = float(args.get("radius_mm", 20.0))
	if reference_component.is_empty():
		# No reference → same shape as get_components (mirrors legacy).
		return _get_components(args)

	var spatial = _get_spatial(host)
	if spatial == null:
		return _err("PCB data not available")

	var nearby = spatial.get_components_near(reference_component, radius)
	var results: Array = []
	for comp_id in nearby:
		results.append({
			"id": comp_id,
			"relationship": spatial.describe_relative_position(reference_component, comp_id),
		})
	return _ok({
		"reference": reference_component,
		"radius_mm": radius,
		"nearby_count": results.size(),
		"nearby": results,
	})


func _describe_component(args: Dictionary) -> Dictionary:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)
	var spatial = _get_spatial(host)
	if spatial == null:
		return _err("PCB data not available")
	var component_id: String = str(args.get("component_id", ""))
	if component_id.is_empty():
		return _err("component_id is required")

	var context: Dictionary = spatial.describe_component_context(component_id)
	if context.is_empty():
		return _err("Component not found: %s" % component_id)
	context["success"] = true
	return context


func _get_change_journal(args: Dictionary) -> Dictionary:
	var data = _resolve_data(args)
	if not (data is Object):
		return data
	var since_timestamp: float = float(args.get("since_timestamp", 0.0))
	var limit: int = int(args.get("limit", 50))

	var entries: Array = data.get_change_journal(since_timestamp)
	if limit > 0 and entries.size() > limit:
		entries = entries.slice(entries.size() - limit)

	return _ok({
		"total_entries": data.change_journal.size(),
		"returned_entries": entries.size(),
		"entries": entries,
	})


func _import_csv(args: Dictionary) -> Dictionary:
	var data = _resolve_data(args)
	if not (data is Object):
		return data
	var csv_content: String = str(args.get("csv_content", ""))
	if csv_content.is_empty():
		return _err("csv_content is required")
	data.from_csv(csv_content)
	return _ok({"component_count": data.get_component_count()})


func _export_csv(args: Dictionary) -> Dictionary:
	var data = _resolve_data(args)
	if not (data is Object):
		return data
	return _ok({"csv": data.to_csv()})


func _import_footprint_geometry(args: Dictionary) -> Dictionary:
	var data = _resolve_data(args)
	if not (data is Object):
		return data
	var geometry_data: Dictionary = args.get("geometry", {})
	if geometry_data.is_empty():
		return _err("geometry data is required")
	var position_is_center: bool = bool(args.get("position_is_center", false))
	var invert_y: bool = bool(args.get("invert_y", false))

	var components_data: Dictionary = geometry_data.get("components", {})
	var updated_count := 0
	var position_adjusted_count := 0
	var missing: Array = []

	for comp_id in components_data:
		var comp = data.get_component(comp_id)
		if not comp:
			missing.append(comp_id)
			continue
		var comp_geometry: Dictionary = components_data[comp_id]
		if comp_geometry.get("footprint_found", false):
			comp.load_pad_geometry(comp_geometry)
			updated_count += 1
			if position_is_center or invert_y:
				var new_pos: Vector2 = comp.position
				if invert_y:
					new_pos.y = data.board_height - new_pos.y
				if position_is_center:
					var xform: Transform2D = comp.get_transform()
					new_pos -= xform * comp.bbox_center_offset
				comp.position = new_pos
				position_adjusted_count += 1
		else:
			missing.append(comp_id)

	data.save_to_history("Import footprint geometry")
	data.data_changed.emit()

	var result := {
		"success": true,
		"updated_count": updated_count,
		"missing_footprints": missing,
		"board_name": geometry_data.get("board_name", ""),
	}
	if position_is_center or invert_y:
		result["position_adjusted_count"] = position_adjusted_count
		result["position_corrections_applied"] = {
			"position_is_center": position_is_center,
			"invert_y": invert_y,
			"board_height": data.board_height,
		}
	return result


func _import_trace_geometry(args: Dictionary) -> Dictionary:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)
	var data = _get_data(host)
	if data == null:
		return _err("PCB data not available")
	var trace_data: Dictionary = args.get("trace_data", {})
	if trace_data.is_empty():
		return _err("trace_data is required")

	data.clear_traces()

	var traces_input: Array = trace_data.get("traces", [])
	var trace_groups: Dictionary = {}
	for seg in traces_input:
		var net_name: String = seg.get("net_name", "")
		var layer: String = seg.get("layer", "F.Cu")
		var key := "%s_%s" % [net_name, layer]
		if not trace_groups.has(key):
			trace_groups[key] = {
				"net_name": net_name,
				"layer": "top" if layer == "F.Cu" else "bottom",
				"width": seg.get("width", 0.3),
				"segments": [],
			}
		var start = seg.get("start", {})
		var end_pt = seg.get("end", {})
		trace_groups[key].segments.append({
			"start": Vector2(start.get("x", 0), start.get("y", 0)),
			"end": Vector2(end_pt.get("x", 0), end_pt.get("y", 0)),
		})

	var trace_count := 0
	for key in trace_groups:
		var group = trace_groups[key]
		var polylines := _build_polylines_from_segments(group.segments)
		for polyline in polylines:
			if polyline.size() < 2:
				continue
			var trace = data.new_trace()
			trace.id = "trace_%d" % trace_count
			trace.net_name = group.net_name
			trace.layer = group.layer
			trace.width = group.width
			for point in polyline:
				trace.waypoints.append(point)
			data.add_trace(trace)
			trace_count += 1

	var vias_input: Array = trace_data.get("vias", [])
	for via_data in vias_input:
		var pos = via_data.get("position", {})
		data.add_via({
			"position": Vector2(pos.get("x", 0), pos.get("y", 0)),
			"size": via_data.get("size", 0.8),
			"drill": via_data.get("drill", 0.4),
			"net_name": via_data.get("net_name", ""),
			"layers": via_data.get("layers", ["F.Cu", "B.Cu"]),
		})

	data.save_to_history("Import traces")
	return _ok({"trace_count": trace_count, "via_count": vias_input.size()})


func _export_trace_geometry(args: Dictionary) -> Dictionary:
	var data = _resolve_data(args)
	if not (data is Object):
		return data

	var traces_output: Array = []
	for trace_id in data.get_trace_ids():
		var trace = data.get_trace(trace_id)
		if not trace:
			continue
		var layer_name: String = "F.Cu" if trace.layer == "top" else "B.Cu"
		for i in range(trace.waypoints.size() - 1):
			var start_pt: Vector2 = trace.waypoints[i]
			var end_pt: Vector2 = trace.waypoints[i + 1]
			traces_output.append({
				"start": {"x": snapped(start_pt.x, 0.0001), "y": snapped(start_pt.y, 0.0001)},
				"end": {"x": snapped(end_pt.x, 0.0001), "y": snapped(end_pt.y, 0.0001)},
				"width": trace.width,
				"layer": layer_name,
				"net_name": trace.net_name,
			})

	var vias_output: Array = []
	for via in data.vias:
		var pos: Vector2 = via.get("position", Vector2.ZERO)
		vias_output.append({
			"position": {"x": snapped(pos.x, 0.0001), "y": snapped(pos.y, 0.0001)},
			"size": via.get("size", 0.8),
			"drill": via.get("drill", 0.4),
			"net_name": via.get("net_name", ""),
			"layers": via.get("layers", ["F.Cu", "B.Cu"]),
		})

	return _ok({
		"trace_count": traces_output.size(),
		"via_count": vias_output.size(),
		"trace_data": {"traces": traces_output, "vias": vias_output},
	})


## Snapshot-style image capture (mirrors minerva_cad_snapshot in spirit). Renders
## the live board canvas via the host's render_content_to_image; headless /
## unmounted → image_data null (never crashes). Metadata is always populated from
## the model. Synchronous: this host's render_content_to_image returns the current
## frame directly (no deferred capture to await), so there is nothing to wait on.
func _get_image(args: Dictionary) -> Dictionary:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)
	var data = _get_data(host)

	var metadata := {}
	if data != null:
		metadata["board_width_mm"] = data.board_width
		metadata["board_height_mm"] = data.board_height
		metadata["component_count"] = data.components.size()
		metadata["net_count"] = data.nets.size()
	if host.has_method("get_all_annotations"):
		metadata["annotation_count"] = (host.call("get_all_annotations") as Array).size()

	var img: Image = null
	if host.has_method("render_content_to_image"):
		img = host.call("render_content_to_image", Rect2()) as Image

	if img == null:
		return _ok({
			"image_data": null,
			"format": "png",
			"metadata": metadata,
			"note": "No rendered image available (panel not mounted / headless).",
		})

	var png_buf: PackedByteArray = img.save_png_to_buffer()
	if png_buf.is_empty():
		return _err("Failed to encode PCB image")
	return _ok({
		"image_data": Marshalls.raw_to_base64(png_buf),
		"format": "png",
		"encoding": "base64",
		"width": img.get_width(),
		"height": img.get_height(),
		"metadata": metadata,
	})


# ── Route-correction collaboration loop ───────────────────────────────────────
#
# minerva_pcb_apply_route_hints closes the route-correction loop (agent-router
# child 019eb47eb567). The propose→inspect→apply→iterate flow:
#
#   1. PROPOSE (commit absent/false): gather the board's OPEN pcb_route_hint
#      annotations (or the given hint_ids), route them through the worker, and
#      write the routed polylines back as AI-authored (author.kind="ai" → cyan)
#      pcb_route_hint PROPOSAL annotations. A proposal carries the routed
#      waypoints + kind_payload.net_names=[net] + kind_payload.proposal_for=
#      [source hint ids]. Proposals do NOT mutate the board — the user inspects
#      them in the dock/canvas first.
#   2. APPLY (commit=true): re-route the selected open hints and MATERIALIZE the
#      results as real traces in the model (journaled via save_to_history), then
#      transition the source hints open→applied. Returns applied/traces_added.
#   3. ITERATE: applied hints are excluded from the default (open) gather and AI
#      proposals are never re-routed (they carry proposal_for), so re-running
#      after the user edits/adds hints picks up only the fresh open hints.
#
# FAILURE AS FEEDBACK: partial/failed routing returns WHERE it got stuck —
# result.unrouted (net + blocked pad pair) surfaced as `stuck`, plus bridge
# warnings — structured data the agent can reason about, not a bare "failed".
#
# WORKER-INVOCATION (documented finding, DCR 019dc140): the worker `route`
# method is dispatcher-registered but NOT reachable from this core module
# in-fence. Worker compute is exposed to core only as Go MCP tools
# (internal/tools/worker_tools.go) — out of fence — and `route` is not among
# them. The panel `request` broker reaches Go channel handlers
# (pcb.serialize/…, declared in manifest.json ipc_channels), NOT the Python
# worker's compute methods, and the manifest is out of fence too. So the
# in-fence half is wired end-to-end (host.run_router → panel.route_board emits a
# "pcb.route" broker request and awaits the reply); making it live needs one
# out-of-fence step — declare the "pcb.route" channel + forward it to the worker
# `route` handler, OR expose minerva_pcb_route in worker_tools.go. Until then
# _run_router returns a structured worker_unavailable (surfaced as feedback), and
# the write-back/apply/lifecycle logic below is validated headless against a
# canned RoutingResult (see test/test_pcb_apply_route_hints.gd).

func _apply_route_hints(args: Dictionary) -> Dictionary:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)
	var data = _get_data(host)
	if data == null:
		return _err("PCB data not available")

	var hint_ids: Array = args.get("hint_ids", [])
	var commit: bool = bool(args.get("commit", false))

	var source_hints: Array = _gather_route_hints(host, hint_ids)
	if source_hints.is_empty():
		return _ok({
			"proposed": 0,
			"proposals": [],
			"unrouted": [],
			"stuck": [],
			"committed": commit,
			"note": "no open route hints to route (add hints or pass hint_ids)",
		})

	var selection: Dictionary
	if hint_ids.is_empty():
		selection = {"mode": "open"}
	else:
		selection = {"mode": "ids", "ids": _hint_id_list(source_hints)}

	var reply: Dictionary = await _run_router(host, selection)
	if not bool(reply.get("ok", false)):
		return _router_unavailable(reply, source_hints)

	var result: Dictionary = reply.get("result", {})
	if commit:
		return _materialize_routes(host, data, result, source_hints)
	return _write_back_proposals(host, result, source_hints)


## Reach the router worker through the in-fence host bridge (async). The host
## forwards to the panel's broker request path. Returns the worker's {ok, result}
## envelope, or a structured worker_unavailable when no bridge is reachable
## (headless / channel not registered — see the WORKER-INVOCATION note above).
func _run_router(host, selection: Dictionary) -> Dictionary:
	if host != null and host.has_method("run_router"):
		return await host.run_router(selection)
	return {"ok": false, "error": {"kind": "worker_unavailable",
		"message": "host has no run_router bridge to the router worker"}}


## Structured failure-as-feedback when the worker did not answer.
func _router_unavailable(reply: Dictionary, source_hints: Array) -> Dictionary:
	return {
		"success": false,
		"error": "route_worker_unavailable",
		"detail": reply.get("error", {}),
		"hint_ids": _hint_id_list(source_hints),
		"note": "Router worker did not answer. In-fence wiring reaches it via host.run_router → panel 'pcb.route' broker request; declaring the 'pcb.route' channel (or exposing minerva_pcb_route in the worker MCP tools) is the out-of-fence follow-up — see pcb/docs/tools.md.",
	}


## Gather the source route hints to route. With explicit hint_ids: exactly those
## (any lifecycle). Without: every OPEN human/source hint. AI proposals (carrying
## kind_payload.proposal_for) are NEVER treated as source hints — that keeps the
## iterate loop from re-routing its own proposals, and applied hints drop out of
## the default open gather.
func _gather_route_hints(host, hint_ids: Array) -> Array:
	var anns: Array = []
	if host != null and host.has_method("get_all_annotations"):
		anns = host.call("get_all_annotations")
	var wanted := {}
	for i in hint_ids:
		wanted[str(i)] = true
	var out: Array = []
	for ann in anns:
		if not (ann is Dictionary):
			continue
		if str(ann.get("kind", "")) != "pcb_route_hint":
			continue
		var payload: Dictionary = ann.get("kind_payload", {}) if ann.get("kind_payload", {}) is Dictionary else {}
		if payload.has("proposal_for"):
			continue  # an AI proposal — not a source hint
		if not wanted.is_empty():
			if wanted.has(str(ann.get("id", ""))):
				out.append(ann)
		elif str(ann.get("lifecycle", "open")) == "open":
			out.append(ann)
	return out


## PROPOSE: routed polylines → AI-authored cyan proposal annotations. The board
## is NOT mutated — only annotations are added. Each proposal links to the source
## hint id(s) answering the same net.
func _write_back_proposals(host, result: Dictionary, source_hints: Array) -> Dictionary:
	var proposals: Array = []
	for route in result.get("routes", []):
		if not (route is Dictionary):
			continue
		var net: String = str(route.get("net", ""))
		var pts: Array = _route_polyline(route)
		if pts.size() < 2:
			continue
		var layer: String = _route_layer(route)
		var width: float = _width_for_net(source_hints, net)
		var linked: Array = _source_hint_ids_for_net(source_hints, net)
		var first: Array = pts[0]
		var envelope: Dictionary = host.call("build_route_hint_envelope",
			float(first[0]), float(first[1]), "", layer, "single_trace", pts, "ai")
		var kp: Dictionary = envelope.get("kind_payload", {})
		kp["net_names"] = [net]
		kp["proposal_for"] = linked
		if width > 0.0:
			kp["width_mm"] = width
		envelope["kind_payload"] = kp
		envelope["summary"] = "Proposed route %s (%d waypoints, %s)" % [net, pts.size(), layer]
		var new_id: String = str(host.call("add_annotation_v2", envelope))
		if new_id.is_empty():
			continue
		proposals.append({
			"id": new_id,
			"net": net,
			"layer": layer,
			"waypoint_count": pts.size(),
			"proposal_for": linked,
			"width_mm": width,
		})
	return {
		"success": true,
		"committed": false,
		"proposed": proposals.size(),
		"proposals": proposals,
		"unrouted": result.get("unrouted", []),
		"stuck": _stuck_from_result(result),
		"via_count": int(result.get("via_count", 0)),
	}


## APPLY: materialize routed polylines as real traces (journaled) + transition
## source hints open→applied. Per-layer segment grouping mirrors
## import_trace_geometry so multi-layer routes become correct single-layer traces.
func _materialize_routes(host, data, result: Dictionary, source_hints: Array) -> Dictionary:
	var traces_added := 0
	var failed: Array = []
	for route in result.get("routes", []):
		if not (route is Dictionary):
			continue
		var net: String = str(route.get("net", ""))
		var width: float = _width_for_net(source_hints, net)
		if width <= 0.0:
			width = 0.25
		var by_layer := {}
		for seg in route.get("segments", []):
			if not (seg is Dictionary):
				continue
			var lyr: String = str(seg.get("layer", "F.Cu"))
			if not by_layer.has(lyr):
				by_layer[lyr] = []
			by_layer[lyr].append({
				"start": _arr_to_vec2(seg.get("start", [0, 0])),
				"end": _arr_to_vec2(seg.get("end", [0, 0])),
			})
		var made_any := false
		for lyr in by_layer:
			for polyline in _build_polylines_from_segments(by_layer[lyr]):
				if polyline.size() < 2:
					continue
				var trace = data.new_trace()
				trace.net_name = net
				trace.layer = "top" if lyr == "F.Cu" else "bottom"
				trace.width = width
				for point in polyline:
					trace.waypoints.append(point)
				data.add_trace(trace)
				traces_added += 1
				made_any = true
		if not made_any:
			failed.append({"net": net, "reason": "no usable segments in routed result"})
		for via in route.get("vias", []):
			data.add_via({
				"position": _arr_to_vec2(via),
				"size": 0.8,
				"drill": 0.4,
				"net_name": net,
				"layers": ["F.Cu", "B.Cu"],
			})

	# Snapshot AFTER mutation so the undo/redo checkpoint captures the applied
	# traces (undo() restores the PREVIOUS entry — matches _import_trace_geometry;
	# snapshotting before would leave the applied state unrecoverable on redo).
	if traces_added > 0:
		data.save_to_history("Apply route hints")

	var applied := 0
	var applied_ids: Array = []
	for hint in source_hints:
		var hid: String = str(hint.get("id", ""))
		if hid.is_empty():
			continue
		if host.has_method("update_annotation_lifecycle"):
			var res: Dictionary = host.update_annotation_lifecycle(hid, "applied")
			if bool(res.get("ok", false)):
				applied += 1
				applied_ids.append(hid)
	return {
		"success": true,
		"committed": true,
		"applied": applied,
		"applied_hint_ids": applied_ids,
		"traces_added": traces_added,
		"failed": failed,
		"unrouted": result.get("unrouted", []),
		"stuck": _stuck_from_result(result),
		"via_count": int(result.get("via_count", 0)),
	}


## unrouted nets (+ bridge warnings) → structured "stuck" feedback the agent can
## reason about: which net, which pad pair is blocked.
func _stuck_from_result(result: Dictionary) -> Array:
	var stuck: Array = []
	for u in result.get("unrouted", []):
		if u is Dictionary:
			stuck.append({
				"net": u.get("net", ""),
				"from": u.get("from", ""),
				"to": u.get("to", ""),
				"reason": "unrouted — blocked pad pair (congestion or no legal path)",
			})
	for w in result.get("warnings", []):
		stuck.append({"warning": w})
	return stuck


## Ordered polyline (Array of [x, y]) chaining a route's segment endpoints. Layer
## changes/vias appear as continuous joints — adequate for a visual proposal.
func _route_polyline(route: Dictionary) -> Array:
	var pts: Array = []
	for seg in route.get("segments", []):
		if not (seg is Dictionary):
			continue
		var st: Array = _arr_pair(seg.get("start", [0, 0]))
		var en: Array = _arr_pair(seg.get("end", [0, 0]))
		if pts.is_empty():
			pts.append(st)
		pts.append(en)
	return pts


## KiCad copper layer of a route (its first segment's layer), defaulting F.Cu.
func _route_layer(route: Dictionary) -> String:
	for seg in route.get("segments", []):
		if seg is Dictionary and (seg as Dictionary).has("layer"):
			return str((seg as Dictionary).get("layer", "F.Cu"))
	return "F.Cu"


## Widest authored trace width among the source hints that target `net`
## (kind_payload.net_names). 0.0 when none specify a width.
func _width_for_net(source_hints: Array, net: String) -> float:
	var w := 0.0
	for hint in source_hints:
		var kp: Dictionary = hint.get("kind_payload", {}) if hint.get("kind_payload", {}) is Dictionary else {}
		if net in _string_list(kp.get("net_names", [])):
			var hw := float(kp.get("width_mm", 0.0))
			if hw > w:
				w = hw
	return w


## Source hint ids that answer `net` (by net_names). Falls back to ALL source
## hint ids when none match by net — the whole selection collectively asked to
## route, so the proposal is still traceable to its origin.
func _source_hint_ids_for_net(source_hints: Array, net: String) -> Array:
	var ids: Array = []
	for hint in source_hints:
		var kp: Dictionary = hint.get("kind_payload", {}) if hint.get("kind_payload", {}) is Dictionary else {}
		if net in _string_list(kp.get("net_names", [])):
			ids.append(str(hint.get("id", "")))
	if ids.is_empty():
		return _hint_id_list(source_hints)
	return ids


func _hint_id_list(source_hints: Array) -> Array:
	var ids: Array = []
	for hint in source_hints:
		ids.append(str(hint.get("id", "")))
	return ids


static func _string_list(raw) -> Array:
	var out: Array = []
	if raw is Array:
		for v in (raw as Array):
			out.append(str(v))
	return out


## Coerce a [x, y] pair (Array or Vector2) to a fresh [float, float] Array.
static func _arr_pair(raw) -> Array:
	if raw is Vector2:
		return [float((raw as Vector2).x), float((raw as Vector2).y)]
	if raw is Array and (raw as Array).size() >= 2:
		return [float((raw as Array)[0]), float((raw as Array)[1])]
	return [0.0, 0.0]


static func _arr_to_vec2(raw) -> Vector2:
	if raw is Vector2:
		return raw
	if raw is Array and (raw as Array).size() >= 2:
		return Vector2(float((raw as Array)[0]), float((raw as Array)[1]))
	return Vector2.ZERO


# ── Internal helpers ──────────────────────────────────────────────────────────

## Resolve editor_name → PcbAnnotationHost via the registry (null on miss).
func _resolve_host(args: Dictionary) -> AnnotationHost:
	var editor_name: String = str(args.get("editor_name", ""))
	if editor_name.is_empty():
		return null
	return AnnotationHostRegistry.get_host(editor_name)


## Structured missing-host error (mirrors MCPCadTools._no_host_error convention).
func _no_host_error(args: Dictionary) -> Dictionary:
	var editor_name: String = str(args.get("editor_name", ""))
	if editor_name.is_empty():
		return _err("editor_name is required")
	var known: Array = AnnotationHostRegistry.list_editor_names()
	return _err("no_pcb_host_for_editor: '%s'. Known editors: %s" % [editor_name, str(known)])


## The live board model off a host, or null (duck-typed — host may lack the getter).
func _get_data(host):
	if host == null or not host.has_method("get_board_data"):
		return null
	return host.get_board_data()


## The spatial index off a host, or null (duck-typed).
func _get_spatial(host):
	if host == null or not host.has_method("get_spatial_index"):
		return null
	return host.get_spatial_index()


## Resolve host → board model in one step, returning either the model (Object) or
## a ready-to-return error Dictionary. Callers guard with `if not (data is Object)`.
func _resolve_data(args: Dictionary) -> Variant:
	var host: AnnotationHost = _resolve_host(args)
	if host == null:
		return _no_host_error(args)
	var data = _get_data(host)
	if data == null:
		return _err("PCB data not available")
	return data


## Connect trace segments into polylines (pure geometry; ported verbatim from the
## legacy MCPPCBTools helper so import_trace_geometry stays call-compatible).
func _build_polylines_from_segments(segments: Array) -> Array:
	if segments.is_empty():
		return []
	var result: Array = []
	var used: Array = []
	used.resize(segments.size())
	used.fill(false)
	for i in range(segments.size()):
		if used[i]:
			continue
		var polyline: Array[Vector2] = [segments[i].start, segments[i].end]
		used[i] = true
		var changed := true
		while changed:
			changed = false
			for j in range(segments.size()):
				if used[j]:
					continue
				var seg = segments[j]
				if seg.start.distance_to(polyline[polyline.size() - 1]) < 0.01:
					polyline.append(seg.end)
					used[j] = true
					changed = true
				elif seg.end.distance_to(polyline[polyline.size() - 1]) < 0.01:
					polyline.append(seg.start)
					used[j] = true
					changed = true
				elif seg.end.distance_to(polyline[0]) < 0.01:
					polyline.insert(0, seg.start)
					used[j] = true
					changed = true
				elif seg.start.distance_to(polyline[0]) < 0.01:
					polyline.insert(0, seg.end)
					used[j] = true
					changed = true
		result.append(polyline)
	return result


## Success/error builders — self-contained so the module is headlessly testable
## without the SingletonObject autoload (mirrors MCPCadTools).
static func _ok(data: Dictionary = {}) -> Dictionary:
	var result := {"success": true}
	result.merge(data)
	return result


static func _err(msg: String) -> Dictionary:
	return {"error": msg, "success": false}

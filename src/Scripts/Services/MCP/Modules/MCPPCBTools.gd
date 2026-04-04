class_name MCPPCBTools
extends MCPToolModule
## MCP tool module for the PCB Editor domain.
## Handles creation, component management, routing, annotations,
## route hints, import/export, image capture, and note creation.

const PCBEditorScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBEditor.gd")
const PCBDataScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBData.gd")
const PCBComponentScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBComponent.gd")
const PCBTraceScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBTrace.gd")
const PCBAnnotationScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBAnnotation.gd")
const PCBRouteHintScript := preload("res://Scripts/UI/Controls/PCBEditor/PCBRouteHint.gd")
const NoteScript := preload("res://Scripts/UI/Controls/Note.gd")


func get_tool_names() -> Array[String]:
	return [
		"minerva_create_pcb_editor",
		"minerva_pcb_set_board_size",
		"minerva_pcb_get_components",
		"minerva_pcb_describe_component",
		"minerva_pcb_spatial_query",
		"minerva_pcb_get_nets",
		"minerva_pcb_add_component",
		"minerva_pcb_move_component",
		"minerva_pcb_move_relative",
		"minerva_pcb_rotate_component",
		"minerva_pcb_delete_component",
		"minerva_pcb_connect_net",
		"minerva_pcb_export_csv",
		"minerva_pcb_export_yaml",
		"minerva_pcb_import_csv",
		"minerva_pcb_import_footprint_geometry",
		"minerva_pcb_import_trace_geometry",
		"minerva_pcb_export_trace_geometry",
		"minerva_pcb_add_annotation",
		"minerva_pcb_list_annotations",
		"minerva_pcb_remove_annotation",
		"minerva_pcb_clear_annotations",
		"minerva_pcb_add_route_hint",
		"minerva_pcb_list_route_hints",
		"minerva_pcb_remove_route_hint",
		"minerva_pcb_clear_route_hints",
		"minerva_pcb_interpret_route_hints",
		"minerva_pcb_get_change_journal",
		"minerva_pcb_get_pin_position",
		"minerva_pcb_get_image",
		"minerva_pcb_create_note",
	]


func register_tools() -> void:
	server._register_tool("minerva_create_pcb_editor",
		"Create a new PCB Editor tab for designing printed circuit board layouts. Next steps: use minerva_pcb_add_component to place components, minerva_pcb_connect_net for routing.",
		{
			"type": "object",
			"properties": {
				"name": {
					"type": "string",
					"description": "Display name for the PCB editor tab"
				},
				"board_width": {
					"type": "number",
					"description": "Board width in mm. Default: 100"
				},
				"board_height": {
					"type": "number",
					"description": "Board height in mm. Default: 100"
				}
			},
			"required": ["name"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_get_components",
		"Get all components from a PCB editor with their positions and connections.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				}
			},
			"required": ["editor_name"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_set_board_size",
		"Set the PCB board dimensions.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"width": {
					"type": "number",
					"description": "Board width in mm"
				},
				"height": {
					"type": "number",
					"description": "Board height in mm"
				}
			},
			"required": ["editor_name", "width", "height"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_describe_component",
		"Get detailed spatial context for a component including nearby components, connections, and region.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"component_id": {
					"type": "string",
					"description": "Component ID (e.g., 'SW1', 'U3')"
				}
			},
			"required": ["editor_name", "component_id"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_spatial_query",
		"Query components based on spatial relationships (e.g., 'what components are near U3?').",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"query": {
					"type": "string",
					"description": "Natural language spatial query"
				},
				"reference_component": {
					"type": "string",
					"description": "Component ID to query relative to"
				},
				"radius_mm": {
					"type": "number",
					"description": "Search radius in mm. Default: 20"
				}
			},
			"required": ["editor_name"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_get_nets",
		"Get all electrical nets (connections) from a PCB.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				}
			},
			"required": ["editor_name"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_get_pin_position",
		"Get the world position and info for a specific pin on a component. Useful for calculating waypoints or verifying pin locations before creating route hints.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"component_id": {
					"type": "string",
					"description": "Component ID (e.g., 'U3', 'R1')"
				},
				"pin": {
					"type": "string",
					"description": "Pin name or number (e.g., '1', 'VCC', 'SDA')"
				}
			},
			"required": ["editor_name", "component_id", "pin"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_add_component",
		"Add a new component to the PCB. NOTE: Component dimensions are estimated defaults based on footprint type. For accurate sizing from KiCAD libraries, run pcb-architect's footprint-geometry command and then call minerva_pcb_import_footprint_geometry to update components with real dimensions.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"id": {
					"type": "string",
					"description": "Component ID (e.g., 'R15', 'U3'). Auto-generated if not specified."
				},
				"footprint": {
					"type": "string",
					"description": "Footprint type: RESISTOR, CAPACITOR, IC_DIP, IC_QFP, SWITCH, CONNECTOR, LED, DIODE, TRANSISTOR, HEADER, MOUNTING_HOLE, MODULE",
					"enum": ["RESISTOR", "CAPACITOR", "IC_DIP", "IC_QFP", "SWITCH", "CONNECTOR", "LED", "DIODE", "TRANSISTOR", "HEADER", "MOUNTING_HOLE", "MODULE"]
				},
				"x": {
					"type": "number",
					"description": "X position in mm"
				},
				"y": {
					"type": "number",
					"description": "Y position in mm"
				},
				"rotation": {
					"type": "number",
					"description": "Rotation in degrees (0, 90, 180, 270). Default: 0"
				},
				"value": {
					"type": "string",
					"description": "Component value (e.g., '10K', '100nF')"
				},
				"pin_count": {
					"type": "integer",
					"description": "Number of pins. Works for all footprint types. HEADER/CONNECTOR = single row, IC_DIP/MODULE = dual row (even), others use generic layout via pad_type/pad_spacing/row_spacing."
				},
				"pad_type": {
					"type": "string",
					"enum": ["smd", "tht"],
					"description": "Pad type for placeholder geometry (default: tht). Used when pin_count is set on non-specialised footprint types."
				},
				"pad_spacing": {
					"type": "number",
					"description": "Centre-to-centre pad spacing in mm (default: 2.54). Used with generic pin layout."
				},
				"row_spacing": {
					"type": "number",
					"description": "Row-to-row spacing for dual-row layouts in mm (default: 7.62). Used with generic pin layout."
				},
				"width": {
					"type": "number",
					"description": "Custom width in mm (overrides default)"
				},
				"height": {
					"type": "number",
					"description": "Custom height in mm (overrides default)"
				},
				"pin_names": {
					"type": "array",
					"items": {"type": "string"},
					"description": "Custom pin names (e.g., ['GND', 'VCC', 'SDA', 'SCL'] for a 4-pin header)"
				},
				"snap_to_grid": {
					"type": "boolean",
					"description": "Whether to snap position to grid (default: true). Set to false for exact positioning."
				}
			},
			"required": ["editor_name", "footprint", "x", "y"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_move_component",
		"Move a component to an absolute position. Requires editor_name from minerva_list_editors and component names from minerva_pcb_get_components.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"component_id": {
					"type": "string",
					"description": "Component ID to move"
				},
				"x": {
					"type": "number",
					"description": "New X position in mm"
				},
				"y": {
					"type": "number",
					"description": "New Y position in mm"
				}
			},
			"required": ["editor_name", "component_id", "x", "y"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_move_relative",
		"Move a component using natural language direction (e.g., 'down a bit', 'closer to U3').",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"component_id": {
					"type": "string",
					"description": "Component ID to move"
				},
				"direction": {
					"type": "string",
					"description": "Natural language direction: 'up', 'down', 'left', 'right', 'closer to X', 'away from X', 'toward center', etc."
				}
			},
			"required": ["editor_name", "component_id", "direction"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_rotate_component",
		"Rotate a component. Positive degrees rotate counter-clockwise (CCW), negative rotate clockwise (CW). Requires editor_name from minerva_list_editors.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"component_id": {
					"type": "string",
					"description": "Component ID to rotate"
				},
				"degrees": {
					"type": "number",
					"description": "Rotation angle. Positive = counter-clockwise (CCW), negative = clockwise (CW). Common values: 90 (CCW), -90 (CW), 180."
				}
			},
			"required": ["editor_name", "component_id", "degrees"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_delete_component",
		"Delete a component from the PCB. Requires editor_name from minerva_list_editors.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"component_id": {
					"type": "string",
					"description": "Component ID to delete"
				}
			},
			"required": ["editor_name", "component_id"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_connect_net",
		"Connect component pins to a net (creates net if it doesn't exist). Get pin names from minerva_pcb_describe_component first. Requires editor_name from minerva_list_editors.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"net_name": {
					"type": "string",
					"description": "Net name (e.g., 'VCC', 'GND', 'SDA')"
				},
				"pins": {
					"type": "array",
					"description": "Array of pin connections: [{\"component\": \"U1\", \"pin\": \"8\"}, ...]",
					"items": {
						"type": "object",
						"properties": {
							"component": {"type": "string"},
							"pin": {"type": "string"}
						}
					}
				}
			},
			"required": ["editor_name", "net_name", "pins"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_export_csv",
		"Export PCB component placement as CSV.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				}
			},
			"required": ["editor_name"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_export_yaml",
		"Export PCB as YAML (compatible with pcb-architect).",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				}
			},
			"required": ["editor_name"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_import_csv",
		"Import component placement from CSV.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"csv_content": {
					"type": "string",
					"description": "CSV content with columns: id,footprint,x,y,rotation,layer,value"
				}
			},
			"required": ["editor_name", "csv_content"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_import_footprint_geometry",
		"IMPORTANT: Call this after adding components to get accurate dimensions from KiCAD footprint libraries. Without this, components use estimated sizes that may not match actual footprints. Run 'pcb-architect footprint-geometry board.yaml -o geometry.json' to generate the input data. Updates component pads with accurate shapes, sizes, drill holes, and body dimensions. Can also correct positions if YAML used different coordinate conventions (use position_is_center and/or invert_y flags).",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"geometry": {
					"type": "object",
					"description": "Footprint geometry JSON from pcb-architect footprint-geometry command. Contains board_name and components with pad arrays.",
					"properties": {
						"board_name": {"type": "string"},
						"components": {
							"type": "object",
							"additionalProperties": {
								"type": "object",
								"properties": {
									"footprint_id": {"type": "string"},
									"footprint_found": {"type": "boolean"},
									"bounding_box": {"type": "object"},
									"pads": {
										"type": "array",
										"items": {
											"type": "object",
											"properties": {
												"number": {"type": "string"},
												"type": {"type": "string", "enum": ["smd", "thru_hole", "np_thru_hole"]},
												"shape": {"type": "string", "enum": ["rect", "circle", "oval", "roundrect", "custom"]},
												"position": {"type": "object"},
												"size": {"type": "object"},
												"drill": {"type": "number"},
												"layers": {"type": "array", "items": {"type": "string"}}
											}
										}
									}
								}
							}
						}
					}
				},
				"position_is_center": {
					"type": "boolean",
					"description": "If true, current component positions are geometric centers (not footprint origins). Will adjust positions by subtracting bounding_box center offset. Default: false"
				},
				"invert_y": {
					"type": "boolean",
					"description": "If true, Y coordinates are inverted (Y=0 at bottom instead of top). Will flip Y relative to board height. Default: false"
				}
			},
			"required": ["editor_name", "geometry"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_import_trace_geometry",
		"Import routed traces and vias from pcb-architect's trace-geometry command output. Clears existing traces and imports new ones. Trace segments are automatically connected into polylines.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"trace_data": {
					"type": "object",
					"description": "Trace geometry JSON from pcb-architect trace-geometry command",
					"properties": {
						"traces": {
							"type": "array",
							"description": "Array of trace segments",
							"items": {
								"type": "object",
								"properties": {
									"start": {"type": "object", "properties": {"x": {"type": "number"}, "y": {"type": "number"}}},
									"end": {"type": "object", "properties": {"x": {"type": "number"}, "y": {"type": "number"}}},
									"width": {"type": "number"},
									"layer": {"type": "string"},
									"net_name": {"type": "string"}
								}
							}
						},
						"vias": {
							"type": "array",
							"description": "Array of vias",
							"items": {
								"type": "object",
								"properties": {
									"position": {"type": "object", "properties": {"x": {"type": "number"}, "y": {"type": "number"}}},
									"size": {"type": "number"},
									"drill": {"type": "number"},
									"net_name": {"type": "string"},
									"layers": {"type": "array", "items": {"type": "string"}}
								}
							}
						}
					}
				}
			},
			"required": ["editor_name", "trace_data"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_export_trace_geometry",
		"Export routed traces and vias from a PCB editor. Returns trace data in the same format accepted by import_trace_geometry, enabling round-trip workflows.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				}
			},
			"required": ["editor_name"]
		}
	, "pcb")

	# Annotation tools
	server._register_tool("minerva_pcb_add_annotation",
		"Add an annotation to the PCB (arrow, text, region, or polyline). Annotations are visual overlays for collaboration between human and AI. Positions use {x,y} coordinates — call minerva_pcb_describe_component first to resolve component names to coordinates. Requires editor_name from minerva_list_editors.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"type": {
					"type": "string",
					"description": "Annotation type: 'arrow', 'text', 'region', or 'polyline'",
					"enum": ["arrow", "text", "region", "polyline"]
				},
				"positions": {
					"type": "array",
					"description": "Array of positions: arrow=[start,end], text=[position], region=[corner1,corner2], polyline=[point1,...,pointN]",
					"items": {
						"type": "object",
						"properties": {
							"x": {"type": "number"},
							"y": {"type": "number"}
						}
					}
				},
				"text": {
					"type": "string",
					"description": "Text content for text annotations, or label for other types"
				},
				"color": {
					"type": "string",
					"description": "Optional color as hex (e.g., '#FF0000'). Defaults to AI color (cyan)"
				},
				"associated_component": {
					"type": "string",
					"description": "Optional: component ID this annotation relates to"
				},
				"associated_net": {
					"type": "string",
					"description": "Optional: net name this annotation relates to"
				}
			},
			"required": ["editor_name", "type", "positions"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_list_annotations",
		"List all annotations on a PCB, optionally filtered by author.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"author": {
					"type": "string",
					"description": "Optional filter by author: 'human', 'ai', or omit for all"
				}
			},
			"required": ["editor_name"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_remove_annotation",
		"Remove a specific annotation by ID.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"annotation_id": {
					"type": "string",
					"description": "ID of the annotation to remove"
				}
			},
			"required": ["editor_name", "annotation_id"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_clear_annotations",
		"Clear annotations from the PCB, optionally filtered by author.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"author": {
					"type": "string",
					"description": "Optional: clear only annotations by 'human' or 'ai'. Omit to clear all."
				}
			},
			"required": ["editor_name"]
		}
	, "pcb")

	# Route hint tools
	server._register_tool("minerva_pcb_add_route_hint",
		"Add a routing hint to suggest trace paths. Supports waypoint-only hints, single trace hints, and bus hints with varying levels of detail. Positions use {x,y} coordinates. Requires editor_name from minerva_list_editors.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"hint_type": {
					"type": "string",
					"enum": ["waypoint", "single_trace", "bus"],
					"description": "Type of hint: 'waypoint' (just bend points), 'single_trace' (one net), 'bus' (parallel traces)"
				},
				"source_pins": {
					"type": "array",
					"items": {"type": "string"},
					"description": "Source pin(s) in format 'Component.Pin' (e.g., ['U1.15'] or ['U1.15', 'U1.16', 'U1.17'])"
				},
				"dest_pins": {
					"type": "array",
					"items": {"type": "string"},
					"description": "Destination pin(s) in format 'Component.Pin'"
				},
				"waypoints": {
					"type": "array",
					"items": {"type": "object", "properties": {"x": {"type": "number"}, "y": {"type": "number"}}},
					"description": "Waypoints/bend points for the route path"
				},
				"layer": {
					"type": "string",
					"description": "Target layer (e.g., 'F.Cu', 'B.Cu'). Empty = unspecified."
				},
				"width": {
					"type": "number",
					"description": "Trace width in mm. 0 = use default."
				},
				"bus_spacing": {
					"type": "number",
					"description": "Spacing between bus traces in mm (for bus hints). 0 = use default."
				},
				"text": {
					"type": "string",
					"description": "Additional notes or description"
				},
				"client_id": {
					"type": "string",
					"description": "Optional idempotency key. If a hint with this client_id already exists, the existing hint is returned instead of creating a duplicate."
				}
			},
			"required": ["editor_name", "hint_type"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_list_route_hints",
		"List all routing hints on a PCB, optionally filtered by author.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"author": {
					"type": "string",
					"description": "Optional: filter by 'human' or 'ai'"
				}
			},
			"required": ["editor_name"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_remove_route_hint",
		"Remove a specific routing hint by ID.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"hint_id": {
					"type": "string",
					"description": "ID of the route hint to remove"
				}
			},
			"required": ["editor_name", "hint_id"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_clear_route_hints",
		"Clear routing hints from the PCB, optionally filtered by author.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"author": {
					"type": "string",
					"description": "Optional: clear only hints by 'human' or 'ai'. Omit to clear all."
				}
			},
			"required": ["editor_name"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_interpret_route_hints",
		"Interpret freeform annotations (arrows, polylines, text) as routing hints. Returns structured route hints inferred from annotation positions and text patterns.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				}
			},
			"required": ["editor_name"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_get_image",
		"Export a PCB view as a base64-encoded PNG image for LLM viewing.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"width": {
					"type": "integer",
					"description": "Image width in pixels. Default: 800"
				},
				"height": {
					"type": "integer",
					"description": "Image height in pixels. Default: 600"
				},
				"show_grid": {
					"type": "boolean",
					"description": "Show alignment grid. Default: current setting"
				},
				"show_ratsnest": {
					"type": "boolean",
					"description": "Show unrouted connections. Default: current setting"
				},
				"show_annotations": {
					"type": "boolean",
					"description": "Show annotations. Default: current setting"
				},
				"show_route_hints": {
					"type": "boolean",
					"description": "Show route hints. Default: current setting"
				}
			},
			"required": ["editor_name"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_create_note",
		"Create a note from a PCB editor. The note displays the PCB as an image preview. Clicking Edit restores the full PCB state (components, nets, annotations, route hints).",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"note_title": {
					"type": "string",
					"description": "Title for the new note. Defaults to editor name if not provided"
				},
				"thread_name": {
					"type": "string",
					"description": "Name of the notes thread/tab to add the note to. Defaults to 'PCB Boards'"
				}
			},
			"required": ["editor_name"]
		}
	, "pcb")

	server._register_tool("minerva_pcb_get_change_journal",
		"Get the change journal for a PCB editor. Returns an append-only log of forward actions (moves, rotations, deletions, etc.) with timestamps.",
		{
			"type": "object",
			"properties": {
				"editor_name": {
					"type": "string",
					"description": "Name of the PCB editor tab"
				},
				"since_timestamp": {
					"type": "number",
					"description": "Optional Unix timestamp to filter entries from. Only entries at or after this time are returned."
				},
				"limit": {
					"type": "integer",
					"description": "Maximum number of entries to return (most recent). Default: 50"
				}
			},
			"required": ["editor_name"]
		}
	, "pcb")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_create_pcb_editor":
			return _create_pcb_editor(arguments)
		"minerva_pcb_set_board_size":
			return _pcb_set_board_size(arguments)
		"minerva_pcb_get_components":
			return _pcb_get_components(arguments)
		"minerva_pcb_describe_component":
			return _pcb_describe_component(arguments)
		"minerva_pcb_spatial_query":
			return _pcb_spatial_query(arguments)
		"minerva_pcb_get_nets":
			return _pcb_get_nets(arguments)
		"minerva_pcb_add_component":
			return _pcb_add_component(arguments)
		"minerva_pcb_move_component":
			return _pcb_move_component(arguments)
		"minerva_pcb_move_relative":
			return _pcb_move_relative(arguments)
		"minerva_pcb_rotate_component":
			return _pcb_rotate_component(arguments)
		"minerva_pcb_delete_component":
			return _pcb_delete_component(arguments)
		"minerva_pcb_connect_net":
			return _pcb_connect_net(arguments)
		"minerva_pcb_export_csv":
			return _pcb_export_csv(arguments)
		"minerva_pcb_export_yaml":
			return _pcb_export_yaml(arguments)
		"minerva_pcb_import_csv":
			return _pcb_import_csv(arguments)
		"minerva_pcb_import_footprint_geometry":
			return _pcb_import_footprint_geometry(arguments)
		"minerva_pcb_import_trace_geometry":
			return _pcb_import_trace_geometry(arguments)
		"minerva_pcb_export_trace_geometry":
			return _pcb_export_trace_geometry(arguments)
		"minerva_pcb_add_annotation":
			return _pcb_add_annotation(arguments)
		"minerva_pcb_list_annotations":
			return _pcb_list_annotations(arguments)
		"minerva_pcb_remove_annotation":
			return _pcb_remove_annotation(arguments)
		"minerva_pcb_clear_annotations":
			return _pcb_clear_annotations(arguments)
		"minerva_pcb_add_route_hint":
			return _pcb_add_route_hint(arguments)
		"minerva_pcb_list_route_hints":
			return _pcb_list_route_hints(arguments)
		"minerva_pcb_remove_route_hint":
			return _pcb_remove_route_hint(arguments)
		"minerva_pcb_clear_route_hints":
			return _pcb_clear_route_hints(arguments)
		"minerva_pcb_interpret_route_hints":
			return _pcb_interpret_route_hints(arguments)
		"minerva_pcb_get_change_journal":
			return _pcb_get_change_journal(arguments)
		"minerva_pcb_get_pin_position":
			return _pcb_get_pin_position(arguments)
		"minerva_pcb_get_image":
			return await _pcb_get_image(arguments)
		"minerva_pcb_create_note":
			return await _pcb_create_note(arguments)
	return MCPToolUtils.error("Unknown PCB tool: %s" % tool_name)


#region Helpers

## Find a PCB editor by name. Returns the inner PCBEditor panel or null.

	var clean_name = name_.strip_edges()

	# Look for PCB editor type
	for editor in editor_pane.get_open_editors():
		if editor.type == Editor.Type.PCB and editor.tab_title == clean_name:
			return editor.pcb_editor

	# Case-insensitive match
	var lower_name = clean_name.to_lower()
	for editor in editor_pane.get_open_editors():
		if editor.type == Editor.Type.PCB and editor.tab_title.to_lower() == lower_name:
			return editor.pcb_editor

	return null


## Helper: find nearest component to a position within max_distance.
func _find_nearest_component(pos: Vector2, component_positions: Dictionary, max_distance: float = 20.0) -> String:
	var nearest_id := ""
	var nearest_dist := max_distance

	for comp_id in component_positions:
		var comp_pos: Vector2 = component_positions[comp_id]
		var dist := pos.distance_to(comp_pos)
		if dist < nearest_dist:
			nearest_dist = dist
			nearest_id = comp_id

	return nearest_id


## Helper: connect trace segments into polylines.
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

		# Try to extend the polyline by finding connected segments
		var changed := true
		while changed:
			changed = false
			for j in range(segments.size()):
				if used[j]:
					continue

				var seg = segments[j]
				# Check if segment connects to end of polyline
				if seg.start.distance_to(polyline[polyline.size() - 1]) < 0.01:
					polyline.append(seg.end)
					used[j] = true
					changed = true
				elif seg.end.distance_to(polyline[polyline.size() - 1]) < 0.01:
					polyline.append(seg.start)
					used[j] = true
					changed = true
				# Check if segment connects to start of polyline
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

#endregion


#region Tool Implementations

## Create a new PCB editor
func _create_pcb_editor(args: Dictionary) -> Dictionary:
	var name_: String = args.get("name", "")
	var board_width: float = args.get("board_width", 100.0)
	var board_height: float = args.get("board_height", 100.0)

	if name_.is_empty():
		return MCPToolUtils.error("name is required")

	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return MCPToolUtils.error("Editor pane not available")

	# Create new PCB editor tab
	var editor = editor_pane.add_pcb_editor(name_)
	if not editor or not editor.pcb_editor:
		return MCPToolUtils.error("Failed to create PCB editor")

	# Set board size
	var data = editor.pcb_editor.get_data()
	if data:
		data.board_width = board_width
		data.board_height = board_height
		data.board_name = name_

	return {
		"success": true,
		"editor_name": name_,
		"board_width": board_width,
		"board_height": board_height
	}


## Set board dimensions
func _pcb_set_board_size(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var width: float = args.get("width", 100.0)
	var height: float = args.get("height", 100.0)

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var data = pcb_editor.get_data()
	if not data:
		return MCPToolUtils.error("PCB data not available")

	data.board_width = width
	data.board_height = height
	data.data_changed.emit()

	return {
		"success": true,
		"board_width": width,
		"board_height": height
	}


## Get all components from a PCB
func _pcb_get_components(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var data = pcb_editor.get_data()
	if not data:
		return MCPToolUtils.error("PCB data not available")

	var components: Array = []
	for comp_id in data.components:
		var comp = data.components[comp_id]
		var comp_info := {
			"id": comp.id,
			"footprint": PCBComponentScript.FootprintType.keys()[comp.footprint],
			"x": comp.position.x,
			"y": comp.position.y,
			"rotation": comp.rotation,
			"layer": comp.layer,
			"pins": comp.pins.keys()
		}
		if comp.properties.has("value"):
			comp_info["value"] = comp.properties["value"]
		components.append(comp_info)

	return {
		"success": true,
		"component_count": components.size(),
		"components": components
	}


## Describe component context
func _pcb_describe_component(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var component_id: String = args.get("component_id", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")
	if component_id.is_empty():
		return MCPToolUtils.error("component_id is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var context = pcb_editor.describe_component(component_id)
	if context.is_empty():
		return MCPToolUtils.error("Component not found: %s" % component_id)

	context["success"] = true
	return context


## Spatial query
func _pcb_spatial_query(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var reference_component: String = args.get("reference_component", "")
	var radius: float = args.get("radius_mm", 20.0)

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	if reference_component.is_empty():
		# Return all components if no reference
		return _pcb_get_components(args)

	var nearby = pcb_editor.get_nearby_components(reference_component, radius)
	var results: Array = []

	var spatial_index = pcb_editor.get_spatial_index()
	for comp_id in nearby:
		var desc = spatial_index.describe_relative_position(reference_component, comp_id)
		results.append({
			"id": comp_id,
			"relationship": desc
		})

	return {
		"success": true,
		"reference": reference_component,
		"radius_mm": radius,
		"nearby_count": results.size(),
		"nearby": results
	}


## Get all nets
func _pcb_get_nets(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var data = pcb_editor.get_data()
	if not data:
		return MCPToolUtils.error("PCB data not available")

	var nets_arr: Array = []
	for net_name in data.nets:
		var net = data.nets[net_name]
		var pins_arr: Array = []
		for pin in net.pins:
			pins_arr.append("%s.%s" % [pin.get("component_id", ""), pin.get("pin_name", "")])

		nets_arr.append({
			"name": net.name,
			"pins": pins_arr,
			"is_power": net.is_power_net
		})

	return {
		"success": true,
		"net_count": nets_arr.size(),
		"nets": nets_arr
	}


## Get pin world position and info
func _pcb_get_pin_position(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var component_id: String = args.get("component_id", "")
	var pin: String = args.get("pin", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")
	if component_id.is_empty():
		return MCPToolUtils.error("component_id is required")
	if pin.is_empty():
		return MCPToolUtils.error("pin is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var data = pcb_editor.get_data()
	if not data:
		return MCPToolUtils.error("PCB data not available")

	var comp = data.get_component(component_id)
	if not comp:
		return MCPToolUtils.error("Component not found: %s" % component_id)

	# Build available pins list for self-correction on error
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
			"available_pins": available_pins
		}

	var world_pos: Vector2 = comp.get_pin_world_position(pin)
	var symbolic_name: String = comp.get_pin_name(pin)

	var result := {
		"success": true,
		"world_position": {"x": float(world_pos.x), "y": float(world_pos.y)},
		"component_position": {"x": float(comp.position.x), "y": float(comp.position.y)},
		"component_rotation": float(comp.rotation),
		"pin": str(pin),
		"pin_name": symbolic_name,
		"available_pins": available_pins
	}

	return result


## Add a component
func _pcb_add_component(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var footprint_str: String = args.get("footprint", "")
	var x: float = float(args.get("x", 50.0))
	var y: float = float(args.get("y", 50.0))

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")
	if footprint_str.is_empty():
		return MCPToolUtils.error("footprint is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var data = pcb_editor.get_data()
	if not data:
		return MCPToolUtils.error("PCB data not available")

	# Parse footprint type
	var footprint_idx := PCBComponentScript.FootprintType.keys().find(footprint_str.to_upper())
	if footprint_idx < 0:
		return MCPToolUtils.error("Invalid footprint type: %s" % footprint_str)

	# Create component
	var component_id: String = args.get("id", "")
	if component_id.is_empty():
		var prefix = footprint_str[0] if footprint_str.length() > 0 else "U"
		component_id = data.generate_component_id(prefix)

	var comp = PCBComponentScript.new()
	comp.id = component_id
	comp.footprint = footprint_idx
	# Use exact position if snap_to_grid is false, otherwise snap
	var snap: bool = args.get("snap_to_grid", true)
	if snap:
		comp.position = data.snap_to_grid(Vector2(x, y))
	else:
		comp.position = Vector2(x, y)
	comp.rotation = float(args.get("rotation", 0.0))

	# Setup pins based on footprint type and optional pin_count
	var pin_count: int = args.get("pin_count", 0)
	var pin_names: Array = args.get("pin_names", [])

	if pin_count > 0:
		# Custom pin count specified — specialised methods for HEADER/DIP/MODULE,
		# generic layout for everything else (SWITCH, RESISTOR, LED, etc.)
		var pad_type: String = args.get("pad_type", "tht")
		var pad_spacing: float = float(args.get("pad_spacing", 2.54))
		var row_sp: float = float(args.get("row_spacing", 7.62))
		match footprint_idx:
			PCBComponentScript.FootprintType.HEADER, PCBComponentScript.FootprintType.CONNECTOR:
				comp.setup_header_pins(pin_count, pin_names)
			PCBComponentScript.FootprintType.IC_DIP:
				comp.setup_dip_pins(pin_count)
			PCBComponentScript.FootprintType.MODULE:
				# MODULE uses wider row spacing and body extends beyond pins
				comp.setup_module_pins(pin_count)
			_:
				comp.setup_generic_pins(pin_count, pad_type, pad_spacing, row_sp)
	else:
		comp.setup_standard_pins()

	# Apply custom size if specified (use set_size to update local_bounds too)
	var custom_width: float = float(args.get("width", comp.width))
	var custom_height: float = float(args.get("height", comp.height))
	if args.has("width") or args.has("height"):
		comp.set_size(custom_width, custom_height)

	if args.has("value"):
		comp.properties["value"] = args.get("value")

	data.save_to_history("Add " + component_id)
	data.add_component(comp)

	return {
		"success": true,
		"component_id": component_id,
		"x": comp.position.x,
		"y": comp.position.y,
		"pin_count": comp.pins.size()
	}


## Move component absolute
func _pcb_move_component(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var component_id: String = args.get("component_id", "")
	var x: float = args.get("x", 0.0)
	var y: float = args.get("y", 0.0)

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")
	if component_id.is_empty():
		return MCPToolUtils.error("component_id is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var data = pcb_editor.get_data()
	if not data:
		return MCPToolUtils.error("PCB data not available")

	if not data.has_component(component_id):
		return MCPToolUtils.error("Component not found: %s" % component_id)

	var new_pos = data.snap_to_grid(Vector2(x, y))
	data.save_to_history("Move " + component_id)
	data.move_component(component_id, new_pos)

	return {
		"success": true,
		"component_id": component_id,
		"x": new_pos.x,
		"y": new_pos.y
	}


## Move component relative
func _pcb_move_relative(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var component_id: String = args.get("component_id", "")
	var direction: String = args.get("direction", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")
	if component_id.is_empty():
		return MCPToolUtils.error("component_id is required")
	if direction.is_empty():
		return MCPToolUtils.error("direction is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var new_pos = pcb_editor.move_component_relative(component_id, direction)

	return {
		"success": true,
		"component_id": component_id,
		"new_x": new_pos.x,
		"new_y": new_pos.y,
		"interpreted_direction": direction
	}


## Rotate component
func _pcb_rotate_component(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var component_id: String = args.get("component_id", "")
	var degrees = args.get("degrees", 90)

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")
	if component_id.is_empty():
		return MCPToolUtils.error("component_id is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var data = pcb_editor.get_data()
	if not data:
		return MCPToolUtils.error("PCB data not available")

	var comp = data.get_component(component_id)
	if not comp:
		return MCPToolUtils.error("Component not found: %s" % component_id)

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

	return {
		"success": true,
		"component_id": component_id,
		"rotation": new_rotation
	}


## Delete component
func _pcb_delete_component(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var component_id: String = args.get("component_id", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")
	if component_id.is_empty():
		return MCPToolUtils.error("component_id is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var data = pcb_editor.get_data()
	if not data:
		return MCPToolUtils.error("PCB data not available")

	if not data.has_component(component_id):
		return MCPToolUtils.error("Component not found: %s" % component_id)

	data.save_to_history("Delete " + component_id)
	data.remove_component(component_id)

	return {
		"success": true,
		"deleted": component_id
	}


## Connect pins to net
func _pcb_connect_net(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var net_name: String = args.get("net_name", "")
	var pins: Array = args.get("pins", [])

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")
	if net_name.is_empty():
		return MCPToolUtils.error("net_name is required")
	if pins.is_empty():
		return MCPToolUtils.error("pins array is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var data = pcb_editor.get_data()
	if not data:
		return MCPToolUtils.error("PCB data not available")

	# Collect operations first
	var operations: Array = []
	for pin_info in pins:
		if pin_info is Dictionary:
			var comp_id: String = pin_info.get("component", "")
			var pin_name: String = pin_info.get("pin", "")
			if not comp_id.is_empty() and not pin_name.is_empty():
				operations.append({"component": comp_id, "pin": pin_name})

	# Build result and test serialization before committing
	var connected: Array = []
	for op in operations:
		connected.append("%s.%s" % [str(op.component), str(op.pin)])

	var result := {
		"success": true,
		"net_name": str(net_name),
		"connected_pins": connected
	}
	var test_json := JSON.stringify(result)
	if test_json.is_empty():
		return MCPToolUtils.error("Internal serialization error")

	# Commit all operations
	for op in operations:
		data.connect_pin_to_net(net_name, op.component, op.pin)

	return result


## Export CSV
func _pcb_export_csv(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var csv = pcb_editor.export_csv()
	return {
		"success": true,
		"csv": csv
	}


## Export YAML
func _pcb_export_yaml(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var yaml = pcb_editor.export_yaml()
	return {
		"success": true,
		"yaml": yaml
	}


## Import CSV
func _pcb_import_csv(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var csv_content: String = args.get("csv_content", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")
	if csv_content.is_empty():
		return MCPToolUtils.error("csv_content is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	pcb_editor.import_csv(csv_content)

	var data = pcb_editor.get_data()
	return {
		"success": true,
		"component_count": data.get_component_count() if data else 0
	}


## Import footprint geometry from pcb-architect
func _pcb_import_footprint_geometry(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var geometry_data: Dictionary = args.get("geometry", {})
	var position_is_center: bool = args.get("position_is_center", false)
	var invert_y: bool = args.get("invert_y", false)

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")
	if geometry_data.is_empty():
		return MCPToolUtils.error("geometry data is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var data = pcb_editor.get_data()
	if not data:
		return MCPToolUtils.error("PCB data not available")

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
			# First load the pad geometry (this sets bbox_center_offset)
			comp.load_pad_geometry(comp_geometry)
			updated_count += 1

			# Then apply position corrections if requested
			if position_is_center or invert_y:
				var new_pos: Vector2 = comp.position

				# Order matters: first invert Y, then convert from center to origin

				# If Y is inverted (Y=0 at bottom), flip relative to board height
				if invert_y:
					new_pos.y = data.board_height - new_pos.y

				# If positions are geometric centers, convert to footprint origin
				# by subtracting the center offset (accounting for rotation)
				if position_is_center:
					var xform: Transform2D = comp.get_transform()
					var center_offset: Vector2 = xform * comp.bbox_center_offset
					new_pos -= center_offset

				comp.position = new_pos
				position_adjusted_count += 1
		else:
			missing.append(comp_id)

	# Save history so this operation can be undone
	data.save_to_history("Import footprint geometry")

	# Trigger redraw and zoom to fit the updated layout
	data.data_changed.emit()
	if pcb_editor.canvas:
		pcb_editor.canvas.zoom_to_fit()

	var result := {
		"success": true,
		"updated_count": updated_count,
		"missing_footprints": missing,
		"board_name": geometry_data.get("board_name", "")
	}

	if position_is_center or invert_y:
		result["position_adjusted_count"] = position_adjusted_count
		result["position_corrections_applied"] = {
			"position_is_center": position_is_center,
			"invert_y": invert_y,
			"board_height": data.board_height
		}

	return result


## Import trace geometry from pcb-architect
func _pcb_import_trace_geometry(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var trace_data: Dictionary = args.get("trace_data", {})

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")
	if trace_data.is_empty():
		return MCPToolUtils.error("trace_data is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var data = pcb_editor.get_data()
	if not data:
		return MCPToolUtils.error("PCB data not available")

	# Clear existing traces
	data.clear_traces()

	# Group trace segments by net and layer into polylines
	var traces_input: Array = trace_data.get("traces", [])
	var trace_groups: Dictionary = {}  # "net_layer" -> {net_name, layer, width, segments}

	for seg in traces_input:
		var net_name: String = seg.get("net_name", "")
		var layer: String = seg.get("layer", "F.Cu")
		var key := "%s_%s" % [net_name, layer]

		if not trace_groups.has(key):
			trace_groups[key] = {
				"net_name": net_name,
				"layer": "top" if layer == "F.Cu" else "bottom",
				"width": seg.get("width", 0.3),
				"segments": []
			}

		var start = seg.get("start", {})
		var end_pt = seg.get("end", {})
		trace_groups[key].segments.append({
			"start": Vector2(start.get("x", 0), start.get("y", 0)),
			"end": Vector2(end_pt.get("x", 0), end_pt.get("y", 0))
		})

	# Convert segment groups to PCBTrace objects with connected waypoints
	var trace_count := 0
	for key in trace_groups:
		var group = trace_groups[key]
		var segments: Array = group.segments

		# Build connected polylines from segments
		var polylines := _build_polylines_from_segments(segments)

		for polyline in polylines:
			if polyline.size() < 2:
				continue

			var trace := PCBTraceScript.new()
			trace.id = "trace_%d" % trace_count
			trace.net_name = group.net_name
			trace.layer = group.layer
			trace.width = group.width

			for point in polyline:
				trace.waypoints.append(point)

			data.add_trace(trace)
			trace_count += 1

	# Import vias
	var vias_input: Array = trace_data.get("vias", [])
	for via_data in vias_input:
		var pos = via_data.get("position", {})
		data.add_via({
			"position": Vector2(pos.get("x", 0), pos.get("y", 0)),
			"size": via_data.get("size", 0.8),
			"drill": via_data.get("drill", 0.4),
			"net_name": via_data.get("net_name", ""),
			"layers": via_data.get("layers", ["F.Cu", "B.Cu"])
		})

	# Save history so this operation can be undone/redone
	data.save_to_history("Import traces")

	if pcb_editor.canvas:
		pcb_editor.canvas.queue_redraw()
		pcb_editor.canvas.zoom_to_fit()

	return {
		"success": true,
		"trace_count": trace_count,
		"via_count": vias_input.size()
	}


## Export trace geometry from a PCB editor
func _pcb_export_trace_geometry(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var data = pcb_editor.get_data()
	if not data:
		return MCPToolUtils.error("PCB data not available")

	# Export traces: expand polyline waypoints to individual segments
	var traces_output: Array = []
	var trace_ids = data.get_trace_ids()

	for trace_id in trace_ids:
		var trace = data.get_trace(trace_id)
		if not trace:
			continue

		# Convert internal layer names to KiCad-style
		var layer_name: String = "F.Cu" if trace.layer == "top" else "B.Cu"

		# Expand waypoints into individual segments
		for i in range(trace.waypoints.size() - 1):
			var start_pt: Vector2 = trace.waypoints[i]
			var end_pt: Vector2 = trace.waypoints[i + 1]

			traces_output.append({
				"start": {"x": snapped(start_pt.x, 0.0001), "y": snapped(start_pt.y, 0.0001)},
				"end": {"x": snapped(end_pt.x, 0.0001), "y": snapped(end_pt.y, 0.0001)},
				"width": trace.width,
				"layer": layer_name,
				"net_name": trace.net_name
			})

	# Export vias
	var vias_output: Array = []
	for via in data.vias:
		var pos: Vector2 = via.get("position", Vector2.ZERO)
		vias_output.append({
			"position": {"x": snapped(pos.x, 0.0001), "y": snapped(pos.y, 0.0001)},
			"size": via.get("size", 0.8),
			"drill": via.get("drill", 0.4),
			"net_name": via.get("net_name", ""),
			"layers": via.get("layers", ["F.Cu", "B.Cu"])
		})

	return {
		"success": true,
		"trace_count": traces_output.size(),
		"via_count": vias_output.size(),
		"trace_data": {
			"traces": traces_output,
			"vias": vias_output
		}
	}


## Add annotation
func _pcb_add_annotation(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var type_str: String = args.get("type", "")
	var positions_arr: Array = args.get("positions", [])
	var text_content: String = args.get("text", "")
	var color_str: String = args.get("color", "")
	var associated_comp: String = args.get("associated_component", "")
	var associated_net: String = args.get("associated_net", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")
	if type_str.is_empty():
		return MCPToolUtils.error("type is required (arrow, text, region, polyline)")
	if positions_arr.is_empty():
		return MCPToolUtils.error("positions array is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var data = pcb_editor.get_data()
	if not data:
		return MCPToolUtils.error("PCB data not available")

	# Convert positions
	var positions: Array[Vector2] = []
	for pos_data in positions_arr:
		if pos_data is Dictionary:
			positions.append(Vector2(pos_data.get("x", 0), pos_data.get("y", 0)))

	# Create annotation based on type
	var annotation: PCBAnnotationScript = null
	match type_str.to_lower():
		"arrow":
			if positions.size() < 2:
				return MCPToolUtils.error("arrow requires 2 positions (start, end)")
			annotation = PCBAnnotationScript.create_arrow(positions[0], positions[1], text_content, "ai")
		"text":
			if positions.size() < 1:
				return MCPToolUtils.error("text requires 1 position")
			if text_content.is_empty():
				return MCPToolUtils.error("text annotation requires text content")
			annotation = PCBAnnotationScript.create_text(positions[0], text_content, "ai")
		"region":
			if positions.size() < 2:
				return MCPToolUtils.error("region requires 2 positions (corners)")
			annotation = PCBAnnotationScript.create_region(positions[0], positions[1], text_content, "ai")
		"polyline":
			if positions.size() < 2:
				return MCPToolUtils.error("polyline requires at least 2 positions")
			annotation = PCBAnnotationScript.create_polyline(positions, text_content, "ai")
		_:
			return MCPToolUtils.error("Unknown annotation type: %s" % type_str)

	# Apply optional settings
	if not color_str.is_empty():
		annotation.color = Color.from_string(color_str, annotation.color)
	if not associated_comp.is_empty():
		annotation.associated_component = associated_comp
	if not associated_net.is_empty():
		annotation.associated_net = associated_net

	# Transactional: build result and test serialization before committing
	var result := {
		"success": true,
		"annotation_id": str(annotation.id),
		"type": str(type_str),
		"description": str(annotation.get_description())
	}
	var test_json := JSON.stringify(result)
	if test_json.is_empty():
		return MCPToolUtils.error("Internal serialization error")

	data.add_annotation(annotation)
	return result


## List annotations
func _pcb_list_annotations(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var author_filter: String = args.get("author", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var data = pcb_editor.get_data()
	if not data:
		return MCPToolUtils.error("PCB data not available")

	var annotations_list: Array = []
	var all_annotations: Array

	if author_filter.is_empty():
		all_annotations = data.get_all_annotations()
	else:
		all_annotations = data.get_annotations_by_author(author_filter)

	for ann in all_annotations:
		# Convert positions to serializable format
		var positions_arr: Array = []
		for pos in ann.positions:
			positions_arr.append({"x": pos.x, "y": pos.y})

		var ann_data := {
			"id": ann.id,
			"type": PCBAnnotationScript.AnnotationType.keys()[ann.type],
			"positions": positions_arr,
			"text": ann.text,
			"author": ann.author,
			"color": ann.color.to_html()
		}
		if not ann.associated_component.is_empty():
			ann_data["associated_component"] = ann.associated_component
		if not ann.associated_net.is_empty():
			ann_data["associated_net"] = ann.associated_net
		annotations_list.append(ann_data)

	return {
		"success": true,
		"count": annotations_list.size(),
		"annotations": annotations_list
	}


## Remove annotation
func _pcb_remove_annotation(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var annotation_id: String = args.get("annotation_id", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")
	if annotation_id.is_empty():
		return MCPToolUtils.error("annotation_id is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var data = pcb_editor.get_data()
	if not data:
		return MCPToolUtils.error("PCB data not available")

	if not data.get_annotation(annotation_id):
		return MCPToolUtils.error("Annotation not found: %s" % annotation_id)

	data.remove_annotation(annotation_id)

	return {
		"success": true,
		"removed": annotation_id
	}


## Clear annotations
func _pcb_clear_annotations(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var author_filter: String = args.get("author", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var data = pcb_editor.get_data()
	if not data:
		return MCPToolUtils.error("PCB data not available")

	# Count before clearing
	var count_before := 0
	if author_filter.is_empty():
		count_before = data.get_all_annotations().size()
	else:
		count_before = data.get_annotations_by_author(author_filter).size()

	data.clear_annotations(author_filter)

	return {
		"success": true,
		"cleared_count": count_before,
		"filter": author_filter if not author_filter.is_empty() else "all"
	}


## Add a routing hint
func _pcb_add_route_hint(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var hint_type_str: String = args.get("hint_type", "")
	var source_pins_arr: Array = args.get("source_pins", [])
	var dest_pins_arr: Array = args.get("dest_pins", [])
	var waypoints_arr: Array = args.get("waypoints", [])
	var layer: String = args.get("layer", "")
	var width: float = args.get("width", 0.0)
	var bus_spacing: float = args.get("bus_spacing", 0.0)
	var text: String = args.get("text", "")
	var client_id: String = args.get("client_id", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")
	if hint_type_str.is_empty():
		return MCPToolUtils.error("hint_type is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var data = pcb_editor.get_data()
	if not data:
		return MCPToolUtils.error("PCB data not available")

	# Convert waypoints to Vector2 array
	var waypoints: Array[Vector2] = []
	for wp_data in waypoints_arr:
		if wp_data is Dictionary:
			waypoints.append(Vector2(wp_data.get("x", 0), wp_data.get("y", 0)))

	# Convert pin arrays to typed arrays
	var source_pins: Array[String] = []
	for pin in source_pins_arr:
		source_pins.append(str(pin))
	var dest_pins: Array[String] = []
	for pin in dest_pins_arr:
		dest_pins.append(str(pin))

	# Create hint based on type
	var hint: PCBRouteHintScript
	match hint_type_str.to_lower():
		"waypoint":
			hint = PCBRouteHintScript.create_waypoint_hint(waypoints, text, "ai")
		"single_trace":
			if source_pins.is_empty() or dest_pins.is_empty():
				return MCPToolUtils.error("single_trace hint requires source_pins and dest_pins")
			if source_pins[0] == dest_pins[0]:
				return MCPToolUtils.error("single_trace hint cannot have the same source and destination pin: %s" % source_pins[0])
			hint = PCBRouteHintScript.create_single_trace_hint(
				source_pins[0], dest_pins[0], waypoints, layer, width, text, "ai"
			)
		"bus":
			if source_pins.is_empty() or dest_pins.is_empty():
				return MCPToolUtils.error("bus hint requires source_pins and dest_pins")
			if source_pins.size() != dest_pins.size():
				return MCPToolUtils.error("bus hint requires equal number of source and dest pins")
			hint = PCBRouteHintScript.create_bus_hint(
				source_pins, dest_pins, waypoints, layer, width, bus_spacing, text, "ai"
			)
		_:
			return MCPToolUtils.error("Invalid hint_type: %s. Must be 'waypoint', 'single_trace', or 'bus'" % hint_type_str)

	# Set layer if specified
	if not layer.is_empty():
		hint.layer = layer

	# Set client_id for idempotency
	if not client_id.is_empty():
		hint.client_id = client_id

	var created_id := hint.id
	var returned_hint = data.add_route_hint(hint)
	if returned_hint == null:
		return MCPToolUtils.error("Route hint was rejected (self-referencing)")

	var is_duplicate: bool = (returned_hint.id != created_id)

	var result := {
		"success": true,
		"hint_id": str(returned_hint.id),
		"hint_type": hint_type_str,
		"detail_level": str(PCBRouteHintScript.DetailLevel.keys()[returned_hint.detail_level]),
		"waypoint_count": int(waypoints.size()),
		"description": str(returned_hint.get_description())
	}
	if is_duplicate:
		result["duplicate"] = true

	# Transactional: test serialization before returning
	var test_json := JSON.stringify(result)
	if test_json.is_empty():
		return MCPToolUtils.error("Internal serialization error")

	return result


## List route hints
func _pcb_list_route_hints(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var author_filter: String = args.get("author", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var data = pcb_editor.get_data()
	if not data:
		return MCPToolUtils.error("PCB data not available")

	# First, just return count and IDs to test
	var hint_ids: Array = []
	for hint_id in data.route_hints:
		hint_ids.append(str(hint_id))

	if hint_ids.is_empty():
		return {"success": true, "count": 0, "hints": []}

	var hints_arr: Array = []
	for hint_id in data.route_hints:
		var hint = data.route_hints[hint_id]
		if not author_filter.is_empty() and hint.author != author_filter:
			continue

		# Convert typed arrays to regular arrays for JSON serialization
		var src_pins: Array = []
		for pin in hint.source_pins:
			src_pins.append(str(pin))
		var dst_pins: Array = []
		for pin in hint.dest_pins:
			dst_pins.append(str(pin))

		# Convert waypoints
		var waypoints_data: Array = []
		for wp in hint.waypoints:
			waypoints_data.append({"x": float(wp.x), "y": float(wp.y)})

		var hint_dict: Dictionary = {
			"id": str(hint.id),
			"hint_type": str(PCBRouteHintScript.HintType.keys()[hint.hint_type]),
			"detail_level": str(PCBRouteHintScript.DetailLevel.keys()[hint.detail_level]),
			"author": str(hint.author),
			"layer": str(hint.layer),
			"width": float(hint.width),
			"source_pins": src_pins,
			"dest_pins": dst_pins,
			"text": str(hint.text),
			"waypoints": waypoints_data
		}

		if hint.hint_type == PCBRouteHintScript.HintType.BUS:
			hint_dict["bus_spacing"] = float(hint.bus_spacing)

		hints_arr.append(hint_dict)

	return {
		"success": true,
		"count": hints_arr.size(),
		"hints": hints_arr
	}


## Remove a route hint
func _pcb_remove_route_hint(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var hint_id: String = args.get("hint_id", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")
	if hint_id.is_empty():
		return MCPToolUtils.error("hint_id is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var data = pcb_editor.get_data()
	if not data:
		return MCPToolUtils.error("PCB data not available")

	if not data.get_route_hint(hint_id):
		return MCPToolUtils.error("Route hint not found: %s" % hint_id)

	data.remove_route_hint(hint_id)

	return {
		"success": true,
		"removed": hint_id
	}


## Clear route hints
func _pcb_clear_route_hints(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var author_filter: String = args.get("author", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var data = pcb_editor.get_data()
	if not data:
		return MCPToolUtils.error("PCB data not available")

	# Count before clearing
	var count_before := 0
	if author_filter.is_empty():
		count_before = data.get_all_route_hints().size()
	else:
		count_before = data.get_route_hints_by_author(author_filter).size()

	data.clear_route_hints(author_filter)

	return {
		"success": true,
		"cleared_count": count_before,
		"filter": author_filter if not author_filter.is_empty() else "all"
	}


## Interpret freeform annotations as route hints
func _pcb_interpret_route_hints(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var data = pcb_editor.get_data()
	if not data:
		return MCPToolUtils.error("PCB data not available")

	# Get all annotations
	var annotations = data.get_all_annotations()
	var components = data.get_all_components()

	# Build component lookup by position for proximity matching
	var component_positions: Dictionary = {}  # component_id -> center position
	for comp in components:
		var center_x: float = comp.x + comp.width / 2.0
		var center_y: float = comp.y + comp.height / 2.0
		component_positions[comp.id] = Vector2(center_x, center_y)

	# Analyze annotations for routing hints
	var interpreted_hints: Array = []

	for annotation in annotations:
		var hint_info: Dictionary = {
			"annotation_id": annotation.id,
			"annotation_type": PCBAnnotationScript.AnnotationType.keys()[annotation.type],
			"author": annotation.author,
			"text": annotation.text,
			"interpretation": {}
		}

		match annotation.type:
			PCBAnnotationScript.AnnotationType.ARROW:
				# Arrow might indicate routing direction between components
				if annotation.positions.size() >= 2:
					var start: Vector2 = annotation.positions[0]
					var end: Vector2 = annotation.positions[1]
					hint_info["interpretation"]["start"] = {"x": start.x, "y": start.y}
					hint_info["interpretation"]["end"] = {"x": end.x, "y": end.y}
					hint_info["interpretation"]["direction_vector"] = {
						"x": end.x - start.x,
						"y": end.y - start.y
					}

					# Find nearest components to start and end
					var nearest_start := _find_nearest_component(start, component_positions)
					var nearest_end := _find_nearest_component(end, component_positions)
					if not nearest_start.is_empty():
						hint_info["interpretation"]["near_start_component"] = nearest_start
					if not nearest_end.is_empty():
						hint_info["interpretation"]["near_end_component"] = nearest_end

					hint_info["interpretation"]["suggested_use"] = "routing_direction"

			PCBAnnotationScript.AnnotationType.POLYLINE:
				# Polyline might be a trace path suggestion
				if annotation.positions.size() >= 2:
					var waypoints_data: Array = []
					for pos in annotation.positions:
						waypoints_data.append({"x": pos.x, "y": pos.y})
					hint_info["interpretation"]["waypoints"] = waypoints_data
					hint_info["interpretation"]["waypoint_count"] = annotation.positions.size()

					# Find components near start and end
					var start: Vector2 = annotation.positions[0]
					var end: Vector2 = annotation.positions[annotation.positions.size() - 1]
					var nearest_start := _find_nearest_component(start, component_positions)
					var nearest_end := _find_nearest_component(end, component_positions)
					if not nearest_start.is_empty():
						hint_info["interpretation"]["near_start_component"] = nearest_start
					if not nearest_end.is_empty():
						hint_info["interpretation"]["near_end_component"] = nearest_end

					hint_info["interpretation"]["suggested_use"] = "trace_path"

			PCBAnnotationScript.AnnotationType.TEXT:
				# Text might contain routing instructions
				hint_info["interpretation"]["position"] = {
					"x": annotation.positions[0].x if annotation.positions.size() > 0 else 0,
					"y": annotation.positions[0].y if annotation.positions.size() > 0 else 0
				}

				# Check for common routing keywords
				var text_lower: String = annotation.text.to_lower()
				var keywords: Array = []
				if "route" in text_lower:
					keywords.append("route")
				if "trace" in text_lower:
					keywords.append("trace")
				if "bus" in text_lower:
					keywords.append("bus")
				if "layer" in text_lower or "f.cu" in text_lower or "b.cu" in text_lower:
					keywords.append("layer")
				if "via" in text_lower:
					keywords.append("via")
				if not keywords.is_empty():
					hint_info["interpretation"]["routing_keywords"] = keywords

				# Find nearest component
				if annotation.positions.size() > 0:
					var nearest := _find_nearest_component(annotation.positions[0], component_positions)
					if not nearest.is_empty():
						hint_info["interpretation"]["near_component"] = nearest

				hint_info["interpretation"]["suggested_use"] = "instruction"

			PCBAnnotationScript.AnnotationType.REGION:
				# Region might highlight an area for routing consideration
				if annotation.positions.size() >= 2:
					hint_info["interpretation"]["bounds"] = {
						"min": {"x": annotation.positions[0].x, "y": annotation.positions[0].y},
						"max": {"x": annotation.positions[1].x, "y": annotation.positions[1].y}
					}

					# Find components within region
					var rect: Rect2 = annotation.get_bounding_rect()
					var components_in_region: Array = []
					for comp_id in component_positions:
						if rect.has_point(component_positions[comp_id]):
							components_in_region.append(comp_id)
					if not components_in_region.is_empty():
						hint_info["interpretation"]["components_in_region"] = components_in_region

					hint_info["interpretation"]["suggested_use"] = "routing_region"

		interpreted_hints.append(hint_info)

	return {
		"success": true,
		"annotation_count": annotations.size(),
		"interpretations": interpreted_hints,
		"note": "These are suggested interpretations. Use minerva_pcb_add_route_hint to create structured hints based on this analysis."
	}


## Get PCB change journal
func _pcb_get_change_journal(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var since_timestamp: float = args.get("since_timestamp", 0.0)
	var limit: int = args.get("limit", 50)

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	var data = pcb_editor.get_data()
	if not data:
		return MCPToolUtils.error("PCB data not available")

	var entries: Array = data.get_change_journal(since_timestamp)

	# Slice to limit (most recent entries)
	if limit > 0 and entries.size() > limit:
		entries = entries.slice(entries.size() - limit)

	return {
		"success": true,
		"total_entries": data.change_journal.size(),
		"returned_entries": entries.size(),
		"entries": entries
	}


## Export PCB view as base64-encoded PNG image
func _pcb_get_image(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var width: int = args.get("width", 800)
	var height: int = args.get("height", 600)

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	if not pcb_editor.canvas:
		return MCPToolUtils.error("PCB canvas not available")

	var canvas = pcb_editor.canvas
	var data = pcb_editor.get_data()

	# Store original display settings to restore after capture
	var orig_show_grid: bool = canvas.show_grid
	var orig_show_ratsnest: bool = canvas.show_ratsnest
	var orig_show_annotations: bool = canvas.show_annotations
	var orig_show_route_hints: bool = canvas.show_route_hints

	# Apply temporary overrides if specified
	if args.has("show_grid"):
		canvas.show_grid = args.get("show_grid")
	if args.has("show_ratsnest"):
		canvas.show_ratsnest = args.get("show_ratsnest")
	if args.has("show_annotations"):
		canvas.show_annotations = args.get("show_annotations")
	if args.has("show_route_hints"):
		canvas.show_route_hints = args.get("show_route_hints")

	# Capture the image
	var base64_png: String = await canvas.capture_to_base64_png(width, height)

	# Restore original settings
	canvas.show_grid = orig_show_grid
	canvas.show_ratsnest = orig_show_ratsnest
	canvas.show_annotations = orig_show_annotations
	canvas.show_route_hints = orig_show_route_hints

	if base64_png.is_empty():
		return MCPToolUtils.error("Failed to capture PCB image")

	# Gather metadata about the board
	var metadata := {}
	if data:
		metadata["board_width_mm"] = data.board_width
		metadata["board_height_mm"] = data.board_height
		metadata["component_count"] = data.components.size()
		metadata["net_count"] = data.nets.size()
		if data.annotations:
			metadata["annotation_count"] = data.annotations.size()
		if data.route_hints:
			metadata["route_hint_count"] = data.route_hints.size()

	return {
		"success": true,
		"image_data": base64_png,
		"format": "png",
		"encoding": "base64",
		"width": width,
		"height": height,
		"metadata": metadata
	}


## Create a PCB note with full state restoration
func _pcb_create_note(args: Dictionary) -> Dictionary:
	var editor_name: String = args.get("editor_name", "")
	var note_title: String = args.get("note_title", "")
	var thread_name: String = args.get("thread_name", "PCB Boards")

	if editor_name.is_empty():
		return MCPToolUtils.error("editor_name is required")

	var pcb_editor = MCPToolUtils.find_pcb(editor_name)
	if not pcb_editor:
		return MCPToolUtils.error("PCB editor not found: %s" % editor_name)

	if not pcb_editor.canvas:
		return MCPToolUtils.error("PCB canvas not available")

	# Use editor name as note title if not provided
	if note_title.is_empty():
		note_title = editor_name

	# Capture image and get PCB data
	var pcb_image: Image = await pcb_editor.canvas.capture_to_image(800, 600)
	var pcb_data: Dictionary = pcb_editor.data.to_dict()

	# Create the PCB note with full state
	var note = NoteScript.create_pcb_note(note_title, pcb_image, pcb_data)

	# Find or create the notes thread
	var notes_container = SingletonObject.notes_container
	if not notes_container:
		return MCPToolUtils.error("Notes container not available")

	var thread_vbox = notes_container.find_or_create_tab(thread_name)
	thread_vbox.add_note(note)

	return {
		"success": true,
		"note_uuid": note.uuid,
		"note_title": note_title,
		"thread_name": thread_name,
		"component_count": pcb_data.get("components", {}).size(),
		"net_count": pcb_data.get("nets", {}).size(),
		"message": "Created PCB note '%s' in thread '%s'. Edit button restores full state." % [note_title, thread_name]
	}

#endregion

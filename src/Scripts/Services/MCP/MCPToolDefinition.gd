class_name MCPToolDefinition
extends Resource
## Represents an MCP tool definition with its schema and metadata.
## Used to describe tools available from MCP servers for LLM function calling.

## The unique name of the tool (e.g., "nudge_set_hint", "cobrowser_navigate")
@export var name: String = ""

## Human-readable description of what the tool does
@export var description: String = ""

## JSON Schema describing the tool's input parameters
@export var input_schema: Dictionary = {}
var output_schema: Dictionary = {}
var annotations: Dictionary = {}
var icons: Array[Dictionary] = []
var execution: Dictionary = {}

## The complete peer definition. Transport adapters use this value so fields
## unknown to this Minerva version survive discovery and re-export unchanged.
var original_definition: Dictionary = {}

## Name of the server that provides this tool
@export var server_name: String = ""

## Tool set this tool belongs to (e.g., "chat", "autocoder", "spreadsheet")
## Used for filtering tools by category. Empty string means uncategorized.
@export var tool_set: String = ""


## Convert to OpenAI function calling format
func to_openai_format() -> Dictionary:
	return {
		"type": "function",
		"function": {
			"name": name,
			"description": description,
			"parameters": input_schema
		}
	}


## Convert to Anthropic Claude tool use format
func to_anthropic_format() -> Dictionary:
	return {
		"name": name,
		"description": description,
		"input_schema": input_schema
	}


## Consumer schemas may be narrowed for an LLM API. Protocol validation and
## re-export always use the peer's original schemas.
func native_input_schema() -> Variant:
	if original_definition.has("inputSchema"):
		return _duplicate_variant(original_definition.inputSchema)
	return input_schema.duplicate(true)


func native_output_schema() -> Variant:
	if original_definition.has("outputSchema"):
		return _duplicate_variant(original_definition.outputSchema)
	return output_schema.duplicate(true)


static func _duplicate_variant(value: Variant) -> Variant:
	return value.duplicate(true) if value is Dictionary or value is Array else value


## Create a tool definition from a dictionary (e.g., from MCP server response)
static func from_dict(data: Dictionary, server: String = ""):
	var script = load("res://Scripts/Services/MCP/MCPToolDefinition.gd")
	var tool = script.new()
	tool.original_definition = data.duplicate(true)
	tool.name = str(data.get("name", ""))
	tool.description = str(data.get("description", ""))
	var input_value: Variant = data.get("inputSchema", data.get("input_schema", {}))
	tool.input_schema = input_value.duplicate(true) if input_value is Dictionary else {}
	var output_value: Variant = data.get("outputSchema", {})
	tool.output_schema = output_value.duplicate(true) if output_value is Dictionary else {}
	var annotations_value: Variant = data.get("annotations", {})
	tool.annotations = annotations_value.duplicate(true) if annotations_value is Dictionary else {}
	var icons_value: Variant = data.get("icons", [])
	if icons_value is Array:
		for icon in icons_value:
			if icon is Dictionary:
				tool.icons.append(icon.duplicate(true))
	var execution_value: Variant = data.get("execution", {})
	tool.execution = execution_value.duplicate(true) if execution_value is Dictionary else {}
	_sanitize_schema(tool.input_schema)
	tool.server_name = server
	return tool


## Return the exact peer definition when one exists. Host-authored definitions
## are assembled from the explicit fields without mutating consumer schemas.
func to_mcp_format() -> Dictionary:
	if not original_definition.is_empty():
		return original_definition.duplicate(true)
	var definition := {}
	definition["name"] = name
	definition["description"] = description
	definition["inputSchema"] = input_schema.duplicate(true)
	if not output_schema.is_empty():
		definition["outputSchema"] = output_schema.duplicate(true)
	if not annotations.is_empty():
		definition["annotations"] = annotations.duplicate(true)
	if not icons.is_empty():
		definition["icons"] = icons.duplicate(true)
	if not execution.is_empty():
		definition["execution"] = execution.duplicate(true)
	return definition


## Recursively fix array schemas missing "items" (required by LLM APIs)
static func _sanitize_schema(schema: Dictionary) -> void:
	var props_value: Variant = schema.get("properties", {})
	if not props_value is Dictionary:
		return
	var props: Dictionary = props_value
	for key in props:
		var prop_value: Variant = props[key]
		if not prop_value is Dictionary:
			# Draft 2020-12 permits boolean schemas at every schema position.
			continue
		var prop: Dictionary = prop_value
		if prop.get("type") == "array" and not prop.has("items"):
			prop["items"] = {"type": "string"}
		# Recurse into nested objects
		if prop.get("type") == "object" and prop.has("properties"):
			_sanitize_schema(prop)
		# Recurse into array items that are objects
		if prop.get("type") == "array" and prop.has("items") and prop["items"] is Dictionary:
			if prop["items"].get("type") == "object" and prop["items"].has("properties"):
				_sanitize_schema(prop["items"])

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


## Create a tool definition from a dictionary (e.g., from MCP server response)
static func from_dict(data: Dictionary, server: String = ""):
	var script = load("res://Scripts/Services/MCP/MCPToolDefinition.gd")
	var tool = script.new()
	tool.name = data.get("name", "")
	tool.description = data.get("description", "")
	tool.input_schema = data.get("inputSchema", data.get("input_schema", {}))
	tool.server_name = server
	return tool

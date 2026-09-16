extends SceneTree
## Exercise provider schema adaptation and wire preservation with nullable types.

var passed := 0
var failed := 0


func check(label: String, condition: bool) -> void:
	if condition:
		passed += 1
	else:
		failed += 1
		printerr("FAIL: ", label)


func _initialize() -> void:
	var Definition = load("res://Scripts/Services/MCP/MCPToolDefinition.gd")
	var peer := {
		"name": "nullable_parameters", "inputSchema": {"type": "object", "properties": {
			"text": {"type": ["string", "null"]},
			"tags": {"type": ["array", "null"]},
			"plain_tags": {"type": "array"},
			"options": {"type": ["object", "null"], "properties": {
				"tags": {"type": ["array", "null"]}}},
			"rows": {"type": ["array", "null"], "items": {
				"type": ["object", "null"], "properties": {"tags": {"type": "array"}}}},
			"plain_rows": {"type": "array", "items": {
				"type": ["object", "null"], "properties": {"tags": {"type": "array"}}}},
			"numbers": {"type": ["array", "null"], "items": {"type": ["number", "null"]}},
			"closed": {"type": ["array", "null"], "items": false},
			"untyped": {}, "allowed": true, "denied": false,
		}},
	}
	var original := peer.duplicate(true)
	var tool = Definition.from_dict(peer, "fixture")
	var props: Dictionary = tool.input_schema.properties
	check("nullable scalar and boolean schemas survive adaptation",
		props.text == original.inputSchema.properties.text
		and props.allowed == true and props.denied == false and props.untyped == {})
	check("plain and nullable arrays gain provider items without losing their type",
		props.tags.type == ["array", "null"] and props.tags.items == {"type": "string"}
		and props.plain_tags.items == {"type": "string"})
	check("nullable objects and array-item objects receive nested adaptation",
		props.options.properties.tags.items == {"type": "string"}
		and props.rows.items.properties.tags.items == {"type": "string"}
		and props.plain_rows.items.properties.tags.items == {"type": "string"})
	check("explicit union and boolean item schemas are retained",
		props.numbers == original.inputSchema.properties.numbers
		and props.closed == original.inputSchema.properties.closed)
	check("both provider formats use the adapted schema",
		tool.to_openai_format().function.parameters == tool.input_schema
		and tool.to_anthropic_format().input_schema == tool.input_schema)
	check("caller input, native schema and MCP re-export remain unchanged",
		peer == original and tool.native_input_schema() == original.inputSchema
		and tool.to_mcp_format() == original)
	print("\n=== Results: %d passed, %d failed ===" % [passed, failed])
	quit(1 if failed else 0)

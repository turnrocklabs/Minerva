class_name MCPJSONSchema
extends RefCounted
## Raw-preserving schema adapter. Callers explicitly compile again when the
## supervised helper generation invalidates a handle.

const ValidatorClient = preload("res://Scripts/Services/MCP/JSONSchemaValidatorClient.gd")

var client
var raw_schema := ""
var registry: Dictionary = {}
var handle


static func create(validator, schema_utf8: String,
		local_registry: Dictionary = {}):
	var schema = load("res://Scripts/Services/MCP/MCPJSONSchema.gd").new()
	schema.client = validator
	schema.raw_schema = schema_utf8
	schema.registry = local_registry.duplicate(true)
	return schema


func compile() -> Dictionary:
	var result: Dictionary = await client.compile(raw_schema, registry)
	if result.get("ok", false):
		handle = result.handle
	return result


func validate_raw(instance_utf8: String) -> Dictionary:
	if handle == null:
		return {"ok": false, "error": {"code": "not_compiled", "message": "schema is not compiled"}}
	return await client.validate_raw(handle, instance_utf8)


func validate_for_application(instance_utf8: String, parsed_value: Variant) -> Dictionary:
	if handle == null:
		return {"ok": false, "error": {"code": "not_compiled", "message": "schema is not compiled"}}
	return await client.validate_for_application(handle, instance_utf8, parsed_value)


func release() -> Dictionary:
	var result := {"ok": true}
	if handle != null:
		result = await client.release(handle)
		handle = null
	return result

class_name MCPPreferenceTools
extends MCPToolModule
## MCP tools for reading and writing host-owned settings (core + plugins).
## Thin wrappers over PluginSettingsStore — all validation, coercion, and
## persistence live in the store. scope is "core" or "plugin:<id>".

## Store override for tests; production resolves the live store from SingletonObject.
var _store_override = null


func _init(mcp_server = null) -> void:
	super._init(mcp_server)


func get_tool_names() -> Array[String]:
	return [
		"minerva_get_preference",
		"minerva_set_preference",
		"minerva_list_preferences",
	]


func register_tools() -> void:
	server._register_tool("minerva_get_preference",
		"Get a host setting's value. scope is \"core\" or \"plugin:<id>\". Returns the persisted value or the schema default.",
		{"type": "object", "properties": {
			"scope": {"type": "string", "description": "\"core\" or \"plugin:<id>\""},
			"key": {"type": "string", "description": "Setting key within the scope"},
		}, "required": ["scope", "key"]}, "settings")

	server._register_tool("minerva_set_preference",
		"Set a host setting. The value is validated and coerced against the setting's declared type; rejected if the key is unknown or the value is invalid.",
		{"type": "object", "properties": {
			"scope": {"type": "string", "description": "\"core\" or \"plugin:<id>\""},
			"key": {"type": "string", "description": "Setting key within the scope"},
			"value": {"description": "New value; must match the setting's declared type"},
		}, "required": ["scope", "key", "value"]}, "settings")

	server._register_tool("minerva_list_preferences",
		"List host settings. With no scope, returns the available scopes. With a scope, returns each field's schema and current value.",
		{"type": "object", "properties": {
			"scope": {"type": "string", "description": "Optional \"core\" or \"plugin:<id>\"; omit to list scopes"},
		}}, "settings")


func handle(tool_name: String, arguments: Dictionary) -> Dictionary:
	match tool_name:
		"minerva_get_preference": return _get_preference(arguments)
		"minerva_set_preference": return _set_preference(arguments)
		"minerva_list_preferences": return _list_preferences(arguments)
	return MCPToolUtils.error("Unknown tool: %s" % tool_name)


func _get_preference(args: Dictionary) -> Dictionary:
	var missing = MCPToolUtils.check_required(args, ["scope", "key"])
	if missing != null:
		return missing
	var store = _get_store()
	if store == null:
		return MCPToolUtils.error("settings store unavailable")
	var scope: String = str(args.get("scope", ""))
	var key: String = str(args.get("key", ""))
	var listing: Dictionary = store.list_settings(scope)
	if not listing.get("success", false):
		return MCPToolUtils.error(str(listing.get("error", "unknown scope '%s'" % scope)))
	for field in listing.get("fields", []):
		if str((field as Dictionary).get("key", "")) == key:
			return MCPToolUtils.success({"scope": scope, "key": key, "value": store.get_value(scope, key)})
	return MCPToolUtils.error("unknown setting '%s' for scope '%s'" % [key, scope])


func _set_preference(args: Dictionary) -> Dictionary:
	var missing = MCPToolUtils.check_required(args, ["scope", "key"])
	if missing != null:
		return missing
	if not args.has("value"):
		return MCPToolUtils.error("value is required")
	var store = _get_store()
	if store == null:
		return MCPToolUtils.error("settings store unavailable")
	var scope: String = str(args.get("scope", ""))
	var key: String = str(args.get("key", ""))
	var result: Dictionary = store.set_value(scope, key, args.get("value"))
	if not result.get("success", false):
		return MCPToolUtils.error(str(result.get("error", "could not set '%s'" % key)))
	return MCPToolUtils.success({"scope": scope, "key": key, "value": result.get("value")})


func _list_preferences(args: Dictionary) -> Dictionary:
	var store = _get_store()
	if store == null:
		return MCPToolUtils.error("settings store unavailable")
	var scope: String = str(args.get("scope", ""))
	if scope.is_empty():
		return MCPToolUtils.success({"scopes": store.list_scopes()})
	var listing: Dictionary = store.list_settings(scope)
	if not listing.get("success", false):
		return MCPToolUtils.error(str(listing.get("error", "unknown scope '%s'" % scope)))
	return MCPToolUtils.success({"scope": scope, "fields": listing.get("fields", [])})


func _get_store():
	if _store_override != null:
		return _store_override
	return SingletonObject.plugin_settings_store

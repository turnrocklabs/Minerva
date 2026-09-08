class_name MCPToolUtils
extends RefCounted
## Shared utilities for MCP tool modules.
## Provides standardized response builders, argument validation,
## type coercion, and common lookups used across all domains.


#region Response Builders

## Build a success response with optional extra fields merged in.
static func success(data: Dictionary = {}) -> Dictionary:
	var result := {"success": true}
	result.merge(data)
	return result


## Build an error response.
static func error(msg: String) -> Dictionary:
	return {"error": msg, "success": false}

#endregion


#region Argument Validation

## Validate that required keys are present in args.
## Returns empty string if valid, or an error message naming the first missing key.
static func require_args(args: Dictionary, keys: Array[String]) -> String:
	for key in keys:
		if not args.has(key) or (args[key] is String and args[key].is_empty()):
			return "%s is required" % key
	return ""


## Validate required args and return error dict immediately if missing.
## Returns null if all args are present (caller should check for null).
static func check_required(args: Dictionary, keys: Array[String]) -> Variant:
	var msg := require_args(args, keys)
	if not msg.is_empty():
		return error(msg)
	return null

#endregion


#region Type Coercion

## Safely coerce a value to int. Handles JSON floats, strings, and nulls.
static func coerce_int(value, default: int = 0) -> int:
	if value == null:
		return default
	if value is int:
		return value
	if value is float:
		return int(value)
	if value is String and value.is_valid_int():
		return value.to_int()
	return default


## Safely coerce a value to float. Handles JSON ints, strings, and nulls.
static func coerce_float(value, default: float = 0.0) -> float:
	if value == null:
		return default
	if value is float:
		return value
	if value is int:
		return float(value)
	if value is String and value.is_valid_float():
		return value.to_float()
	return default


## Safely coerce a value to Color. Accepts Color objects, HTML hex strings,
## and named colors. Returns default on failure instead of opaque black.
static func coerce_color(value, default: Color = Color.TRANSPARENT) -> Color:
	if value == null:
		return default
	if value is Color:
		return value
	if value is String:
		var s: String = value.strip_edges()
		if s.is_empty():
			return default
		# Try HTML hex format (with or without #)
		if Color.html_is_valid(s):
			return Color.html(s)
		# Try named color
		if Color.html_is_valid(s.to_lower()):
			return Color.html(s.to_lower())
	return default


## Safely coerce a value to bool. Handles JSON booleans, strings ("true"/"false"),
## and numeric values (0/1).
static func coerce_bool(value, default: bool = false) -> bool:
	if value == null:
		return default
	if value is bool:
		return value
	if value is String:
		return value.to_lower() == "true"
	if value is int or value is float:
		return value != 0
	return default

## Coerce a JSON string to a Dictionary. If value is already a Dictionary, return as-is.
## If it's a string that parses as JSON object, return the parsed dict. Otherwise return default.
static func coerce_object(value, default: Dictionary = {}) -> Dictionary:
	if value == null:
		return default
	if value is Dictionary:
		return value
	if value is String:
		var parsed = JSON.parse_string(value)
		if parsed is Dictionary:
			return parsed
	return default


## Coerce tool arguments to match declared schema types.
## LLMs (especially Sonnet) often send objects as JSON strings, integers as strings,
## and integers as floats. This function uses the tool's input_schema to fix these
## before forwarding to external MCP servers that expect correct types.
static func coerce_args_to_schema(arguments: Dictionary, schema: Dictionary) -> Dictionary:
	# Tool discovery stores the Anthropic wrapper; direct callers also pass
	# bare JSON Schema. Normalize once at this shared boundary.
	var input_schema: Dictionary = schema.get("input_schema", schema)
	var properties: Dictionary = input_schema.get("properties", {})
	if properties.is_empty():
		return arguments
	for key in arguments.keys():
		if not properties.has(key):
			continue
		var declared_type: String = str(properties[key].get("type", ""))
		var value = arguments[key]
		match declared_type:
			"object":
				if value is String:
					var parsed = JSON.parse_string(value)
					if parsed is Dictionary:
						arguments[key] = parsed
			"integer":
				# Leave invalid values for the tool's validator; never silently
				# turn a fractional dimension or malformed input into zero.
				if value is float and is_finite(value) and float(int(value)) == value:
					arguments[key] = int(value)
				elif value is String and value.is_valid_int():
					arguments[key] = value.to_int()
			"number":
				if value is String and value.is_valid_float():
					arguments[key] = value.to_float()
			"boolean":
				if value is String and value.to_lower() in ["true", "false"]:
					arguments[key] = coerce_bool(value)
				elif (value is int or value is float) and value in [0, 1]:
					arguments[key] = coerce_bool(value)
	return arguments

#endregion


#region Editor Finders

## Find an editor tab by name. Returns the Editor node or null.
static func find_editor_by_name(name_: String) -> Variant:
	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return null

	var clean_name := name_.strip_edges()

	var matches: Array = []
	for i in range(editor_pane.Tabs.get_tab_count()):
		var editor = editor_pane.Tabs.get_tab_control(i)
		if DocumentIdentity.handle(editor, "view") == clean_name:
			return editor
		if editor_pane.Tabs.get_tab_title(i) == clean_name:
			matches.append(editor)
	# A duplicate title must not silently select the first document.
	return matches[0] if matches.size() == 1 else null


## Find an editor of a specific type by name. Returns the Editor node or null.
## Pass Editor.Type.SPREADSHEET, Editor.Type.GRAPHICS, etc.
static func find_typed_editor(name_: String, editor_type: int) -> Variant:
	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return null

	var clean_name := name_.strip_edges()

	# Exact match with type filter
	for editor in editor_pane.get_open_editors():
		if editor.type == editor_type and editor.tab_title == clean_name:
			return editor

	# Case-insensitive fallback
	var lower_name := clean_name.to_lower()
	for editor in editor_pane.get_open_editors():
		if editor.type == editor_type and editor.tab_title.to_lower() == lower_name:
			return editor

	return null


## Find a typed editor and return its inner panel (e.g. .spreadsheet_editor).
## property_name is the Editor property that holds the domain-specific panel.
## Returns the inner panel or null.
static func find_editor_panel(name_: String, editor_type: int, property_name: String) -> Variant:
	var editor = find_typed_editor(name_, editor_type)
	if editor and editor.get(property_name):
		return editor.get(property_name)
	return null


## Convenience: find spreadsheet editor panel by name.
static func find_spreadsheet(name_: String) -> Variant:
	return find_typed_editor(name_, _get_editor_type("SPREADSHEET"))


## Convenience: find video editor panel by name.
static func find_video(name_: String) -> Variant:
	return find_editor_panel(name_, _get_editor_type("VIDEO_EDITOR"), "video_editor_panel")


## Convenience: find webview editor by name.
static func find_webview(name_: String) -> Variant:
	return find_typed_editor(name_, _get_editor_type("WEBVIEW"))


## Convenience: find kanban board panel by name (with partial match fallback).
static func find_kanban(name_: String) -> Variant:
	var editor_pane = SingletonObject.editor_pane
	if not editor_pane:
		return null

	var clean_name := name_.strip_edges()
	var kanban_type := _get_editor_type("KANBAN")

	# Exact match
	for editor in editor_pane.get_open_editors():
		if editor.type == kanban_type and editor.tab_title == clean_name:
			return editor.kanban_board

	# Case-insensitive
	var lower_name := clean_name.to_lower()
	for editor in editor_pane.get_open_editors():
		if editor.type == kanban_type and editor.tab_title.to_lower() == lower_name:
			return editor.kanban_board

	# Partial/contains match
	for editor in editor_pane.get_open_editors():
		if editor.type == kanban_type:
			if editor.tab_title.to_lower().contains(lower_name) or lower_name.contains(editor.tab_title.to_lower()):
				return editor.kanban_board

	return null


## Get Editor.Type enum value by name string, avoiding direct const dependency.
static func _get_editor_type(type_name: String) -> int:
	var editor_script = load("res://Scripts/UI/Controls/Editor.gd")
	return editor_script.Type.get(type_name, -1)

#endregion


#region Chat Finders

## Find a ServiceHistory (chat) by its HistoryId. Returns the history or null.
static func find_chat_by_id(chat_id: String) -> Variant:
	for history in SingletonObject.ChatList:
		if history.HistoryId == chat_id:
			return history
	return null


## Find a chat's tab index by HistoryId. Returns -1 if not found.
static func find_chat_tab_index(chat_id: String) -> int:
	for i in range(SingletonObject.ChatList.size()):
		if SingletonObject.ChatList[i].HistoryId == chat_id:
			return i
	return -1

#endregion


#region Provider Helpers

## Get a provider name string for an API_MODEL_PROVIDERS enum value.
static func get_provider_name(enum_value: int) -> String:
	for key in SingletonObject.API_MODEL_PROVIDERS:
		if SingletonObject.API_MODEL_PROVIDERS[key] == enum_value:
			return key
	return "unknown"


## Get the MCPManager for the provider name string (e.g. "chatgpt", "claude").
## Returns a provider instance or null.
static func get_provider_for_name(provider_name: String) -> Variant:
	var lower := provider_name.strip_edges().to_lower()
	for key in SingletonObject.API_MODEL_PROVIDERS:
		if str(key).to_lower() == lower:
			var enum_val: int = SingletonObject.API_MODEL_PROVIDERS[key]
			if SingletonObject.API_MODEL_PROVIDER_SCRIPTS.has(enum_val):
				return SingletonObject.API_MODEL_PROVIDER_SCRIPTS[enum_val].new()
	return null

#endregion

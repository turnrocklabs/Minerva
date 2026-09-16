extends RefCounted
## Header annotations are schema paths, never arbitrary peer-supplied headers.
const Protocol = preload("res://Scripts/Services/MCP/MCPProtocol.gd")
const Utf8 = preload("res://Scripts/Services/MCP/MCPUtf8.gd")
const TOKEN := "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"

static func annotations(schema: Variant) -> Dictionary:
	var result := {"paths": [], "names": {}, "error": ""}
	if not schema is Dictionary and not schema is bool:
		result.error = "Invalid schema representation"
		return result
	_walk(schema, [], true, result)
	return result

static func _walk(value: Variant, path: Array, reachable: bool, result: Dictionary) -> void:
	if value is Array:
		for child: Variant in value:
			_walk(child, path, false, result)
	elif value is Dictionary:
		if value.has("x-mcp-header"):
			var name: Variant = value["x-mcp-header"]
			if not reachable or path.is_empty() or not name is String or name.is_empty() \
					or value.get("type") not in ["string", "integer", "boolean"]:
				result.error = "Invalid x-mcp-header location or type"
				return
			for character: String in name:
				if not TOKEN.contains(character):
					result.error = "Invalid x-mcp-header name"
					return
			if result.names.has(name.to_lower()):
				result.error = "Duplicate x-mcp-header name"
				return
			result.names[name.to_lower()] = true
			result.paths.append({"path": path.duplicate(), "name": name, "type": value.type})
		for key: String in value:
			if key == "properties" and value[key] is Dictionary:
				for property: String in value[key]:
					_walk(value[key][property], path + [property], reachable, result)
			elif key in ["items", "prefixItems", "contains", "additionalProperties", "unevaluatedProperties", "unevaluatedItems", "propertyNames", "allOf", "anyOf", "oneOf", "not", "if", "then", "else", "contentSchema"]:
				_walk(value[key], path, false, result)
			elif key in ["$defs", "definitions", "patternProperties", "dependentSchemas"] and value[key] is Dictionary:
				for child: Variant in value[key].values():
					_walk(child, path, false, result)

static func encode(value: String) -> String:
	var encoded := value != value.strip_edges() or (value.begins_with("=?base64?") and value.ends_with("?="))
	for byte: int in value.to_utf8_buffer():
		if (byte < 32 and byte != 9) or byte > 126:
			encoded = true
	return "=?base64?%s?=" % Marshalls.raw_to_base64(value.to_utf8_buffer()) if encoded else value

static func build(request: Dictionary, schema: Variant, version: String, session: String = "") -> Dictionary:
	var headers: PackedStringArray = ["Content-Type: application/json", "Accept: application/json, text/event-stream", "MCP-Protocol-Version: " + version]
	if not session.is_empty():
		if encode(session) != session:
			return {"error": "Invalid legacy session header"}
		headers.append("Mcp-Session-Id: " + session)
	if version == Protocol.MODERN_VERSION:
		headers.append("Mcp-Method: " + str(request.method))
		var params: Dictionary = request.get("params", {})
		if request.method in ["tools/call", "resources/read", "prompts/get"]:
			headers.append("Mcp-Name: " + encode(str(params.get("name", params.get("uri", "")))))
		if request.method == "tools/call":
			var extracted := annotations(schema)
			if not extracted.error.is_empty():
				return {"error": extracted.error}
			for item: Dictionary in extracted.paths:
				var value: Variant = params.get("arguments", {})
				for part: String in item.path:
					value = value.get(part) if value is Dictionary else null
				if value == null:
					continue
				var text: String
				match item.type:
					"string":
						if not value is String:
							return {"error": "Header parameter must be a string"}
						text = value
					"boolean":
						if not value is bool:
							return {"error": "Header parameter must be boolean"}
						text = "true" if value else "false"
					"integer":
						if not Protocol.valid_request_id(value) or value is String:
							return {"error": "Header parameter must be a safe integer"}
						text = str(int(value))
				headers.append("Mcp-Param-%s: %s" % [item.name, encode(text)])
	var size := 0
	for header: String in headers:
		var bytes := header.to_utf8_buffer().size()
		if bytes > 8192:
			return {"error": "HTTP header exceeds byte budget"}
		size += bytes
	if size > 65536:
		return {"error": "HTTP headers exceed byte budget"}
	return {"headers": headers}


static func validate_mirror(request: Dictionary, schema: Variant,
		headers: Dictionary, version: String) -> String:
	if str(headers.get("mcp-protocol-version", "")) != version:
		return "MCP-Protocol-Version header must match request metadata"
	if str(headers.get("mcp-method", "")) != str(request.get("method", "")):
		return "Mcp-Method header must match the request method"
	var method: String = str(request.get("method", ""))
	var params: Dictionary = request.get("params", {})
	if method in ["tools/call", "resources/read", "prompts/get"]:
		if not headers.has("mcp-name"):
			return "Mcp-Name header is required"
		var decoded_name := decode(str(headers.get("mcp-name", "")))
		if not decoded_name.get("ok", false) \
				or decoded_name.value != str(params.get("name", params.get("uri", ""))):
			return "Mcp-Name header must match the request target"
	if method != "tools/call":
		return ""
	var extracted := annotations(schema)
	if not extracted.error.is_empty():
		return extracted.error
	for item: Dictionary in extracted.paths:
		var value: Variant = params.get("arguments", {})
		for part: String in item.path:
			value = value.get(part) if value is Dictionary else null
		var header_name := "mcp-param-%s" % str(item.name).to_lower()
		if value == null:
			if headers.has(header_name):
				return "%s header has no matching argument" % item.name
			continue
		if not headers.has(header_name):
			return "%s header is required for its annotated argument" % item.name
		var text: String
		match item.type:
			"string":
				if not value is String:
					return "Header parameter must be a string"
				text = value
			"boolean":
				if not value is bool:
					return "Header parameter must be boolean"
				text = "true" if value else "false"
			"integer":
				if not Protocol.valid_request_id(value) or value is String:
					return "Header parameter must be a safe integer"
				text = str(int(value))
		var decoded := decode(str(headers.get(header_name, "")))
		if not decoded.get("ok", false) or decoded.value != text:
			return "%s header must match its annotated argument" % item.name
	return ""


static func decode(value: String) -> Dictionary:
	for byte: int in value.to_utf8_buffer():
		if byte != 9 and (byte < 32 or byte > 126):
			return {"ok": false}
	if not value.begins_with("=?base64?") or not value.ends_with("?="):
		return {"ok": true, "value": value}
	var encoded := value.substr(9, value.length() - 11)
	if not _valid_base64(encoded):
		return {"ok": false}
	var raw := Marshalls.base64_to_raw(encoded)
	if Marshalls.raw_to_base64(raw) != encoded:
		return {"ok": false}
	if not Utf8.is_valid(raw):
		return {"ok": false}
	var decoded := raw.get_string_from_utf8()
	return {"ok": true, "value": decoded}


static func _valid_base64(value: String) -> bool:
	if value.length() % 4 != 0:
		return false
	var padding_started := false
	var padding_count := 0
	for character: String in value:
		if character == "=":
			padding_started = true
			padding_count += 1
			if padding_count > 2:
				return false
		elif padding_started or not (character >= "A" and character <= "Z") \
				and not (character >= "a" and character <= "z") \
				and not (character >= "0" and character <= "9") \
				and character not in ["+", "/"]:
			return false
	return true

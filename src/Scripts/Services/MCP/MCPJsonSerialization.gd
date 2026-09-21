extends RefCounted
## Godot's default JSON precision shortens native floats, and nonfinite values
## become null. Reject unsupported native values before producing wire bytes.
static var _invalid_control_pattern := RegEx.create_from_string(r"[\x00-\x1f]|\\.")

static func encode(value: Variant) -> Dictionary:
	var budget := [1000000]
	var error := _validate(value, 0, budget)
	if not error.is_empty():
		return {"ok": false, "error": {"code": "unsupported_representation", "message": error}}
	var raw := JSON.stringify(value, "", true, true)
	return {"ok": true, "raw": _escape_invalid_controls(raw)}


## Godot emits some C0 characters literally and spells vertical tab as the
## invalid JSON escape `\v`. The regex also consumes valid escape pairs, which
## keeps a literal backslash-v (`\\v`) distinct. Unchanged spans avoid a
## per-character interpreted loop over large numeric payloads.
static func _escape_invalid_controls(raw: String) -> String:
	var escaped := PackedStringArray()
	var span_start := 0
	for match_result in _invalid_control_pattern.search_all(raw):
		var token := match_result.get_string()
		var code := token.unicode_at(0)
		if code >= 0x20 and token != "\\v":
			continue
		var start := match_result.get_start()
		if start > span_start:
			escaped.append(raw.substr(span_start, start - span_start))
		match code:
			8: escaped.append("\\b")
			9: escaped.append("\\t")
			10: escaped.append("\\n")
			12: escaped.append("\\f")
			13: escaped.append("\\r")
			_:
				escaped.append("\\u000b" if token == "\\v" else "\\u%04x" % code)
		span_start = match_result.get_end()
	if escaped.is_empty():
		return raw
	if span_start < raw.length():
		escaped.append(raw.substr(span_start))
	return "".join(escaped)

static func _validate(value: Variant, depth: int, budget: Array) -> String:
	budget[0] -= 1
	if depth > 128 or budget[0] < 0:
		return "Native JSON exceeds structural budget"
	if value is float and not is_finite(value):
		return "Nonfinite numbers cannot be represented in JSON"
	if value is Dictionary:
		for key: Variant in value:
			if not key is String:
				return "JSON object keys must be strings"
			var error := _validate(value[key], depth + 1, budget)
			if not error.is_empty():
				return error
	elif value is Array:
		for child: Variant in value:
			var error := _validate(child, depth + 1, budget)
			if not error.is_empty():
				return error
	elif value != null and not (value is String or value is bool or value is int or value is float):
		return "Unsupported native JSON value"
	return ""

extends RefCounted
## Godot's default JSON precision shortens native floats, and nonfinite values
## become null. Reject unsupported native values before producing wire bytes.
static func encode(value: Variant) -> Dictionary:
	var budget := [1000000]
	var error := _validate(value, 0, budget)
	if not error.is_empty():
		return {"ok": false, "error": {"code": "unsupported_representation", "message": error}}
	return {"ok": true, "raw": JSON.stringify(value, "", true, true)}

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

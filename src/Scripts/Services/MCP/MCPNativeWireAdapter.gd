class_name MCPNativeWireAdapter
extends RefCounted
## Converts host-native JSON-like values to an explicit wire-safe tree.

const MAX_DEPTH := 128
const MAX_VALUES := 1000000
const MAX_SAFE_INTEGER := 9007199254740991

static func adapt(value: Variant) -> Dictionary:
	var budget := [MAX_VALUES]
	return _adapt(value, 0, budget)


static func _adapt(value: Variant, depth: int, budget: Array) -> Dictionary:
	budget[0] -= 1
	if depth > MAX_DEPTH or budget[0] < 0:
		return _failure("native result exceeds structural budget")
	if value == null or value is String or value is bool:
		return {"ok": true, "value": value}
	if value is int:
		return {"ok": true, "value": value} \
			if value >= -MAX_SAFE_INTEGER and value <= MAX_SAFE_INTEGER \
			else _failure("native result integer exceeds the safe JSON range")
	if value is StringName:
		return {"ok": true, "value": str(value)}
	if value is float:
		return {"ok": true, "value": value} if is_finite(value) \
			else _failure("native result contains a nonfinite number")
	if value is Array:
		var result: Array = []
		for child: Variant in value:
			var adapted := _adapt(child, depth + 1, budget)
			if not adapted.get("ok", false):
				return adapted
			result.append(adapted.value)
		return {"ok": true, "value": result}
	if value is Dictionary:
		var result := {}
		for key: Variant in value:
			if not (key is String or key is StringName):
				return _failure("native result object key is not text")
			var text_key := str(key)
			if result.has(text_key):
				return _failure("native result object keys collide after text normalization")
			var adapted := _adapt(value[key], depth + 1, budget)
			if not adapted.get("ok", false):
				return adapted
			result[text_key] = adapted.value
		return {"ok": true, "value": result}
	return _failure("native result contains an unsupported value")


static func _failure(message: String) -> Dictionary:
	return {"ok": false, "error": message}

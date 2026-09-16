class_name MCPWireAdapter
extends RefCounted
## Shared wire gate used before a transport exposes Godot-decoded JSON. The
## native helper rejects unsafe source numbers and supplies exact binary64 words
## for the adjacent-value rounding defect in Godot's decoder.

const ValidatorClient = preload("res://Scripts/Services/MCP/JSONSchemaValidatorClient.gd")
const MonotonicDeadline = preload("res://Scripts/Services/MCP/MCPMonotonicDeadline.gd")

static var _validator = null
static var _active_validations := 0
const MAX_ACTIVE_VALIDATIONS := 32

class Completion extends RefCounted:
	signal finished
	var done := false
	var result: Dictionary = {}
	func finish(value: Dictionary) -> void:
		if done:
			return
		done = true
		result = value
		finished.emit()


static func validate_for_application(wire_value, timeout_sec: float = 2.0) -> Dictionary:
	if wire_value == null:
		return {"ok": false, "error": {"code": "missing_wire_value",
			"message": "MCP response has no preserved wire representation"}}
	var validator = _shared_validator()
	if validator == null:
		return {"ok": false, "error": {"code": "validator_unavailable",
			"message": "MCP numeric compatibility validator is unavailable"}}
	if _active_validations >= MAX_ACTIVE_VALIDATIONS:
		return {"ok": false, "error": {"code": "queue_full",
			"message": "MCP raw-value validation queue is full"}}
	_active_validations += 1
	var completion := Completion.new()
	var deadline = MonotonicDeadline.new()
	var on_timeout := completion.finish.bind({"ok": false, "error": {
		"code": "deadline_exceeded", "message": "MCP numeric validation timed out"}})
	if timeout_sec > 0.0:
		deadline.expired.connect(on_timeout)
		if not deadline.start(timeout_sec):
			completion.finish({"ok": false, "error": {"code": "deadline_unavailable",
				"message": "MCP numeric validation deadline is unavailable"}})
	_complete_validation(validator, wire_value, completion)
	if not completion.done:
		await completion.finished
	deadline.cancel()
	if deadline.expired.is_connected(on_timeout):
		deadline.expired.disconnect(on_timeout)
	return completion.result


static func _complete_validation(validator, wire_value, completion: Completion) -> void:
	var result: Dictionary = await validator.prepare_application_numbers(
		wire_value.raw_utf8, wire_value.parsed)
	_active_validations -= 1
	if completion.done:
		return
	if not result.get("ok", false):
		completion.finish(result)
		return
	var applied := _apply_numeric_corrections(wire_value.parsed,
		result.get("corrections"))
	if not applied.get("ok", false):
		completion.finish({"ok": false, "error": {
			"code": "invalid_numeric_correction",
			"message": "MCP numeric compatibility validator returned an invalid correction"}})
		return
	wire_value.parsed = applied.value
	completion.finish({"ok": true})


static func _apply_numeric_corrections(value: Variant, correction: Variant) -> Dictionary:
	if correction == null:
		return {"ok": true, "value": value}
	if value is float or value is int:
		if not correction is Array or correction.size() != 2 \
				or not correction[0] is String or not correction[1] is String:
			return {"ok": false}
		var low_text: String = correction[0]
		var high_text: String = correction[1]
		if not low_text.is_valid_int() or not high_text.is_valid_int():
			return {"ok": false}
		var low := low_text.to_int()
		var high := high_text.to_int()
		if low < 0 or low > 0xffffffff or high < 0 or high > 0xffffffff:
			return {"ok": false}
		var bytes := PackedByteArray()
		bytes.resize(8)
		bytes.encode_u32(0, low)
		bytes.encode_u32(4, high)
		var decoded := bytes.decode_double(0)
		return {"ok": is_finite(decoded), "value": decoded}
	if value is Array:
		if not correction is Array or correction.size() != value.size():
			return {"ok": false}
		for index in value.size():
			var child := _apply_numeric_corrections(value[index], correction[index])
			if not child.get("ok", false):
				return child
			value[index] = child.value
		return {"ok": true, "value": value}
	if value is Dictionary:
		if not correction is Dictionary:
			return {"ok": false}
		for key: Variant in correction:
			if not key is String or not value.has(key):
				return {"ok": false}
			var child := _apply_numeric_corrections(value[key], correction[key])
			if not child.get("ok", false):
				return child
			value[key] = child.value
		return {"ok": true, "value": value}
	return {"ok": false}


static func _shared_validator():
	if _validator != null and is_instance_valid(_validator):
		return _validator
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return null
	_validator = ValidatorClient.new()
	_validator.name = "MCPWireNumericValidator"
	tree.root.add_child(_validator)
	return _validator


static func validator_client():
	return _shared_validator()

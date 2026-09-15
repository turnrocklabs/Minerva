class_name MCPWireAdapter
extends RefCounted
## Shared lossless-wire gate used before a transport exposes Godot-decoded JSON
## to application code. The native helper proves numeric conversion did not
## change a value; helper unavailability is an explicit failure.

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
	var result: Dictionary = await validator.compare_application_numbers(
		wire_value.raw_utf8, wire_value.parsed)
	_active_validations -= 1
	completion.finish(result)


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

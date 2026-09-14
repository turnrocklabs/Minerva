class_name VoiceFeatureControl
extends RefCounted
## Owns the saved Voice Support admission decision and active Core voice work.

const SECTION := "Voice"
const ENABLED_KEY := "turnrock_enabled"
const DISABLED_CODE := "turnrock_voice_disabled"

static var _generation := 0
static var _operations: Array[WeakRef] = []


static func is_enabled() -> bool:
	if typeof(SingletonObject) == TYPE_NIL or SingletonObject.config_file == null:
		return true
	return bool(SingletonObject.config_file.get_value(SECTION, ENABLED_KEY, true))


static func disabled_failure() -> Dictionary:
	return {"success": false, "error_code": DISABLED_CODE,
		"error_message": "Voice Support is disabled in Preferences.",
		"error": "Voice Support is disabled in Preferences."}


static func admit(operation: VoiceOperation = null) -> Dictionary:
	if not is_enabled():
		return disabled_failure()
	if operation != null:
		if operation.voice_owner.is_empty():
			operation.voice_owner = "turnrock"
		register_operation(operation)
	return {"success": true, "generation": _generation}


static func register_operation(operation: VoiceOperation) -> void:
	if operation == null:
		return
	_prune()
	for operation_ref: WeakRef in _operations:
		if operation_ref.get_ref() == operation:
			return
	_operations.append(weakref(operation))


static func set_enabled(enabled: bool) -> void:
	var was_enabled := is_enabled()
	SingletonObject.save_to_config_file(SECTION, ENABLED_KEY, enabled)
	if was_enabled and not enabled:
		_generation += 1


static func cancel_active() -> void:
	var references := _operations
	_operations = []
	for operation_ref: WeakRef in references:
		var operation: VoiceOperation = operation_ref.get_ref()
		if operation != null and operation.voice_owner == "turnrock" and operation.can_start():
			operation.cancel()


static func _prune() -> void:
	var live: Array[WeakRef] = []
	for operation_ref: WeakRef in _operations:
		if operation_ref.get_ref() != null:
			live.append(operation_ref)
	_operations = live

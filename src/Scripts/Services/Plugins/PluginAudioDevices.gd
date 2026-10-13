class_name PluginAudioDevices
extends RefCounted
## Generic internal endpoints; selection has one owner for UI and MCP.
## host.audio authorizes targeted audio only to its registered endpoint.

signal changed

const CAPABILITY: String = "host.audio"
const OUTPUT_EVENT: String = "voice.audio"

var _config: VoiceConfig
var _policy: PluginPolicy
var _send: Callable
var _next_frame: Callable
var _get_os_output: Callable
var _set_os_output: Callable
var _notify: Callable
var _devices: Dictionary = {}
var _playing: Dictionary = {}
var _next_stream: int = 0


func _init(config: VoiceConfig, policy: PluginPolicy, send: Callable, next_frame: Callable, get_os_output: Callable, set_os_output: Callable, notify: Callable) -> void:
	_config = config
	_policy = policy
	_send = send
	_next_frame = next_frame
	_get_os_output = get_os_output
	_set_os_output = set_os_output
	_notify = notify


func handle(plugin_id: String, args: Dictionary) -> Dictionary:
	var device_id: String = str(args.get("device_id", ""))
	if device_id.is_empty() or device_id.length() > 64 or not device_id.is_valid_identifier():
		return PluginErrors.schema_validation_failed(plugin_id, "device_id must be an identifier of at most 64 characters")
	var key: String = "plugin:%s:%s" % [plugin_id, device_id]
	match str(args.get("op", "")):
		"register":
			if not args.get("label") is String or str(args.label).is_empty() or str(args.label).length() > 160:
				return PluginErrors.schema_validation_failed(plugin_id, "register requires a label of 1–160 characters")
			if args.has("input") or args.get("output", false) != true:
				return PluginErrors.schema_validation_failed(plugin_id, "register requires output:true; microphone endpoints are unavailable")
			_remove(key)
			_devices[key] = {"id": key, "plugin_id": plugin_id, "device_id": device_id,
				"label": str(args.label), "output": true, "available": false}
			changed.emit()
			return PluginErrors.success({"id": key})
		"availability":
			if not _devices.has(key) or not args.get("available") is bool:
				return PluginErrors.schema_validation_failed(plugin_id, "availability requires a registered device and boolean available")
			_devices[key]["available"] = args.available
			if not args.available:
				_cancel(key)
			changed.emit()
			return PluginErrors.success({})
		"unregister":
			_remove(key)
			changed.emit()
			return PluginErrors.success({})
		"output_complete":
			var stream: Variant = args.get("stream_id")
			if not (stream is int or stream is float) or not args.get("success") is bool:
				return PluginErrors.schema_validation_failed(plugin_id, "output_complete requires integer stream_id and boolean success")
			var stream_number: float = stream
			if not is_finite(stream_number) or stream_number != floor(stream_number) or stream_number < 1 or stream_number > 9007199254740991.0:
				return PluginErrors.schema_validation_failed(plugin_id, "stream_id is outside the exact integer range")
			var stream_id: int = int(stream_number)
			var delivered: bool = args.success
			var output: PluginSpeechOutput = _playing.get(key)
			if output == null or stream_id != output_stream_id(key):
				return PluginErrors.schema_validation_failed(plugin_id, "output_complete names no active stream")
			output.acknowledge(delivered, str(args.get("error_message", "Plugin audio delivery failed.")))
			return PluginErrors.success({})
	return PluginErrors.schema_validation_failed(plugin_id, "unknown host.audio operation")


func devices(direction: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if direction != "output":
		return result
	var native: PackedStringArray = AudioServer.get_output_device_list()
	for name: String in native:
		result.append({"id": "os:" + name, "label": name, "available": true})
	for key: String in _devices:
		var device: Dictionary = _devices[key]
		var supported: bool = device.get(direction, false)
		if supported and _granted(str(device.plugin_id)):
			result.append(device.duplicate(true))
	return result


func select(direction: String, device_id: String) -> Dictionary:
	if direction != "output":
		return VoiceServiceClient.failure("invalid_audio_device", "Only speaker selection is available.")
	var found: bool = false
	for device: Dictionary in devices(direction):
		if str(device.id) == device_id:
			found = true
	if not found:
		return VoiceServiceClient.failure("invalid_audio_device", "Audio device is not registered.")
	_config.output_device = device_id if device_id.begins_with("plugin:") else ""
	if device_id.begins_with("os:"):
		_set_os_output.call(device_id.trim_prefix("os:"))
	_config.save()
	changed.emit()
	return {"success": true, "direction": direction, "device_id": device_id}


func selected_output() -> String:
	return _config.output_device if _config.output_device.begins_with("plugin:") else "os:" + str(_get_os_output.call())


func os_output_selected() -> void:
	_config.output_device = ""
	_config.save()
	changed.emit()


func report_failure(outcome: Dictionary) -> void:
	if not outcome.get("success", false) and str(outcome.get("error_code", "")) != "cancelled":
		_notify.call("Speech: " + str(outcome.get("error_message", "Playback failed.")))


func speech_output(player: AudioStreamPlayer, origin: Dictionary = {}, explicit: bool = false) -> SpeechOutput:
	var key: String = _config.output_device
	# Ordinary replies retain OS playback even while a plugin is selected.
	# An unavailable selected plugin is still a plugin route: never silently
	# spill a remote/status message onto a different speaker.
	if not key.begins_with("plugin:") or (not explicit and (str(origin.get("plugin_id", "")).is_empty() or not key.begins_with("plugin:" + str(origin.get("plugin_id", "")) + ":"))):
		return OSSpeechOutput.new(player)
	_cancel(key)
	_next_stream += 1
	var output := PluginSpeechOutput.new(_next_stream,
		_send_audio.bind(key), _next_frame, _available.bind(key))
	_playing[key] = output
	_stream_ids[key] = _next_stream
	output.finished.connect(_finished.bind(key, output), CONNECT_ONE_SHOT)
	return output


var _stream_ids: Dictionary = {}


func output_stream_id(key: String) -> int:
	var stream_id: int = _stream_ids.get(key, 0)
	return stream_id


func plugin_stopped(plugin_id: String) -> void:
	for key: String in _devices.keys():
		if str(_devices[key].plugin_id) == plugin_id:
			_remove(key)
	changed.emit()


func capability_revoked(plugin_id: String, capability: String) -> void:
	if capability == CAPABILITY:
		plugin_stopped(plugin_id)


func _granted(plugin_id: String) -> bool:
	return _policy != null and _policy.is_capability_granted(plugin_id, CAPABILITY)


func _available(key: String) -> bool:
	var device: Dictionary = _devices.get(key, {})
	var available: bool = device.get("available", false)
	return not device.is_empty() and available and _granted(str(device.plugin_id))


func _send_audio(payload: Dictionary, key: String) -> bool:
	# Teardown may send cancel after a grant is revoked: it carries no audio
	# and releases the already admitted playback, never admits new work.
	if not _devices.has(key) or (str(payload.get("op", "")) != "cancel" and not _available(key)):
		return false
	var device: Dictionary = _devices[key]
	payload["device_id"] = device.device_id
	var sent: Error = _send.call(str(device.plugin_id), OUTPUT_EVENT, payload)
	return sent == OK


func _finished(_outcome: Dictionary, key: String, output: PluginSpeechOutput) -> void:
	if _playing.get(key) == output:
		_playing.erase(key)
		_stream_ids.erase(key)
	output.stop()


func _cancel(key: String) -> void:
	var output: PluginSpeechOutput = _playing.get(key)
	if output != null:
		output.acknowledge(false, "Plugin speaker session ended.")


func _remove(key: String) -> void:
	_cancel(key)
	_devices.erase(key)

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
var _devices: Dictionary = {}
var _playing: Dictionary = {}
var _next_stream: int = 0


func _init(config: VoiceConfig, policy: PluginPolicy, send: Callable, next_frame: Callable) -> void:
	_config = config
	_policy = policy
	_send = send
	_next_frame = next_frame


func handle(plugin_id: String, args: Dictionary) -> Dictionary:
	var device_id: String = str(args.get("device_id", ""))
	if device_id.is_empty() or device_id.length() > 64 or not device_id.is_valid_identifier():
		return PluginErrors.schema_validation_failed(plugin_id, "device_id must be an identifier of at most 64 characters")
	var key: String = "plugin:%s:%s" % [plugin_id, device_id]
	match str(args.get("op", "")):
		"register":
			if not args.get("label") is String or str(args.label).is_empty() or str(args.label).length() > 160:
				return PluginErrors.schema_validation_failed(plugin_id, "register requires a label of 1–160 characters")
			if not args.get("input", false) is bool or not args.get("output", false) is bool:
				return PluginErrors.schema_validation_failed(plugin_id, "input and output must be booleans")
			if not bool(args.get("input", false)) and not bool(args.get("output", false)):
				return PluginErrors.schema_validation_failed(plugin_id, "register requires input or output")
			_remove(key)
			_devices[key] = {"id": key, "plugin_id": plugin_id, "device_id": device_id,
				"label": str(args.label), "input": bool(args.get("input", false)),
				"output": bool(args.get("output", false)), "available": false}
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
			if not (stream is int or stream is float) or not is_finite(float(stream)) or float(stream) != floor(float(stream)) or not args.get("success") is bool:
				return PluginErrors.schema_validation_failed(plugin_id, "output_complete requires integer stream_id and boolean success")
			var output: PluginSpeechOutput = _playing.get(key)
			if output == null or int(stream) != output_stream_id(key):
				return PluginErrors.schema_validation_failed(plugin_id, "output_complete names no active stream")
			output.acknowledge(bool(args.success), str(args.get("error_message", "Plugin audio delivery failed.")))
			return PluginErrors.success({})
	return PluginErrors.schema_validation_failed(plugin_id, "unknown host.audio operation")


func devices(direction: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var native: PackedStringArray = AudioServer.get_input_device_list() if direction == "input" else AudioServer.get_output_device_list()
	for name: String in native:
		result.append({"id": "os:" + name, "label": name, "available": true})
	for key: String in _devices:
		var device: Dictionary = _devices[key]
		if bool(device.get(direction, false)) and _granted(str(device.plugin_id)):
			result.append(device.duplicate(true))
	return result


func select(direction: String, device_id: String) -> Dictionary:
	if direction not in ["input", "output"]:
		return VoiceServiceClient.failure("invalid_audio_device", "direction must be input or output")
	var found: bool = false
	for device: Dictionary in devices(direction):
		if str(device.id) == device_id:
			found = true
	if not found:
		return VoiceServiceClient.failure("invalid_audio_device", "Audio device is not registered.")
	if direction == "input":
		_config.input_device = device_id
		if device_id.begins_with("os:"):
			AudioServer.input_device = device_id.trim_prefix("os:")
	else:
		_config.output_device = device_id
		if device_id.begins_with("os:"):
			AudioServer.output_device = device_id.trim_prefix("os:")
	_config.save()
	changed.emit()
	return {"success": true, "direction": direction, "device_id": device_id}


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
	return int(_stream_ids.get(key, 0))


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
	return not device.is_empty() and bool(device.available) and _granted(str(device.plugin_id))


func _send_audio(payload: Dictionary, key: String) -> bool:
	if not _available(key):
		return false
	var device: Dictionary = _devices[key]
	payload["device_id"] = device.device_id
	return int(_send.call(str(device.plugin_id), OUTPUT_EVENT, payload)) == OK


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

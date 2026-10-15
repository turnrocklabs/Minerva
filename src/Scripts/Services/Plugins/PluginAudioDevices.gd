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
var _get_os_input: Callable
var _set_os_input: Callable
var _notify: Callable
var _devices: Dictionary = {}
var _playing: Dictionary = {}
var _next_stream: int = 0
var _notification_pending: bool = false


func _init(config: VoiceConfig, policy: PluginPolicy, send: Callable, next_frame: Callable, get_os_output: Callable, set_os_output: Callable, notify: Callable, get_os_input: Callable = Callable(), set_os_input: Callable = Callable()) -> void:
	_config = config
	_policy = policy
	_send = send
	_next_frame = next_frame
	_get_os_output = get_os_output
	_set_os_output = set_os_output
	_notify = notify
	_get_os_input = get_os_input
	_set_os_input = set_os_input


func handle(plugin_id: String, args: Dictionary) -> Dictionary:
	var device_id: String = str(args.get("device_id", ""))
	if device_id.is_empty() or device_id.length() > 64 or not device_id.is_valid_identifier():
		return PluginErrors.schema_validation_failed(plugin_id, "device_id must be an identifier of at most 64 characters")
	var key: String = "plugin:%s:%s" % [plugin_id, device_id]
	match str(args.get("op", "")):
		"register":
			if not args.get("label") is String or str(args.label).is_empty() or str(args.label).length() > 160:
				return PluginErrors.schema_validation_failed(plugin_id, "register requires a label of 1–160 characters")
			if not args.get("input", false) is bool or not args.get("output", false) is bool or not (args.get("input", false) or args.get("output", false)):
				return PluginErrors.schema_validation_failed(plugin_id, "register requires input:true or output:true")
			_remove(key)
			_devices[key] = {"id": key, "plugin_id": plugin_id, "device_id": device_id,
				"label": str(args.label), "input": args.get("input", false), "output": args.get("output", false), "available": false}
			changed.emit()
			return PluginErrors.success({"id": key})
		"availability":
			if not _devices.has(key) or not args.get("available") is bool:
				return PluginErrors.schema_validation_failed(plugin_id, "availability requires a registered device and boolean available")
			_devices[key]["available"] = args.available
			if not args.available:
				_cancel(key)
				_cancel(key + ":tone")
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
				output = _playing.get(key + ":tone")
				if output == null or stream_id != output_stream_id(key + ":tone"):
					return PluginErrors.schema_validation_failed(plugin_id, "output_complete names no active stream")
			output.acknowledge(delivered, str(args.get("error_message", "Plugin audio delivery failed.")))
			return PluginErrors.success({})
	return PluginErrors.schema_validation_failed(plugin_id, "unknown host.audio operation")


func devices(direction: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if direction not in ["input", "output"]:
		return result
	var native: PackedStringArray = AudioServer.get_input_device_list() if direction == "input" else AudioServer.get_output_device_list()
	for name: String in native:
		result.append({"id": "os:" + name, "label": name, "available": true})
	for key: String in _devices:
		var device: Dictionary = _devices[key]
		var supported: bool = device.get(direction, false)
		if supported and _granted(str(device.plugin_id)):
			result.append(device.duplicate(true))
	return result


func select(direction: String, device_id: String) -> Dictionary:
	if direction not in ["input", "output"] or (direction == "input" and not _set_os_input.is_valid()):
		return VoiceServiceClient.failure("invalid_audio_device", "Audio direction is unavailable.")
	var found: bool = false
	for device: Dictionary in devices(direction):
		if str(device.id) == device_id:
			found = true
	if not found:
		return VoiceServiceClient.failure("invalid_audio_device", "Audio device is not registered.")
	_config.set(direction + "_device", device_id if device_id.begins_with("plugin:") else "")
	if device_id.begins_with("os:"):
		var setter: Callable = _set_os_input if direction == "input" else _set_os_output
		setter.call(device_id.trim_prefix("os:"))
	_config.save()
	changed.emit()
	return {"success": true, "direction": direction, "device_id": device_id}


func selected_output() -> String:
	return _config.output_device if _config.output_device.begins_with("plugin:") else "os:" + str(_get_os_output.call())


func selected_input() -> String:
	return _config.input_device if _config.input_device.begins_with("plugin:") else "os:" + (str(_get_os_input.call()) if _get_os_input.is_valid() else AudioServer.input_device)


func os_input_selected() -> void:
	_config.input_device = ""
	_config.save()
	changed.emit()


func endpoint_available(key: String, direction: String) -> bool:
	var device: Dictionary = _devices.get(key, {})
	return _available(key) and device.get(direction, false)


func os_output_selected() -> void:
	_config.output_device = ""
	_config.save()
	changed.emit()


func report_failure(outcome: Dictionary) -> void:
	if not outcome.get("success", false) and str(outcome.get("error_code", "")) != "cancelled":
		_notify.call("Speech: " + str(outcome.get("error_message", "Playback failed.")))


func route_output(origin: Dictionary = {}, explicit: bool = false) -> String:
	var key: String = _config.output_device
	if not key.begins_with("plugin:") or (not explicit and (str(origin.get("plugin_id", "")).is_empty() or not key.begins_with("plugin:" + str(origin.get("plugin_id", "")) + ":"))):
		return "os:" + str(_get_os_output.call())
	return key


func replay_target_valid(key: String) -> bool:
	if key == "os:" + str(_get_os_output.call()):
		return true
	var device: Dictionary = _devices.get(key, {})
	return not device.is_empty() and device.get("output", false) and _granted(str(device.plugin_id))


func output_busy(key: String) -> bool:
	return _playing.has(key)


func play_notification(player: AudioStreamPlayer, tone: AudioStreamWAV) -> void:
	if _notification_pending:
		return
	_notification_pending = true
	var key: String = selected_output()
	# Completion tones follow existing speech, without replacing its stream.
	while output_busy(key) or output_busy(key + ":tone"):
		await _next_frame.call()
		key = selected_output()
	_notification_pending = false
	if key.begins_with("os:"):
		player.play()
		return
	var output: SpeechOutput = output_for_device(player, key, {}, true, true)
	output.finished.connect(report_failure, CONNECT_ONE_SHOT)
	var opened: Dictionary = output.begin("pcm_s16le", tone.mix_rate, minf(db_to_linear(player.volume_db), 1.0))
	if not opened.success:
		report_failure(opened)
		output.stop()
		return
	if not output.append(tone.data):
		output.stop()
		return
	output.end()


func speech_output(player: AudioStreamPlayer, origin: Dictionary = {}, explicit: bool = false) -> SpeechOutput:
	return output_for_device(player, route_output(origin, explicit), origin, explicit)


func output_for_device(player: AudioStreamPlayer, key: String, origin: Dictionary = {}, explicit: bool = false, notification: bool = false) -> SpeechOutput:
	if key == "os:" + str(_get_os_output.call()):
		return OSSpeechOutput.new(player)
	# An unavailable plugin remains a plugin route, with a visible failure.
	# A tone and reserved speech have separate lifetimes on the same device.
	var active_key: String = key + ":tone" if notification else key
	_cancel(active_key)
	_next_stream += 1
	var output := PluginSpeechOutput.new(_next_stream,
		_send_audio.bind(key), _next_frame, _available.bind(key),
		{"kind": "explicit"} if explicit else ({"kind": "turn", "chat_id": str(origin.chat_id), "send_id": origin.get("send_id", 0)} if not str(origin.get("chat_id", "")).is_empty() else {}),
		Callable() if notification else _tone_finished.bind(key))
	_playing[active_key] = output
	_stream_ids[active_key] = _next_stream
	output.finished.connect(_finished.bind(active_key, output), CONNECT_ONE_SHOT)
	return output


func _tone_finished(key: String) -> bool:
	return not output_busy(key + ":tone")


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
	_cancel(key + ":tone")
	_cancel(key)
	_devices.erase(key)

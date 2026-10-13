class_name SpeechDelivery
extends RefCounted
## One owner for admission, terminal playback receipts and log visibility.
signal changed
var _store: SpeechLog
var _devices: PluginAudioDevices
var _client: VoiceServiceClient
var _player_factory: Callable
var _notify: Callable
var _publish: Callable
var _active: Dictionary = {}


func _init(store: SpeechLog, devices: PluginAudioDevices, client: VoiceServiceClient, player_factory: Callable, notify: Callable, publish: Callable) -> void:
	_store = store
	_devices = devices
	_client = client
	_player_factory = player_factory
	_notify = notify
	_publish = publish
	if not store.errors.is_empty():
		_notify.call("Speech log: " + "; ".join(store.errors))


func prepare(operation: SpeechOperation, player: AudioStreamPlayer, config: VoiceConfig, text: String, origin: Dictionary = {}, explicit: bool = false, topic: String = "", summary: String = "") -> Dictionary:
	var device: String = _devices.route_output(origin, explicit)
	if not device.begins_with("plugin:"):
		operation.bind_output(OSSpeechOutput.new(player))
		return {"success": true, "log_id": "", "device": device}
	var producer: String = "explicit" if explicit else str(origin.get("plugin_id", ""))
	var exempt_ids: Array[String] = []
	for id: String in _active:
		var active: SpeechOperation = _active[id]
		if active.playback_started and not active.done:
			exempt_ids.append(id)
	var result: Dictionary = _store.admit({"producer": producer, "topic": topic, "text": text, "original_text": text,
		"summary": (summary if not summary.is_empty() else text).substr(0, 21), "summary_explicit": not summary.is_empty(), "origin": origin.duplicate(true),
		"device": device, "voice_id": config.voice_id, "voice_name": config.voice_name, "backend": config.tts_backend,
		"volume": config.tts_volume, "error": "", "fallback_reason": ""}, exempt_ids)
	if not result.success:
		operation.finish(result)
		_notify.call(result.error_message)
		return result
	var id: String = result.record.log_id
	# Cancel only superseded synthesis, never an item that has begun playback.
	for old_id: String in _active.keys():
		var old: SpeechOperation = _active[old_id]
		var old_record: Dictionary = _store.get_record(old_id)
		if old_record.get("superseded", false) and not old.playback_started:
			old.cancel()
	if _devices.output_busy(device):
		operation.finished.connect(_finished.bind(id, operation), CONNECT_ONE_SHOT)
		_active[id] = operation
		operation.finish(VoiceServiceClient.failure("speech_busy", "Speaker is busy; speech is queued for explicit replay."))
	else:
		_bind(id, operation, player, device, origin, explicit)
	_changed()
	return {"success": true, "log_id": id, "device": device}


func save_spoken(id: String, text: String, fallback: String = "") -> Dictionary:
	if id.is_empty():
		return {"success": true}
	var fields: Dictionary = {"text": text, "fallback_reason": fallback}
	var record: Dictionary = _store.get_record(id)
	if not record.get("summary_explicit", false):
		fields["summary"] = text.substr(0, 21)
	var result: Dictionary = _store.update_record(id, fields)
	if not result.success:
		_notify.call(result.error_message)
	_changed()
	return result


func _bind(id: String, operation: SpeechOperation, player: AudioStreamPlayer, device: String, origin: Dictionary, explicit: bool) -> void:
	_active[id] = operation
	operation.finished.connect(_finished.bind(id, operation), CONNECT_ONE_SHOT)
	operation.bind_output(_devices.output_for_device(player, device, origin, explicit))


func _finished(outcome: Dictionary, id: String, operation: SpeechOperation) -> void:
	if _active.get(id) != operation:
		return
	_active.erase(id)
	var record: Dictionary = _store.get_record(id)
	if record.is_empty():
		return
	var fields: Dictionary = {"error": "" if outcome.get("success", false) else str(outcome.get("error_message", "Playback failed."))}
	if outcome.get("success", false):
		fields["heard"] = true
	var saved: Dictionary = _store.update_record(id, fields)
	if not saved.success:
		outcome.merge(saved, true)
		_notify.call(saved.error_message)
	_changed()


func state(producer: String = "", topic: String = "") -> Dictionary:
	var records: Array[Dictionary] = _visible_records(producer, topic)
	var unheard: int = 0
	for record: Dictionary in records:
		if not record.heard and not record.superseded:
			unheard += 1
	return {"success": _store.errors.is_empty(), "unheard": unheard, "total": records.size(), "errors": _store.errors.duplicate()}


func handle(args: Dictionary, producer: String = "") -> Dictionary:
	var op: String = str(args.get("op", "list"))
	var id: String = str(args.get("log_id", ""))
	var topic: String = str(args.get("topic", ""))
	if op in ["list", "state"]:
		var page: Dictionary = state(producer, topic)
		if op == "state":
			if not id.is_empty():
				var detail: Dictionary = _store.get_record(id)
				if detail.is_empty() or (not producer.is_empty() and not str(detail.device).begins_with("plugin:" + producer + ":")):
					return VoiceServiceClient.failure("invalid_speech_log", "Speech record is unavailable.")
				page["item"] = detail
			return page
		var offset: Variant = args.get("offset", 0)
		var limit: Variant = args.get("limit", 20)
		if not SpeechLog._integer(offset) or not SpeechLog._integer(limit):
			return VoiceServiceClient.failure("invalid_speech_log", "offset must be nonnegative and limit 1–100.")
		var offset_number: float = offset
		var limit_number: float = limit
		var page_offset: int = int(offset_number)
		var page_limit: int = int(limit_number)
		if page_limit < 1 or page_limit > 100:
			return VoiceServiceClient.failure("invalid_speech_log", "offset must be nonnegative and limit 1–100.")
		var records: Array[Dictionary] = _visible_records(producer, topic)
		var items: Array[Dictionary] = []
		for item: Dictionary in records.slice(mini(page_offset, records.size()), mini(page_offset + page_limit, records.size())):
			items.append({"log_id": item.log_id, "created_at": item.created_at, "summary": item.summary,
				"heard": item.heard, "superseded": item.superseded, "origin_kind": "explicit" if item.producer == "explicit" else "turn"})
		page["items"] = items
		return page
	var record: Dictionary = _store.get_record(id)
	if record.is_empty() or (not producer.is_empty() and not str(record.device).begins_with("plugin:" + producer + ":")):
		return VoiceServiceClient.failure("invalid_speech_log", "Speech record is unavailable.")
	if _active.has(id) and op == "play":
		return VoiceServiceClient.failure("speech_busy", "Speech item is already active.")
	var result: Dictionary
	match op:
		"play":
			var target: String = str(args.get("device_id", ""))
			if not producer.is_empty() and not target.begins_with("plugin:" + producer + ":"):
				return VoiceServiceClient.failure("invalid_audio_device", "Plugin replay requires its own speaker.")
			return await _replay(record, target)
		"mark":
			if not args.get("heard") is bool:
				return VoiceServiceClient.failure("invalid_speech_log", "heard must be a boolean.")
			result = _store.update_record(id, {"heard": args.heard})
		"delete":
			if _active.has(id):
				var active: SpeechOperation = _active[id]
				active.cancel()
			result = _store.delete_record(id)
		_:
			return VoiceServiceClient.failure("invalid_speech_log", "Unknown speech-log operation.")
	if not result.success:
		_notify.call(result.error_message)
		return result
	_changed()
	return state(producer, topic)


func _replay(record: Dictionary, device: String) -> Dictionary:
	if device.is_empty():
		device = _devices.selected_output()
	if not _devices.replay_target_valid(device):
		return VoiceServiceClient.failure("invalid_audio_device", "Replay requires a registered plugin speaker or current OS route.")
	if _devices.output_busy(device):
		return VoiceServiceClient.failure("speech_busy", "Speaker is busy; replay after playback finishes.")
	var player: AudioStreamPlayer = _player_factory.call()
	if not is_instance_valid(player):
		return VoiceServiceClient.failure("no_audio_player", "No chat pane is available for speech.")
	var operation := SpeechOperation.new()
	player.set_meta("speech_operation", operation)
	operation.finished.connect(func(_outcome: Dictionary) -> void:
		if is_instance_valid(player):
			player.queue_free(), CONNECT_ONE_SHOT)
	var config := VoiceConfig.new()
	config.voice_id = record.voice_id
	config.voice_name = record.voice_name
	config.tts_backend = record.backend
	config.tts_volume = record.volume
	var id: String = record.log_id
	var text: String = record.text
	var origin: Dictionary = record.origin
	var explicit: bool = record.producer == "explicit"
	_bind(id, operation, player, device, origin, explicit)
	return await synthesize(id, text, config, operation, player, device)


func synthesize(id: String, text: String, config: VoiceConfig, operation: SpeechOperation, player: AudioStreamPlayer, device: String) -> Dictionary:
	if operation.done:
		return receipt(id, device, operation) if not id.is_empty() else operation.completion_outcome
	var result: Dictionary = await _client.synthesize_auto_playback_result(text, config, operation, player)
	if not result.get("success", false) and not operation.done:
		operation.finish(result)
	# Pending physical delivery returns a durable queued receipt. The retained
	# operation updates heard only when its terminal acknowledgement arrives.
	if id.is_empty():
		return operation.completion_outcome if operation.done else result
	return receipt(id, device, operation)


func receipt(id: String, device: String, operation: SpeechOperation) -> Dictionary:
	var outcome: Dictionary = operation.completion_outcome
	var result: Dictionary = {"success": true, "delivery": "played_live" if operation.done and outcome.get("success", false) else "queued",
		"log_id": id, "device": device, "unheard_count": state().unheard}
	if outcome.get("error_code") == "speech_log_write":
		return outcome
	if not outcome.get("success", false):
		result["error_code"] = outcome.get("error_code", "pending")
		result["error_message"] = outcome.get("error_message", "Speech is queued.")
	return result


func _changed() -> void:
	changed.emit()
	_publish.call(self)


func _visible_records(scope: String, topic: String) -> Array[Dictionary]:
	var records: Array[Dictionary] = []
	for record: Dictionary in _store.list_records("", topic):
		if scope.is_empty() or str(record.device).begins_with("plugin:" + scope + ":"):
			records.append(record)
	return records

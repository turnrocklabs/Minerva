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


static func snapshot(config: VoiceConfig) -> VoiceConfig:
	var result := VoiceConfig.new()
	result.voice_id = config.voice_id
	result.voice_name = config.voice_name
	result.tts_backend = config.tts_backend
	result.tts_provider = config.tts_provider
	result.tts_volume = config.tts_volume
	result.speak_mode = config.speak_mode
	result.summary_model = config.summary_model
	result.summary_timeout = config.summary_timeout
	result.summary_prompt = config.summary_prompt
	result.summary_max_tokens = config.summary_max_tokens
	return result


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
	var logged_origin: Dictionary = origin.duplicate(true)
	logged_origin["kind"] = "explicit" if explicit else "turn"
	var result: Dictionary = _store.admit({"producer": producer, "topic": topic, "text": text, "original_text": text,
		"summary": (summary if not summary.is_empty() else text).substr(0, 21), "summary_explicit": not summary.is_empty(), "origin": logged_origin,
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
		if not record.heard and not record.superseded and not _active.has(str(record.log_id)):
			unheard += 1
	return {"success": _store.ready, "unheard": unheard, "total": records.size(), "errors": _store.errors.duplicate()}


func handle(args: Dictionary, producer: String = "") -> Dictionary:
	var op: String = str(args.get("op", "list"))
	var id: String = str(args.get("log_id", ""))
	var topic: String = str(args.get("topic", ""))
	if op == "delete_all":
		if not args.get("confirmed") is bool or not args.confirmed:
			return VoiceServiceClient.failure("confirmation_required", "Confirm deletion of all speech in this scope.")
		for record: Dictionary in _visible_records(producer, ""):
			var record_id: String = record.log_id
			if _active.has(record_id):
				var active: SpeechOperation = _active[record_id]
				active.cancel()
			var removed: Dictionary = _store.delete_record(record_id)
			if not removed.success:
				_notify.call(removed.error_message)
				_changed()
				return removed
		_changed()
		return state(producer)
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
		if not SpeechLog.is_integer(offset) or not SpeechLog.is_integer(limit):
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
			var played: Dictionary = _replay(record, target)
			if not producer.is_empty() and played.get("success", false):
				played["unheard_count"] = state(producer).unheard
			return played
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
	# Replay is a fresh explicit playback action; historical origin stays saved.
	_bind(id, operation, player, device, {"kind": "explicit"}, true)
	return start(id, text, config, operation, player, device)


func start(id: String, text: String, config: VoiceConfig, operation: SpeechOperation, player: AudioStreamPlayer, device: String) -> Dictionary:
	# Retain the operation while synthesis runs; control RPCs never await audio.
	synthesize(id, text, config, operation, player, device)
	return receipt(id, device, operation)


func synthesize(id: String, text: String, config: VoiceConfig, operation: SpeechOperation, player: AudioStreamPlayer, device: String) -> Dictionary:
	if operation.done:
		return receipt(id, device, operation) if not id.is_empty() else operation.completion_outcome
	var result: Dictionary = await _client.synthesize_auto_playback_result(text, config, operation, player)
	if not result.get("success", false) and not operation.done:
		operation.finish(result)
	# Pending live delivery returns playing. Undeliverable saved work is queued.
	# The retained operation updates heard only when its terminal acknowledgement arrives.
	if id.is_empty() and not result.get("success", false):
		result.merge({"device": "os", "unheard_count": state().unheard})
		return result
	return receipt(id, device, operation)


func receipt(id: String, device: String, operation: SpeechOperation) -> Dictionary:
	var outcome: Dictionary = operation.completion_outcome
	var delivery: String = "playing" if not operation.done else ("played_live" if outcome.get("success", false) else "queued")
	var result: Dictionary = {"success": true, "delivery": delivery,
		"device": "os" if device.begins_with("os:") else device, "unheard_count": state().unheard}
	if not id.is_empty():
		result["log_id"] = id
	if outcome.get("error_code") == "speech_log_write":
		return outcome
	if id.is_empty() and operation.done and not outcome.get("success", false):
		var failed: Dictionary = outcome.duplicate()
		failed.merge({"device": "os", "unheard_count": state().unheard})
		return failed
	if operation.done and not outcome.get("success", false):
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

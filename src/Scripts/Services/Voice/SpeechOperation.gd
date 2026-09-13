class_name SpeechOperation
extends VoiceOperation
## Owns one summary/synthesis/playback lifetime. stop() never supplies completion.

signal finished(outcome: Dictionary)
signal playback_began
var done := false
var playback_started := false
var _player: AudioStreamPlayer
var _owned_stream: AudioStream
var _stream_sink: Node
var _stream_volume := 1.0

func can_start() -> bool:
	return not done and not cancelled

func cancel() -> void:
	_complete({"success": false, "error_code": "cancelled", "error_message": "Speech cancelled locally."}, true)

func finish(outcome: Dictionary) -> void:
	_complete(outcome, false)

func _complete(outcome: Dictionary, cancel_pending: bool) -> void:
	if done:
		return
	done = true
	if is_instance_valid(_stream_sink):
		if _stream_sink.finished.is_connected(_on_stream_playback_finished):
			_stream_sink.finished.disconnect(_on_stream_playback_finished)
		_stream_sink.stop()
		_stream_sink.queue_free()
	elif is_instance_valid(_player):
		if _player.finished.is_connected(_on_playback_finished):
			_player.finished.disconnect(_on_playback_finished)
		if _owned_stream != null and _player.stream == _owned_stream:
			_player.stop()
			_player.stream = null
	_stream_sink = null
	_owned_stream = null
	_player = null
	# Mark terminal before cancel resumes pending adapter coroutines synchronously.
	if cancel_pending:
		var pending := _request
		if pending != null and pending.has_method("accept_stream_open"):
			_disconnect_stream_request(pending)
		super.cancel()
	finished.emit(outcome)

func play(player: AudioStreamPlayer, audio: PackedByteArray, volume: float) -> bool:
	if done:
		return false
	if not is_instance_valid(player):
		finish({"success": false, "error_code": "no_audio_player", "error_message": "Speech player is unavailable."})
		return false
	var stream := VoiceServiceClient.decode_audio(audio)
	if stream == null:
		finish({"success": false, "error_code": "invalid_audio", "error_message": "Speech audio could not be decoded."})
		return false
	_player = player
	_player.stream = stream
	_owned_stream = stream
	_player.volume_db = linear_to_db(volume)
	_player.finished.connect(_on_playback_finished)
	playback_started = true
	_player.play()
	playback_began.emit()
	return true

func receive_stream(request, player: AudioStreamPlayer, volume: float) -> Dictionary:
	var prepared := prepare_stream(request, player, volume)
	if not prepared.success:
		return prepared
	return await receive_prepared_stream(request)

func prepare_stream(request, player: AudioStreamPlayer, volume: float) -> Dictionary:
	if not can_start():
		request.cancel()
		return {"success": false, "error_code": "cancelled", "error_message": "Speech cancelled locally."}
	if _request != null:
		request.cancel()
		return {"success": false, "error_code": "operation_busy", "error_message": "Voice operation already has an active request."}
	if not is_instance_valid(player):
		request.cancel()
		return {"success": false, "error_code": "no_audio_player", "error_message": "Speech player is unavailable."}
	_player = player
	_stream_volume = volume
	_request = request
	request.stream_opened.connect(_on_stream_open, CONNECT_ONE_SHOT)
	request.stream_chunk.connect(_on_stream_chunk)
	request.stream_ended.connect(_on_stream_end, CONNECT_ONE_SHOT)
	return {"success": true}

func receive_prepared_stream(request) -> Dictionary:
	var completed: Dictionary = await request.receive_caller_result()
	if _request == request:
		_request = null
	_disconnect_stream_request(request)
	return completed

func _on_stream_open(meta: Dictionary) -> void:
	if done:
		return
	if not is_instance_valid(_player):
		_complete({"success": false, "error_code": "no_audio_player", "error_message": "Speech player is unavailable."}, true)
		return
	_stream_sink = load("res://Scripts/Services/Voice/StreamingSpeechPlayback.gd").new()
	_player.add_child(_stream_sink)
	_stream_sink.finished.connect(_on_stream_playback_finished, CONNECT_ONE_SHOT)
	_stream_sink.started.connect(_on_stream_playback_began, CONNECT_ONE_SHOT)
	if not _stream_sink.begin(_player, str(meta.format), int(meta.sample_rate), _stream_volume):
		_complete({"success": false, "error_code": "unsupported_audio_stream", "error_message": "Speech stream layout is unsupported."}, true)

func _on_stream_chunk(audio: PackedByteArray) -> void:
	if done or not is_instance_valid(_stream_sink):
		return
	if not _stream_sink.append(audio):
		var active := _request
		if active != null:
			active.cancel()

func _on_stream_end() -> void:
	if not done and is_instance_valid(_stream_sink):
		_stream_sink.end()

func _on_stream_playback_began() -> void:
	if done:
		return
	playback_started = true
	playback_began.emit()

func _on_stream_playback_finished(outcome: Dictionary) -> void:
	if done:
		return
	var completed_sink := _stream_sink
	_stream_sink = null
	if is_instance_valid(completed_sink):
		completed_sink.queue_free()
	if outcome.get("success", false):
		finish(outcome)
	else:
		_complete(outcome, true)

func _disconnect_stream_request(request) -> void:
	for pair in [[request.stream_opened, _on_stream_open], [request.stream_chunk, _on_stream_chunk], [request.stream_ended, _on_stream_end]]:
		if pair[0].is_connected(pair[1]):
			pair[0].disconnect(pair[1])

func _on_playback_finished() -> void:
	finish({"success": true})

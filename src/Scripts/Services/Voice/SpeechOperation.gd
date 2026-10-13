class_name SpeechOperation
extends VoiceOperation
## Owns one summary/synthesis/playback lifetime. stop() never supplies completion.

signal finished(outcome: Dictionary)
signal playback_began
var done := false
var playback_started := false
var _output: SpeechOutput
var _stream_open := false
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
	var output := _output
	_output = null
	_stream_open = false
	if output != null:
		if output.finished.is_connected(_on_output_finished):
			output.finished.disconnect(_on_output_finished)
		if output.started.is_connected(_on_output_started):
			output.started.disconnect(_on_output_started)
		output.stop()
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
	_ensure_output(player)
	var played := _output.play(audio, volume)
	if not played.success:
		finish(played)
		return false
	return true


func bind_output(output: SpeechOutput) -> bool:
	if _output != null or not can_start() or is_busy():
		return false
	_output = output
	_output.finished.connect(_on_output_finished)
	_output.started.connect(_on_output_started)
	return true


func _ensure_output(player: AudioStreamPlayer) -> void:
	if _output == null:
		bind_output(OSSpeechOutput.new(player))


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
	_ensure_output(player)
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
	if _output == null or not _output.is_available():
		_complete({"success": false, "error_code": "no_audio_player", "error_message": "Speech player is unavailable."}, true)
		return
	var opened := _output.begin(str(meta.format), int(meta.sample_rate), _stream_volume)
	if not opened.success:
		_complete(opened, true)
		return
	_stream_open = true

func _on_stream_chunk(audio: PackedByteArray) -> void:
	if done or not _stream_open or _output == null:
		return
	if not _output.append(audio):
		var active := _request
		if active != null:
			active.cancel()

func _on_stream_end() -> void:
	if not done and _stream_open and _output != null:
		_output.end()

func _on_output_started() -> void:
	if done:
		return
	playback_started = true
	playback_began.emit()

func _on_output_finished(outcome: Dictionary) -> void:
	if done:
		return
	if outcome.get("success", false):
		finish(outcome)
	else:
		_complete(outcome, true)

func _disconnect_stream_request(request) -> void:
	for pair in [[request.stream_opened, _on_stream_open], [request.stream_chunk, _on_stream_chunk], [request.stream_ended, _on_stream_end]]:
		if pair[0].is_connected(pair[1]):
			pair[0].disconnect(pair[1])

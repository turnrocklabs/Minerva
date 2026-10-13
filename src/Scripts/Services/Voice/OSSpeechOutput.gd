class_name OSSpeechOutput
extends SpeechOutput
## Existing OS playback, isolated from the synthesis request's lifetime.

const StreamPlayback = preload("res://Scripts/Services/Voice/StreamingSpeechPlayback.gd")

var _player: AudioStreamPlayer
var _owned_stream: AudioStream
var _stream_sink: StreamPlayback


func _init(player: AudioStreamPlayer) -> void:
	_player = player


func is_available() -> bool:
	return is_instance_valid(_player)


func play(audio: PackedByteArray, volume: float) -> Dictionary:
	if not is_available():
		return VoiceServiceClient.failure("no_audio_player", "Speech player is unavailable.")
	var stream: AudioStream = VoiceServiceClient.decode_audio(audio)
	if stream == null:
		return VoiceServiceClient.failure("invalid_audio", "Speech audio could not be decoded.")
	_owned_stream = stream
	_player.stream = stream
	_player.volume_db = linear_to_db(volume)
	_player.finished.connect(_on_playback_finished)
	_player.play()
	started.emit()
	return {"success": true}


func begin(format: String, sample_rate: int, volume: float) -> Dictionary:
	if not is_available():
		return VoiceServiceClient.failure("no_audio_player", "Speech player is unavailable.")
	_stream_sink = StreamPlayback.new()
	_player.add_child(_stream_sink)
	_stream_sink.finished.connect(_on_stream_finished, CONNECT_ONE_SHOT)
	_stream_sink.started.connect(_on_stream_started, CONNECT_ONE_SHOT)
	if not _stream_sink.begin(_player, format, sample_rate, volume):
		return VoiceServiceClient.failure("unsupported_audio_stream", "Speech stream layout is unsupported.")
	return {"success": true}


func append(audio: PackedByteArray) -> bool:
	return is_instance_valid(_stream_sink) and _stream_sink.append(audio)


func end() -> void:
	if is_instance_valid(_stream_sink):
		_stream_sink.end()


func stop() -> void:
	if is_instance_valid(_stream_sink):
		if _stream_sink.finished.is_connected(_on_stream_finished):
			_stream_sink.finished.disconnect(_on_stream_finished)
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


func _on_stream_started() -> void:
	started.emit()


func _on_stream_finished(outcome: Dictionary) -> void:
	var completed: StreamPlayback = _stream_sink
	_stream_sink = null
	if is_instance_valid(completed):
		completed.queue_free()
	finished.emit(outcome)


func _on_playback_finished() -> void:
	finished.emit({"success": true})

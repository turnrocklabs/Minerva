class_name SpeechOperation
extends VoiceOperation
## Owns one summary/synthesis/playback lifetime. stop() never supplies completion.

signal finished(outcome: Dictionary)
var done := false
var playback_started := false
var _player: AudioStreamPlayer

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
	if is_instance_valid(_player):
		if _player.finished.is_connected(_on_playback_finished):
			_player.finished.disconnect(_on_playback_finished)
		_player.stop()
	_player = null
	# Mark terminal before cancel resumes pending adapter coroutines synchronously.
	if cancel_pending:
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
	_player.volume_db = linear_to_db(volume)
	_player.finished.connect(_on_playback_finished)
	playback_started = true
	_player.play()
	return true

func _on_playback_finished() -> void:
	finish({"success": true})

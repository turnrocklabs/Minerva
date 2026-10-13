class_name SpeechOutput
extends RefCounted
## A speech operation owns synthesis; its output owns playback and completion.

signal finished(outcome: Dictionary)
signal started


func _report_started() -> void:
	started.emit()


func _report_finished(outcome: Dictionary) -> void:
	finished.emit(outcome)


func is_available() -> bool:
	return false


func play(_audio: PackedByteArray, _volume: float) -> Dictionary:
	return VoiceServiceClient.failure("no_audio_player", "Speech output is unavailable.")


func begin(_format: String, _sample_rate: int, _volume: float) -> Dictionary:
	return VoiceServiceClient.failure("no_audio_player", "Speech output is unavailable.")


func append(_audio: PackedByteArray) -> bool:
	return false


func end() -> void:
	pass


func stop() -> void:
	pass

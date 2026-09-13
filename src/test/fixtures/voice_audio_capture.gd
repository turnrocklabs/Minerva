extends "res://Scripts/Models/AudioToText.gd"
## Drives the real recording-stop/conversion route without opening a microphone.

class CaptureEffect extends RefCounted:
	var recording: AudioStreamWAV
	var active := false

	func _init(value: AudioStreamWAV) -> void:
		recording = value

	func is_recording_active() -> bool:
		return active

	func get_recording() -> AudioStreamWAV:
		return recording

	func set_recording_active(value: bool) -> void:
		active = value


class NormalizationCapture extends RefCounted:
	var frames := PackedVector2Array()
	var discarded := 0

	func clear_buffer() -> void:
		# Replace the value so clearing this fake ring never mutates a caller's fixture array.
		frames = PackedVector2Array()

	func get_discarded_frames() -> int:
		return discarded

	func get_frames_available() -> int:
		return frames.size()

	func get_buffer(count: int) -> PackedVector2Array:
		if count > frames.size():
			return PackedVector2Array()
		var result := frames.slice(0, count)
		frames = frames.slice(count)
		return result


var submitted := PackedByteArray()

func _ready() -> void:
	pass

func _start_mic() -> void:
	pass

func _stop_mic() -> void:
	pass

func _start_voice_service_stt(wav_bytes: PackedByteArray, _voice_config: VoiceConfig) -> void:
	submitted = wav_bytes

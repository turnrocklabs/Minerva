extends "res://Scripts/Services/Voice/VoiceGatewayClient.gd"
## Runs gateway session transitions without microphone, HTTP, or WebSocket I/O.

var mic_starts := 0
var mic_stops := 0
var detector: FakeDetector

class FakeDetector extends Node:
	signal connected
	signal disconnected
	signal event_received(event: Dictionary)
	signal start_failed(reason: String)
	var starts := 0
	var stops := 0
	var configs: Array[Dictionary] = []
	var audio: Array[PackedByteArray] = []
	var connected_state := false

	func start(configuration: Dictionary) -> void:
		starts += 1
		configs.append(configuration.duplicate(true))
	func stop() -> void:
		stops += 1
		connected_state = false
	func update_config(configuration: Dictionary) -> void:
		configs.append(configuration.duplicate(true))
	func send_audio(pcm: PackedByteArray) -> Error:
		if not connected_state:
			return ERR_CONNECTION_ERROR
		audio.append(pcm.duplicate())
		return OK
	func emit_connected() -> void:
		connected_state = true
		connected.emit()
	func emit_disconnected() -> void:
		connected_state = false
		disconnected.emit()
	func emit_event(event: Dictionary) -> void:
		event_received.emit(event)

func _ready() -> void:
	_capture_timer = Timer.new()
	add_child(_capture_timer)
	_idle_timer = Timer.new()
	add_child(_idle_timer)
	_capture_effect = AudioEffectCapture.new()
	_setup_detector()

func _create_detector_adapter() -> Node:
	detector = FakeDetector.new()
	return detector

func _start_mic_capture() -> void:
	mic_starts += 1

func _stop_mic_capture() -> void:
	mic_stops += 1
	_input_converter = null

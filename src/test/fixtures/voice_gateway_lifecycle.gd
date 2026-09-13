extends "res://Scripts/Services/Voice/VoiceGatewayClient.gd"
## Runs gateway session transitions without microphone, HTTP, or WebSocket I/O.

var health_generations: Array[int] = []
var mic_starts := 0
var mic_stops := 0

func _ready() -> void:
	_capture_timer = Timer.new()
	add_child(_capture_timer)
	_idle_timer = Timer.new()
	add_child(_idle_timer)
	_reconnect_timer = Timer.new()
	add_child(_reconnect_timer)
	_capture_effect = AudioEffectCapture.new()

func _poll_gateway_health(generation: int) -> void:
	health_generations.append(generation)

func _start_mic_capture() -> void:
	mic_starts += 1

func _stop_mic_capture() -> void:
	mic_stops += 1
	_input_converter = null

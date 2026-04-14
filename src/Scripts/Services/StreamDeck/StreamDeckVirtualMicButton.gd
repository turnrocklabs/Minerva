class_name StreamDeckVirtualMicButton
extends Button

## Virtual mic button adapter for the Stream Deck PTT flow.
##
## Satisfies the mic_button slot in AudioToTexts.PTTRequest without rendering
## any UI. Intercepts modulate / icon / disabled property changes made by
## AudioToText and translates them into a "mic_state" WebSocket broadcast:
##
##   modulate = LIME_GREEN   → state "recording"
##   icon     = loading.png  → state "transcribing"
##   modulate = WHITE  AND
##   icon     = mic.png      → state "idle"
##
## Instantiated once per StreamDeckServer and reused across PTT sessions.
## The server holds a strong reference; call queue_free() in server.stop().

const LOADING_ICON_PATH := "res://assets/icons/loading_white-16-16.png"
const MIC_ICON_PATH := "res://assets/icons/mic_icons/microphone_24.png"

var _server: StreamDeckServer

## Internal shadow values so we can detect the combined idle condition.
var _shadow_modulate: Color = Color.WHITE
var _shadow_icon_path: String = MIC_ICON_PATH


func _init(server: StreamDeckServer) -> void:
	_server = server


## Shadow the CanvasItem modulate property so we can intercept assignments.
var modulate: Color:
	set(v):
		_shadow_modulate = v
		super.modulate = v
		_evaluate_state()
	get:
		return super.modulate


## Shadow the Button icon property so we can intercept assignments.
var icon: Texture2D:
	set(v):
		super.icon = v
		if v == null:
			_shadow_icon_path = ""
		else:
			_shadow_icon_path = v.resource_path
		_evaluate_state()
	get:
		return super.icon


## Evaluate the combined (modulate, icon) pair and broadcast mic_state.
## Called after every intercepted property write.
func _evaluate_state() -> void:
	if _server == null:
		return

	var is_lime := _shadow_modulate.is_equal_approx(Color.LIME_GREEN)
	var is_loading := _shadow_icon_path.ends_with("loading_white-16-16.png")

	if is_loading:
		_server.broadcast_mic_state("transcribing")
	elif is_lime:
		_server.broadcast_mic_state("recording")
	else:
		# WHITE modulate + mic icon (or any other icon) → idle
		_server.broadcast_mic_state("idle")

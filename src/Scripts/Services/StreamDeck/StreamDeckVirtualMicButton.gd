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

# Untyped to break the class_name cycle between this class and StreamDeckServer —
# circular class_name type references cause one side to fail class registration.
var _server: Node

## Internal shadow values so we can detect the combined idle condition.
var _shadow_modulate: Color = Color.WHITE
var _shadow_icon_path: String = MIC_ICON_PATH


func _init(server: Node) -> void:
	_server = server
	visible = false


## Intercept writes to inherited modulate / icon via the virtual _set hook.
## GDScript 4 does not permit re-declaring inherited properties with custom
## setters at class scope — that silently breaks class_name registration.
## Returning false here lets the default (inherited) setter also run.
func _set(property: StringName, value) -> bool:
	if property == &"modulate":
		_shadow_modulate = value
		_evaluate_state()
		return false
	if property == &"icon":
		if value == null:
			_shadow_icon_path = ""
		else:
			_shadow_icon_path = (value as Texture2D).resource_path
		_evaluate_state()
		return false
	return false


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

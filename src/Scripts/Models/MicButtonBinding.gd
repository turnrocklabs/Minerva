class_name MicButtonBinding
extends RefCounted

## UI adapter that translates AudioToTexts.ptt_state_changed signals into
## mic-button visuals. One binding per button, auto-attached by
## AudioToTexts.start_ptt via `attach()` and held alive through button metadata.
##
## A button reacts only when it owns the current PTT session (info.mic_button == self).
## Other bindings reset their button to READY so at most one button shows active state.

const MIC_ICON_PATH := "res://assets/icons/mic_icons/microphone_24.png"
const LOADING_ICON_PATH := "res://assets/icons/loading_white-16-16.png"
const META_KEY := &"_mic_button_binding"

var _button: BaseButton


## Idempotently attach a binding to `button`. Safe to call every start_ptt.
static func attach(button: BaseButton) -> void:
	if button == null or button.has_meta(META_KEY):
		return
	var binding := MicButtonBinding.new()
	binding._button = button
	button.set_meta(META_KEY, binding)
	var atT = SingletonObject.AtT
	if atT == null:
		return
	atT.ptt_state_changed.connect(binding._on_state_changed)
	button.tree_exited.connect(binding._on_button_freed, CONNECT_ONE_SHOT)


func _on_button_freed() -> void:
	var atT = SingletonObject.AtT
	if atT != null and atT.ptt_state_changed.is_connected(_on_state_changed):
		atT.ptt_state_changed.disconnect(_on_state_changed)


func _on_state_changed(new_state: int, info: Dictionary) -> void:
	if _button == null or not is_instance_valid(_button):
		return
	var active_btn = info.get("mic_button")
	if active_btn != _button:
		# Not our session — keep READY so only one button reflects active state.
		_apply_ready()
		return
	match new_state:
		AudioToTexts.PTTState.READY:
			_apply_ready()
		AudioToTexts.PTTState.LISTENING:
			_apply_listening()
		AudioToTexts.PTTState.TRANSCRIBING:
			_apply_transcribing()
		AudioToTexts.PTTState.ERROR:
			_apply_error()


func _apply_ready() -> void:
	_button.modulate = Color.WHITE
	_button.icon = load(MIC_ICON_PATH)
	_button.disabled = false


func _apply_listening() -> void:
	_button.modulate = Color.LIME_GREEN
	_button.icon = load(MIC_ICON_PATH)
	_button.disabled = false


func _apply_transcribing() -> void:
	_button.modulate = Color.WHITE
	_button.icon = load(LOADING_ICON_PATH)
	_button.disabled = true


func _apply_error() -> void:
	_button.modulate = Color.RED
	_button.icon = load(MIC_ICON_PATH)
	_button.disabled = false

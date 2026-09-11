extends "res://test/fixtures/plugin_catalog_chat_pane.gd"
## Render seam only; speech controller/cancellation/playback are production methods.
var released := 0
var sent_utterances: Array[String] = []
var last_status: RichTextLabel

class QuietPicker extends ProviderOptionButton:
	func _ready() -> void:
		pass

func _init() -> void:
	var controls := {
		"txtMainUserInput": TextEdit.new(), "ProviderOptionButton": QuietPicker.new(),
		"BufferControlChats": Control.new(), "AudioStop1": IconsButton.new(),
		"btnChat": Button.new(), "DynamicUIContainer": VBoxContainer.new(),
	}
	for control_name in controls:
		var control: Control = controls[control_name]
		control.name = control_name
		add_child(control)
		control.owner = self
		control.unique_name_in_owner = true

func _ready() -> void:
	pass

func _lazy_pre_warm() -> void:
	pass

func _voice_send_utterance(text: String) -> void:
	sent_utterances.append(text)
	_voice_llm_busy = true

func _voice_on_response_complete() -> void:
	released += 1
	_voice_llm_busy = false

func _create_voice_status_label(_msg_node: Control) -> RichTextLabel:
	var status := RichTextLabel.new()
	add_child(status)
	last_status = status
	return status

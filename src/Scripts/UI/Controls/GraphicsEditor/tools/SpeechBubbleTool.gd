extends BaseTool
class_name SpeechBubbleTool

var layer: LayerV2

func _tool_selected():
	pass

func handle_input_event(event: InputEvent) -> void:
	event = editor.active_layer.localize_input(event)

	if event is InputEventMouseButton:

		if event.pressed and not layer:
			
			layer = LayerV2.create_speech_bubble_layer("Layer")
			layer.custom_minimum_size = Vector2(100, 100)
			editor.add_layer(layer)


func _on_edit_mode_check_button_toggled(toggled_on: bool) -> void:
	layer.speech_bubble.editing = toggled_on
	layer.queue_redraw()


func _on_line_edit_text_changed(new_text: String) -> void:
	layer.speech_bubble.text = new_text
	layer.queue_redraw()

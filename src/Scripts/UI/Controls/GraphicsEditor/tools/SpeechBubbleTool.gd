extends BaseTool
class_name SpeechBubbleTool


func _tool_selected():
	pass

func handle_input_event(event: InputEvent) -> void:
	event = editor.active_layer.localize_input(event)

	if event is InputEventMouseButton:

		if event.pressed:
			
			var layer: = LayerV2.create_speech_bubble_layer("Layer")
			editor.add_layer(layer)

			editor.active_layer.speech_bubble.position = event.position

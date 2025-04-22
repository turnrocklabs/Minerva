class_name MultiMessageContainer extends Control


@onready var slider_container: SliderContainer = %SliderContainer



func _on_prev_button_pressed() -> void:
	%SliderContainer.previous_child()


func _on_next_button_pressed() -> void:
	%SliderContainer.next_child()

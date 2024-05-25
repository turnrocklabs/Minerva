extends Control


func _gui_input(event):

	if event.is_action_released("zoom_in", true):
		SingletonObject.zoom_ui(1)
		
		accept_event()

	if event.is_action_released("zoom_out", true):
		SingletonObject.zoom_ui(-1)
		
		accept_event()

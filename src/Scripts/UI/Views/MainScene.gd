extends Control


func _gui_input(event):

	if event.is_action_released("zoom_in", true):
		if theme.has_default_font_size():
			theme.default_font_size += 1
		else:
			theme.default_font_size = ThemeDB.fallback_font_size + 1
		
		accept_event()

	if event.is_action_released("zoom_out", true):
		if theme.has_default_font_size():
			theme.default_font_size -= 1
		else:
			theme.default_font_size = ThemeDB.fallback_font_size - 1
		
		accept_event()
